//! Impeller Vulkan backend (Phase 0.5) — binds Impeller to an embedder's window
//! and clears the screen. Phase 1 generalizes this to consume a draw list; for now
//! it only does `clear()`.
//!
//! Setup order is dictated by Impeller's Vulkan interop: **Impeller owns the
//! `VkInstance`**. So we create the Impeller context first (feeding it the
//! embedder's `vkGetInstanceProcAddr`), read back the instance, ask the embedder to
//! make a `VkSurfaceKHR` from *that* instance, then wrap it in an Impeller swapchain.
//! Per frame the swapchain hands us an `ImpellerSurface` to draw into and present.

const std = @import("std");
const impeller = @import("../impeller.zig");
const dl = @import("../draw_list.zig");
const geometry = @import("../geometry.zig");
const text = @import("../text.zig"); // the measurement seam (no layout dependency)
const impeller_text = @import("impeller_text.zig"); // its Impeller implementation
const vk_wsi = @import("vk_wsi.zig");
const c = impeller.c;

pub const Renderer = struct {
    const Self = @This();

    gpa: std.mem.Allocator,
    context: c.ImpellerContext,
    swapchain: c.ImpellerVulkanSwapchain,
    // Impeller's VkInstance, kept so `resize()` can mint a fresh VkSurfaceKHR. The
    // swapchain owns its surface (docs), so recreating means: release swapchain
    // (destroys old surface) → new surface → new swapchain.
    vk_instance: ?*anyopaque,
    // Native-Wayland WSI shim (heap so its address is stable — Impeller keeps calling
    // into it). Patches the swapchain's surface extent from the live window size.
    shim: *vk_wsi.Shim,
    // Per-frame Impeller objects/geometry. Impeller's display list builder resolves
    // everything lazily at CreateDisplayList — the paint AND the `const ImpellerRect*`
    // / `const ImpellerPoint*` pointers — not at each Draw call. So paints and the
    // geometry structs they point at must all outlive the emit loop. Reused across
    // frames (clearRetainingCapacity). Fixed-cap geometry per command below.
    paints: std.ArrayList(c.ImpellerPaint) = .empty,
    rects: std.ArrayList(c.ImpellerRect) = .empty,
    points: std.ArrayList(c.ImpellerPoint) = .empty,
    radii: std.ArrayList(c.ImpellerRoundingRadii) = .empty,
    // Per-frame paragraph handles, released after present (same lifetime as paints).
    paragraphs: std.ArrayList(c.ImpellerParagraph) = .empty,
    typography: impeller_text.Typography,

    // ponytail: inferred error sets — the embedder is duck-typed, so its
    // createVulkanSurface error set flows through without us naming a union.
    pub const InitError = error{ NoVulkanLoader, ContextCreate, VulkanInfo, SwapchainCreate };
    pub const FrameError = error{ AcquireSurface, BuildDisplayList } || std.mem.Allocator.Error || impeller_text.Error;

    /// `embedder` is any conforming embedder pointer (duck-typed) — provides the
    /// Vulkan proc loader and surface creation.
    pub fn init(gpa: std.mem.Allocator, io: std.Io, embedder: anytype) !Self {
        // NONNULL to Impeller — guard null here rather than let it panic at the
        // C-call coercion (translate-c makes IMPELLER_NONNULL params non-optional).
        const proc_addr = embedder.vkGetInstanceProcAddr() orelse return InitError.NoVulkanLoader;

        // Install the native-Wayland WSI shim: Impeller resolves all Vulkan functions
        // through our callback, letting us patch the surface extent from the live
        // window size. `size_cb` reads the embedder's drawable size on demand.
        const E = @TypeOf(embedder);
        const size_cb = struct {
            fn f(ctx: ?*anyopaque) vk_wsi.Extent {
                const e: E = @ptrCast(@alignCast(ctx));
                const s = e.drawableSize();
                return .{ .width = s.width, .height = s.height };
            }
        }.f;
        const shim = try gpa.create(vk_wsi.Shim);
        errdefer gpa.destroy(shim);
        vk_wsi.install(shim, proc_addr, size_cb, @ptrCast(embedder));

        var settings: c.ImpellerContextVulkanSettings = .{
            .user_data = @ptrCast(shim),
            .proc_address_callback = @ptrCast(&vk_wsi.procAddr),
            .enable_vulkan_validation = false,
        };
        const context = c.ImpellerContextCreateVulkanNew(impeller.version_packed, &settings) orelse
            return InitError.ContextCreate;
        errdefer c.ImpellerContextRelease(context);

        // Read back the VkInstance Impeller created; the surface must come from it.
        var info: c.ImpellerContextVulkanInfo = undefined;
        if (!c.ImpellerContextGetVulkanInfo(context, &info)) return InitError.VulkanInfo;

        const surface_khr = try embedder.createVulkanSurface(info.vk_instance);
        const swapchain = c.ImpellerVulkanSwapchainCreateNew(context, @ptrCast(surface_khr)) orelse
            return InitError.SwapchainCreate;

        const typography = try impeller_text.Typography.init(gpa, io);

        return .{ .gpa = gpa, .context = context, .swapchain = swapchain, .vk_instance = info.vk_instance, .shim = shim, .typography = typography };
    }

    /// Recreate the swapchain against a fresh surface — call when the window
    /// resizes (and once after the first Wayland configure, which is what gives the
    /// window its real size). The old swapchain owns the old surface, so release it
    /// first, then mint a new surface + swapchain at the current window size.
    pub fn resize(self: *Self, embedder: anytype) !void {
        c.ImpellerVulkanSwapchainRelease(self.swapchain);
        const surface_khr = try embedder.createVulkanSurface(self.vk_instance);
        self.swapchain = c.ImpellerVulkanSwapchainCreateNew(self.context, @ptrCast(surface_khr)) orelse
            return InitError.SwapchainCreate;
    }

    /// A text `Measurer` bound to this renderer's typography — hand it to the layout
    /// engine so `fit` sizing can measure glyph runs.
    pub fn measurer(self: *Self) text.Measurer {
        return .{ .ctx = &self.typography, .func = measureText };
    }

    fn measureText(ctx: ?*anyopaque, str: []const u8, size: f32) text.Metrics {
        const ty: *impeller_text.Typography = @ptrCast(@alignCast(ctx));
        const m = ty.measure(str, size);
        return .{ .w = m.w, .h = m.h };
    }

    pub fn deinit(self: *Self) void {
        self.paints.deinit(self.gpa);
        self.rects.deinit(self.gpa);
        self.points.deinit(self.gpa);
        self.radii.deinit(self.gpa);
        self.paragraphs.deinit(self.gpa);
        self.typography.deinit();
        c.ImpellerVulkanSwapchainRelease(self.swapchain);
        c.ImpellerContextRelease(self.context);
        self.gpa.destroy(self.shim);
        self.* = undefined;
    }

    /// Acquire the next swapchain surface, translate `list` into Impeller draw
    /// calls, and present. This is the backend consuming the draw-list seam.
    pub fn render(self: *Self, list: *const dl.DrawList) FrameError!void {
        const surface = c.ImpellerVulkanSwapchainAcquireNextSurfaceNew(self.swapchain) orelse
            return FrameError.AcquireSurface;
        defer c.ImpellerSurfaceRelease(surface);

        const builder = c.ImpellerDisplayListBuilderNew(null) orelse return FrameError.BuildDisplayList;
        defer c.ImpellerDisplayListBuilderRelease(builder);

        // Each command gets its own paint + geometry, all kept alive until after
        // present — Impeller resolves them at CreateDisplayList, not at each Draw call.
        // Reserve up front so appends never reallocate mid-loop (which would re-dangle
        // the pointers we hand Impeller). Worst case: 1 paint+rect and 2 points/command.
        const n = list.items().len;
        self.paints.clearRetainingCapacity();
        self.rects.clearRetainingCapacity();
        self.points.clearRetainingCapacity();
        self.radii.clearRetainingCapacity();
        self.paragraphs.clearRetainingCapacity();
        try self.paints.ensureTotalCapacity(self.gpa, n);
        try self.rects.ensureTotalCapacity(self.gpa, n);
        try self.points.ensureTotalCapacity(self.gpa, n * 2);
        try self.radii.ensureTotalCapacity(self.gpa, n);
        try self.paragraphs.ensureTotalCapacity(self.gpa, n);
        defer for (self.paints.items) |p| c.ImpellerPaintRelease(p);
        defer for (self.paragraphs.items) |p| c.ImpellerParagraphRelease(p);

        for (list.items()) |cmd| try self.emit(builder, cmd);

        const display_list = c.ImpellerDisplayListBuilderCreateDisplayListNew(builder) orelse
            return FrameError.BuildDisplayList;
        defer c.ImpellerDisplayListRelease(display_list);

        _ = c.ImpellerSurfaceDrawDisplayList(surface, display_list);
        _ = c.ImpellerSurfacePresent(surface);
    }

    /// Translate one draw-list command into Impeller builder calls. Paint and
    /// geometry are stashed in `self.*` (pre-reserved) so their pointers stay valid
    /// until Impeller resolves the display list. See `render`.
    fn emit(self: *Self, builder: c.ImpellerDisplayListBuilder, cmd: dl.Command) FrameError!void {
        const paint = c.ImpellerPaintNew() orelse return FrameError.BuildDisplayList;
        self.paints.appendAssumeCapacity(paint);
        switch (cmd) {
            .background => |color| {
                setColor(paint, color);
                c.ImpellerPaintSetDrawStyle(paint, c.kImpellerDrawStyleFill);
                c.ImpellerDisplayListBuilderDrawPaint(builder, paint);
            },
            .fill_rect => |r| {
                setColor(paint, r.color);
                c.ImpellerPaintSetDrawStyle(paint, c.kImpellerDrawStyleFill);
                self.rects.appendAssumeCapacity(.{ .x = r.rect.x, .y = r.rect.y, .width = r.rect.w, .height = r.rect.h });
                c.ImpellerDisplayListBuilderDrawRect(builder, &self.rects.items[self.rects.items.len - 1], paint);
            },
            .line => |l| {
                setColor(paint, l.color);
                c.ImpellerPaintSetDrawStyle(paint, c.kImpellerDrawStyleStroke);
                c.ImpellerPaintSetStrokeWidth(paint, l.width);
                c.ImpellerPaintSetStrokeCap(paint, c.kImpellerStrokeCapRound);
                self.points.appendAssumeCapacity(.{ .x = l.from.x, .y = l.from.y });
                self.points.appendAssumeCapacity(.{ .x = l.to.x, .y = l.to.y });
                const len = self.points.items.len;
                c.ImpellerDisplayListBuilderDrawLine(builder, &self.points.items[len - 2], &self.points.items[len - 1], paint);
            },
            .rounded_rect => |r| {
                setColor(paint, r.color);
                c.ImpellerPaintSetDrawStyle(paint, c.kImpellerDrawStyleFill);
                self.rects.appendAssumeCapacity(.{ .x = r.rect.x, .y = r.rect.y, .width = r.rect.w, .height = r.rect.h });
                self.radii.appendAssumeCapacity(uniformRadii(r.radius));
                const ri = self.rects.items.len - 1;
                const di = self.radii.items.len - 1;
                c.ImpellerDisplayListBuilderDrawRoundedRect(builder, &self.rects.items[ri], &self.radii.items[di], paint);
            },
            .clip_push => |cl| {
                // Scope the clip with Save so clip_pop's Restore reverts exactly it.
                c.ImpellerDisplayListBuilderSave(builder);
                self.rects.appendAssumeCapacity(.{ .x = cl.rect.x, .y = cl.rect.y, .width = cl.rect.w, .height = cl.rect.h });
                const ri = self.rects.items.len - 1;
                if (cl.radius > 0) {
                    self.radii.appendAssumeCapacity(uniformRadii(cl.radius));
                    c.ImpellerDisplayListBuilderClipRoundedRect(builder, &self.rects.items[ri], &self.radii.items[self.radii.items.len - 1], c.kImpellerClipOperationIntersect);
                } else {
                    c.ImpellerDisplayListBuilderClipRect(builder, &self.rects.items[ri], c.kImpellerClipOperationIntersect);
                }
            },
            .clip_pop => c.ImpellerDisplayListBuilderRestore(builder),
            .text => |t| {
                // Text carries its own color via the paragraph's foreground; the paint
                // above goes unused for this command (still released with the rest).
                const paragraph = try self.typography.buildParagraph(t.str, t.size, t.color, t.width);
                self.paragraphs.appendAssumeCapacity(paragraph);
                self.points.appendAssumeCapacity(.{ .x = t.pos.x, .y = t.pos.y });
                c.ImpellerDisplayListBuilderDrawParagraph(builder, paragraph, &self.points.items[self.points.items.len - 1]);
            },
        }
    }

    fn uniformRadii(r: f32) c.ImpellerRoundingRadii {
        const p: c.ImpellerPoint = .{ .x = r, .y = r };
        return .{ .top_left = p, .top_right = p, .bottom_left = p, .bottom_right = p };
    }

    fn setColor(paint: c.ImpellerPaint, color: geometry.Color) void {
        var col: c.ImpellerColor = .{
            .red = color.r,
            .green = color.g,
            .blue = color.b,
            .alpha = color.a,
            .color_space = c.kImpellerColorSpaceSRGB,
        };
        c.ImpellerPaintSetColor(paint, &col);
    }
};
