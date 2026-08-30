//! Layout engine (Phase 3, D3) — measure/arrange over a node tree.
//!
//! Two passes, the attribute-grammar shape: `measure` walks bottom-up filling each
//! node's desired size (content up); `arrange` walks top-down assigning final rects
//! (positions down). Mode-agnostic: both frontends build a `Node` tree and hand it
//! here — the engine doesn't know or care which.
//!
//! Own box model (not the CSS spec, but complete for app use):
//!   - **Flex**: per-axis `fixed`/`grow`/`fit`, row/column, main-axis `justify`
//!     (start/center/end/space-between/around/evenly) + cross-axis `cross`
//!     (start/center/end/stretch), `gap`, `pad`.
//!   - **Grid**: `fixed`/`fr`/`auto` tracks, explicit cell placement + spanning,
//!     sequential auto-flow, row/column gaps. Children fill their cell (grid-default
//!     stretch).
//!   - **Absolute**: `pos` takes a node out of flow, placed at the parent's content
//!     origin + offset.
//!
//! Text sizing needs the renderer (only Impeller can measure a glyph run), and grid
//! needs scratch arrays, so `layout` takes a `Ctx` (measurer + allocator).
//!
//! The one deliberate boundary vs full CSS grid: auto-track content sizing splits a
//! spanning child's size evenly across its spanned auto tracks rather than running
//! the spec's min/max-content distribution. Everything declared for Phase 3 is built.

const std = @import("std");
const geometry = @import("geometry.zig");
const text = @import("text.zig");
const Rect = geometry.Rect;
const Point = geometry.Point;
const Color = geometry.Color;

/// Re-exported for callers that phrase sizes in layout terms; the canonical home is
/// `geometry.Size`.
pub const Size = geometry.Size;
pub const Axis = enum { row, column };

/// Length along one axis. `fit` = size to content; `grow` shares the parent's
/// leftover main-axis space by weight; `fixed` is exact pixels.
pub const Len = union(enum) {
    fixed: f32,
    grow: f32,
    fit,
};

/// Main-axis distribution of flow children when there's leftover space.
pub const Justify = enum { start, center, end, space_between, space_around, space_evenly };
/// Cross-axis alignment of flow children within the container's cross extent.
pub const Align = enum { start, center, end, stretch };

/// A grid track's sizing: `fixed` px, `fr` (fraction of leftover, like CSS fr), or
/// `auto` (max content of its cells).
pub const Track = union(enum) {
    fixed: f32,
    fr: f32,
    auto,
};

pub const Grid = struct {
    cols: []const Track,
    rows: []const Track,
    col_gap: f32 = 0,
    row_gap: f32 = 0,
};

/// A node's placement in its parent grid. Omit for sequential auto-flow.
pub const Placement = struct { col: u16, row: u16, col_span: u16 = 1, row_span: u16 = 1 };

pub const Style = struct {
    /// Child stacking direction (flex containers).
    axis: Axis = .column,
    w: Len = .fit,
    h: Len = .fit,
    gap: f32 = 0,
    pad: f32 = 0,
    justify: Justify = .start,
    cross: Align = .start,
    /// Absolute placement: out of flow, offset from the parent's content origin.
    pos: ?Point = null,
    /// If set, this container lays its children on a grid (overrides flex).
    grid: ?Grid = null,
    /// This node's cell in its *parent's* grid (null = auto-flow).
    cell: ?Placement = null,
    /// Clip children to this node's rect (rounded by `bg_radius`) — for scroll
    /// viewports and any overflow-hiding container.
    clip: bool = false,
};

pub const Content = union(enum) {
    none,
    text: struct { str: []const u8, size: f32, color: Color },
};

/// A layout/render node. `bg` fills behind content+children (buttons, panels).
/// Children are heap-boxed so pointers stay stable as siblings are appended (the
/// immediate frontend's container stack relies on this). `tag` is opaque metadata
/// for frontends to associate hit-testing with a widget — layout never reads it.
pub const Node = struct {
    style: Style = .{},
    bg: ?Color = null,
    /// Corner radius for `bg` (and the clip, if `style.clip`). 0 = square.
    bg_radius: f32 = 0,
    content: Content = .none,
    tag: u64 = 0,
    children: std.ArrayList(*Node) = .empty,

    // Filled by `layout`:
    rect: Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
    measured: Size = .{},

    /// Heap-box `child` in `gpa` and append it; returns the stable pointer.
    pub fn add(self: *Node, gpa: std.mem.Allocator, child: Node) !*Node {
        const c = try gpa.create(Node);
        c.* = child;
        try self.children.append(gpa, c);
        return c;
    }

    /// Recursively free children (boxes + their lists) and this node's list. The
    /// root is caller-owned (not freed). Retained frontends call this to tear down;
    /// immediate frontends use a frame arena and skip it.
    pub fn deinitTree(self: *Node, gpa: std.mem.Allocator) void {
        for (self.children.items) |c| {
            c.deinitTree(gpa);
            gpa.destroy(c);
        }
        self.children.deinit(gpa);
    }
};

/// The text-measurement seam lives in `text.zig` so the render backend can implement
/// it without importing this layout engine. Re-exported for call-site convenience.
pub const Measurer = text.Measurer;

/// Everything the passes thread through: text measurement + scratch allocator (grid).
pub const Ctx = struct { m: Measurer, a: std.mem.Allocator };

fn mainLen(style: Style, axis: Axis) Len {
    return if (axis == .row) style.w else style.h;
}
fn crossLen(style: Style, axis: Axis) Len {
    return if (axis == .row) style.h else style.w;
}

/// Run both passes: fill every node's `rect` for the tree rooted at `root`, laid
/// into `area`. `a` is scratch storage for grid track/placement arrays.
pub fn layout(root: *Node, area: Rect, m: Measurer, a: std.mem.Allocator) !void {
    const ctx: Ctx = .{ .m = m, .a = a };
    try measure(root, ctx);
    try arrange(root, area, ctx);
}

// ── Measure ────────────────────────────────────────────────────────────────────

/// Bottom-up: fill `node.measured` (desired size ignoring grow expansion).
fn measure(node: *Node, ctx: Ctx) !void {
    for (node.children.items) |c| try measure(c, ctx);

    var nat: Size = .{};
    switch (node.content) {
        .text => |t| nat = ctx.m.measure(t.str, t.size),
        .none => nat = if (node.style.grid != null)
            try gridNatural(node, ctx)
        else
            flexNatural(node),
    }

    node.measured.w = switch (node.style.w) {
        .fixed => |v| v,
        else => nat.w,
    };
    node.measured.h = switch (node.style.h) {
        .fixed => |v| v,
        else => nat.h,
    };
}

fn flexNatural(node: *Node) Size {
    const axis = node.style.axis;
    var main: f32 = 0;
    var cross: f32 = 0;
    var flow: usize = 0;
    for (node.children.items) |c| {
        if (c.style.pos != null) continue; // out of flow — doesn't grow the parent
        main += if (axis == .row) c.measured.w else c.measured.h;
        cross = @max(cross, if (axis == .row) c.measured.h else c.measured.w);
        flow += 1;
    }
    if (flow > 1) main += node.style.gap * @as(f32, @floatFromInt(flow - 1));
    main += node.style.pad * 2;
    cross += node.style.pad * 2;
    return if (axis == .row) .{ .w = main, .h = cross } else .{ .w = cross, .h = main };
}

// ── Arrange ──────────────────────────────────────────────────────────────────

/// Top-down: assign `node.rect`, then place children in `rect`'s content box.
/// Explicit error set (only allocation can fail) breaks the arrange↔arrangeGrid
/// inferred-error recursion cycle.
fn arrange(node: *Node, rect: Rect, ctx: Ctx) std.mem.Allocator.Error!void {
    node.rect = rect;
    if (node.children.items.len == 0) return;
    if (node.style.grid != null) return arrangeGrid(node, rect, ctx);
    return arrangeFlex(node, rect, ctx);
}

fn arrangeFlex(node: *Node, rect: Rect, ctx: Ctx) !void {
    const pad = node.style.pad;
    const ox = rect.x + pad;
    const oy = rect.y + pad;
    const cw = rect.w - pad * 2;
    const ch = rect.h - pad * 2;
    const axis = node.style.axis;
    const main_avail = if (axis == .row) cw else ch;
    const cross_avail = if (axis == .row) ch else cw;

    // First: base main sizes + grow weights (flow children only).
    var used: f32 = 0;
    var grow_total: f32 = 0;
    var flow: usize = 0;
    for (node.children.items) |c| {
        if (c.style.pos != null) continue;
        used += if (axis == .row) c.measured.w else c.measured.h;
        switch (mainLen(c.style, axis)) {
            .grow => |wgt| grow_total += wgt,
            else => {},
        }
        flow += 1;
    }
    if (flow > 1) used += node.style.gap * @as(f32, @floatFromInt(flow - 1));
    const leftover = @max(0, main_avail - used);

    // Justify only applies when there's free space AND nothing is growing to eat it.
    var offset: f32 = 0;
    var extra_gap: f32 = 0;
    if (grow_total == 0 and flow > 0) {
        const n: f32 = @floatFromInt(flow);
        switch (node.style.justify) {
            .start => {},
            .center => offset = leftover / 2,
            .end => offset = leftover,
            .space_between => if (flow > 1) {
                extra_gap = leftover / (n - 1);
            },
            .space_around => {
                extra_gap = leftover / n;
                offset = extra_gap / 2;
            },
            .space_evenly => {
                extra_gap = leftover / (n + 1);
                offset = extra_gap;
            },
        }
    }

    var cursor: f32 = (if (axis == .row) ox else oy) + offset;
    for (node.children.items) |c| {
        if (c.style.pos) |p| {
            try arrange(c, .{ .x = ox + p.x, .y = oy + p.y, .w = c.measured.w, .h = c.measured.h }, ctx);
            continue;
        }
        var main_sz = if (axis == .row) c.measured.w else c.measured.h;
        if (grow_total > 0) switch (mainLen(c.style, axis)) {
            .grow => |wgt| main_sz += leftover * (wgt / grow_total),
            else => {},
        };

        // Cross size: stretch when the child grows on cross, or the container aligns
        // stretch and the child isn't a fixed cross size.
        const cl = crossLen(c.style, axis);
        const stretch = cl == .grow or (node.style.cross == .stretch and cl != .fixed);
        const c_measured = if (axis == .row) c.measured.h else c.measured.w;
        const cross_sz = if (stretch) cross_avail else @min(cross_avail, c_measured);
        const cross_off: f32 = switch (node.style.cross) {
            .start, .stretch => 0,
            .center => (cross_avail - cross_sz) / 2,
            .end => cross_avail - cross_sz,
        };
        const cbase = (if (axis == .row) oy else ox) + cross_off;

        const cr: Rect = if (axis == .row)
            .{ .x = cursor, .y = cbase, .w = main_sz, .h = cross_sz }
        else
            .{ .x = cbase, .y = cursor, .w = cross_sz, .h = main_sz };
        try arrange(c, cr, ctx);
        cursor += main_sz + node.style.gap + extra_gap;
    }
}

// ── Grid ───────────────────────────────────────────────────────────────────────

const Cell = struct { col: u16, row: u16, cspan: u16, rspan: u16 };

/// Resolve each child's grid cell: explicit `cell`, else sequential row-major
/// auto-flow across the column count. ponytail: auto-flow is sequential and does not
/// dodge explicitly-placed cells (collision-aware packing is a rarely-needed CSS
/// nicety) — mix explicit + auto in the same grid only when they don't overlap.
fn placements(node: *Node, a: std.mem.Allocator) ![]Cell {
    const g = node.style.grid.?;
    const ncol: u16 = @intCast(g.cols.len);
    const cells = try a.alloc(Cell, node.children.items.len);
    var ccol: u16 = 0;
    var crow: u16 = 0;
    for (node.children.items, 0..) |c, i| {
        if (c.style.pos != null) {
            cells[i] = .{ .col = 0, .row = 0, .cspan = 0, .rspan = 0 }; // absolute: skip flow
            continue;
        }
        if (c.style.cell) |p| {
            cells[i] = .{ .col = p.col, .row = p.row, .cspan = @max(1, p.col_span), .rspan = @max(1, p.row_span) };
        } else {
            if (ncol > 0 and ccol >= ncol) {
                ccol = 0;
                crow += 1;
            }
            cells[i] = .{ .col = ccol, .row = crow, .cspan = 1, .rspan = 1 };
            ccol += 1;
        }
    }
    return cells;
}

/// Auto/content base size per track along one axis (`col`=true → columns).
fn autoBases(node: *Node, cells: []const Cell, col: bool, ntrack: usize, a: std.mem.Allocator) ![]f32 {
    const base = try a.alloc(f32, ntrack);
    @memset(base, 0);
    for (node.children.items, cells) |c, cell| {
        if (cell.cspan == 0) continue; // absolute
        const start = if (col) cell.col else cell.row;
        const n = if (col) cell.cspan else cell.rspan;
        const sz = if (col) c.measured.w else c.measured.h;
        const per = sz / @as(f32, @floatFromInt(n)); // split spanning size evenly
        var t: usize = start;
        while (t < start + n and t < ntrack) : (t += 1) base[t] = @max(base[t], per);
    }
    return base;
}

/// Resolve each track to a pixel size: fixed→px, auto→content base, fr→share of the
/// leftover after fixed+auto+gaps. `avail<=0` (natural sizing) leaves fr at 0.
fn sizeTracks(tracks: []const Track, bases: []const f32, avail: f32, gap: f32, a: std.mem.Allocator) ![]f32 {
    const out = try a.alloc(f32, tracks.len);
    var rigid: f32 = 0;
    var fr_total: f32 = 0;
    for (tracks, 0..) |tr, i| switch (tr) {
        .fixed => |v| {
            out[i] = v;
            rigid += v;
        },
        .auto => {
            out[i] = bases[i];
            rigid += bases[i];
        },
        .fr => |w| {
            out[i] = 0;
            fr_total += w;
        },
    };
    const gaps = if (tracks.len > 1) gap * @as(f32, @floatFromInt(tracks.len - 1)) else 0;
    const free = @max(0, avail - rigid - gaps);
    if (fr_total > 0) for (tracks, 0..) |tr, i| switch (tr) {
        .fr => |w| out[i] = free * (w / fr_total),
        else => {},
    };
    return out;
}

fn prefix(sizes: []const f32, origin: f32, gap: f32, i: usize) f32 {
    var p = origin;
    var k: usize = 0;
    while (k < i) : (k += 1) p += sizes[k] + gap;
    return p;
}
fn span(sizes: []const f32, gap: f32, start: usize, count: usize) f32 {
    var s: f32 = 0;
    var k: usize = start;
    while (k < start + count and k < sizes.len) : (k += 1) {
        s += sizes[k];
        if (k > start) s += gap;
    }
    return s;
}

fn gridNatural(node: *Node, ctx: Ctx) !Size {
    const g = node.style.grid.?;
    const cells = try placements(node, ctx.a);
    defer ctx.a.free(cells);
    const cbase = try autoBases(node, cells, true, g.cols.len, ctx.a);
    defer ctx.a.free(cbase);
    const rbase = try autoBases(node, cells, false, g.rows.len, ctx.a);
    defer ctx.a.free(rbase);
    const cs = try sizeTracks(g.cols, cbase, 0, g.col_gap, ctx.a);
    defer ctx.a.free(cs);
    const rs = try sizeTracks(g.rows, rbase, 0, g.row_gap, ctx.a);
    defer ctx.a.free(rs);

    var w: f32 = node.style.pad * 2;
    for (cs) |v| w += v;
    if (g.cols.len > 1) w += g.col_gap * @as(f32, @floatFromInt(g.cols.len - 1));
    var h: f32 = node.style.pad * 2;
    for (rs) |v| h += v;
    if (g.rows.len > 1) h += g.row_gap * @as(f32, @floatFromInt(g.rows.len - 1));
    return .{ .w = w, .h = h };
}

fn arrangeGrid(node: *Node, rect: Rect, ctx: Ctx) !void {
    const g = node.style.grid.?;
    const pad = node.style.pad;
    const ox = rect.x + pad;
    const oy = rect.y + pad;
    const cw = rect.w - pad * 2;
    const ch = rect.h - pad * 2;

    const cells = try placements(node, ctx.a);
    defer ctx.a.free(cells);
    const cbase = try autoBases(node, cells, true, g.cols.len, ctx.a);
    defer ctx.a.free(cbase);
    const rbase = try autoBases(node, cells, false, g.rows.len, ctx.a);
    defer ctx.a.free(rbase);
    const cs = try sizeTracks(g.cols, cbase, cw, g.col_gap, ctx.a);
    defer ctx.a.free(cs);
    const rs = try sizeTracks(g.rows, rbase, ch, g.row_gap, ctx.a);
    defer ctx.a.free(rs);

    for (node.children.items, cells) |c, cell| {
        if (c.style.pos) |p| {
            try arrange(c, .{ .x = ox + p.x, .y = oy + p.y, .w = c.measured.w, .h = c.measured.h }, ctx);
            continue;
        }
        const x = prefix(cs, ox, g.col_gap, cell.col);
        const y = prefix(rs, oy, g.row_gap, cell.row);
        const w = span(cs, g.col_gap, cell.col, cell.cspan);
        const h = span(rs, g.row_gap, cell.row, cell.rspan);
        try arrange(c, .{ .x = x, .y = y, .w = w, .h = h }, ctx); // children fill their cell
    }
}

// ── Hit-test ─────────────────────────────────────────────────────────────────
// (Emitting a laid-out tree to a draw list lives in `paint.zig`, so this module
//  stays pure measure/arrange and doesn't depend on the draw list.)

/// True if `p` is inside `r` (hit-testing helper for frontends).
pub fn contains(r: Rect, p: Point) bool {
    return p.x >= r.x and p.x < r.x + r.w and p.y >= r.y and p.y < r.y + r.h;
}

// ── Tests ──────────────────────────────────────────────────────────────────────

const white: Color = .{ .r = 1, .g = 1, .b = 1 };
fn fakeMeasure(_: ?*anyopaque, s: []const u8, _: f32) Size {
    return .{ .w = @floatFromInt(s.len * 10), .h = 20 };
}

test "row distributes grow, fit sizes to content" {
    const gpa = std.testing.allocator;
    const m: Measurer = .{ .ctx = null, .func = fakeMeasure };

    var root: Node = .{ .style = .{ .axis = .row, .w = .{ .fixed = 300 }, .h = .{ .fixed = 20 } } };
    defer root.deinitTree(gpa);
    _ = try root.add(gpa, .{ .content = .{ .text = .{ .str = "ab", .size = 12, .color = white } } });
    _ = try root.add(gpa, .{ .style = .{ .w = .{ .grow = 1 } } });
    _ = try root.add(gpa, .{ .content = .{ .text = .{ .str = "c", .size = 12, .color = white } } });

    try layout(&root, .{ .x = 0, .y = 0, .w = 300, .h = 20 }, m, gpa);

    try std.testing.expectEqual(@as(f32, 20), root.children.items[0].rect.w);
    try std.testing.expectEqual(@as(f32, 270), root.children.items[1].rect.w);
    try std.testing.expectEqual(@as(f32, 290), root.children.items[2].rect.x);
}

test "justify center and cross center position a fit child" {
    const gpa = std.testing.allocator;
    const m: Measurer = .{ .ctx = null, .func = fakeMeasure };
    var root: Node = .{ .style = .{ .axis = .row, .w = .{ .fixed = 100 }, .h = .{ .fixed = 100 }, .justify = .center, .cross = .center } };
    defer root.deinitTree(gpa);
    _ = try root.add(gpa, .{ .style = .{ .w = .{ .fixed = 20 }, .h = .{ .fixed = 20 } } });
    try layout(&root, .{ .x = 0, .y = 0, .w = 100, .h = 100 }, m, gpa);
    const r = root.children.items[0].rect;
    try std.testing.expectEqual(@as(f32, 40), r.x); // (100-20)/2
    try std.testing.expectEqual(@as(f32, 40), r.y);
}

test "grid places cells with fixed + fr tracks and spanning" {
    const gpa = std.testing.allocator;
    const m: Measurer = .{ .ctx = null, .func = fakeMeasure };
    const cols = [_]Track{ .{ .fixed = 50 }, .{ .fr = 1 }, .{ .fr = 1 } };
    const rows = [_]Track{ .{ .fixed = 30 }, .{ .fixed = 30 } };
    var root: Node = .{ .style = .{
        .w = .{ .fixed = 250 },
        .h = .{ .fixed = 60 },
        .grid = .{ .cols = &cols, .rows = &rows },
    } };
    defer root.deinitTree(gpa);
    // Cell (0,0); a (1..3, row 0) spanning two fr cols; cell (0,1).
    _ = try root.add(gpa, .{ .style = .{ .cell = .{ .col = 0, .row = 0 } } });
    _ = try root.add(gpa, .{ .style = .{ .cell = .{ .col = 1, .row = 0, .col_span = 2 } } });
    _ = try root.add(gpa, .{ .style = .{ .cell = .{ .col = 0, .row = 1 } } });
    try layout(&root, .{ .x = 0, .y = 0, .w = 250, .h = 60 }, m, gpa);

    // fr space = 250 - 50 = 200, split → 100 each.
    try std.testing.expectEqual(@as(f32, 50), root.children.items[0].rect.w);
    try std.testing.expectEqual(@as(f32, 50), root.children.items[1].rect.x); // starts after fixed col
    try std.testing.expectEqual(@as(f32, 200), root.children.items[1].rect.w); // spans 2×100
    try std.testing.expectEqual(@as(f32, 30), root.children.items[2].rect.y); // second row
}
