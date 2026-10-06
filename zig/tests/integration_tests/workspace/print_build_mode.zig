const builtin = @import("builtin");
const std = @import("std");

const mode_name = switch (builtin.mode) {
    std.builtin.OptimizeMode.Debug => "Debug",
    std.builtin.OptimizeMode.ReleaseSafe => "ReleaseSafe",
    std.builtin.OptimizeMode.ReleaseFast => "ReleaseFast",
    std.builtin.OptimizeMode.ReleaseSmall => "ReleaseSmall",
};

pub fn main(init: std.process.Init) void {
    std.Io.File.writeStreamingAll(.stdout(), init.io, mode_name) catch unreachable;
}
