const std = @import("std");
const runfiles = @import("runfiles");

fn getTestingEnvVar(allocator: std.mem.Allocator, key: []const u8) !?[]const u8 {
    return std.testing.environ.getAlloc(allocator, key) catch |e| switch (e) {
        error.EnvironmentVariableMissing => null,
        else => |e_| return e_,
    };
}

fn getEnvVarFromInit(allocator: std.mem.Allocator, init: std.process.Init, key: []const u8) !?[]const u8 {
    const value = init.environ_map.get(key) orelse return null;
    return try allocator.dupe(u8, value);
}

fn createTestingRunfiles(allocator: std.mem.Allocator) !?runfiles.Runfiles {
    var env_map = try std.process.Environ.createMap(std.testing.environ, allocator);
    defer env_map.deinit();
    return try runfiles.Runfiles.create(.{
        .allocator = allocator,
        .io = std.testing.io,
        .environ_map = &env_map,
    });
}

fn createRunfilesFromInit(allocator: std.mem.Allocator, init: std.process.Init) !?runfiles.Runfiles {
    return try runfiles.Runfiles.create(.{
        .allocator = allocator,
        .io = init.io,
        .argv = init.minimal.args,
        .environ_map = init.environ_map,
    });
}

fn readFileAlloc(io: anytype, allocator: std.mem.Allocator, path: []const u8, limit: usize) ![]u8 {
    const file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    var buffer: [1024]u8 = undefined;
    var reader = file.reader(io, &buffer);
    return try reader.interface.allocRemaining(allocator, .limited(limit));
}

fn readTestingFileAlloc(allocator: std.mem.Allocator, path: []const u8, limit: usize) ![]u8 {
    return try readFileAlloc(std.testing.io, allocator, path, limit);
}

fn printData(io: anytype, content: []const u8) !void {
    var buffer: [512]u8 = undefined;
    var writer = std.Io.File.stdout().writer(io, &buffer);
    const stdout = &writer.interface;
    try stdout.print("data: {s}", .{content});
    try stdout.flush();
}

pub fn main(init: std.process.Init) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    const allocator = arena.allocator();

    var r = try createRunfilesFromInit(allocator, init) orelse
        return error.RunfilesNotFound;
    defer r.deinit(allocator);

    const rpath = try getEnvVarFromInit(allocator, init, "DATA") orelse return error.EnvVarNotFoundDATA;
    defer allocator.free(rpath);

    const file_path = try r
        .withSourceRepo("")
        .rlocationAlloc(allocator, rpath) orelse
        return error.RLocationNotFound;
    defer allocator.free(file_path);

    const content = try readFileAlloc(init.io, allocator, file_path, 4096);
    defer allocator.free(content);

    try printData(init.io, content);
}

test "read data file" {
    var r = try createTestingRunfiles(std.testing.allocator) orelse
        return error.RunfilesNotFound;
    defer r.deinit(std.testing.allocator);

    const rpath = try getTestingEnvVar(std.testing.allocator, "DATA") orelse return error.EnvVarNotFoundDATA;
    defer std.testing.allocator.free(rpath);

    const file_path = try r
        .withSourceRepo("")
        .rlocationAlloc(std.testing.allocator, rpath) orelse
        return error.RLocationNotFound;
    defer std.testing.allocator.free(file_path);

    const content = try readTestingFileAlloc(std.testing.allocator, file_path, 4096);
    defer std.testing.allocator.free(content);

    try std.testing.expectEqualStrings("Hello World!\n", content);
}

test "resolve external dependency rpath" {
    var r = try createTestingRunfiles(std.testing.allocator) orelse
        return error.RunfilesNotFound;
    defer r.deinit(std.testing.allocator);

    const rpath = try getTestingEnvVar(std.testing.allocator, "DEPENDENCY_DATA") orelse return error.EnvVarNotFoundDEPENDENCY_DATA;
    defer std.testing.allocator.free(rpath);

    const file_path = try r
        .withSourceRepo("")
        .rlocationAlloc(std.testing.allocator, rpath) orelse
        return error.RLocationNotFound;
    defer std.testing.allocator.free(file_path);

    const content = try readTestingFileAlloc(std.testing.allocator, file_path, 4096);
    defer std.testing.allocator.free(content);

    try std.testing.expectEqualStrings("Hello from dependency!\n", content);
}

test "read data file in dependency Zig module" {
    const content = try @import("module_with_data").readData(std.testing.allocator);
    defer std.testing.allocator.free(content);

    try std.testing.expectEqualStrings("Hello from transitive dependency!\n", content);
}

test "runfiles in nested binary" {
    var r = try createTestingRunfiles(std.testing.allocator) orelse
        return error.RunfilesNotFound;
    defer r.deinit(std.testing.allocator);

    const rpath = try getTestingEnvVar(std.testing.allocator, "BINARY") orelse return error.EnvVarNotFoundBINARY;
    defer std.testing.allocator.free(rpath);

    const binary_path = try r
        .withSourceRepo("")
        .rlocationAlloc(std.testing.allocator, rpath) orelse
        return error.RLocationNotFound;
    defer std.testing.allocator.free(binary_path);

    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();

    const data_rpath = try getTestingEnvVar(std.testing.allocator, "DATA") orelse return error.EnvVarNotFoundBINARY;
    defer std.testing.allocator.free(data_rpath);
    try env.put("DATA", data_rpath);
    try r.environment(&env);

    const result = try std.process.run(std.testing.allocator, std.testing.io, .{
        .argv = &[_][]const u8{binary_path},
        .environ_map = &env,
    });
    defer std.testing.allocator.free(result.stdout);
    defer std.testing.allocator.free(result.stderr);

    std.log.warn("stderr: {s}", .{result.stderr});
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);

    try std.testing.expectEqualStrings("data: Hello World!\n", result.stdout);
}
