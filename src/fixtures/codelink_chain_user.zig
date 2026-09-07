//! A file that imports the root and takes a two-hop dotted shortcut,
//! matching the `const Allocator = std.mem.Allocator;` idiom used
//! throughout Zig's own standard library.
const std = @import("codelink_chain_std.zig");
const Allocator = std.mem.Allocator;
