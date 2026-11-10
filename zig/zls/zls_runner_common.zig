/// Shared ZLS launcher setup.
///
/// Resolves runfiles and prepares configuration, arguments and environment.
/// Each launcher owns its child process.
const std = @import("std");
const builtin = @import("builtin");

const Runfiles = @import("runfiles").Runfiles;

pub const Runtime = struct {
    runfiles: Runfiles,
    source_repo: []const u8,
    allocator: std.mem.Allocator,

    pub fn create(init: std.process.Init, source_repo: []const u8) !Runtime {
        return .{
            .runfiles = try Runfiles.create(.{ .allocator = init.arena.allocator(), .io = init.io, .environ_map = init.environ_map, .argv = init.minimal.args }) orelse
                return error.RunfilesNotFound,
            .source_repo = source_repo,
            .allocator = init.arena.allocator(),
        };
    }

    pub fn resolve(self: *const Runtime, rpath: []const u8) ![]const u8 {
        return try self.runfiles.withSourceRepo(self.source_repo).rlocationAlloc(self.allocator, rpath) orelse
            error.RLocationNotFound;
    }
};

pub const TempDir = struct {
    path: []const u8,
    io: std.Io,

    pub fn create(init: std.process.Init) !TempDir {
        const base = init.environ_map.get("TMPDIR") orelse init.environ_map.get("TEMP") orelse init.environ_map.get("TMP") orelse
            if (builtin.os.tag == .windows) return error.TemporaryDirectoryNotConfigured else "/tmp";
        var random: u128 = undefined;
        init.io.random(std.mem.asBytes(&random));
        const path = try std.fmt.allocPrint(init.arena.allocator(), "{s}/rules-zig-zls-{s}", .{ base, std.fmt.hex(random) });
        try std.Io.Dir.createDirAbsolute(init.io, path, if (builtin.os.tag == .windows) .default_dir else .fromMode(0o700));
        return .{ .path = path, .io = init.io };
    }

    pub fn deinit(self: TempDir) void {
        std.Io.Dir.cwd().deleteTree(self.io, self.path) catch {};
    }
};

pub const Launch = struct {
    temp: TempDir,
    argv: []const []const u8,
    environ_map: std.process.Environ.Map,

    pub fn create(init: std.process.Init, zls_bin_path: []const u8, zig_lib_computed_path: []const u8, global_cache_path: []const u8, config: anytype) !Launch {
        const arena = init.arena;
        const io = init.io;

        const temp = try TempDir.create(init);
        errdefer temp.deinit();
        const tmp_file_path = try std.fmt.allocPrint(arena.allocator(), "{s}/zls.json", .{temp.path});

        {
            var tmp_file = try std.Io.Dir.createFileAbsolute(io, tmp_file_path, .{});
            defer tmp_file.close(io);

            var out_buf: [4096]u8 = undefined;
            var tmp_file_writer = tmp_file.writer(io, &out_buf);

            const formatter = std.json.fmt(config, .{ .whitespace = .indent_2 });

            try tmp_file_writer.interface.print("{f}", .{formatter});
            try tmp_file_writer.interface.flush();
        }

        const args = init.minimal.args.toSlice(arena.allocator()) catch return error.ArgsAllocFailed;

        const exec_args_len = args.len - 1 + 3; // Skip args[0] and add "zls" + --config-path + tmp_file_path
        var exec_args = try arena.allocator().alloc([]const u8, exec_args_len);

        exec_args[0] = zls_bin_path; // "zls"

        @memcpy(exec_args[1 .. exec_args.len - 2], args[1..]);
        @memcpy(exec_args[exec_args.len - 2 ..], &[_][]const u8{
            "--config-path",
            tmp_file_path,
        });
        var child_env_map: std.process.Environ.Map = .init(arena.allocator());
        errdefer child_env_map.deinit();
        for (init.environ_map.keys(), init.environ_map.values()) |key, value| {
            try child_env_map.put(key, value);
        }
        try child_env_map.put("ZIG_LIB_DIR", zig_lib_computed_path);
        try child_env_map.put("ZIG_GLOBAL_CACHE_DIR", global_cache_path);
        try child_env_map.put("ZIG_LOCAL_CACHE_DIR", global_cache_path);

        return .{ .temp = temp, .argv = exec_args, .environ_map = child_env_map };
    }

    pub fn deinit(self: *Launch) void {
        self.environ_map.deinit();
        self.temp.deinit();
    }
};
