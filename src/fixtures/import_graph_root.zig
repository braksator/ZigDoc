//! Root of a small import graph fixture.
pub const child = @import("import_graph_child.zig");
pub const left = @import("import_graph_diamond_left.zig");
pub const right = @import("import_graph_diamond_right.zig");

/// Declared directly on the root, not via an import.
pub fn ownDecl() void {}
