/// Custom ZLS launcher.
///
/// Sets up paths to ZLS dependencies with Bazel runfiles and implements the
/// compiler proxy for the native Zig build protocol.
///
/// This file is used as a template by `zls_write_runner_zig_src.bzl`.
const std = @import("std");
const builtin = @import("builtin");

const bazel_builtin = @import("bazel_builtin");
const common = @import("zls_runner_common");
const owned = @import("owned_process");
const bsp = @import("zls_bsp");

const Config = struct {
    /// Override the Zig library path. Will be automatically resolved using the 'zig_exe_path'.
    zig_lib_path: ?[]const u8 = null,

    /// Specify the path to the Zig executable (not the directory). If unset, zig is looked up in `PATH`. e.g. `/path/to/zig-templeos-armless-1.0.0/zig`.
    zig_exe_path: ?[]const u8 = null,

    /// Path to a directory that will be used as zig's cache. Will default to `${KnownFolders.Cache}/zls`.
    global_cache_path: ?[]const u8 = null,

    /// Build-on-save expects a watch-capable Zig build runner protocol.
    enable_build_on_save: ?bool = false,
};

fn exitCode(term: std.process.Child.Term) u8 {
    return switch (term) {
        .exited => |code| @intCast(code),
        .signal => |signal| @intCast(128 + @as(u16, @intCast(@backingInt(signal)))),
        else => 1,
    };
}

fn proxy(init: std.process.Init, args: []const []const u8) !u8 {
    const allocator = init.arena.allocator();
    const sdk = init.environ_map.get("RULES_ZIG_ZLS_SDK") orelse return error.MissingSdk;
    if (args.len == 2 and std.mem.eql(u8, args[1], "env")) {
        const result = try owned.capture(init, .{ .argv = &.{ sdk, "env" } }, null);
        try std.Io.File.stderr().writeStreamingAll(init.io, result.stderr);
        if (!result.term.success()) {
            try std.Io.File.stdout().writeStreamingAll(init.io, result.stdout);
            return exitCode(result.term);
        }
        const Env = struct {
            zig_exe: []const u8,
            lib_dir: ?[]const u8,
            std_dir: []const u8,
            global_cache_dir: []const u8,
            version: []const u8,
            target: ?[]const u8 = null,
        };
        var diagnostics: std.zon.parse.Diagnostics = undefined;
        var env = try std.zon.parse.fromSlice(Env, .{
            .arena = allocator,
            .gpa = allocator,
            .diagnostics = &diagnostics,
            .source = try allocator.dupeSentinel(u8, result.stdout, 0),
            .ignore_unknown_fields = true,
        });
        // ZLS uses zig_exe from zig env for subsequent commands. Keep them
        // routed through the proxy.
        env.zig_exe = try std.process.executablePathAlloc(init.io, allocator);
        var buffer: [4096]u8 = undefined;
        var stdout = std.Io.File.stdout().writer(init.io, &buffer);
        try std.json.Stringify.value(env, .{}, &stdout.interface);
        try stdout.interface.flush();
        return 0;
    }
    if (args.len > 1 and std.mem.eql(u8, args[1], "build")) {
        const temp = try common.TempDir.create(init);
        defer temp.deinit();
        const config = try std.fmt.allocPrint(allocator, "{s}/configuration", .{temp.path});
        // Every configuration load re-evaluates Bazel, as the legacy runner did.
        const version = "--@zig_toolchains//:version=" ++ builtin.zig_version_string;
        const command: []const []const u8 = &.{ "bazel", "run", version, "--", "__COMPLETION_PRINTER_TARGET__" };
        const supported = args.len == 3 and std.mem.eql(u8, args[2], "--listen=-");
        try bsp.serve(init, config, command, supported);
        return 0;
    }
    const command = try allocator.alloc([]const u8, args.len);
    command[0] = sdk;
    @memcpy(command[1..], args[1..]);
    var child = try owned.Owned.spawn(init.io, .{ .argv = command });
    defer child.deinit();
    return exitCode(try child.join(null));
}

fn run(init: std.process.Init) !u8 {
    const arena = init.arena;
    const io = init.io;

    if (!owned.supported) {
        return error.NativeZlsRequiresLinuxOrMacOS;
    }
    owned.install();
    defer owned.restore();

    const args = try init.minimal.args.toSlice(arena.allocator());
    if (init.environ_map.get("RULES_ZIG_ZLS_SDK") != null) {
        return proxy(init, args);
    }

    const runtime = try common.Runtime.create(init, bazel_builtin.current_repository);
    const zls_bin_path = try runtime.resolve("__ZLS_BIN_RPATH__");
    const zig_exe_path = try runtime.resolve("__ZIG_EXE_RPATH__");
    const zig_lib_computed_path = try runtime.resolve("__ZIG_LIB_RPATH__");
    const global_cache_path = "__GLOBAL_CACHE_PATH__";

    const config: Config = .{
        .zig_exe_path = try std.process.executablePathAlloc(io, arena.allocator()),
        .zig_lib_path = zig_lib_computed_path,
        .global_cache_path = global_cache_path,
    };

    var launch = try common.Launch.create(init, zls_bin_path, zig_lib_computed_path, global_cache_path, config);
    defer launch.deinit();
    try launch.environ_map.put("RULES_ZIG_ZLS_SDK", zig_exe_path);

    var child = try owned.Owned.spawn(io, .{
        .argv = launch.argv,
        .environ_map = &launch.environ_map,
    });
    child.grace_ms = 2000; // Inner metadata owners get time to stop and reap.
    defer child.deinit();
    return exitCode(try child.join(null));
}

pub fn main(init: std.process.Init) void {
    const code = run(init) catch |err| {
        if (err != error.Canceled) std.log.err("ZLS launcher: {s}", .{@errorName(err)});
        std.process.exit(if (err == error.Canceled) 130 else 1);
    };
    std.process.exit(code);
}
