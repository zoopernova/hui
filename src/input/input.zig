//! Input state (Phase 3) — mode-agnostic pointer + keyboard tracking.
//!
//! Accumulates embedder events into a per-frame snapshot both frontends read:
//! pointer position/button (with press/release edges), key held/pressed edges by
//! scancode, and this frame's typed UTF-8 text. Hit-testing lives in
//! `layout.contains`. Pointer coordinates arrive in pixels (the embedder scales for
//! HiDPI), matching the draw list / layout space.

const std = @import("std");
const geometry = @import("../core/geometry.zig");
const Point = geometry.Point;

/// Scancode space. SDL3's `SDL_SCANCODE_COUNT` is 512; sized to cover it.
pub const scancode_count = 512;

/// SDL3 scancodes for the keys widgets care about (avoids importing SDL here).
pub const key = struct {
    pub const backspace = 42;
    pub const tab = 43;
    pub const enter = 40;
    pub const escape = 41;
    pub const delete = 76;
    pub const right = 79;
    pub const left = 80;
    pub const home = 74;
    pub const end = 77;
    pub const page_up = 75;
    pub const page_down = 78;
    pub const lctrl = 224;
    pub const lshift = 225;
    pub const rctrl = 228;
    pub const rshift = 229;
    pub const a = 4;
    pub const c = 6;
    pub const v = 25;
    pub const x = 27;
};

pub const Input = struct {
    pos: Point = .{ .x = 0, .y = 0 },
    down: bool = false, // button currently held
    pressed: bool = false, // went down this frame (edge)
    released: bool = false, // went up this frame (edge)
    scroll_x: f32 = 0, // wheel delta accumulated this frame (pixels)
    scroll_y: f32 = 0,

    held: std.StaticBitSet(scancode_count) = std.StaticBitSet(scancode_count).initEmpty(),
    key_pressed: std.StaticBitSet(scancode_count) = std.StaticBitSet(scancode_count).initEmpty(),

    // UTF-8 typed this frame (bounded; overflow is dropped). Read via `typed()`.
    text_buf: [64]u8 = undefined,
    text_len: usize = 0,

    /// Clear per-frame edges. Call once before feeding this frame's events.
    pub fn beginFrame(self: *Input) void {
        self.pressed = false;
        self.released = false;
        self.scroll_x = 0;
        self.scroll_y = 0;
        self.key_pressed = std.StaticBitSet(scancode_count).initEmpty();
        self.text_len = 0;
    }

    /// Fold one embedder event into the state. Generic over the event union to keep
    /// input decoupled from the embedder module.
    pub fn feed(self: *Input, ev: anytype) void {
        switch (ev) {
            .pointer_motion => |m| self.pos = .{ .x = m.x, .y = m.y },
            .pointer_button => |b| {
                self.pos = .{ .x = b.x, .y = b.y };
                if (b.down and !self.down) self.pressed = true;
                if (!b.down and self.down) self.released = true;
                self.down = b.down;
            },
            .pointer_scroll => |s| {
                self.scroll_x += s.dx;
                self.scroll_y += s.dy;
            },
            .key => |k| {
                if (k.scancode < scancode_count) {
                    if (k.down and !self.held.isSet(k.scancode)) self.key_pressed.set(k.scancode);
                    self.held.setValue(k.scancode, k.down);
                }
            },
            .text => |t| {
                const room = self.text_buf.len - self.text_len;
                const take = @min(room, t.utf8.len);
                @memcpy(self.text_buf[self.text_len..][0..take], t.utf8[0..take]);
                self.text_len += take;
            },
            else => {},
        }
    }

    /// Is this key currently held?
    pub fn keyDown(self: *const Input, scancode: u32) bool {
        return scancode < scancode_count and self.held.isSet(scancode);
    }

    /// Did this key go down this frame (edge)?
    pub fn keyPressed(self: *const Input, scancode: u32) bool {
        return scancode < scancode_count and self.key_pressed.isSet(scancode);
    }

    /// UTF-8 text typed this frame (empty if none).
    pub fn typed(self: *const Input) []const u8 {
        return self.text_buf[0..self.text_len];
    }

    pub fn shift(self: *const Input) bool {
        return self.keyDown(key.lshift) or self.keyDown(key.rshift);
    }
    pub fn ctrl(self: *const Input) bool {
        return self.keyDown(key.lctrl) or self.keyDown(key.rctrl);
    }
};

test "pointer edges and key state" {
    var in: Input = .{};
    in.beginFrame();
    in.feed(@as(TestEv, .{ .pointer_button = .{ .x = 5, .y = 6, .down = true } }));
    try std.testing.expect(in.pressed and in.down);
    try std.testing.expectEqual(@as(f32, 5), in.pos.x);

    in.beginFrame();
    try std.testing.expect(!in.pressed and in.down); // edge cleared, still held
    in.feed(@as(TestEv, .{ .key = .{ .scancode = 40, .down = true } }));
    try std.testing.expect(in.keyPressed(40) and in.keyDown(40));

    in.beginFrame();
    try std.testing.expect(!in.keyPressed(40) and in.keyDown(40)); // edge cleared, still held
    in.feed(@as(TestEv, .{ .text = .{ .utf8 = "hi" } }));
    try std.testing.expectEqualStrings("hi", in.typed());
}

// A stand-in event union for the test (mirrors embedder.Event, so `feed`'s `else`
// prong stays reachable when instantiated for this type).
const TestEv = union(enum) {
    close_requested,
    resized: struct { width: u32, height: u32 },
    pointer_motion: struct { x: f32, y: f32 },
    pointer_button: struct { x: f32, y: f32, down: bool },
    pointer_scroll: struct { dx: f32, dy: f32 },
    key: struct { scancode: u32, down: bool },
    text: struct { utf8: []const u8 },
};
