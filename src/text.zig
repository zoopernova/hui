//! Text seam — the neutral interface between the layout engine (which must measure
//! glyph runs to size `fit` content) and whatever backend actually rasterizes text.
//!
//! Homing `Measurer` here (not in `layout.zig`) is what lets the render backend
//! implement text measurement without the backend importing the layout engine. The
//! Impeller implementation lives in `backend/impeller_text.zig`; a future software
//! raster backend (Phase 4) will implement the same seam via its own glyph
//! rasterizer. Depends only on `geometry`.
//!
//! Reserved for Phase 4: a `glyph`/`font` rasterization interface alongside
//! `Measurer`, added when the raster backend needs CPU glyphs (kept out until then —
//! no implementation exists yet to shape it against).

const geometry = @import("geometry.zig");

/// The font both backends load. ponytail: one hardcoded face on this machine
/// (fc-match "Noto Sans"). Upgrade path: fontconfig lookup / embedder-supplied bytes.
pub const default_font_path = "/usr/share/fonts/noto/NotoSans-Regular.ttf";

/// Measured extent of a laid-out glyph run.
pub const Metrics = geometry.Size;

/// Text-measurement hook a backend supplies to the layout engine. `ctx` is opaque
/// (the backend's typography state).
pub const Measurer = struct {
    ctx: ?*anyopaque,
    func: *const fn (ctx: ?*anyopaque, str: []const u8, size: f32) Metrics,
    pub fn measure(self: Measurer, str: []const u8, size: f32) Metrics {
        return self.func(self.ctx, str, size);
    }
};
