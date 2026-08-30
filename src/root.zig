//! By convention, root.zig is the root source file when making a package.
//! Public HUI surface: submodules are re-exported here so consumers reach them
//! via `@import("HUI").<name>`.
const std = @import("std");

/// Shared geometry/color primitives (the bottom layer). See `src/core/geometry.zig`.
pub const geometry = @import("core/geometry.zig");

/// Impeller C API bindings (Phase 0). See `src/render/impeller/bindings.zig`.
pub const impeller = @import("render/impeller/bindings.zig");

/// Windowing/embedder contract (Phase 0). See `src/embedder/embedder.zig`.
pub const embedder = @import("embedder/embedder.zig");

/// Draw-list seam + geometry/color vocabulary (Phase 1). See `src/core/draw_list.zig`.
pub const draw_list = @import("core/draw_list.zig");

/// Text-measurement seam (Phase 2). Impl in `src/render/impeller/text.zig`.
pub const text = @import("core/text.zig");

/// Input state + hit-testing (Phase 3). See `src/input/input.zig`.
pub const input = @import("input/input.zig");

/// Keyboard-focus state, shared by both frontends (Phase 4). See `src/input/focus.zig`.
pub const focus = @import("input/focus.zig");

/// Clipboard seam (Phase 4). See `src/input/clipboard.zig`.
pub const clipboard = @import("input/clipboard.zig");

/// Layout engine — measure/arrange, own box model (Phase 3). See `src/core/layout.zig`.
pub const layout = @import("core/layout.zig");

/// Paint — walk a laid-out node tree into a draw list (Phase 3). See `src/core/paint.zig`.
pub const paint = @import("core/paint.zig");

/// Immediate-mode frontend (Phase 3). See `src/ui/immediate.zig`.
pub const immediate = @import("ui/immediate.zig");

/// Retained-mode frontend (Phase 3). See `src/ui/retained.zig`.
pub const retained = @import("ui/retained.zig");

/// Widgets — checkbox, slider, text field, scroll (Phase 4). See `src/ui/widgets.zig`.
pub const widgets = @import("ui/widgets.zig");

/// Impeller Vulkan backend (Phase 0/1). See `src/render/impeller/renderer.zig`.
pub const backend = @import("render/impeller/renderer.zig");

/// Software raster backend (Phase 4) — same draw list, CPU RGBA8 buffer, no GPU.
pub const raster = @import("render/raster/renderer.zig");

test {
    // Pull submodule tests into the module test run.
    std.testing.refAllDecls(@This());
}
