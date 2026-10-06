const std = @import("std");

fn getEnvVarOwned(allocator: std.mem.Allocator, key: []const u8) ![]u8 {
    return std.testing.environ.getAlloc(allocator, key) catch |e| switch (e) {
        error.EnvironmentVariableMissing => error.NotSet,
        else => |e_| return e_,
    };
}

test "bazel controlled env var" {
    const attr = try getEnvVarOwned(std.testing.allocator, "ENV_ATTR");
    defer std.testing.allocator.free(attr);

    try std.testing.expectEqualStrings("42", attr);

    const inherit = try getEnvVarOwned(std.testing.allocator, "ENV_INHERIT");
    defer std.testing.allocator.free(inherit);

    try std.testing.expectEqualStrings("21", inherit);
}
