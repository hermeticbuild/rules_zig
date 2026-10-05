const std = @import("std");
const builtin = @import("builtin");
const c = std.builtin.CallingConvention.c;

const mode_name = switch (builtin.mode) {
    std.builtin.OptimizeMode.Debug => "Debug",
    std.builtin.OptimizeMode.ReleaseSafe => "ReleaseSafe",
    std.builtin.OptimizeMode.ReleaseFast => "ReleaseFast",
    std.builtin.OptimizeMode.ReleaseSmall => "ReleaseSmall",
};

comptime {
    @export(&internalName, .{
        .name = mode_name,
        .linkage = .strong,
    });
}

fn internalName() callconv(c) void {}
