const std = @import("std");

extern fn addThroughMiddle(u8, u8) u8;

pub fn main(init: std.process.Init) !void {
    var buffer: [16]u8 = undefined;
    var writer = std.Io.File.stdout().writer(init.io, &buffer);
    try writer.interface.print("{d}\n", .{addThroughMiddle(1, 2)});
    try writer.interface.flush();
}
