const std = @import("std");

fn getEnvVarOwnedFromInit(allocator: std.mem.Allocator, init: std.process.Init, key: []const u8) !?[]u8 {
    const value = init.environ_map.get(key) orelse return null;
    return try allocator.dupe(u8, value);
}

fn printEnv(io: anytype, name: []const u8, value: []const u8) !void {
    var buffer: [512]u8 = undefined;
    var writer = std.Io.File.stdout().writer(io, &buffer);
    const stdout = &writer.interface;
    try stdout.print("{s}: '{s}'\n", .{ name, value });
    try stdout.flush();
}

pub fn main(init: std.process.Init) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    const allocator = arena.allocator();

    const env_attr = try getEnvVarOwnedFromInit(allocator, init, "ENV_ATTR");
    defer if (env_attr) |value| allocator.free(value);

    const env_genrule = try getEnvVarOwnedFromInit(allocator, init, "ENV_GENRULE");
    defer if (env_genrule) |value| allocator.free(value);

    if (env_attr) |value| try printEnv(init.io, "ENV_ATTR", value);
    if (env_genrule) |value| try printEnv(init.io, "ENV_GENRULE", value);
}

test "bazel controlled env var" {
    const value = try std.testing.environ.getAlloc(std.testing.allocator, "ENV_ATTR");
    defer std.testing.allocator.free(value);

    try std.testing.expectEqualStrings("42", value);
}
