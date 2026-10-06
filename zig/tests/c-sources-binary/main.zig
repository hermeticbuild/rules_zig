const std = @import("std");

extern const symbol_a: i32;
extern const symbol_b: i32;

pub fn main(init: std.process.Init) !void {
    var buffer: [512]u8 = undefined;
    var writer = std.Io.File.stdout().writer(init.io, &buffer);
    const stdout = &writer.interface;
    try stdout.print("{d}\n", .{symbol_a + symbol_b});
    try stdout.flush();
}
