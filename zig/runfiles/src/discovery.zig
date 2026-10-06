//! Implements the runfiles strategy and discovery as defined in the following design document:
//! https://docs.google.com/document/d/e/2PACX-1vSDIrFnFvEYhKsCMdGdD40wZRBX3m3aZ5HhVj4CtHPmiXKDCxioTUbYsDydjKtFDAzER5eg7OjJWs3V/pub

const std = @import("std");
const builtin = @import("builtin");
const log = std.log.scoped(.runfiles);
const testutil = @import("testutil.zig");

pub const runfiles_manifest_var_name = "RUNFILES_MANIFEST_FILE";
pub const runfiles_directory_var_name = "RUNFILES_DIR";
pub const runfiles_manifest_suffix = ".runfiles_manifest";
pub const runfiles_directory_suffix = ".runfiles";
pub const repo_mapping_file_name = "_repo_mapping";

/// * Manifest-based: reads the runfiles manifest file to look up runfiles.
/// * Directory-based: appends the runfile's path to the runfiles root.
///   The client is responsible for checking that the resulting path exists.
pub const Strategy = enum {
    manifest,
    directory,
};

/// The path to a runfiles manifest file or a runfiles directory.
pub const Location = union(Strategy) {
    manifest: []const u8,
    directory: []const u8,

    pub fn deinit(self: *Location, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .manifest => |value| allocator.free(value),
            .directory => |value| allocator.free(value),
        }
    }
};

pub const DiscoverOptions = struct {
    /// Used during runfiles discovery.
    allocator: std.mem.Allocator,
    /// Used for IO operations during discovery.
    io: std.Io,
    /// Command-line arguments, used for runfiles discovery.
    argv: ?std.process.Args = null,
    /// Environment variables, used for runfiles discovery.
    environ_map: ?*std.process.Environ.Map = null,
    /// User override for the `RUNFILES_MANIFEST_FILE` variable.
    manifest: ?[]const u8 = null,
    /// User override for the `RUNFILES_DIRECTORY` variable.
    directory: ?[]const u8 = null,
    /// User override for `argv[0]`.
    argv0: ?[]const u8 = null,
};

pub const DiscoverError = std.fmt.BufPrintError || error{
    OutOfMemory,
    InvalidCmdLine,
    InvalidWtf8,
    MissingArg0,
};

/// The unified runfiles discovery strategy is to:
/// * check if `RUNFILES_MANIFEST_FILE` or `RUNFILES_DIR` envvars are set, and
///   again initialize a `Runfiles` object accordingly; otherwise
/// * check if the `argv[0] + ".runfiles_manifest"` file or the
///   `argv[0] + ".runfiles"` directory exists (keeping in mind that argv[0]
///   may not include the `".exe"` suffix on Windows), and if so, initialize a
///   manifest- or directory-based `Runfiles` object; otherwise
/// * assume the binary has no runfiles.
///
/// The caller has to free the path contained in the returned location.
pub fn discoverRunfiles(options: DiscoverOptions) DiscoverError!?Location {
    if (options.manifest) |value|
        return .{ .manifest = try options.allocator.dupe(u8, value) };

    if (options.directory) |value|
        return .{ .directory = try options.allocator.dupe(u8, value) };

    if (options.environ_map) |environ_map| {
        if (environ_map.get(runfiles_manifest_var_name)) |value|
            return .{ .manifest = try options.allocator.dupe(u8, value) };
        if (environ_map.get(runfiles_directory_var_name)) |value|
            return .{ .directory = try options.allocator.dupe(u8, value) };
    }

    var iter: ?std.process.Args.Iterator = null;
    defer if (iter) |*it| it.deinit();
    const argv0 = options.argv0 orelse blk: {
        if (options.argv) |argv| {
            iter = try argv.iterateAllocator(options.allocator);
            break :blk iter.?.next();
        }
        break :blk null;
    } orelse return error.MissingArg0;

    var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;

    var path = try std.fmt.bufPrint(&buffer, "{s}{s}", .{ argv0, runfiles_manifest_suffix });
    if (isReadableFile(options.io, path))
        return .{ .manifest = try options.allocator.dupe(u8, path) };

    path = try std.fmt.bufPrint(&buffer, "{s}.exe{s}", .{ argv0, runfiles_manifest_suffix });
    if (isReadableFile(options.io, path))
        return .{ .manifest = try options.allocator.dupe(u8, path) };

    path = try std.fmt.bufPrint(&buffer, "{s}{s}", .{ argv0, runfiles_directory_suffix });
    if (isOpenableDir(options.io, path))
        return .{ .directory = try options.allocator.dupe(u8, path) };

    path = try std.fmt.bufPrint(&buffer, "{s}.exe{s}", .{ argv0, runfiles_directory_suffix });
    if (isOpenableDir(options.io, path))
        return .{ .directory = try options.allocator.dupe(u8, path) };

    return null;
}

pub fn isReadableFile(io: std.Io, file_path: []const u8) bool {
    var file = std.Io.Dir.cwd().openFile(io, file_path, .{}) catch return false;
    file.close(io);
    return true;
}

pub fn isOpenableDir(io: std.Io, dir_path: []const u8) bool {
    var dir = std.Io.Dir.cwd().openDir(io, dir_path, .{}) catch return false;
    dir.close(io);
    return true;
}

const testing = struct {
    const c = struct {
        extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
        extern "c" fn unsetenv(name: [*:0]const u8) c_int;
        extern "c" fn _putenv_s(name: [*:0]const u8, value: [*:0]const u8) c_int;
    };

    pub fn setenv(name: []const u8, value: []const u8) !void {
        const nameZ = try std.testing.allocator.dupeSentinel(u8, name, 0);
        defer std.testing.allocator.free(nameZ);
        const valueZ = try std.testing.allocator.dupeSentinel(u8, value, 0);
        defer std.testing.allocator.free(valueZ);
        if (builtin.os.tag == .windows) {
            if (testing.c._putenv_s(nameZ, valueZ) != 0)
                return error.SetEnvFailed;
        } else {
            if (testing.c.setenv(nameZ, valueZ, 1) != 0)
                return error.SetEnvFailed;
        }
    }

    pub fn unsetenv(name: []const u8) !void {
        const nameZ = try std.testing.allocator.dupeSentinel(u8, name, 0);
        defer std.testing.allocator.free(nameZ);
        if (builtin.os.tag == .windows) {
            if (testing.c._putenv_s(nameZ, "") != 0)
                return error.UnsetEnvFailed;
        } else {
            if (testing.c.unsetenv(nameZ) != 0)
                return error.UnsetEnvFailed;
        }
    }
};

fn testingEnvironMap() !std.process.Environ.Map {
    const environ: std.process.Environ = switch (builtin.os.tag) {
        .windows => .{ .block = .global },
        else => environ: {
            const c_environ = std.c.environ;
            var env_count: usize = 0;
            while (c_environ[env_count] != null) : (env_count += 1) {}
            break :environ .{ .block = .{ .slice = c_environ[0..env_count :null] } };
        },
    };
    return try std.process.Environ.createMap(environ, std.testing.allocator);
}

fn discoverTestOptions(
    manifest: ?[]const u8,
    directory: ?[]const u8,
    argv0: ?[]const u8,
    environ_map: ?*std.process.Environ.Map,
) DiscoverOptions {
    return .{
        .allocator = std.testing.allocator,
        .io = std.testing.io,
        .manifest = manifest,
        .directory = directory,
        .argv0 = argv0,
        .environ_map = environ_map,
    };
}

fn discoverTestRunfilesWithEnv(
    manifest: ?[]const u8,
    directory: ?[]const u8,
    argv0: ?[]const u8,
) !?Location {
    var env_map = try testingEnvironMap();
    defer env_map.deinit();
    return try discoverRunfiles(discoverTestOptions(manifest, directory, argv0, &env_map));
}

test "discover user specified manifest" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try testutil.tmpWriteFile(tmp.dir, "test.runfiles_manifest", "");

    const manifest_path = try testutil.tmpRealpathAlloc(tmp.dir, std.testing.allocator, "test.runfiles_manifest");
    defer std.testing.allocator.free(manifest_path);

    try testing.setenv(runfiles_manifest_var_name, "MANIFEST_DOES_NOT_EXIST");
    try testing.setenv(runfiles_directory_var_name, "DIRECTORY_DOES_NOT_EXIST");

    var location = try discoverRunfiles(discoverTestOptions(manifest_path, null, null, null)) orelse
        return error.TestRunfilesNotFound;
    defer location.deinit(std.testing.allocator);

    try std.testing.expectEqual(Strategy.manifest, @as(Strategy, location));
    try std.testing.expectEqualStrings(manifest_path, location.manifest);
}

test "discover environment specified manifest" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try testutil.tmpWriteFile(tmp.dir, "test.runfiles_manifest", "");

    const manifest_path = try testutil.tmpRealpathAlloc(tmp.dir, std.testing.allocator, "test.runfiles_manifest");
    defer std.testing.allocator.free(manifest_path);

    try testing.setenv(runfiles_manifest_var_name, manifest_path);
    try testing.unsetenv(runfiles_directory_var_name);

    var location = try discoverTestRunfilesWithEnv(null, null, null) orelse
        return error.TestRunfilesNotFound;
    defer location.deinit(std.testing.allocator);

    try std.testing.expectEqual(Strategy.manifest, @as(Strategy, location));
    try std.testing.expectEqualStrings(manifest_path, location.manifest);
}

test "discover user specified directory" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try testutil.tmpMakeDir(tmp.dir, "test.runfiles");

    const directory_path = try testutil.tmpRealpathAlloc(tmp.dir, std.testing.allocator, "test.runfiles");
    defer std.testing.allocator.free(directory_path);

    try testing.setenv(runfiles_manifest_var_name, "MANIFEST_DOES_NOT_EXIST");
    try testing.setenv(runfiles_directory_var_name, "DIRECTORY_DOES_NOT_EXIST");

    var location = try discoverRunfiles(discoverTestOptions(null, directory_path, null, null)) orelse
        return error.TestRunfilesNotFound;
    defer location.deinit(std.testing.allocator);

    try std.testing.expectEqual(Strategy.directory, @as(Strategy, location));
    try std.testing.expectEqualStrings(directory_path, location.directory);
}

test "discover environment specified directory" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try testutil.tmpMakeDir(tmp.dir, "test.runfiles");

    const directory_path = try testutil.tmpRealpathAlloc(tmp.dir, std.testing.allocator, "test.runfiles");
    defer std.testing.allocator.free(directory_path);

    try testing.unsetenv(runfiles_manifest_var_name);
    try testing.setenv(runfiles_directory_var_name, directory_path);

    var location = try discoverTestRunfilesWithEnv(null, null, null) orelse
        return error.TestRunfilesNotFound;
    defer location.deinit(std.testing.allocator);

    try std.testing.expectEqual(Strategy.directory, @as(Strategy, location));
    try std.testing.expectEqualStrings(directory_path, location.directory);
}

test "discover user specified argv0 manifest" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try testutil.tmpWriteFile(tmp.dir, "test.runfiles_manifest", "");

    const manifest_path = try testutil.tmpRealpathAlloc(tmp.dir, std.testing.allocator, "test.runfiles_manifest");
    defer std.testing.allocator.free(manifest_path);

    try testing.unsetenv(runfiles_manifest_var_name);
    try testing.unsetenv(runfiles_directory_var_name);

    const argv0 = manifest_path[0 .. manifest_path.len - ".runfiles_manifest".len];

    var location = try discoverRunfiles(discoverTestOptions(null, null, argv0, null)) orelse
        return error.TestRunfilesNotFound;
    defer location.deinit(std.testing.allocator);

    try std.testing.expectEqual(Strategy.manifest, @as(Strategy, location));
    try std.testing.expectEqualStrings(manifest_path, location.manifest);
}

test "discover user specified argv0 .exe manifest" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try testutil.tmpWriteFile(tmp.dir, "test.exe.runfiles_manifest", "");

    const manifest_path = try testutil.tmpRealpathAlloc(tmp.dir, std.testing.allocator, "test.exe.runfiles_manifest");
    defer std.testing.allocator.free(manifest_path);

    try testing.unsetenv(runfiles_manifest_var_name);
    try testing.unsetenv(runfiles_directory_var_name);

    const argv0 = manifest_path[0 .. manifest_path.len - ".exe.runfiles_manifest".len];

    var location = try discoverRunfiles(discoverTestOptions(null, null, argv0, null)) orelse
        return error.TestRunfilesNotFound;
    defer location.deinit(std.testing.allocator);

    try std.testing.expectEqual(Strategy.manifest, @as(Strategy, location));
    try std.testing.expectEqualStrings(manifest_path, location.manifest);
}

test "discover user specified argv0 directory" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try testutil.tmpMakeDir(tmp.dir, "test.runfiles");

    const directory_path = try testutil.tmpRealpathAlloc(tmp.dir, std.testing.allocator, "test.runfiles");
    defer std.testing.allocator.free(directory_path);

    try testing.unsetenv(runfiles_manifest_var_name);
    try testing.unsetenv(runfiles_directory_var_name);

    const argv0 = directory_path[0 .. directory_path.len - ".runfiles".len];

    var location = try discoverRunfiles(discoverTestOptions(null, null, argv0, null)) orelse
        return error.TestRunfilesNotFound;
    defer location.deinit(std.testing.allocator);

    try std.testing.expectEqual(Strategy.directory, @as(Strategy, location));
    try std.testing.expectEqualStrings(directory_path, location.directory);
}

test "discover user specified argv0 .exe directory" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try testutil.tmpMakeDir(tmp.dir, "test.exe.runfiles");

    const directory_path = try testutil.tmpRealpathAlloc(tmp.dir, std.testing.allocator, "test.exe.runfiles");
    defer std.testing.allocator.free(directory_path);

    try testing.unsetenv(runfiles_manifest_var_name);
    try testing.unsetenv(runfiles_directory_var_name);

    const argv0 = directory_path[0 .. directory_path.len - ".exe.runfiles".len];

    var location = try discoverRunfiles(discoverTestOptions(null, null, argv0, null)) orelse
        return error.TestRunfilesNotFound;
    defer location.deinit(std.testing.allocator);

    try std.testing.expectEqual(Strategy.directory, @as(Strategy, location));
    try std.testing.expectEqualStrings(directory_path, location.directory);
}

test "discover not found" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const tmp_path = try testutil.tmpRealpathAlloc(tmp.dir, std.testing.allocator, ".");
    defer std.testing.allocator.free(tmp_path);

    try testing.unsetenv(runfiles_manifest_var_name);
    try testing.unsetenv(runfiles_directory_var_name);

    const argv0 = try std.fmt.allocPrint(std.testing.allocator, "{s}/does-not-exist", .{tmp_path});
    defer std.testing.allocator.free(argv0);

    const result = try discoverRunfiles(discoverTestOptions(null, null, argv0, null));

    try std.testing.expectEqual(@as(?Location, null), result);
}

test "discover priority" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try testutil.tmpWriteFile(tmp.dir, "test.runfiles_manifest", "");
    try testutil.tmpMakeDir(tmp.dir, "test.runfiles");

    const manifest_path = try testutil.tmpRealpathAlloc(tmp.dir, std.testing.allocator, "test.runfiles_manifest");
    defer std.testing.allocator.free(manifest_path);
    const directory_path = try testutil.tmpRealpathAlloc(tmp.dir, std.testing.allocator, "test.runfiles");
    defer std.testing.allocator.free(directory_path);

    const argv0 = manifest_path[0 .. manifest_path.len - ".runfiles_manifest".len];

    {
        // user specified manifest first.

        try testing.setenv(runfiles_manifest_var_name, manifest_path);
        try testing.setenv(runfiles_directory_var_name, directory_path);

        var location = try discoverRunfiles(discoverTestOptions(manifest_path, directory_path, argv0, null)) orelse
            return error.TestRunfilesNotFound;
        defer location.deinit(std.testing.allocator);

        try std.testing.expectEqual(Strategy.manifest, @as(Strategy, location));
        try std.testing.expectEqualStrings(manifest_path, location.manifest);
    }

    {
        // user specified directory next.

        try testing.setenv(runfiles_manifest_var_name, manifest_path);
        try testing.setenv(runfiles_directory_var_name, directory_path);

        var location = try discoverRunfiles(discoverTestOptions(null, directory_path, argv0, null)) orelse
            return error.TestRunfilesNotFound;
        defer location.deinit(std.testing.allocator);

        try std.testing.expectEqual(Strategy.directory, @as(Strategy, location));
        try std.testing.expectEqualStrings(directory_path, location.directory);
    }

    {
        // environment specified manifest next.

        try testing.setenv(runfiles_manifest_var_name, manifest_path);
        try testing.setenv(runfiles_directory_var_name, directory_path);

        var location = try discoverTestRunfilesWithEnv(null, null, argv0) orelse
            return error.TestRunfilesNotFound;
        defer location.deinit(std.testing.allocator);

        try std.testing.expectEqual(Strategy.manifest, @as(Strategy, location));
        try std.testing.expectEqualStrings(manifest_path, location.manifest);
    }

    {
        // environment specified directory next.

        try testing.unsetenv(runfiles_manifest_var_name);
        try testing.setenv(runfiles_directory_var_name, directory_path);

        var location = try discoverTestRunfilesWithEnv(null, null, argv0) orelse
            return error.TestRunfilesNotFound;
        defer location.deinit(std.testing.allocator);

        try std.testing.expectEqual(Strategy.directory, @as(Strategy, location));
        try std.testing.expectEqualStrings(directory_path, location.directory);
    }

    {
        // argv0 specified manifest next.

        try testing.unsetenv(runfiles_manifest_var_name);
        try testing.unsetenv(runfiles_directory_var_name);

        var location = try discoverRunfiles(discoverTestOptions(null, null, argv0, null)) orelse
            return error.TestRunfilesNotFound;
        defer location.deinit(std.testing.allocator);

        try std.testing.expectEqual(Strategy.manifest, @as(Strategy, location));
        try std.testing.expectEqualStrings(manifest_path, location.manifest);
    }

    try testutil.tmpDeleteFile(tmp.dir, "test.runfiles_manifest");

    {
        // argv0 specified directory next.

        try testing.unsetenv(runfiles_manifest_var_name);
        try testing.unsetenv(runfiles_directory_var_name);

        var location = try discoverRunfiles(discoverTestOptions(null, null, argv0, null)) orelse
            return error.TestRunfilesNotFound;
        defer location.deinit(std.testing.allocator);

        try std.testing.expectEqual(Strategy.directory, @as(Strategy, location));
        try std.testing.expectEqualStrings(directory_path, location.directory);
    }

    try testutil.tmpDeleteDir(tmp.dir, "test.runfiles");

    {
        // finally runfiles not found.

        try testing.unsetenv(runfiles_manifest_var_name);
        try testing.unsetenv(runfiles_directory_var_name);

        const result = try discoverRunfiles(discoverTestOptions(null, null, argv0, null));

        try std.testing.expectEqual(@as(?Location, null), result);
    }
}
