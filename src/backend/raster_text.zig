//! stb_truetype implementation of the text seam (`text.zig`) for the software-raster
//! backend. Loads the same TTF as the Impeller path, measures glyph runs for layout,
//! and exposes the `stbtt_fontinfo` + scale so the raster backend can rasterize and
//! blit glyph coverage bitmaps itself.

const std = @import("std");
const Io = std.Io;
const geometry = @import("../geometry.zig");
const text = @import("../text.zig");
const stb = @import("stb.zig");
const c = stb.c;

pub const Error = error{ FontLoad, FontInit } || std.mem.Allocator.Error;

pub const Font = struct {
    gpa: std.mem.Allocator,
    info: c.stbtt_fontinfo,
    bytes: []u8, // must outlive `info` (stb keeps a pointer into it)
    ascent: i32,
    descent: i32,
    line_gap: i32,

    pub fn init(gpa: std.mem.Allocator, io: Io) Error!Font {
        const bytes = Io.Dir.cwd().readFileAlloc(io, text.default_font_path, gpa, .limited(32 * 1024 * 1024)) catch
            return Error.FontLoad;
        errdefer gpa.free(bytes);

        var info: c.stbtt_fontinfo = undefined;
        const off = c.stbtt_GetFontOffsetForIndex(bytes.ptr, 0);
        if (c.stbtt_InitFont(&info, bytes.ptr, off) == 0) return Error.FontInit;

        var a: c_int = 0;
        var d: c_int = 0;
        var lg: c_int = 0;
        c.stbtt_GetFontVMetrics(&info, &a, &d, &lg);
        return .{ .gpa = gpa, .info = info, .bytes = bytes, .ascent = a, .descent = d, .line_gap = lg };
    }

    pub fn deinit(self: *Font) void {
        self.gpa.free(self.bytes);
        self.* = undefined;
    }

    pub fn scaleFor(self: *const Font, px: f32) f32 {
        return c.stbtt_ScaleForPixelHeight(@constCast(&self.info), px);
    }

    /// Satisfies `text.Measurer`: run width = Σ advances × scale; height = the font's
    /// ascent−descent scaled (single line — matches the single-line text we render).
    pub fn measure(self: *Font, str: []const u8, px: f32) text.Metrics {
        const scale = self.scaleFor(px);
        var w: f32 = 0;
        var view = std.unicode.Utf8View.init(str) catch return .{};
        var it = view.iterator();
        while (it.nextCodepoint()) |cp| {
            var adv: c_int = 0;
            var lsb: c_int = 0;
            c.stbtt_GetCodepointHMetrics(&self.info, @intCast(cp), &adv, &lsb);
            w += @as(f32, @floatFromInt(adv)) * scale;
        }
        const h = @as(f32, @floatFromInt(self.ascent - self.descent)) * scale;
        return .{ .w = w, .h = h };
    }

    pub fn measurer(self: *Font) text.Measurer {
        return .{ .ctx = self, .func = measureThunk };
    }

    fn measureThunk(ctx: ?*anyopaque, str: []const u8, px: f32) text.Metrics {
        const self: *Font = @ptrCast(@alignCast(ctx));
        return self.measure(str, px);
    }
};
