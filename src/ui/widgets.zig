//! Widgets (Phase 4) — checkbox, slider, single-line text field, scroll container.
//!
//! Each widget is a small persistent subtree of `layout.Node`s built once; its
//! `update(...)` mutates state from input each frame and reflects it by tweaking node
//! fields in place (grow weights, bg, text, absolute positions) — no per-frame
//! allocation, no tree diffing. Thumb/caret positions ride the flex engine: e.g. a
//! slider is `[grow=value] [thumb] [grow=1-value]`, so moving the value just re-weights
//! two spacers. Frontend-agnostic: the retained frontend registers these and calls
//! `Widget.update` each frame; an immediate wrapper can reuse the same logic via a
//! per-tag state cache.
//!
//! Text-field ceiling (declared in the Phase 4 grill): single line; caret indices are
//! byte offsets (fine for Latin text — not grapheme-correct); no IME/bidi/undo.

const std = @import("std");
const layout = @import("../core/layout.zig");
const geometry = @import("../core/geometry.zig");
const input = @import("../input/input.zig");
const focusmod = @import("../input/focus.zig");
const clipboardmod = @import("../input/clipboard.zig");
const text = @import("../core/text.zig");
const Node = layout.Node;
const Color = geometry.Color;

pub const theme = struct {
    pub const field_bg: Color = .{ .r = 0.16, .g = 0.18, .b = 0.23 };
    pub const track: Color = .{ .r = 0.24, .g = 0.27, .b = 0.34 };
    pub const accent: Color = .{ .r = 0.30, .g = 0.62, .b = 0.95 };
    pub const fg: Color = .{ .r = 0.92, .g = 0.95, .b = 1.0 };
    pub const thumb: Color = .{ .r = 0.55, .g = 0.60, .b = 0.70 };
    pub const sel: Color = .{ .r = 0.20, .g = 0.35, .b = 0.55 };
};

/// A live widget the frontend updates each frame. Built by the `build*` helpers.
pub const Widget = union(enum) {
    checkbox: Checkbox,
    slider: Slider,
    text_field: TextField,
    scroll: Scroll,

    pub fn update(self: *Widget, in: *const input.Input, foc: *focusmod.Focus, clip: ?clipboardmod.Clipboard, m: layout.Measurer) void {
        switch (self.*) {
            .checkbox => |*w| w.update(in),
            .slider => |*w| w.update(in),
            .text_field => |*w| w.update(in, foc, clip, m),
            .scroll => |*w| w.update(in),
        }
    }

    /// Register the widget with focus (in declaration order) if it's focusable.
    pub fn visitFocus(self: *Widget, in: *const input.Input, foc: *focusmod.Focus) void {
        switch (self.*) {
            .text_field => |*w| foc.visit(w.tag, layout.contains(w.box.rect, in.pos), in.pressed),
            else => {},
        }
    }
};

// ── Checkbox ─────────────────────────────────────────────────────────────────

pub const Checkbox = struct {
    value: *bool,
    box: *Node,
    check: *Node,

    /// Build a 22px check box under `parent`. `tag` identifies it for hit-testing.
    pub fn build(gpa: std.mem.Allocator, parent: *Node, value: *bool, tag: u64) !Checkbox {
        const box = try parent.add(gpa, .{
            .style = .{ .w = .{ .fixed = 22 }, .h = .{ .fixed = 22 }, .pad = 4 },
            .bg = theme.field_bg,
            .bg_radius = 5,
            .tag = tag,
        });
        const check = try box.add(gpa, .{ .style = .{ .w = .{ .grow = 1 }, .h = .{ .grow = 1 } }, .bg_radius = 2 });
        return .{ .value = value, .box = box, .check = check };
    }

    pub fn update(self: *Checkbox, in: *const input.Input) void {
        if (in.pressed and layout.contains(self.box.rect, in.pos)) self.value.* = !self.value.*;
        self.check.bg = if (self.value.*) theme.accent else null;
    }
};

// ── Slider ───────────────────────────────────────────────────────────────────

pub const Slider = struct {
    value: *f32, // 0..1
    track: *Node,
    left: *Node,
    right: *Node,
    dragging: bool = false,

    pub fn build(gpa: std.mem.Allocator, parent: *Node, value: *f32, tag: u64) !Slider {
        const track = try parent.add(gpa, .{
            .style = .{ .axis = .row, .w = .{ .grow = 1 }, .h = .{ .fixed = 20 }, .pad = 6, .cross = .center },
            .bg = theme.track,
            .bg_radius = 10,
            .tag = tag,
        });
        const left = try track.add(gpa, .{ .style = .{ .w = .{ .grow = 0.0001 } } });
        _ = try track.add(gpa, .{ .style = .{ .w = .{ .fixed = 14 }, .h = .{ .fixed = 14 } }, .bg = theme.fg, .bg_radius = 7 });
        const right = try track.add(gpa, .{ .style = .{ .w = .{ .grow = 0.9999 } } });
        return .{ .value = value, .track = track, .left = left, .right = right };
    }

    pub fn update(self: *Slider, in: *const input.Input) void {
        const r = self.track.rect;
        if (in.pressed and layout.contains(r, in.pos)) self.dragging = true;
        if (!in.down) self.dragging = false;
        if (self.dragging and r.w > 0) self.value.* = std.math.clamp((in.pos.x - r.x) / r.w, 0, 1);
        // Reflect value by re-weighting the two spacers around the thumb.
        self.left.style.w = .{ .grow = @max(@as(f32, 0.0001), self.value.*) };
        self.right.style.w = .{ .grow = @max(@as(f32, 0.0001), 1 - self.value.*) };
    }
};

// ── Text field ───────────────────────────────────────────────────────────────

pub const TextField = struct {
    buf: [256]u8 = undefined,
    len: usize = 0,
    caret: usize = 0,
    anchor: ?usize = null, // selection anchor; selection is [min,max) with caret at one end
    size: f32 = 24,
    tag: u64,
    box: *Node,
    textn: *Node,
    caretn: *Node,
    seln: *Node,

    pub fn build(gpa: std.mem.Allocator, parent: *Node, tag: u64, size: f32) !TextField {
        const box = try parent.add(gpa, .{
            .style = .{ .w = .{ .grow = 1 }, .h = .{ .fixed = size + 14 }, .pad = 7 },
            .bg = theme.field_bg,
            .bg_radius = 5,
            .tag = tag,
        });
        // Selection highlight (behind text), the text, and the caret — all absolute so
        // their x is driven by measured widths in `update`.
        const seln = try box.add(gpa, .{ .style = .{ .pos = .{ .x = 0, .y = 0 }, .w = .{ .fixed = 0 }, .h = .{ .fixed = size } }, .bg = theme.sel, .bg_radius = 2 });
        const textn = try box.add(gpa, .{ .style = .{ .pos = .{ .x = 0, .y = 0 } }, .content = .{ .text = .{ .str = "", .size = size, .color = theme.fg } } });
        const caretn = try box.add(gpa, .{ .style = .{ .pos = .{ .x = 0, .y = 0 }, .w = .{ .fixed = 2 }, .h = .{ .fixed = size } } });
        return .{ .tag = tag, .size = size, .box = box, .textn = textn, .caretn = caretn, .seln = seln };
    }

    fn str(self: *TextField) []const u8 {
        return self.buf[0..self.len];
    }

    fn selRange(self: *TextField) ?[2]usize {
        const a = self.anchor orelse return null;
        if (a == self.caret) return null;
        return .{ @min(a, self.caret), @max(a, self.caret) };
    }

    fn deleteRange(self: *TextField, lo: usize, hi: usize) void {
        std.mem.copyForwards(u8, self.buf[lo..], self.buf[hi..self.len]);
        self.len -= (hi - lo);
        self.caret = lo;
        self.anchor = null;
    }

    fn deleteSelection(self: *TextField) bool {
        if (self.selRange()) |s| {
            self.deleteRange(s[0], s[1]);
            return true;
        }
        return false;
    }

    fn insert(self: *TextField, bytes: []const u8) void {
        _ = self.deleteSelection();
        const n = @min(bytes.len, self.buf.len - self.len);
        if (n == 0) return;
        std.mem.copyBackwards(u8, self.buf[self.caret + n .. self.len + n], self.buf[self.caret..self.len]);
        @memcpy(self.buf[self.caret .. self.caret + n], bytes[0..n]);
        self.len += n;
        self.caret += n;
        self.anchor = null;
    }

    fn moveCaret(self: *TextField, to: usize, selecting: bool) void {
        if (selecting) {
            if (self.anchor == null) self.anchor = self.caret;
        } else self.anchor = null;
        self.caret = to;
    }

    pub fn update(self: *TextField, in: *const input.Input, foc: *focusmod.Focus, clip: ?clipboardmod.Clipboard, m: layout.Measurer) void {
        const focused = foc.has(self.tag);
        // Click to place caret (only when the click lands in the box).
        if (in.pressed and layout.contains(self.box.rect, in.pos)) {
            self.caret = self.indexAt(in.pos.x, m);
            self.anchor = null;
        }
        if (focused) self.edit(in, clip, m);

        // Reflect state into the nodes.
        self.textn.content = .{ .text = .{ .str = self.str(), .size = self.size, .color = theme.fg } };
        const caret_x = m.measure(self.buf[0..self.caret], self.size).w;
        self.caretn.style.pos = .{ .x = caret_x, .y = 0 };
        self.caretn.bg = if (focused) theme.accent else null;
        if (self.selRange()) |s| {
            const x0 = m.measure(self.buf[0..s[0]], self.size).w;
            const x1 = m.measure(self.buf[0..s[1]], self.size).w;
            self.seln.style.pos = .{ .x = x0, .y = 0 };
            self.seln.style.w = .{ .fixed = x1 - x0 };
            self.seln.bg = theme.sel;
        } else self.seln.bg = null;
    }

    fn edit(self: *TextField, in: *const input.Input, clip: ?clipboardmod.Clipboard, m: layout.Measurer) void {
        _ = m;
        const k = input.key;
        // Typed text (respects an active selection).
        if (in.typed().len > 0) self.insert(in.typed());

        if (in.ctrl()) {
            if (in.keyPressed(k.a)) {
                self.anchor = 0;
                self.caret = self.len;
            }
            if (in.keyPressed(k.c)) if (self.selRange()) |s| if (clip) |cb| cb.set(self.buf[s[0]..s[1]]);
            if (in.keyPressed(k.x)) if (self.selRange()) |s| {
                if (clip) |cb| cb.set(self.buf[s[0]..s[1]]);
                self.deleteRange(s[0], s[1]);
            };
            if (in.keyPressed(k.v)) if (clip) |cb| self.insert(cb.get());
            return;
        }

        if (in.keyPressed(k.backspace)) {
            if (!self.deleteSelection() and self.caret > 0) self.deleteRange(self.caret - 1, self.caret);
        }
        if (in.keyPressed(k.delete)) {
            if (!self.deleteSelection() and self.caret < self.len) self.deleteRange(self.caret, self.caret + 1);
        }
        if (in.keyPressed(k.left) and self.caret > 0) self.moveCaret(self.caret - 1, in.shift());
        if (in.keyPressed(k.right) and self.caret < self.len) self.moveCaret(self.caret + 1, in.shift());
        if (in.keyPressed(k.home)) self.moveCaret(0, in.shift());
        if (in.keyPressed(k.end)) self.moveCaret(self.len, in.shift());
    }

    /// Byte index whose caret x is nearest `x_px` (box-relative measurement).
    fn indexAt(self: *TextField, x_px: f32, m: layout.Measurer) usize {
        const rel = x_px - (self.box.rect.x + self.box.style.pad);
        var best: usize = 0;
        var best_d: f32 = std.math.floatMax(f32);
        var i: usize = 0;
        while (i <= self.len) : (i += 1) {
            const w = m.measure(self.buf[0..i], self.size).w;
            const d = @abs(w - rel);
            if (d < best_d) {
                best_d = d;
                best = i;
            }
        }
        return best;
    }
};

// ── Scroll container ───────────────────────────────────────────────────────────

pub const Scroll = struct {
    offset: f32 = 0,
    view: *Node, // clipping viewport
    content: *Node, // scrolled child (absolute pos.y = -offset)
    thumb: *Node,
    dragging: bool = false,
    drag_start_off: f32 = 0,
    drag_start_y: f32 = 0,

    /// Build a scroll viewport under `parent`. Returns the container plus the
    /// `content` node the caller fills with rows.
    pub fn build(gpa: std.mem.Allocator, parent: *Node, tag: u64) !Scroll {
        const view = try parent.add(gpa, .{
            .style = .{ .w = .{ .grow = 1 }, .h = .{ .grow = 1 }, .clip = true },
            .bg = theme.field_bg,
            .bg_radius = 6,
            .tag = tag,
        });
        const content = try view.add(gpa, .{ .style = .{ .pos = .{ .x = 0, .y = 0 }, .w = .{ .grow = 1 }, .pad = 8, .gap = 6 } });
        const thumb = try view.add(gpa, .{ .style = .{ .pos = .{ .x = 0, .y = 0 }, .w = .{ .fixed = 6 }, .h = .{ .fixed = 0 } }, .bg_radius = 3 });
        return .{ .view = view, .content = content, .thumb = thumb };
    }

    pub fn update(self: *Scroll, in: *const input.Input) void {
        const vr = self.view.rect;
        const content_h = self.content.measured.h;
        const view_h = vr.h;
        const maxoff = @max(@as(f32, 0), content_h - view_h);

        if (in.scroll_y != 0 and layout.contains(vr, in.pos)) self.offset -= in.scroll_y;

        // Scrollbar thumb geometry + drag.
        if (maxoff > 0) {
            const th = @max(@as(f32, 20), view_h * (view_h / content_h));
            const track_span = view_h - th;
            if (in.pressed and layout.contains(self.thumb.rect, in.pos)) {
                self.dragging = true;
                self.drag_start_off = self.offset;
                self.drag_start_y = in.pos.y;
            }
            if (!in.down) self.dragging = false;
            if (self.dragging and track_span > 0) {
                self.offset = self.drag_start_off + (in.pos.y - self.drag_start_y) * (maxoff / track_span);
            }
            self.offset = std.math.clamp(self.offset, 0, maxoff);
            const ty = if (track_span > 0) (self.offset / maxoff) * track_span else 0;
            self.thumb.style.pos = .{ .x = vr.w - 8, .y = ty };
            self.thumb.style.h = .{ .fixed = th };
            self.thumb.bg = theme.thumb;
        } else {
            self.offset = 0;
            self.thumb.bg = null;
        }
        self.content.style.pos = .{ .x = 0, .y = -self.offset };
    }
};
