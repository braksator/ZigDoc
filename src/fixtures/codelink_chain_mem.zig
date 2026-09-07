//! Stand-in for `std/mem.zig`: re-exports a decl that lives in its own file.
pub const Allocator = @import("codelink_chain_allocator.zig");
