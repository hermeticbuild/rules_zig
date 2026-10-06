const std = @import("std");
const builtin = @import("builtin");

pub fn main(init: std.process.Init) void {
    var buffer: [512]u8 = undefined;
    var writer = std.Io.File.stdout().writer(init.io, &buffer);
    const stdout = &writer.interface;
    stdout.print("{}\n", .{builtin.single_threaded}) catch unreachable;
    stdout.flush() catch unreachable;
}
