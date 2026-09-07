const std = @import("codelink_void_std.zig");
const Allocator = std.mem.Allocator;

pub const Tz = struct {
    allocator: Allocator,
    footer: ?[]const u8,

    pub fn deinit(self: *Tz) void {
        if (self.footer) |footer| {
            self.allocator.free(footer);
        }
    }
};
