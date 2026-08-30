//! Focus — shared keyboard-focus state used by both frontends.
//!
//! Holds the focused widget's `tag` (the same stable id used for hit-testing; 0 =
//! nothing focused). Focusable widgets call `visit(tag)` each frame in declaration
//! order so Tab / Shift-Tab can cycle; clicking a widget calls `take(tag)`, and a
//! click on empty space calls `clear()`. Key/text events route to whoever
//! `has(tag)` returns true.
//!
//! Tab is resolved against the *previous* frame's visit order (rebuilt identically
//! each frame), so `handleTab` at frame start uses the buffer already populated. A
//! fixed capacity avoids an allocator; overflow focusables just aren't Tab-reachable
//! (ponytail: 128 is far more than any real form; raise if a screen needs it).

const std = @import("std");
const input = @import("input.zig");

pub const capacity = 128;

pub const Focus = struct {
    current: u64 = 0,
    order: [capacity]u64 = undefined,
    n: usize = 0,

    /// Call once at frame start, before widgets are declared: apply a pending Tab
    /// (using last frame's order), then clear the order for this frame's rebuild.
    pub fn beginFrame(self: *Focus, in: *const input.Input) void {
        if (in.keyPressed(input.key.tab)) self.handleTab(!in.shift());
        self.n = 0;
    }

    /// Register a focusable widget (in declaration order). Also acquires focus on a
    /// left-click inside `rect` this frame.
    pub fn visit(self: *Focus, tag: u64, rect_hit: bool, pressed: bool) void {
        if (self.n < capacity) {
            self.order[self.n] = tag;
            self.n += 1;
        }
        if (pressed and rect_hit) self.current = tag;
    }

    pub fn has(self: *const Focus, tag: u64) bool {
        return self.current != 0 and self.current == tag;
    }

    pub fn clear(self: *Focus) void {
        self.current = 0;
    }

    fn handleTab(self: *Focus, forward: bool) void {
        if (self.n == 0) return;
        // Index of the currently-focused tag in last frame's order, or none.
        var idx: ?usize = null;
        for (self.order[0..self.n], 0..) |t, i| {
            if (t == self.current) idx = i;
        }
        const next: usize = if (idx) |i|
            (if (forward) (i + 1) % self.n else (i + self.n - 1) % self.n)
        else
            (if (forward) 0 else self.n - 1);
        self.current = self.order[next];
    }
};

test "tab cycles focus in visit order, shift-tab reverses" {
    var f: Focus = .{};

    // Runs one frame: apply pending Tab, then re-declare the three focusables.
    const Frame = struct {
        fn run(fp: *Focus, tab: bool, shift: bool) void {
            var in: input.Input = .{};
            if (tab) in.key_pressed.set(input.key.tab);
            if (shift) in.held.set(input.key.lshift);
            fp.beginFrame(&in);
            fp.visit(10, false, false);
            fp.visit(20, false, false);
            fp.visit(30, false, false);
        }
    };

    Frame.run(&f, false, false);
    try std.testing.expectEqual(@as(u64, 0), f.current);
    Frame.run(&f, true, false); // Tab → first
    try std.testing.expectEqual(@as(u64, 10), f.current);
    Frame.run(&f, true, false); // Tab → next
    try std.testing.expectEqual(@as(u64, 20), f.current);
    Frame.run(&f, true, true); // Shift-Tab → back
    try std.testing.expectEqual(@as(u64, 10), f.current);
}
