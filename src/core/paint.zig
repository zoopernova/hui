//! Paint — walk a laid-out `layout.Node` tree and translate it into draw-list
//! commands. This is the bridge from the view/layout tree to the render seam, kept
//! out of `layout.zig` so the layout engine stays pure measure/arrange (no draw-list
//! dependency). Frontends call `paint.emit(root, &list)` after `layout.layout`.

const layout = @import("layout.zig");
const dl = @import("draw_list.zig");

/// Emit the laid-out tree into a draw list (backgrounds, then content, depth-first).
pub fn emit(node: *const layout.Node, list: *dl.DrawList) !void {
    if (node.bg) |color| {
        if (node.bg_radius > 0) try list.roundedRect(node.rect, node.bg_radius, color) else try list.fillRect(node.rect, color);
    }
    switch (node.content) {
        .text => |t| try list.text(.{ .x = node.rect.x, .y = node.rect.y }, t.str, t.size, t.color),
        .none => {},
    }
    // A clipping container bounds its children to its rect for the draw duration.
    const clipping = node.style.clip;
    if (clipping) try list.clipPush(node.rect, node.bg_radius);
    for (node.children.items) |c| try emit(c, list);
    if (clipping) try list.clipPop();
}
