const std = @import("std");

pub fn build(b: *std.Build) void {
    const host = b.dependency("host", .{});
    const mod = b.addModule("hostuser", .{ .root_source_file = b.path("src/root.zig") });
    mod.addImport("host", host.module("host"));
}
