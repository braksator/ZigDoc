//! Stand-in for `std/mem/Allocator.zig`: the actual documented content,
//! reached only via two hops of bare re-export. Real `@This()`-style
//! files like Zig's own `Allocator.zig` have no nested decl of the same
//! name inside them -- the file itself is what a chain bottoms out on.
pub fn create() void {}
