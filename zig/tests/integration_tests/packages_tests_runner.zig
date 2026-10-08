const std = @import("std");
const integration_testing = @import("integration_testing");
const BitContext = integration_testing.BitContext;

// Fixtures packed into `file://` tarballs, in topological order
// (dependencies first).
const packages = [_][]const u8{
    "leaf",
};

test "Zig packages are imported from file:// tarballs" {
    const ctx = try BitContext.init();
    defer ctx.deinit();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    for (packages) |name| {
        const dir = try std.fmt.allocPrint(allocator, "{s}/fixtures/{s}", .{ ctx.workspace_path, name });
        const tarball = try std.fmt.allocPrint(allocator, "{s}/{s}.tar", .{ ctx.workspace_path, name });
        const pack = try ctx.exec_bazel(.{
            .argv = &[_][]const u8{ "run", "//tools:pack", "--", dir, tarball },
        });
        defer pack.deinit();
        try std.testing.expect(pack.success);

        const hash = try allocator.dupe(u8, std.mem.trim(u8, pack.stdout, " \t\r\n"));
        const url = try std.fmt.allocPrint(allocator, "file://{s}", .{tarball});
        try ctx.patchWorkspaceFile("MODULE.bazel", &.{
            .{ try placeholder(allocator, name, "URL"), url },
            .{ try placeholder(allocator, name, "HASH"), hash },
        });
    }

    const result = try ctx.exec_bazel(.{
        .argv = &[_][]const u8{ "build", "//:binary" },
    });
    defer result.deinit();
    try std.testing.expect(result.success);
}

fn placeholder(allocator: std.mem.Allocator, name: []const u8, kind: []const u8) ![]const u8 {
    const upper = try allocator.alloc(u8, name.len);
    _ = std.ascii.upperString(upper, name);
    return std.fmt.allocPrint(allocator, "__{s}_{s}__", .{ upper, kind });
}
