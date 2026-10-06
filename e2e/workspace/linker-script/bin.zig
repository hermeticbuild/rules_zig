const std = @import("std");

extern const custom_global_symbol: u8;

pub fn main(init: std.process.Init) !void {
    var buffer: [512]u8 = undefined;
    var writer = std.Io.File.stdout().writer(init.io, &buffer);
    const stdout = &writer.interface;
    try stdout.print("{d}\n", .{custom_global_symbol});
    try stdout.flush();
}
