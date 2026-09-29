//! HUI demos.
//!
//!   zig build run                 # immediate-mode counter (Phase 3)
//!   zig build run -- retained     # retained-mode counter
//!   zig build run -- settings     # Phase 4 settings panel (retained), live/Impeller
//!   zig build run -- settings raster   # same panel rendered HEADLESS via raster → PPM
//!   zig build run -- 120          # cap frames (headless smoke); combines with a mode
//!
//! The settings panel exercises every Phase 4 widget (text field, checkbox, slider,
//! scroll) and is rendered by two entirely different backends off the *same* draw
//! list — the proof that the draw-list seam isn't Impeller-shaped.

const std = @import("std");
const Io = std.Io;
const HUI = @import("HUI");
const geometry = HUI.geometry;

const bg: geometry.Color = .{ .r = 0.10, .g = 0.12, .b = 0.16 };
const fg: geometry.Color = .{ .r = 0.92, .g = 0.95, .b = 1.0 };
const panel_c: geometry.Color = .{ .r = 0.14, .g = 0.16, .b = 0.21 };

pub fn main(init: std.process.Init) !void {
    const gpa = init.arena.allocator();
    const io = init.io;

    var retained = false;
    var settings = false;
    var use_raster = false;
    var max_frames: u64 = 0; // 0 = run until the window is closed
    const args = try init.minimal.args.toSlice(gpa);
    for (args[1..]) |arg| {
        if (std.mem.eql(u8, arg, "retained")) retained = true
        else if (std.mem.eql(u8, arg, "immediate")) retained = false
        else if (std.mem.eql(u8, arg, "settings")) settings = true
        else if (std.mem.eql(u8, arg, "raster")) use_raster = true
        else max_frames = std.fmt.parseInt(u64, arg, 10) catch max_frames;
    }

    var buf: [160]u8 = undefined;
    var stdout: Io.File.Writer = .init(.stdout(), io, &buf);
    const w = &stdout.interface;

    // Headless: render the settings panel once through the software-raster backend.
    if (settings and use_raster) {
        const path = "settings_raster.ppm";
        try renderSettingsHeadless(gpa, io, path);
        try w.print("HUI: settings panel rendered headless via raster → {s}\n", .{path});
        try w.flush();
        return;
    }

    var embedder = try HUI.embedder.Default.init(gpa, .{ .title = "HUI" });
    defer embedder.deinit();
    var renderer = try HUI.backend.Renderer.init(gpa, io, &embedder);
    defer renderer.deinit();
    var scene = HUI.draw_list.DrawList.init(gpa);
    defer scene.deinit();

    const frames = if (settings)
        try runSettings(gpa, &embedder, &renderer, &scene, max_frames)
    else if (retained)
        try runRetained(gpa, &embedder, &renderer, &scene, max_frames)
    else
        try runImmediate(gpa, &embedder, &renderer, &scene, max_frames);

    const kind = if (settings) "settings" else if (retained) "retained counter" else "immediate counter";
    try w.print("HUI: {s}, rendered {d} frames, clean exit\n", .{ kind, frames });
    try w.flush();
}

// ── Settings panel (Phase 4) ─────────────────────────────────────────────────

const Settings = struct {
    enabled: bool = true,
    volume: f32 = 0.6,
};

/// Build the settings panel into `tree` (shared by the live and headless paths).
fn buildSettingsPanel(tree: *HUI.retained.Tree, st: *Settings) !void {
    const gpa = tree.gpa;
    tree.root.bg = bg;
    const panel = try tree.root.add(gpa, .{
        .style = .{ .axis = .column, .w = .{ .fixed = 480 }, .h = .{ .fixed = 460 }, .pad = 26, .gap = 16, .cross = .stretch },
        .bg = panel_c,
        .bg_radius = 16,
    });
    _ = try panel.add(gpa, .{ .content = .{ .text = .{ .str = "Settings", .size = 34, .color = fg } } });

    // Name: label + text field.
    {
        const row = try labeledRow(tree, panel, "Name");
        _ = try tree.textField(row, 22);
    }
    // Enabled: label + checkbox.
    {
        const row = try labeledRow(tree, panel, "Enabled");
        try tree.checkbox(row, &st.enabled);
    }
    // Volume: label + slider.
    {
        const row = try labeledRow(tree, panel, "Volume");
        try tree.slider(row, &st.volume);
    }
    // A scrollable list (exercises clip + wheel + scrollbar).
    _ = try panel.add(gpa, .{ .content = .{ .text = .{ .str = "Items", .size = 20, .color = fg } } });
    const sc = try tree.scroll(panel);
    inline for (1..13) |i| {
        _ = try sc.scroll.content.add(gpa, .{
            .style = .{ .h = .{ .fixed = 30 } },
            .content = .{ .text = .{ .str = std.fmt.comptimePrint("Item {d}", .{i}), .size = 18, .color = fg } },
        });
    }
}

fn labeledRow(tree: *HUI.retained.Tree, panel: *HUI.layout.Node, label: []const u8) !*HUI.layout.Node {
    const gpa = tree.gpa;
    const row = try panel.add(gpa, .{ .style = .{ .axis = .row, .gap = 14, .cross = .center } });
    _ = try row.add(gpa, .{ .style = .{ .w = .{ .fixed = 110 } }, .content = .{ .text = .{ .str = label, .size = 20, .color = fg } } });
    return row;
}

fn runSettings(gpa: std.mem.Allocator, embedder: anytype, renderer: anytype, scene: *HUI.draw_list.DrawList, max_frames: u64) !u64 {
    var in: HUI.input.Input = .{};
    var st: Settings = .{};
    var tree = HUI.retained.Tree.init(gpa, .{ .axis = .column, .pad = 30, .justify = .center, .cross = .center });
    defer tree.deinit();
    try buildSettingsPanel(&tree, &st);
    const clip = embedder.clipboard();

    var event_buf: [64]HUI.embedder.Event = undefined;
    var frame: u64 = 0;
    while (true) : (frame += 1) {
        in.beginFrame();
        for (embedder.pollEvents(&event_buf)) |ev| {
            switch (ev) {
                .close_requested => return frame,
                .resized => try renderer.resize(embedder),
                else => {},
            }
            in.feed(ev);
        }
        try tree.frame(windowArea(embedder), renderer.measurer(), &in, clip, scene);
        try renderer.render(scene);
        if (max_frames != 0 and frame + 1 >= max_frames) return frame + 1;
    }
}

/// Render the settings panel once through the software-raster backend and dump a PPM.
fn renderSettingsHeadless(gpa: std.mem.Allocator, io: Io, ppm_path: []const u8) !void {
    var raster = try HUI.raster.Raster.init(gpa, io, 900, 620);
    defer raster.deinit();

    var st: Settings = .{};
    var tree = HUI.retained.Tree.init(gpa, .{ .axis = .column, .pad = 30, .justify = .center, .cross = .center });
    defer tree.deinit();
    try buildSettingsPanel(&tree, &st);

    var scene = HUI.draw_list.DrawList.init(gpa);
    defer scene.deinit();
    const area: geometry.Rect = .{ .x = 0, .y = 0, .w = 900, .h = 620 };

    // A few frames so widget-driven styles (slider weights, etc.) settle before capture.
    var in: HUI.input.Input = .{};
    var f: u32 = 0;
    while (f < 3) : (f += 1) {
        in.beginFrame();
        try tree.frame(area, raster.measurer(), &in, null, &scene);
        try raster.render(&scene);
    }
    try raster.writePpm(io, ppm_path);
}

test "settings panel renders headless through the raster backend" {
    const gpa = std.testing.allocator;
    var threaded: Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const rio = threaded.io();

    var raster = try HUI.raster.Raster.init(gpa, rio, 900, 620);
    defer raster.deinit();
    var st: Settings = .{}; // enabled=true, volume=0.6
    var tree = HUI.retained.Tree.init(gpa, .{ .axis = .column, .pad = 30, .justify = .center, .cross = .center });
    defer tree.deinit();
    try buildSettingsPanel(&tree, &st);

    var scene = HUI.draw_list.DrawList.init(gpa);
    defer scene.deinit();
    const area: geometry.Rect = .{ .x = 0, .y = 0, .w = 900, .h = 620 };
    var in: HUI.input.Input = .{};
    var f: u32 = 0;
    while (f < 3) : (f += 1) {
        in.beginFrame();
        try tree.frame(area, raster.measurer(), &in, null, &scene);
        try raster.render(&scene);
    }

    // Window background at a corner is dark.
    try std.testing.expect(raster.pixel(2, 2)[0] < 40);
    // The checked checkbox paints accent blue somewhere in the buffer.
    var accent = false;
    var y: u32 = 0;
    while (y < 620) : (y += 1) {
        var x: u32 = 0;
        while (x < 900) : (x += 1) {
            const p = raster.pixel(x, y);
            if (p[2] > 200 and p[1] > 120 and p[1] < 200 and p[0] < 130) accent = true;
        }
    }
    try std.testing.expect(accent);
}

/// Full-window layout area in draw-list (pixel) space.
fn windowArea(embedder: anytype) HUI.geometry.Rect {
    const ds = embedder.drawableSize();
    return .{ .x = 0, .y = 0, .w = @floatFromInt(ds.width), .h = @floatFromInt(ds.height) };
}

fn runImmediate(gpa: std.mem.Allocator, embedder: anytype, renderer: anytype, scene: *HUI.draw_list.DrawList, max_frames: u64) !u64 {
    var in: HUI.input.Input = .{};
    var ui = HUI.immediate.Imm.init(gpa, renderer.measurer(), &in);
    defer ui.deinit();

    var count: i64 = 0;
    var event_buf: [64]HUI.embedder.Event = undefined;
    var frame: u64 = 0;
    while (true) : (frame += 1) {
        in.beginFrame();
        for (embedder.pollEvents(&event_buf)) |ev| {
            switch (ev) {
                .close_requested => return frame,
                .resized => try renderer.resize(embedder),
                else => {},
            }
            in.feed(ev);
        }

        try ui.begin(.{ .axis = .column, .pad = 30, .gap = 16, .justify = .center, .cross = .center });
        ui.root.bg = bg;
        var lbl: [64]u8 = undefined;
        try ui.label(try std.fmt.bufPrint(&lbl, "Count: {d}", .{count}), 40, fg);
        try ui.beginBox(.{ .axis = .row, .gap = 12 });
        if (try ui.button(1, "  -  ", 32)) count -= 1;
        if (try ui.button(2, "  +  ", 32)) count += 1;
        ui.endBox();
        try ui.end(windowArea(embedder), scene);

        try renderer.render(scene);
        if (max_frames != 0 and frame + 1 >= max_frames) return frame + 1;
    }
}

const Counter = struct {
    fn inc(ctx: ?*anyopaque) void {
        const c: *i64 = @ptrCast(@alignCast(ctx));
        c.* += 1;
    }
    fn dec(ctx: ?*anyopaque) void {
        const c: *i64 = @ptrCast(@alignCast(ctx));
        c.* -= 1;
    }
};

fn runRetained(gpa: std.mem.Allocator, embedder: anytype, renderer: anytype, scene: *HUI.draw_list.DrawList, max_frames: u64) !u64 {
    var in: HUI.input.Input = .{};
    var count: i64 = 0;

    var tree = HUI.retained.Tree.init(gpa, .{ .axis = .column, .pad = 30, .gap = 16, .justify = .center, .cross = .center });
    defer tree.deinit();
    tree.root.bg = bg;
    const label = try tree.root.add(gpa, .{ .content = .{ .text = .{ .str = "", .size = 40, .color = fg } } });
    const row = try tree.root.add(gpa, .{ .style = .{ .axis = .row, .gap = 12 } });
    _ = try tree.button(row, "  -  ", 32, .{ .func = Counter.dec, .ctx = &count });
    _ = try tree.button(row, "  +  ", 32, .{ .func = Counter.inc, .ctx = &count });

    var lbl: [64]u8 = undefined;
    var event_buf: [64]HUI.embedder.Event = undefined;
    var frame: u64 = 0;
    while (true) : (frame += 1) {
        in.beginFrame();
        for (embedder.pollEvents(&event_buf)) |ev| {
            switch (ev) {
                .close_requested => return frame,
                .resized => try renderer.resize(embedder),
                else => {},
            }
            in.feed(ev);
        }

        // Retained state lives in the tree — just refresh the label's text.
        label.content.text.str = try std.fmt.bufPrint(&lbl, "Count: {d}", .{count});
        try tree.frame(windowArea(embedder), renderer.measurer(), &in, null, scene);

        try renderer.render(scene);
        if (max_frames != 0 and frame + 1 >= max_frames) return frame + 1;
    }
}
