//! Root module that instantiates a generic type imported from another
//! file. `Box` is not an `@import` boundary itself (it's an ordinary
//! decl on this page); its body's real `sourceFile` is the imported
//! file, not this one.

const generic_container = @import("generic_container.zig");

/// Instantiated container of `u32`.
pub const Box = generic_container.Container(u32);

/// An ordinary same-file struct, for contrast.
pub const Plain = struct {
    /// A same-file method.
    pub fn touch(self: Plain) void {
        _ = self;
    }
};

/// A real decl whose bare name collides with the generic container's
/// own `comptime T: type` parameter, over in `generic_container.zig`.
/// That parameter must never itself resolve to a link (it shadows,
/// it isn't a decl) — this collision is what let it fall through to
/// this decl's bare-name table entry instead and render as a dead
/// self-link in `Container`'s own signature.
pub const T = struct {
    marker: bool = false,
};
