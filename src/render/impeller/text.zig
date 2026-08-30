//! Impeller implementation of the text seam (`text.zig`).
//!
//! Impeller's standalone SDK has no system-font discovery (no fontconfig), so we
//! register one TTF into an `ImpellerTypographyContext` and reference it by an alias.
//! The renderer owns a `Typography` and calls `buildParagraph` per text command, and
//! exposes `measure` to satisfy the layout engine's `text.Measurer`.
//!
//! ponytail: one hardcoded font, one size knob. Add a font stack / fontconfig lookup
//! when a project needs more than one face.

const std = @import("std");
const Io = std.Io;
const impeller = @import("bindings.zig");
const geometry = @import("../../core/geometry.zig");
const text = @import("../../core/text.zig");
const c = impeller.c;

/// Family alias we register the font under and reference in paragraph styles.
pub const family = "HUI Sans";

const font_path = text.default_font_path;

pub const Error = error{ Typography, FontLoad, FontRegister, ParagraphBuild } || std.mem.Allocator.Error;

pub const Typography = struct {
    gpa: std.mem.Allocator,
    ctx: c.ImpellerTypographyContext,
    // Font bytes must outlive the context — Impeller references the mapping, doesn't
    // necessarily copy. Freed in deinit.
    font_bytes: []u8,

    pub fn init(gpa: std.mem.Allocator, io: Io) Error!Typography {
        const ctx = c.ImpellerTypographyContextNew() orelse return Error.Typography;
        errdefer c.ImpellerTypographyContextRelease(ctx);

        // Absolute path — cwd() + openat ignores the dirfd for absolute paths.
        const bytes = Io.Dir.cwd().readFileAlloc(io, font_path, gpa, .limited(32 * 1024 * 1024)) catch
            return Error.FontLoad;
        errdefer gpa.free(bytes);

        const mapping: c.ImpellerMapping = .{ .data = bytes.ptr, .length = bytes.len, .on_release = null };
        if (!c.ImpellerTypographyContextRegisterFont(ctx, &mapping, null, family))
            return Error.FontRegister;

        return .{ .gpa = gpa, .ctx = ctx, .font_bytes = bytes };
    }

    pub fn deinit(self: *Typography) void {
        c.ImpellerTypographyContextRelease(self.ctx);
        self.gpa.free(self.font_bytes);
        self.* = undefined;
    }

    /// Lay out `str` at `size`px in `color`, returning a paragraph handle the caller
    /// draws with `DrawParagraph` and must `ImpellerParagraphRelease`. `width` is the
    /// layout/wrap width in pixels.
    pub fn buildParagraph(self: *Typography, str: []const u8, size: f32, color: geometry.Color, width: f32) Error!c.ImpellerParagraph {
        const style = c.ImpellerParagraphStyleNew() orelse return Error.ParagraphBuild;
        defer c.ImpellerParagraphStyleRelease(style);
        c.ImpellerParagraphStyleSetFontFamily(style, family);
        c.ImpellerParagraphStyleSetFontSize(style, size);

        const paint = c.ImpellerPaintNew() orelse return Error.ParagraphBuild;
        defer c.ImpellerPaintRelease(paint);
        var col: c.ImpellerColor = .{ .red = color.r, .green = color.g, .blue = color.b, .alpha = color.a, .color_space = c.kImpellerColorSpaceSRGB };
        c.ImpellerPaintSetColor(paint, &col);
        c.ImpellerParagraphStyleSetForeground(style, paint);

        const builder = c.ImpellerParagraphBuilderNew(self.ctx) orelse return Error.ParagraphBuild;
        defer c.ImpellerParagraphBuilderRelease(builder);
        c.ImpellerParagraphBuilderPushStyle(builder, style);
        c.ImpellerParagraphBuilderAddText(builder, str.ptr, @intCast(str.len));

        return c.ImpellerParagraphBuilderBuildParagraphNew(builder, width) orelse Error.ParagraphBuild;
    }

    /// Measure `str` at `size`px (unbounded width) — satisfies `text.Measurer`.
    /// Returns zeros on failure: a mis-measured label is cosmetic, not worth
    /// propagating an error through the layout pass.
    pub fn measure(self: *Typography, str: []const u8, size: f32) text.Metrics {
        const p = self.buildParagraph(str, size, .{ .r = 0, .g = 0, .b = 0 }, 1.0e6) catch return .{};
        defer c.ImpellerParagraphRelease(p);
        return .{ .w = c.ImpellerParagraphGetLongestLineWidth(p), .h = c.ImpellerParagraphGetHeight(p) };
    }
};
