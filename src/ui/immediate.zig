//! Immediate frontend (Phase 3) — the widget tree is rebuilt from scratch each
//! frame; widgets return their interaction result at the call site.
//!
//! The immediate-mode chicken-and-egg (a button must report "clicked" before layout
//! has positioned it) is solved the standard way: hit-testing uses the button's rect
//! from the *previous* frame. Tree memory is a frame arena reset each `begin`, so the
//! per-frame rebuild allocates nothing lasting.
//!
//! Same `layout` engine and `input` as the retained frontend — the only difference is
//! ephemeral-tree-with-return-values vs persistent-tree-with-callbacks (that contrast
//! is the whole point of Phase 3).

const std = @import("std");
const layout = @import("../core/layout.zig");
const paint = @import("../core/paint.zig");
const dl = @import("../core/draw_list.zig");
const geometry = @import("../core/geometry.zig");
const input = @import("../input/input.zig");
const Node = layout.Node;

const btn_bg: geometry.Color = .{ .r = 0.22, .g = 0.25, .b = 0.32 };
const btn_bg_hot: geometry.Color = .{ .r = 0.30, .g = 0.34, .b = 0.44 };
const btn_fg: geometry.Color = .{ .r = 0.95, .g = 0.97, .b = 1.0 };

pub const Imm = struct {
    gpa: std.mem.Allocator, // persistent (the prev-rect map)
    arena: std.heap.ArenaAllocator, // per-frame tree memory
    m: layout.Measurer,
    in: *const input.Input,

    // Per-frame build state (all arena-allocated):
    a: std.mem.Allocator = undefined,
    root: *Node = undefined,
    stack: std.ArrayList(*Node) = .empty,

    // Last frame's tagged rects, for this frame's hit-testing.
    prev: std.AutoHashMapUnmanaged(u64, geometry.Rect) = .empty,

    pub fn init(gpa: std.mem.Allocator, m: layout.Measurer, in: *const input.Input) Imm {
        return .{ .gpa = gpa, .arena = std.heap.ArenaAllocator.init(gpa), .m = m, .in = in };
    }

    pub fn deinit(self: *Imm) void {
        self.arena.deinit();
        self.prev.deinit(self.gpa);
        self.* = undefined;
    }

    /// Start a frame: reset the arena, create the root container.
    pub fn begin(self: *Imm, root_style: layout.Style) !void {
        _ = self.arena.reset(.retain_capacity);
        self.a = self.arena.allocator();
        self.root = try self.a.create(Node);
        self.root.* = .{ .style = root_style };
        self.stack = .empty;
        try self.stack.append(self.a, self.root);
    }

    fn top(self: *Imm) *Node {
        return self.stack.items[self.stack.items.len - 1];
    }

    /// Open a container (row/column/panel); children go inside until `endBox`.
    pub fn beginBox(self: *Imm, style: layout.Style) !void {
        const box = try self.top().add(self.a, .{ .style = style });
        try self.stack.append(self.a, box);
    }

    pub fn endBox(self: *Imm) void {
        _ = self.stack.pop();
    }

    pub fn label(self: *Imm, str: []const u8, size: f32, color: geometry.Color) !void {
        _ = try self.top().add(self.a, .{ .content = .{ .text = .{ .str = str, .size = size, .color = color } } });
    }

    /// A clickable button. `tag` must be stable across frames for a given button
    /// (its identity for last-frame hit-testing). Returns true on the frame the
    /// press lands inside it.
    pub fn button(self: *Imm, tag: u64, text: []const u8, size: f32) !bool {
        const hot = if (self.prev.get(tag)) |r| layout.contains(r, self.in.pos) else false;
        const b = try self.top().add(self.a, .{
            .style = .{ .pad = 10 },
            .bg = if (hot) btn_bg_hot else btn_bg,
            .tag = tag,
        });
        _ = try b.add(self.a, .{ .content = .{ .text = .{ .str = text, .size = size, .color = btn_fg } } });
        return self.in.pressed and hot;
    }

    /// End the frame: layout, record tagged rects for next frame, emit into `list`.
    pub fn end(self: *Imm, area: geometry.Rect, list: *dl.DrawList) !void {
        try layout.layout(self.root, area, self.m, self.a);
        try self.store(self.root);
        list.reset();
        try paint.emit(self.root, list);
    }

    fn store(self: *Imm, node: *Node) !void {
        if (node.tag != 0) try self.prev.put(self.gpa, node.tag, node.rect);
        for (node.children.items) |c| try self.store(c);
    }
};
