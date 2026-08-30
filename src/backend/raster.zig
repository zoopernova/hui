//! Software raster backend — consumes the *same* `draw_list.DrawList` as the Impeller
//! backend but rasterizes into a CPU RGBA8 buffer, with no window or GPU. Its whole
//! reason to exist (ROADMAP Phase 4) is to prove the draw-list seam isn't
//! Impeller-shaped: a second, totally different backend behind the same commands.
//!
//! Coverage-AA for shapes (signed-distance rounded rects, distance-to-segment lines),
//! stb_truetype AA glyph bitmaps for text, rect clip stack. Colors are blended
//! straight in their given 0..1 values (no sRGB encode) — consistent with itself; the
//! headless tests assert against this backend's own math, not Impeller's pixels.
//!
//! ponytail (declared ceilings): rounded *clip* is approximated as a rect clip
//! (corners not rounded when clipping); diagonal-line AA is present but simple. The
//! settings-panel demo needs neither corner-case.

const std = @import("std");
const Io = std.Io;
const geometry = @import("../geometry.zig");
const dl = @import("../draw_list.zig");
const text = @import("../text.zig");
const raster_text = @import("raster_text.zig");
const stb = @import("stb.zig");
const c = stb.c;

const Rect = geometry.Rect;
const Color = geometry.Color;

pub const Error = raster_text.Error || std.mem.Allocator.Error;

pub const Raster = struct {
    gpa: std.mem.Allocator,
    w: u32,
    h: u32,
    pixels: []u8, // RGBA8, row-major, w*h*4
    font: raster_text.Font,
    clip: Rect,
    clip_stack: std.ArrayList(Rect) = .empty,

    pub fn init(gpa: std.mem.Allocator, io: Io, w: u32, h: u32) Error!Raster {
        const pixels = try gpa.alloc(u8, @as(usize, w) * h * 4);
        errdefer gpa.free(pixels);
        @memset(pixels, 0);
        const font = try raster_text.Font.init(gpa, io);
        return .{ .gpa = gpa, .w = w, .h = h, .pixels = pixels, .font = font, .clip = full(w, h) };
    }

    pub fn deinit(self: *Raster) void {
        self.font.deinit();
        self.clip_stack.deinit(self.gpa);
        self.gpa.free(self.pixels);
        self.* = undefined;
    }

    pub fn measurer(self: *Raster) text.Measurer {
        return self.font.measurer();
    }

    fn full(w: u32, h: u32) Rect {
        return .{ .x = 0, .y = 0, .w = @floatFromInt(w), .h = @floatFromInt(h) };
    }

    /// Rasterize `list` into the buffer (does not clear first — a `background`
    /// command is the frame clear, as with the Impeller backend).
    pub fn render(self: *Raster, list: *const dl.DrawList) !void {
        self.clip = full(self.w, self.h);
        self.clip_stack.clearRetainingCapacity();
        for (list.items()) |cmd| switch (cmd) {
            .background => |color| self.clear(color),
            .fill_rect => |r| self.fillRoundRect(r.rect, 0, r.color),
            .rounded_rect => |r| self.fillRoundRect(r.rect, r.radius, r.color),
            .line => |l| self.drawLine(l.from, l.to, l.width, l.color),
            .text => |t| self.drawText(t.pos, t.str, t.size, t.color),
            .clip_push => |cl| {
                try self.clip_stack.append(self.gpa, self.clip);
                self.clip = intersect(self.clip, cl.rect);
            },
            .clip_pop => {
                if (self.clip_stack.pop()) |prev| self.clip = prev;
            },
        };
    }

    // ── Pixel ops ────────────────────────────────────────────────────────────

    /// Straight-alpha "over" blend of `col` (scaled by `cov`) onto pixel (x,y),
    /// respecting bounds and the current clip (tested at the pixel center).
    fn blend(self: *Raster, x: i32, y: i32, col: Color, cov: f32) void {
        if (x < 0 or y < 0 or x >= @as(i32, @intCast(self.w)) or y >= @as(i32, @intCast(self.h))) return;
        const cx = @as(f32, @floatFromInt(x)) + 0.5;
        const cy = @as(f32, @floatFromInt(y)) + 0.5;
        if (cx < self.clip.x or cx >= self.clip.x + self.clip.w or cy < self.clip.y or cy >= self.clip.y + self.clip.h) return;
        const a = col.a * cov;
        if (a <= 0) return;
        const idx = (@as(usize, @intCast(y)) * self.w + @as(usize, @intCast(x))) * 4;
        const inv = 1 - a;
        self.pixels[idx + 0] = over(col.r, self.pixels[idx + 0], a, inv);
        self.pixels[idx + 1] = over(col.g, self.pixels[idx + 1], a, inv);
        self.pixels[idx + 2] = over(col.b, self.pixels[idx + 2], a, inv);
        const da: f32 = @as(f32, @floatFromInt(self.pixels[idx + 3])) / 255;
        self.pixels[idx + 3] = toU8(a + da * inv);
    }

    fn over(src: f32, dst_u8: u8, a: f32, inv: f32) u8 {
        const dst = @as(f32, @floatFromInt(dst_u8)) / 255;
        return toU8(src * a + dst * inv);
    }

    fn clear(self: *Raster, color: Color) void {
        const r = toU8(color.r);
        const g = toU8(color.g);
        const b = toU8(color.b);
        const a = toU8(color.a);
        var i: usize = 0;
        while (i < self.pixels.len) : (i += 4) {
            self.pixels[i + 0] = r;
            self.pixels[i + 1] = g;
            self.pixels[i + 2] = b;
            self.pixels[i + 3] = a;
        }
    }

    // ── Shapes ───────────────────────────────────────────────────────────────

    /// Fill a (optionally rounded) rect with signed-distance coverage AA. `radius`=0
    /// gives a plain AA rect.
    fn fillRoundRect(self: *Raster, rect: Rect, radius: f32, color: Color) void {
        const r = @min(radius, @min(rect.w, rect.h) / 2);
        const cx = rect.x + rect.w / 2;
        const cy = rect.y + rect.h / 2;
        const hw = rect.w / 2;
        const hh = rect.h / 2;
        var y = ffloor(rect.y - 1);
        const y1 = fceil(rect.y + rect.h + 1);
        const x1 = fceil(rect.x + rect.w + 1);
        while (y < y1) : (y += 1) {
            var x = ffloor(rect.x - 1);
            while (x < x1) : (x += 1) {
                const px = @as(f32, @floatFromInt(x)) + 0.5;
                const py = @as(f32, @floatFromInt(y)) + 0.5;
                const cov = std.math.clamp(0.5 - sdRoundRect(px, py, cx, cy, hw, hh, r), 0, 1);
                if (cov > 0) self.blend(x, y, color, cov);
            }
        }
    }

    fn sdRoundRect(px: f32, py: f32, cx: f32, cy: f32, hw: f32, hh: f32, r: f32) f32 {
        const qx = @abs(px - cx) - (hw - r);
        const qy = @abs(py - cy) - (hh - r);
        const mx = @max(qx, 0);
        const my = @max(qy, 0);
        return @sqrt(mx * mx + my * my) + @min(@max(qx, qy), 0) - r;
    }

    fn drawLine(self: *Raster, from: geometry.Point, to: geometry.Point, width: f32, color: Color) void {
        const hw = width / 2;
        const minx = ffloor(@min(from.x, to.x) - hw - 1);
        const maxx = fceil(@max(from.x, to.x) + hw + 1);
        const miny = ffloor(@min(from.y, to.y) - hw - 1);
        const maxy = fceil(@max(from.y, to.y) + hw + 1);
        var y = miny;
        while (y < maxy) : (y += 1) {
            var x = minx;
            while (x < maxx) : (x += 1) {
                const px = @as(f32, @floatFromInt(x)) + 0.5;
                const py = @as(f32, @floatFromInt(y)) + 0.5;
                const d = distSeg(px, py, from.x, from.y, to.x, to.y);
                const cov = std.math.clamp(hw + 0.5 - d, 0, 1);
                if (cov > 0) self.blend(x, y, color, cov);
            }
        }
    }

    fn distSeg(px: f32, py: f32, ax: f32, ay: f32, bx: f32, by: f32) f32 {
        const dx = bx - ax;
        const dy = by - ay;
        const len2 = dx * dx + dy * dy;
        if (len2 == 0) return @sqrt((px - ax) * (px - ax) + (py - ay) * (py - ay));
        const t = std.math.clamp(((px - ax) * dx + (py - ay) * dy) / len2, 0, 1);
        const qx = ax + t * dx;
        const qy = ay + t * dy;
        return @sqrt((px - qx) * (px - qx) + (py - qy) * (py - qy));
    }

    // ── Text ─────────────────────────────────────────────────────────────────

    fn drawText(self: *Raster, pos: geometry.Point, str: []const u8, size: f32, color: Color) void {
        const scale = self.font.scaleFor(size);
        const baseline = pos.y + @as(f32, @floatFromInt(self.font.ascent)) * scale;
        var cursor = pos.x;
        var view = std.unicode.Utf8View.init(str) catch return;
        var it = view.iterator();
        while (it.nextCodepoint()) |cp| {
            var bw: c_int = 0;
            var bh: c_int = 0;
            var xoff: c_int = 0;
            var yoff: c_int = 0;
            const bmp = c.stbtt_GetCodepointBitmap(&self.font.info, 0, scale, @intCast(cp), &bw, &bh, &xoff, &yoff);
            if (bmp != null) {
                const gx0 = @as(i32, @intFromFloat(@round(cursor))) + xoff;
                const gy0 = @as(i32, @intFromFloat(@round(baseline))) + yoff;
                var j: i32 = 0;
                while (j < bh) : (j += 1) {
                    var i: i32 = 0;
                    while (i < bw) : (i += 1) {
                        const a = @as(f32, @floatFromInt(bmp[@intCast(j * bw + i)])) / 255;
                        if (a > 0) self.blend(gx0 + i, gy0 + j, color, a);
                    }
                }
                c.stbtt_FreeBitmap(bmp, null);
            }
            var adv: c_int = 0;
            var lsb: c_int = 0;
            c.stbtt_GetCodepointHMetrics(&self.font.info, @intCast(cp), &adv, &lsb);
            cursor += @as(f32, @floatFromInt(adv)) * scale;
        }
    }

    // ── Output / inspection ────────────────────────────────────────────────────

    /// Read one pixel as RGBA bytes (for tests / spot checks).
    pub fn pixel(self: *const Raster, x: u32, y: u32) [4]u8 {
        const idx = (@as(usize, y) * self.w + x) * 4;
        return .{ self.pixels[idx], self.pixels[idx + 1], self.pixels[idx + 2], self.pixels[idx + 3] };
    }

    /// Dump the buffer as a binary PPM (P6, RGB) for eyeballing. No deps.
    pub fn writePpm(self: *const Raster, io: Io, path: []const u8) !void {
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(self.gpa);
        var hdr: [64]u8 = undefined;
        try buf.appendSlice(self.gpa, try std.fmt.bufPrint(&hdr, "P6\n{d} {d}\n255\n", .{ self.w, self.h }));
        var i: usize = 0;
        while (i < self.pixels.len) : (i += 4) {
            try buf.appendSlice(self.gpa, self.pixels[i .. i + 3]); // RGB, drop alpha
        }
        try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = buf.items });
    }
};

fn toU8(f: f32) u8 {
    return @intFromFloat(std.math.clamp(f * 255 + 0.5, 0, 255));
}
fn ffloor(f: f32) i32 {
    return @intFromFloat(@floor(f));
}
fn fceil(f: f32) i32 {
    return @intFromFloat(@ceil(f));
}
fn intersect(a: Rect, b: Rect) Rect {
    const x0 = @max(a.x, b.x);
    const y0 = @max(a.y, b.y);
    const x1 = @min(a.x + a.w, b.x + b.w);
    const y1 = @min(a.y + a.h, b.y + b.h);
    return .{ .x = x0, .y = y0, .w = @max(0, x1 - x0), .h = @max(0, y1 - y0) };
}

// ── Tests ──────────────────────────────────────────────────────────────────────

const bg_c: Color = .{ .r = 0.10, .g = 0.12, .b = 0.16 };
const red_c: Color = .{ .r = 0.90, .g = 0.20, .b = 0.10 };
const green_c: Color = .{ .r = 0.20, .g = 0.70, .b = 0.30 };
const white_c: Color = .{ .r = 1, .g = 1, .b = 1 };

test "raster renders shapes + text into the buffer (headless spot-check)" {
    const gpa = std.testing.allocator;
    var threaded: Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var r = try Raster.init(gpa, io, 100, 60);
    defer r.deinit();

    var list = dl.DrawList.init(gpa);
    defer list.deinit();
    try list.background(bg_c);
    try list.fillRect(.{ .x = 10, .y = 10, .w = 30, .h = 20 }, red_c);
    try list.roundedRect(.{ .x = 50, .y = 10, .w = 40, .h = 30 }, 8, green_c);
    try list.text(.{ .x = 8, .y = 38 }, "Hi", 20, white_c);
    try r.render(&list);

    // Background at a corner.
    try std.testing.expect(r.pixel(0, 0)[0] < 40 and r.pixel(0, 0)[2] > 30);
    // Center of the red rect is fully covered red.
    try std.testing.expect(r.pixel(25, 20)[0] > 200 and r.pixel(25, 20)[1] < 90);
    // Center of the green rounded rect.
    try std.testing.expect(r.pixel(70, 25)[1] > 150 and r.pixel(70, 25)[0] < 90);
    // Rounded corner is cut: the extreme top-left pixel of the green box is still bg.
    try std.testing.expect(r.pixel(50, 10)[1] < 90);
    // Some near-white glyph coverage exists in the text region.
    var text_hit = false;
    var yy: u32 = 30;
    while (yy < 55) : (yy += 1) {
        var xx: u32 = 8;
        while (xx < 45) : (xx += 1) {
            const p = r.pixel(xx, yy);
            if (p[0] > 180 and p[1] > 180 and p[2] > 180) text_hit = true;
        }
    }
    try std.testing.expect(text_hit);
}

test "raster clip stack hides out-of-clip draws" {
    const gpa = std.testing.allocator;
    var threaded: Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var r = try Raster.init(gpa, io, 60, 60);
    defer r.deinit();

    var list = dl.DrawList.init(gpa);
    defer list.deinit();
    try list.background(bg_c);
    try list.clipPush(.{ .x = 0, .y = 0, .w = 5, .h = 5 }, 0);
    try list.fillRect(.{ .x = 10, .y = 10, .w = 30, .h = 20 }, red_c); // fully outside clip
    try list.clipPop();
    try r.render(&list);

    // The red fill was clipped away — that region is still background.
    try std.testing.expect(r.pixel(25, 20)[0] < 40);
}
