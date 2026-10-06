const std = @import("std");

const embedded = @embedFile("message.txt");

pub fn main(init: std.process.Init) !void {
    var buffer: [512]u8 = undefined;
    var writer = std.Io.File.stdout().writer(init.io, &buffer);
    const stdout = &writer.interface;
    try stdout.print("{s}", .{embedded});
    try stdout.flush();
}

test "embedded contents" {
    try std.testing.expectEqualStrings("Hello world!\n", embedded);
}
