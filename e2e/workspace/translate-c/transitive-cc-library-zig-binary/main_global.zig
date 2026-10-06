const std = @import("std");
const c = @import("c");

pub fn main(init: std.process.Init) !void {
    var buffer: [512]u8 = undefined;
    var writer = std.Io.File.stdout().writer(init.io, &buffer);
    const stdout = &writer.interface;
    try stdout.print("global={}\n", .{c.global()});
    try stdout.flush();
}
