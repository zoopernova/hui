//! stb_truetype binding for the software-raster backend's glyph rasterizer.
//!
//! We `@cInclude` only the *declarations* — the implementation (guarded by
//! `STB_TRUETYPE_IMPLEMENTATION`) is compiled as real C in `src/vendor/stb_impl.c`
//! (wired in build.zig), because Zig's translate-c mis-handles a couple of stb's
//! implementation macros. Clang compiles that section fine; the linker resolves the
//! symbols. Vendored header is `src/vendor/stb_truetype.h` (public domain, v1.26).

pub const c = @cImport({
    @cInclude("stb_truetype.h");
});
