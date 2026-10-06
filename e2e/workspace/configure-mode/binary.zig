const std = @import("std");
const builtin = @import("builtin");

const mode_name = switch (builtin.mode) {
    std.builtin.OptimizeMode.Debug => "Debug",
    std.builtin.OptimizeMode.ReleaseSafe => "ReleaseSafe",
    std.builtin.OptimizeMode.ReleaseFast => "ReleaseFast",
    std.builtin.OptimizeMode.ReleaseSmall => "ReleaseSmall",
};

pub fn main(init: std.process.Init) !void {
    var buffer: [512]u8 = undefined;
    var writer = std.Io.File.stdout().writer(init.io, &buffer);
    const stdout = &writer.interface;
    try stdout.print("{s}\n", .{mode_name});
    try stdout.flush();
}
