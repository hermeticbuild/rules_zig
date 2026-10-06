const builtin = @import("builtin");
const std = @import("std");

const is_zig_0_17_or_later = builtin.zig_version.major == 0 and builtin.zig_version.minor >= 17;

const c = if (is_zig_0_17_or_later) @import("c") else @import("cimport").c;

pub fn main(init: std.process.Init) !void {
    var buffer: [512]u8 = undefined;
    var writer = std.Io.File.stdout().writer(init.io, &buffer);
    const stdout = &writer.interface;
    try stdout.print("{d}\n", .{c.THREE});
    try stdout.flush();
}

test "One plus two equals three" {
    try std.testing.expectEqual(@as(u8, 3), c.THREE);
}
