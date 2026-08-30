//! SDL3 embedder (Phase 0.4) — the first per-target adapter, for Linux/Wayland.
//!
//! Owns an SDL3 Vulkan-capable window and maps SDL events to HUI `Event`s. Provides
//! the surface plumbing Impeller's Vulkan interop needs: the `vkGetInstanceProcAddr`
//! pointer (so Impeller can build its instance) and `VkSurfaceKHR` creation from
//! Impeller's instance. Per-frame acquire/present is the Impeller swapchain's job
//! (backend, 0.5) — not here.
//!
//! SDL3 is linked as a system library (3.4.x). Vulkan handle types come from SDL's
//! own `SDL_vulkan.h` typedefs, so no Vulkan headers are needed here. The backend
//! (0.5) reuses `c` from this file to keep Vulkan handle ABI identical across the
//! embedder/backend boundary.

const std = @import("std");
const contract = @import("../embedder.zig");
const clip = @import("../clipboard.zig");
const Config = contract.Config;
const Event = contract.Event;
const Extent = contract.Extent;

pub const c = @cImport({
    @cInclude("SDL3/SDL.h");
    @cInclude("SDL3/SDL_vulkan.h");
});

pub const Sdl3 = struct {
    const Self = @This();

    window: *c.SDL_Window,
    // Last SDL_GetClipboardText result (SDL-allocated); freed on the next get / deinit.
    clip_last: ?[*c]u8 = null,

    pub const Error = error{
        SdlInit,
        CreateWindow,
        VulkanSurface,
    };

    pub fn init(gpa: std.mem.Allocator, config: Config) Error!Self {
        _ = gpa; // SDL manages its own allocations; kept for contract uniformity.
        // Native Wayland. Impeller's swapchain can't size itself here (Wayland reports
        // an undefined surface extent); the backend's WSI shim patches that from the
        // window size. See src/backend/vk_wsi.zig.
        // ponytail: library code returns errors, it doesn't log to global stderr —
        // the caller reports. `lastError()` exposes SDL's message for those who want it.
        if (!c.SDL_Init(c.SDL_INIT_VIDEO)) return Error.SdlInit;
        errdefer c.SDL_Quit();

        const flags: c.SDL_WindowFlags = c.SDL_WINDOW_VULKAN | c.SDL_WINDOW_RESIZABLE;
        const window = c.SDL_CreateWindow(
            config.title.ptr,
            @intCast(config.width),
            @intCast(config.height),
            flags,
        ) orelse return Error.CreateWindow;
        _ = c.SDL_RaiseWindow(window); // bring to front + request focus on open
        _ = c.SDL_StartTextInput(window); // enable SDL_EVENT_TEXT_INPUT (keyboard text)
        return .{ .window = window };
    }

    /// SDL's last error string (valid until the next SDL call). For callers that
    /// want to report why an `Error` came back.
    pub fn lastError() [*:0]const u8 {
        return c.SDL_GetError();
    }

    pub fn deinit(self: *Self) void {
        if (self.clip_last) |p| c.SDL_free(p);
        c.SDL_DestroyWindow(self.window);
        c.SDL_Quit();
        self.* = undefined;
    }

    /// A `Clipboard` seam backed by SDL's system clipboard (for the text field).
    pub fn clipboard(self: *Self) clip.Clipboard {
        return .{ .ctx = self, .get_fn = clipGet, .set_fn = clipSet };
    }

    fn clipGet(ctx: ?*anyopaque) []const u8 {
        const self: *Self = @ptrCast(@alignCast(ctx));
        if (self.clip_last) |p| c.SDL_free(p); // free the previous result
        self.clip_last = c.SDL_GetClipboardText(); // never null; "" if empty
        return std.mem.span(self.clip_last.?);
    }

    fn clipSet(ctx: ?*anyopaque, text: []const u8) void {
        _ = ctx;
        // SDL copies the string; give it a NUL-terminated bounded copy.
        var buf: [1024:0]u8 = undefined;
        const nlen = @min(text.len, buf.len);
        @memcpy(buf[0..nlen], text[0..nlen]);
        buf[nlen] = 0;
        _ = c.SDL_SetClipboardText(&buf);
    }

    /// Drain SDL's event queue into `buf`, returning the filled slice. Only the
    /// events HUI cares about in Phase 0 are surfaced; the rest are dropped.
    pub fn pollEvents(self: *Self, buf: []Event) []Event {
        // Logical points → pixels, so pointer coords share the draw list's space
        // (correct hit-testing on HiDPI, where density != 1).
        const density = c.SDL_GetWindowPixelDensity(self.window);
        var n: usize = 0;
        var ev: c.SDL_Event = undefined;
        while (n < buf.len and c.SDL_PollEvent(&ev)) {
            switch (ev.type) {
                c.SDL_EVENT_QUIT => {
                    buf[n] = .close_requested;
                    n += 1;
                },
                c.SDL_EVENT_WINDOW_RESIZED => {
                    buf[n] = .{ .resized = .{
                        .width = @intCast(@max(0, ev.window.data1)),
                        .height = @intCast(@max(0, ev.window.data2)),
                    } };
                    n += 1;
                },
                c.SDL_EVENT_MOUSE_MOTION => {
                    buf[n] = .{ .pointer_motion = .{ .x = ev.motion.x * density, .y = ev.motion.y * density } };
                    n += 1;
                },
                c.SDL_EVENT_MOUSE_BUTTON_DOWN, c.SDL_EVENT_MOUSE_BUTTON_UP => {
                    if (ev.button.button == c.SDL_BUTTON_LEFT) {
                        buf[n] = .{ .pointer_button = .{
                            .x = ev.button.x * density,
                            .y = ev.button.y * density,
                            .down = ev.type == c.SDL_EVENT_MOUSE_BUTTON_DOWN,
                        } };
                        n += 1;
                    }
                },
                c.SDL_EVENT_KEY_DOWN, c.SDL_EVENT_KEY_UP => {
                    buf[n] = .{ .key = .{
                        .scancode = @intCast(ev.key.scancode),
                        .down = ev.type == c.SDL_EVENT_KEY_DOWN,
                    } };
                    n += 1;
                },
                c.SDL_EVENT_MOUSE_WHEEL => {
                    // Wheel deltas are in "lines"; scale to pixels for scroll offset.
                    buf[n] = .{ .pointer_scroll = .{ .dx = ev.wheel.x * 40, .dy = ev.wheel.y * 40 } };
                    n += 1;
                },
                c.SDL_EVENT_TEXT_INPUT => {
                    buf[n] = .{ .text = .{ .utf8 = std.mem.span(ev.text.text) } };
                    n += 1;
                },
                else => {},
            }
        }
        return buf[0..n];
    }

    /// The Vulkan loader entry point, for Impeller's `proc_address_callback`.
    /// Returned opaque; the backend casts it to Impeller's callback type (0.5).
    pub fn vkGetInstanceProcAddr(self: *Self) ?*const anyopaque {
        _ = self;
        return @ptrCast(c.SDL_Vulkan_GetVkGetInstanceProcAddr());
    }

    /// Create a `VkSurfaceKHR` for this window from `instance` (Impeller's
    /// `VkInstance`, passed opaque). Returned opaque as the surface handle.
    pub fn createVulkanSurface(self: *Self, instance: ?*anyopaque) Error!?*anyopaque {
        var surface: c.VkSurfaceKHR = null;
        if (!c.SDL_Vulkan_CreateSurface(self.window, @ptrCast(instance), null, &surface)) {
            return Error.VulkanSurface;
        }
        return @ptrCast(surface);
    }

    /// Drawable size in pixels (not screen coords) — what the swapchain sizes to.
    pub fn drawableSize(self: *Self) Extent {
        var w: c_int = 0;
        var h: c_int = 0;
        _ = c.SDL_GetWindowSizeInPixels(self.window, &w, &h);
        return .{ .width = @intCast(@max(0, w)), .height = @intCast(@max(0, h)) };
    }
};

test "Sdl3 satisfies the embedder contract" {
    // Comptime only — no window opened (keeps the test headless-safe). A real
    // window smoke test lives in main.zig (0.6).
    comptime contract.assertEmbedder(Sdl3);
}
