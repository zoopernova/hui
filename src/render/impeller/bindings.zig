//! FFI bindings to the standalone Impeller C API (`impeller.h`).
//!
//! Thin by design: expose the raw translated C namespace as `c`, plus small
//! helpers only where a raw call is awkward. Backends (see `src/backend/`) build
//! on this; nothing above the backend layer should import this directly.
//!
//! SDK pinned in `build.zig.zon` (`.impeller`) — Flutter stable 3.47.1, Impeller
//! v1.4.0. Vulkan interop requires >= 1.4.

pub const c = @cImport({
    @cInclude("impeller.h");
});

/// The packed version the header was compiled against, for `ImpellerContextCreate*New`.
/// The `IMPELLER_VERSION` macro is multi-line and doesn't translate, so rebuild it
/// from the component defines (same bit layout as `IMPELLER_MAKE_VERSION`). Must
/// match the linked lib's `ImpellerGetVersion()` or context creation fails by design.
pub const version_packed: u32 =
    (@as(u32, c.IMPELLER_VERSION_VARIANT) << 29) |
    (@as(u32, c.IMPELLER_VERSION_MAJOR) << 22) |
    (@as(u32, c.IMPELLER_VERSION_MINOR) << 12) |
    @as(u32, c.IMPELLER_VERSION_PATCH);

/// Runtime version of the linked `libimpeller.so`, decoded from `ImpellerGetVersion()`.
pub const Version = struct {
    variant: u32,
    major: u32,
    minor: u32,
    patch: u32,

    pub fn get() Version {
        const v = c.ImpellerGetVersion();
        // ponytail: mirror the IMPELLER_VERSION_GET_* bit layout from impeller.h
        // (variant<<29 | major<<22 | minor<<12 | patch). Hand-decoded because the
        // macros don't translate to callable Zig.
        return .{
            .variant = v >> 29,
            .major = (v >> 22) & 0x7f,
            .minor = (v >> 12) & 0x3ff,
            .patch = v & 0xfff,
        };
    }
};

test "linked libimpeller reports a sane version" {
    const std = @import("std");
    const v = Version.get();
    // Proves both translate-c and linking work: we called into the .so.
    try std.testing.expect(v.variant >= 1);
    try std.testing.expect(v.major >= 1); // pinned SDK is 1.4.x
}
