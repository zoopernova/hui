//! Retained frontend (Phase 3) — a persistent widget tree with click callbacks.
//!
//! Build the tree once (nodes live until `deinit`); each frame `frame()` re-lays-out,
//! dispatches clicks to handlers, and re-emits the draw list. State changes happen in
//! handlers, which mutate app state (and node content, e.g. a label's text).
//!
//! Invalidation today is "re-layout the whole tree each frame" — correct, and
//! microseconds for normal trees. Rung-2 (dirty-flag + subtree skip + constraint
//! cache) and the SAC north star (see ROADMAP D3) slot in behind `frame()` without
//! changing this API.

const std = @import("std");
const layout = @import("layout.zig");
const paint = @import("paint.zig");
const dl = @import("draw_list.zig");
const geometry = @import("geometry.zig");
const input = @import("input.zig");
const focusmod = @import("focus.zig");
const clipboardmod = @import("clipboard.zig");
const wids = @import("widgets.zig");
const Node = layout.Node;

pub const Handler = struct {
    func: *const fn (ctx: ?*anyopaque) void,
    ctx: ?*anyopaque = null,
};

const btn_bg: geometry.Color = .{ .r = 0.22, .g = 0.25, .b = 0.32 };
const btn_fg: geometry.Color = .{ .r = 0.95, .g = 0.97, .b = 1.0 };

pub const Tree = struct {
    gpa: std.mem.Allocator,
    root: Node,
    handlers: std.AutoHashMapUnmanaged(u64, Handler) = .empty,
    widgets: std.ArrayList(*wids.Widget) = .empty,
    focus: focusmod.Focus = .{},
    next_tag: u64 = 1,

    pub fn init(gpa: std.mem.Allocator, root_style: layout.Style) Tree {
        return .{ .gpa = gpa, .root = .{ .style = root_style } };
    }

    pub fn deinit(self: *Tree) void {
        for (self.widgets.items) |w| self.gpa.destroy(w);
        self.widgets.deinit(self.gpa);
        self.root.deinitTree(self.gpa);
        self.handlers.deinit(self.gpa);
        self.* = undefined;
    }

    fn newTag(self: *Tree) u64 {
        const t = self.next_tag;
        self.next_tag += 1;
        return t;
    }

    fn addWidget(self: *Tree, w: wids.Widget) !*wids.Widget {
        const box = try self.gpa.create(wids.Widget);
        box.* = w;
        try self.widgets.append(self.gpa, box);
        return box;
    }

    /// A toggle bound to `value`.
    pub fn checkbox(self: *Tree, parent: *Node, value: *bool) !void {
        _ = try self.addWidget(.{ .checkbox = try wids.Checkbox.build(self.gpa, parent, value, self.newTag()) });
    }

    /// A 0..1 slider bound to `value`.
    pub fn slider(self: *Tree, parent: *Node, value: *f32) !void {
        _ = try self.addWidget(.{ .slider = try wids.Slider.build(self.gpa, parent, value, self.newTag()) });
    }

    /// A single-line text field. Returns the widget so the app can read `.text_field`.
    pub fn textField(self: *Tree, parent: *Node, size: f32) !*wids.Widget {
        return self.addWidget(.{ .text_field = try wids.TextField.build(self.gpa, parent, self.newTag(), size) });
    }

    /// A scrollable viewport. Returns the widget; add rows to `.scroll.content`.
    pub fn scroll(self: *Tree, parent: *Node) !*wids.Widget {
        return self.addWidget(.{ .scroll = try wids.Scroll.build(self.gpa, parent, self.newTag()) });
    }

    /// Attach a click handler to `node` (assigns it a unique tag).
    pub fn onClick(self: *Tree, node: *Node, h: Handler) !void {
        const tag = self.next_tag;
        self.next_tag += 1;
        node.tag = tag;
        try self.handlers.put(self.gpa, tag, h);
    }

    /// Convenience: append a padded button (bg + centered-ish text label) under
    /// `parent` and wire its click handler. Returns the button node.
    pub fn button(self: *Tree, parent: *Node, label: []const u8, size: f32, h: Handler) !*Node {
        const b = try parent.add(self.gpa, .{ .style = .{ .pad = 10 }, .bg = btn_bg });
        _ = try b.add(self.gpa, .{ .content = .{ .text = .{ .str = label, .size = size, .color = btn_fg } } });
        try self.onClick(b, h);
        return b;
    }

    /// One frame. Widget state + focus are resolved *before* layout (hit-testing on
    /// the previous frame's rects, immediate-mode style) so the style tweaks widgets
    /// make — grow weights, caret/thumb positions, sizes — are reflected by *this*
    /// frame's layout rather than lagging one frame. `clip` is optional (text-field
    /// cut/copy/paste); pass `null` if the app has no clipboard.
    pub fn frame(self: *Tree, area: geometry.Rect, m: layout.Measurer, in: *const input.Input, clip: ?clipboardmod.Clipboard, list: *dl.DrawList) !void {
        self.focus.beginFrame(in);
        if (in.pressed) self.focus.clear(); // click clears focus; a field click re-takes it below
        for (self.widgets.items) |w| w.visitFocus(in, &self.focus);
        for (self.widgets.items) |w| w.update(in, &self.focus, clip, m);
        if (in.pressed) _ = self.dispatch(&self.root, in.pos);

        try layout.layout(&self.root, area, m, self.gpa);
        list.reset();
        try paint.emit(&self.root, list);
    }

    /// Topmost-first hit test: last-drawn child wins, first tagged hit consumes.
    fn dispatch(self: *Tree, node: *Node, pos: geometry.Point) bool {
        var i = node.children.items.len;
        while (i > 0) {
            i -= 1;
            if (self.dispatch(node.children.items[i], pos)) return true;
        }
        if (node.tag != 0 and layout.contains(node.rect, pos)) {
            if (self.handlers.get(node.tag)) |h| {
                h.func(h.ctx);
                return true;
            }
        }
        return false;
    }
};

test "clicking the + button runs its handler" {
    const gpa = std.testing.allocator;
    const M = struct {
        fn f(_: ?*anyopaque, s: []const u8, _: f32) layout.Size {
            return .{ .w = @floatFromInt(s.len * 10), .h = 20 };
        }
    };
    const m: layout.Measurer = .{ .ctx = null, .func = M.f };

    var count: i64 = 0;
    const Inc = struct {
        fn f(ctx: ?*anyopaque) void {
            const c: *i64 = @ptrCast(@alignCast(ctx));
            c.* += 1;
        }
    };

    var tree = Tree.init(gpa, .{ .axis = .column, .pad = 10 });
    defer tree.deinit();
    const btn = try tree.button(&tree.root, "+", 32, .{ .func = Inc.f, .ctx = &count });

    var list = dl.DrawList.init(gpa);
    defer list.deinit();

    // Frame 1: layout so the button gets a rect; no press yet.
    var in: input.Input = .{};
    try tree.frame(.{ .x = 0, .y = 0, .w = 200, .h = 100 }, m, &in, null, &list);
    try std.testing.expectEqual(@as(i64, 0), count);

    // Press inside the button's laid-out rect → handler fires once.
    const c = btn.rect;
    in = .{ .pressed = true, .pos = .{ .x = c.x + c.w / 2, .y = c.y + c.h / 2 } };
    try tree.frame(.{ .x = 0, .y = 0, .w = 200, .h = 100 }, m, &in, null, &list);
    try std.testing.expectEqual(@as(i64, 1), count);

    // Press outside → nothing.
    in = .{ .pressed = true, .pos = .{ .x = 500, .y = 500 } };
    try tree.frame(.{ .x = 0, .y = 0, .w = 200, .h = 100 }, m, &in, null, &list);
    try std.testing.expectEqual(@as(i64, 1), count);
}
