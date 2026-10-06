const std = @import("std");

fn getEnvVarOwnedFromInit(allocator: std.mem.Allocator, init: std.process.Init, key: []const u8) !?[]u8 {
    const value = init.environ_map.get(key) orelse return null;
    return try allocator.dupe(u8, value);
}

fn printEnv(io: anytype, env_value: ?[]const u8, name: []const u8) !void {
    const value = env_value orelse return;
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
    try printEnv(init.io, try getEnvVarOwnedFromInit(allocator, init, "ENV_ATTR"), "ENV_ATTR");
    try printEnv(init.io, try getEnvVarOwnedFromInit(allocator, init, "ENV_INHERIT"), "ENV_INHERIT");
}
