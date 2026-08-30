//! Embedder contract (Phase 0.3, revised in 0.4) — the windowing seam.
//!
//! Flutter-style split: HUI's core renders into a surface an *embedder* provides.
//! The embedder owns the OS window, input, and the platform surface plumbing.
//! Nothing about widgets, layout, or the draw list belongs here.
//!
//! Contract shaped to the SDL3 + Vulkan + Impeller path (the chosen first target).
//! Note on ownership: with Impeller's Vulkan interop, **Impeller creates the
//! `VkInstance`** (via a proc-address callback) and its **swapchain owns per-frame
//! acquire/present**. So the embedder does NOT expose acquireFrame/present — those
//! are the backend/swapchain's job (0.5). The embedder only provides the surface
//! plumbing Impeller needs.
//!
//! Zig has no `interface` keyword — the contract is a comptime-checked convention.
//! An embedder is any struct exposing these decls:
//!
//!     init(gpa: std.mem.Allocator, config: Config) !Self
//!     deinit(self: *Self) void
//!     pollEvents(self: *Self, buf: []Event) ![]Event
//!     vkGetInstanceProcAddr(self: *Self) ?*const anyopaque  // PFN for Impeller's callback
//!     createVulkanSurface(self: *Self, instance: ?*anyopaque) !?*anyopaque  // VkSurfaceKHR
//!     drawableSize(self: *Self) Extent                        // pixels, for the swapchain
//!
//! Default per-target embedder selection: `Default` below.

const std = @import("std");
const builtin = @import("builtin");

/// Window creation parameters. Sentinel-terminated title so it can pass straight
/// to C windowing APIs (SDL3) without re-allocation.
pub const Config = struct {
    title: [:0]const u8 = "HUI",
    width: u32 = 800,
    height: u32 = 600,
};

/// Window drawable extent in **pixels** (integer). Distinct from `geometry.Size`
/// (f32 layout units) on purpose — see the D3/decoupling notes.
pub const Extent = struct { width: u32, height: u32 };

/// Input/window events surfaced by the embedder. Close + resize drive the loop;
/// pointer + keyboard events (Phase 3) feed input/hit-testing.
///
/// Pointer coordinates are in **pixels** (top-left origin) — the embedder scales
/// logical points by the window's pixel density so they share the draw list's space.
/// `key` uses the embedder's native scancode. `text` is a UTF-8 chunk valid only for
/// the current poll (consumers must copy to retain it).
pub const Event = union(enum) {
    close_requested,
    resized: Extent,
    pointer_motion: struct { x: f32, y: f32 },
    pointer_button: struct { x: f32, y: f32, down: bool },
    pointer_scroll: struct { dx: f32, dy: f32 },
    key: struct { scancode: u32, down: bool },
    text: struct { utf8: []const u8 },
};

/// The per-target default embedder. Consumers can ignore this and pass their own
/// conforming type instead (see `assertEmbedder`).
///
/// ponytail: single target today. Add cases as D4 expands; each is one line + a
/// new `embedder/<lib>.zig`. A build-option opt-out (bring-your-own, don't link
/// the default) is a later refinement — not built until a consumer needs it.
pub const Default = switch (builtin.os.tag) {
    .linux => @import("sdl3.zig").Sdl3,
    else => @compileError("HUI: no default embedder for this target yet (see ROADMAP D4)"),
};

/// Comptime-verify that `T` satisfies the embedder contract. Call from an embedder
/// impl (or its test) to get a clear error at the definition site instead of a
/// cryptic one at first use.
///
/// ponytail: checks decl presence, not full signatures — Zig type-checks the
/// actual calls at the use site anyway, so signature reflection here would be
/// redundant machinery. Upgrade to signature checks only if a wrong-shaped method
/// ever slips through to a confusing error.
pub fn assertEmbedder(comptime T: type) void {
    const required = [_][]const u8{
        "init",                  "deinit",
        "pollEvents",            "vkGetInstanceProcAddr",
        "createVulkanSurface",   "drawableSize",
    };
    inline for (required) |decl| {
        if (!@hasDecl(T, decl)) {
            @compileError(@typeName(T) ++ " is not a valid embedder: missing '" ++ decl ++ "'");
        }
    }
}

test "the default embedder satisfies the contract" {
    comptime assertEmbedder(Default);
}
