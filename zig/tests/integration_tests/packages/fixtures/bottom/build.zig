const std = @import("std");

pub fn build(b: *std.Build) void {
    const base = b.dependency("base", .{});
    const mod = b.addModule("bottom", .{ .root_source_file = b.path("src/bottom.zig") });
    mod.addImport("base", base.module("base"));
}
