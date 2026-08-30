//! By convention, root.zig is the root source file when making a package.
//! Public HUI surface: submodules are re-exported here so consumers reach them
//! via `@import("HUI").<name>`.
const std = @import("std");
const Io = std.Io;

/// Shared geometry/color primitives (the bottom layer). See `src/geometry.zig`.
pub const geometry = @import("geometry.zig");

/// Impeller C API bindings (Phase 0). See `src/impeller.zig`.
pub const impeller = @import("impeller.zig");

/// Windowing/embedder contract (Phase 0). See `src/embedder.zig`.
pub const embedder = @import("embedder.zig");

/// Draw-list seam + geometry/color vocabulary (Phase 1). See `src/draw_list.zig`.
pub const draw_list = @import("draw_list.zig");

/// Text-measurement seam (Phase 2). Impl in `src/backend/impeller_text.zig`.
pub const text = @import("text.zig");

/// Input state + hit-testing (Phase 3). See `src/input.zig`.
pub const input = @import("input.zig");

/// Keyboard-focus state, shared by both frontends (Phase 4). See `src/focus.zig`.
pub const focus = @import("focus.zig");

/// Clipboard seam (Phase 4). See `src/clipboard.zig`.
pub const clipboard = @import("clipboard.zig");

/// Layout engine — measure/arrange, own box model (Phase 3). See `src/layout.zig`.
pub const layout = @import("layout.zig");

/// Paint — walk a laid-out node tree into a draw list (Phase 3). See `src/paint.zig`.
pub const paint = @import("paint.zig");

/// Immediate-mode frontend (Phase 3). See `src/immediate.zig`.
pub const immediate = @import("immediate.zig");

/// Retained-mode frontend (Phase 3). See `src/retained.zig`.
pub const retained = @import("retained.zig");

/// Widgets — checkbox, slider, text field, scroll (Phase 4). See `src/widgets.zig`.
pub const widgets = @import("widgets.zig");

/// Impeller Vulkan backend (Phase 0/1). See `src/backend/impeller.zig`.
pub const backend = @import("backend/impeller.zig");

/// Software raster backend (Phase 4) — same draw list, CPU RGBA8 buffer, no GPU.
pub const raster = @import("backend/raster.zig");

test {
    // Pull submodule tests into the module test run.
    std.testing.refAllDecls(@This());
}

/// This is a documentation comment to explain the `printAnotherMessage` function below.
///
/// Accepting an `Io.Writer` instance is a handy way to write reusable code.
pub fn printAnotherMessage(writer: *Io.Writer) Io.Writer.Error!void {
    try writer.print("Run `zig build test` to run the tests.\n", .{});
}

pub fn add(a: i32, b: i32) i32 {
    return a + b;
}

test "basic add functionality" {
    try std.testing.expect(add(3, 7) == 10);
}
