//! References the root by its own package name (`@import("codelink_pkg_std")`,
//! not a relative `.zig` path), then hops through a relative re-export to
//! reach a decl in a different file — mirroring
//! `const Allocator = std.mem.Allocator;` in Zig's real standard library,
//! where `std` is brought in via `@import("std")`.
const std = @import("codelink_pkg_std");
const SomeType = std.zon_parse.SomeType;
