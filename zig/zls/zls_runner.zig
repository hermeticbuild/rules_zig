/// Custom ZLS launcher.
///
/// Sets up paths to ZLS dependencies with Bazel runfiles.
///
/// This file is used as a template by `zls_write_runner_zig_src.bzl`.
const std = @import("std");
const builtin = @import("builtin");

const bazel_builtin = @import("bazel_builtin");
const common = @import("zls_runner_common");

const Config = struct {
    /// Override the Zig library path. Will be automatically resolved using the 'zig_exe_path'.
    zig_lib_path: ?[]const u8 = null,

    /// Specify the path to the Zig executable (not the directory). If unset, zig is looked up in `PATH`. e.g. `/path/to/zig-templeos-armless-1.0.0/zig`.
    zig_exe_path: ?[]const u8 = null,

    /// Specify a custom build runner to resolve build system information.
    build_runner_path: ?[]const u8 = null,

    /// Path to a directory that will be used as zig's cache. Will default to `${KnownFolders.Cache}/zls`.
    global_cache_path: ?[]const u8 = null,

    /// Build-on-save expects a watch-capable Zig build runner protocol.
    enable_build_on_save: ?bool = false,
};

fn exitCode(term: std.process.Child.Term) u8 {
    return switch (term) {
        .exited => |code| @intCast(code),
        .signal => |signal| @intCast(128 + @as(u16, @intCast(@intFromEnum(signal)))),
        else => 1,
    };
}

fn run(init: std.process.Init) !u8 {
    const io = init.io;

    if (builtin.zig_version.major != 0 or builtin.zig_version.minor != 16) {
        return error.UnsupportedZigVersionForZls;
    }

    const runtime = try common.Runtime.create(init, bazel_builtin.current_repository);
    const zls_bin_path = try runtime.resolve("__ZLS_BIN_RPATH__");
    const zig_exe_path = try runtime.resolve("__ZIG_EXE_RPATH__");
    const zig_lib_computed_path = try runtime.resolve("__ZIG_LIB_RPATH__");
    const zls_build_runner_path = try runtime.resolve("__ZLS_BUILD_RUNNER_RPATH__");
    const global_cache_path = "__GLOBAL_CACHE_PATH__";

    const config: Config = .{
        .zig_exe_path = zig_exe_path,
        .zig_lib_path = zig_lib_computed_path,
        .build_runner_path = zls_build_runner_path,
        .global_cache_path = global_cache_path,
    };

    var launch = try common.Launch.create(init, zls_bin_path, zig_lib_computed_path, global_cache_path, config);
    defer launch.deinit();

    var child = try std.process.spawn(io, .{
        .argv = launch.argv,
        .environ_map = &launch.environ_map,
    });
    return exitCode(try child.wait(io));
}

pub fn main(init: std.process.Init) void {
    const code = run(init) catch |err| {
        if (err != error.Canceled) std.log.err("ZLS launcher: {s}", .{@errorName(err)});
        std.process.exit(if (err == error.Canceled) 130 else 1);
    };
    std.process.exit(code);
}
