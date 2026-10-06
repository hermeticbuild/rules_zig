const std = @import("std");

extern fn add(u8, u8) u8;

pub fn main(init: std.process.Init) !void {
    const three = add(1, 2);
    var buffer: [512]u8 = undefined;
    var writer = std.Io.File.stdout().writer(init.io, &buffer);
    const stdout = &writer.interface;
    try stdout.print("{d}\n", .{three});
    try stdout.flush();
}

test "One plus two equals three" {
    try std.testing.expectEqual(@as(u8, 3), add(1, 2));
}
