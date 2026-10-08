const std = @import("std");
const lib = @import("lib");

pub fn main(init: std.process.Init) !void {
    var buffer: [64]u8 = undefined;
    var writer = std.Io.File.stdout().writer(init.io, &buffer);
    const stdout = &writer.interface;
    try stdout.print("value={}\n", .{lib.value()});
    try stdout.flush();
}
