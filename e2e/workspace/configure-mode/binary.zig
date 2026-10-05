const std = @import("std");
const builtin = @import("builtin");

const is_zig_0_16_or_later = builtin.zig_version.major == 0 and builtin.zig_version.minor >= 16;

const mode_name = switch (builtin.mode) {
    std.builtin.OptimizeMode.Debug => "Debug",
    std.builtin.OptimizeMode.ReleaseSafe => "ReleaseSafe",
    std.builtin.OptimizeMode.ReleaseFast => "ReleaseFast",
    std.builtin.OptimizeMode.ReleaseSmall => "ReleaseSmall",
};

pub const main = if (is_zig_0_16_or_later) main_016 else main_pre_016;

fn main_pre_016() !void {
    var buffer: [512]u8 = undefined;
    var writer = std.fs.File.stdout().writer(&buffer);
    const stdout = &writer.interface;
    try stdout.print("{s}\n", .{mode_name});
    try stdout.flush();
}

fn main_016(init: std.process.Init) !void {
    var buffer: [512]u8 = undefined;
    var writer = std.Io.File.stdout().writer(init.io, &buffer);
    const stdout = &writer.interface;
    try stdout.print("{s}\n", .{mode_name});
    try stdout.flush();
}
