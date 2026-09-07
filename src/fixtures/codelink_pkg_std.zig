//! Root module for the package self-import test.
pub const zon_parse = @import("codelink_pkg_parse.zig");
const user = @import("codelink_pkg_user.zig");
