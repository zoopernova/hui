//! Geometry + color primitives — the bottom layer everyone shares.
//!
//! These are plain value types with no behavior and no dependencies, so layout,
//! input, the draw list, text measurement, and the frontends can all speak the same
//! vocabulary without importing each other. Homing them here (rather than inside a
//! rendering or layout module) is what keeps those modules from coupling through a
//! borrowed type. Pixel/layout units are `f32`; window *pixel* extent is a distinct
//! integer type (`embedder.Extent`) on purpose.

pub const Color = struct { r: f32, g: f32, b: f32, a: f32 = 1.0 };
pub const Point = struct { x: f32, y: f32 };
/// Axis-aligned rectangle, top-left origin.
pub const Rect = struct { x: f32, y: f32, w: f32, h: f32 };
/// A width/height in layout units.
pub const Size = struct { w: f32 = 0, h: f32 = 0 };
