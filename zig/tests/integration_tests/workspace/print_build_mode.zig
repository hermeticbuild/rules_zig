const builtin = @import("builtin");
const std = @import("std");

const is_zig_0_16_or_later = builtin.zig_version.major == 0 and builtin.zig_version.minor >= 16;

const mode_name = switch (builtin.mode) {
    std.builtin.OptimizeMode.Debug => "Debug",
    std.builtin.OptimizeMode.ReleaseSafe => "ReleaseSafe",
    std.builtin.OptimizeMode.ReleaseFast => "ReleaseFast",
    std.builtin.OptimizeMode.ReleaseSmall => "ReleaseSmall",
};

pub const main = if (is_zig_0_16_or_later) main_016 else main_pre_016;

fn main_pre_016() void {
    std.fs.File.stdout().writeAll(mode_name) catch unreachable;
}

fn main_016(init: std.process.Init) void {
    std.Io.File.writeStreamingAll(.stdout(), init.io, mode_name) catch unreachable;
}
