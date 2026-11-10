/// Custom ZLS launcher.
///
/// Sets up paths to ZLS dependencies with Bazel runfiles.
///
/// This file is used as a template by `zls_write_runner_zig_src.bzl`.
const std = @import("std");
const builtin = @import("builtin");

const bazel_builtin = @import("bazel_builtin");
const runfiles = @import("runfiles");

const native_protocol = builtin.zig_version.major == 0 and builtin.zig_version.minor == 17;
const owned = @import("owned_process");

const TempDir = struct {
    path: []const u8,
    io: std.Io,

    fn create(init: std.process.Init) !TempDir {
        const base = init.environ_map.get("TMPDIR") orelse init.environ_map.get("TEMP") orelse init.environ_map.get("TMP") orelse
            if (builtin.os.tag == .windows) return error.TemporaryDirectoryNotConfigured else "/tmp";
        var random: u128 = undefined;
        init.io.random(std.mem.asBytes(&random));
        const path = try std.fmt.allocPrint(init.arena.allocator(), "{s}/rules-zig-zls-{s}", .{ base, std.fmt.hex(random) });
        try std.Io.Dir.createDirAbsolute(init.io, path, if (builtin.os.tag == .windows) .default_dir else .fromMode(0o700));
        return .{ .path = path, .io = init.io };
    }

    fn deinit(self: TempDir) void {
        std.Io.Dir.cwd().deleteTree(self.io, self.path) catch {};
    }
};

fn exitCode(term: std.process.Child.Term) u8 {
    return switch (term) {
        .exited => |code| @intCast(code),
        .signal => |signal| @intCast(128 + @as(u16, @intCast(__SIGNAL_NUMBER__))),
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
        env.zig_exe = try std.process.executablePathAlloc(init.io, allocator);
        var buffer: [4096]u8 = undefined;
        var stdout = std.Io.File.stdout().writer(init.io, &buffer);
        try std.json.Stringify.value(env, .{}, &stdout.interface);
        try stdout.interface.flush();
        return 0;
    }
    if (args.len > 1 and std.mem.eql(u8, args[1], "build")) {
        const temp = try TempDir.create(init);
        defer temp.deinit();
        const config = try std.fmt.allocPrint(allocator, "{s}/configuration", .{temp.path});
        // Every configuration load re-evaluates Bazel, as the legacy runner did.
        const version = "--@zig_toolchains//:version=" ++ builtin.zig_version_string;
        const command: []const []const u8 = &.{ "bazel", "run", version, "--", "__COMPLETION_PRINTER_TARGET__" };
        const supported = args.len == 3 and std.mem.eql(u8, args[2], "--listen=-");
        try @import("zls_bsp").serve(init, config, command, supported);
        return 0;
    }
    const command = try allocator.alloc([]const u8, args.len);
    command[0] = sdk;
    @memcpy(command[1..], args[1..]);
    var child = try owned.Owned.spawn(init.io, .{ .argv = command });
    defer child.deinit();
    return exitCode(try child.join(null));
}

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

fn run(init: std.process.Init) !u8 {
    const arena = init.arena;
    const io = init.io;
    const args = try init.minimal.args.toSlice(arena.allocator());
    if (native_protocol) {
        if (!owned.supported) return error.NativeZlsRequiresLinuxOrMacOS;
        owned.install();
    } else if (builtin.zig_version.major != 0 or builtin.zig_version.minor != 16) {
        return error.UnsupportedZigVersionForZls;
    }
    defer if (native_protocol) owned.restore();
    if (native_protocol and init.environ_map.get("RULES_ZIG_ZLS_SDK") != null) return proxy(init, args);

    var r_ = try runfiles.Runfiles.create(.{ .allocator = arena.allocator(), .io = io, .environ_map = init.environ_map, .argv = init.minimal.args }) orelse
        return error.RunfilesNotFound;
    const r = r_.withSourceRepo(bazel_builtin.current_repository);

    const zls_bin_rpath = "__ZLS_BIN_RPATH__";
    var zls_bin_path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const zls_bin_path = try r.rlocation(zls_bin_rpath, &zls_bin_path_buf) orelse
        return error.RLocationNotFound;

    const zig_exe_rpath = "__ZIG_EXE_RPATH__";
    var zig_exe_path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const zig_exe_path = try r.rlocation(zig_exe_rpath, &zig_exe_path_buf) orelse
        return error.RLocationNotFound;

    const zig_lib_path = "__ZIG_LIB_RPATH__";
    var zig_lib_path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const zig_lib_computed_path = try r.rlocation(zig_lib_path, &zig_lib_path_buf) orelse
        return error.RLocationNotFound;

    const zls_build_runner_rpath = "__ZLS_BUILD_RUNNER_RPATH__";
    var zls_build_runner_path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const zls_build_runner_path = try r.rlocation(zls_build_runner_rpath, &zls_build_runner_path_buf) orelse
        return error.RLocationNotFound;

    const global_cache_path = "__GLOBAL_CACHE_PATH__";

    const config: Config = .{
        .zig_exe_path = if (native_protocol) try std.process.executablePathAlloc(io, arena.allocator()) else zig_exe_path,
        .zig_lib_path = zig_lib_computed_path,
        .build_runner_path = if (native_protocol) null else zls_build_runner_path,
        .global_cache_path = global_cache_path,
    };

    const temp = try TempDir.create(init);
    defer temp.deinit();
    const tmp_file_path = try std.fmt.allocPrint(arena.allocator(), "{s}/zls.json", .{temp.path});

    {
        var tmp_file = try std.Io.Dir.createFileAbsolute(io, tmp_file_path, .{});
        defer tmp_file.close(io);

        var out_buf: [4096]u8 = undefined;
        var tmp_file_writer = tmp_file.writer(io, &out_buf);

        const formatter = std.json.fmt(config, .{ .whitespace = .indent_2, .emit_null_optional_fields = false });

        try tmp_file_writer.interface.print("{f}", .{formatter});
        try tmp_file_writer.interface.flush();
    }

    const exec_args_len = args.len - 1 + 3; // Skip args[0] and add "zls" + --config-path + tmp_file_path
    var exec_args = try arena.allocator().alloc([]const u8, exec_args_len);

    exec_args[0] = zls_bin_path; // "zls"

    @memcpy(exec_args[1 .. exec_args.len - 2], args[1..]);
    @memcpy(exec_args[exec_args.len - 2 ..], &[_][]const u8{
        "--config-path",
        tmp_file_path,
    });
    var child_env_map: std.process.Environ.Map = .init(arena.allocator());
    defer child_env_map.deinit();
    for (init.environ_map.keys(), init.environ_map.values()) |key, value| {
        try child_env_map.put(key, value);
    }
    try child_env_map.put("ZIG_LIB_DIR", zig_lib_computed_path);
    try child_env_map.put("ZIG_GLOBAL_CACHE_DIR", global_cache_path);
    try child_env_map.put("ZIG_LOCAL_CACHE_DIR", global_cache_path);
    if (native_protocol) try child_env_map.put("RULES_ZIG_ZLS_SDK", zig_exe_path);

    if (native_protocol) {
        var child = try owned.Owned.spawn(io, .{ .argv = exec_args, .environ_map = &child_env_map });
        child.grace_ms = 2000; // Inner metadata owners get time to stop and reap.
        defer child.deinit();
        return exitCode(try child.join(null));
    }
    var child = try std.process.spawn(io, .{
        .argv = exec_args,
        .environ_map = &child_env_map,
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
