const std = @import("std");

pub fn build(b: *std.Build) void {
    const left = b.dependency("left", .{});
    const right = b.dependency("right", .{});
    const mod = b.addModule("top", .{ .root_source_file = b.path("src/top.zig") });
    mod.addImport("left", left.module("left"));
    mod.addImport("right", right.module("right"));
}
