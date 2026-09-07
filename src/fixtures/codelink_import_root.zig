//! Root of a small import fixture for cross-file codelinks.
const mem = @import("codelink_import_leaf.zig");

/// Re-exported through a dotted chain that crosses an `@import`.
pub const Allocator = mem.Allocator;
