const std = @import("std");
const integration_testing = @import("integration_testing");
const BitContext = integration_testing.BitContext;

test "the packages workspace builds with the Zig SDK" {
    const ctx = try BitContext.init();
    defer ctx.deinit();

    const result = try ctx.exec_bazel(.{
        .argv = &[_][]const u8{ "build", "//:binary" },
    });
    defer result.deinit();

    try std.testing.expect(result.success);
}
