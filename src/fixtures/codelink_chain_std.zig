//! Stand-in for `std.zig`: re-exports a submodule via a bare `@import`.
pub const mem = @import("codelink_chain_mem.zig");
