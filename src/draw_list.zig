//! Draw list (Phase 1) — the seam.
//!
//! A backend-agnostic, mode-agnostic list of draw commands. Frontends (immediate,
//! retained — Phase 3) *produce* it; backends (Impeller, raster — Phase 4) *consume*
//! it. Nothing here knows about Impeller, Vulkan, or widgets — keep it that way.
//!
//! Geometry/color primitives live in `geometry.zig` (the shared bottom layer); this
//! module owns only the command vocabulary and the list itself.

const std = @import("std");
const geometry = @import("geometry.zig");
const Color = geometry.Color;
const Point = geometry.Point;
const Rect = geometry.Rect;

/// One drawing operation. Grows with the primitive set; backends switch on it.
pub const Command = union(enum) {
    /// Fill the whole surface — the frame "clear".
    background: Color,
    fill_rect: struct { rect: Rect, color: Color },
    rounded_rect: struct { rect: Rect, radius: f32, color: Color },
    line: struct { from: Point, to: Point, color: Color, width: f32 = 1.0 },
    // `str` is borrowed, not copied — it must outlive the frame (static or
    // caller-owned). ponytail: dupe into the list if a caller ever needs otherwise.
    text: struct { pos: Point, str: []const u8, size: f32 = 16.0, color: Color, width: f32 = 1.0e6 },
    // Clip stack: push intersects the current clip with `rect` (rounded if radius>0)
    // for subsequent commands; pop restores. Backends map these to save/restore.
    clip_push: struct { rect: Rect, radius: f32 = 0 },
    clip_pop,
};

pub const DrawList = struct {
    gpa: std.mem.Allocator,
    cmds: std.ArrayList(Command) = .empty,

    pub fn init(gpa: std.mem.Allocator) DrawList {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *DrawList) void {
        self.cmds.deinit(self.gpa);
        self.* = undefined;
    }

    /// Empty the list but keep the backing memory — the per-frame reset for an
    /// immediate-mode rebuild.
    pub fn reset(self: *DrawList) void {
        self.cmds.clearRetainingCapacity();
    }

    pub fn background(self: *DrawList, color: Color) !void {
        try self.cmds.append(self.gpa, .{ .background = color });
    }

    pub fn fillRect(self: *DrawList, rect: Rect, color: Color) !void {
        try self.cmds.append(self.gpa, .{ .fill_rect = .{ .rect = rect, .color = color } });
    }

    pub fn roundedRect(self: *DrawList, rect: Rect, radius: f32, color: Color) !void {
        try self.cmds.append(self.gpa, .{ .rounded_rect = .{ .rect = rect, .radius = radius, .color = color } });
    }

    pub fn clipPush(self: *DrawList, rect: Rect, radius: f32) !void {
        try self.cmds.append(self.gpa, .{ .clip_push = .{ .rect = rect, .radius = radius } });
    }

    pub fn clipPop(self: *DrawList) !void {
        try self.cmds.append(self.gpa, .clip_pop);
    }

    pub fn line(self: *DrawList, from: Point, to: Point, color: Color, width: f32) !void {
        try self.cmds.append(self.gpa, .{ .line = .{ .from = from, .to = to, .color = color, .width = width } });
    }

    /// Draw `str` with its top-left at `pos`. `str` is borrowed (see `Command.text`).
    pub fn text(self: *DrawList, pos: Point, str: []const u8, size: f32, color: Color) !void {
        try self.cmds.append(self.gpa, .{ .text = .{ .pos = pos, .str = str, .size = size, .color = color } });
    }

    pub fn items(self: *const DrawList) []const Command {
        return self.cmds.items;
    }
};

test "draw list records commands in order" {
    var dl = DrawList.init(std.testing.allocator);
    defer dl.deinit();
    try dl.background(.{ .r = 0, .g = 0, .b = 0 });
    try dl.fillRect(.{ .x = 1, .y = 2, .w = 3, .h = 4 }, .{ .r = 1, .g = 0, .b = 0 });
    try dl.line(.{ .x = 0, .y = 0 }, .{ .x = 5, .y = 5 }, .{ .r = 0, .g = 1, .b = 0 }, 2.0);

    const cmds = dl.items();
    try std.testing.expectEqual(@as(usize, 3), cmds.len);
    try std.testing.expect(cmds[0] == .background);
    try std.testing.expectEqual(@as(f32, 3), cmds[1].fill_rect.rect.w);
    try std.testing.expectEqual(@as(f32, 2.0), cmds[2].line.width);

    dl.reset();
    try std.testing.expectEqual(@as(usize, 0), dl.items().len);
}
