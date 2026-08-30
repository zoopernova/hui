//! Clipboard seam — a neutral interface so widgets (the text field) can cut/copy/
//! paste without importing a platform/embedder. The embedder provides an
//! implementation (SDL3: `Sdl3.clipboard()`); the app hands it to widgets that want it.

pub const Clipboard = struct {
    ctx: ?*anyopaque,
    /// Returns the clipboard's current UTF-8 text. The slice is valid until the next
    /// `get` call on the same clipboard (copy it if you need to retain it).
    get_fn: *const fn (ctx: ?*anyopaque) []const u8,
    set_fn: *const fn (ctx: ?*anyopaque, text: []const u8) void,

    pub fn get(self: Clipboard) []const u8 {
        return self.get_fn(self.ctx);
    }
    pub fn set(self: Clipboard, text: []const u8) void {
        self.set_fn(self.ctx, text);
    }
};
