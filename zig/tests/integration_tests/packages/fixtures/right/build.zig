const std = @import("std");

pub fn build(b: *std.Build) void {
    const bottom = b.dependency("bottom", .{});
    const mod = b.addModule("right", .{ .root_source_file = b.path("src/right.zig") });
    mod.addImport("bottom", bottom.module("bottom"));
}
