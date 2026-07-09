const std = @import("std");

pub fn build(b: *std.Build) void {
    const foo = b.dependency("foo", .{});
    const bar = b.dependency("bar", .{});
    const mod = b.addModule("host", .{ .root_source_file = b.path("src/root.zig") });
    mod.addImport("foo", foo.module("foo"));
    mod.addImport("barlib", bar.module("bar"));
}
