//! Shared single-line stderr progress indicator: repeated `update`
//! calls overwrite the same line rather than printing a new one.
const std = @import("std");
const builtin = @import("builtin");

const spaces: [512]u8 = @splat(' ');

pub const Progress = struct {
    width: usize = 0,

    pub fn update(self: *Progress, comptime fmt: []const u8, args: anytype) void {
        if (builtin.is_test) return;
        var buf: [512]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, fmt, args) catch return;
        std.debug.print("\r{s}", .{msg});
        if (msg.len < self.width) std.debug.print("{s}", .{spaces[0 .. self.width - msg.len]});
        self.width = msg.len;
    }

    pub fn clear(self: *Progress) void {
        if (builtin.is_test) return;
        if (self.width == 0) return;
        std.debug.print("\r{s}\r", .{spaces[0..@min(self.width, spaces.len)]});
        self.width = 0;
    }
};
