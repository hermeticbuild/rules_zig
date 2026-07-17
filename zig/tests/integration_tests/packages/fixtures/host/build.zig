const std = @import("std");

pub fn build(b: *std.Build) void {
    const foo = b.dependency("foo", .{});
    const bar = b.dependency("bar", .{});
    const mod = b.addModule("host", .{ .root_source_file = b.path("src/root.zig") });
    mod.addImport("foo", foo.module("foo"));
    mod.addImport("barlib", bar.module("bar"));
    // A C source and an include directory of the sub-tree dependency `foo`,
    // reached through `dep.path`.
    mod.addCSourceFile(.{ .file = foo.path("csrc/doubled.c"), .flags = &.{} });
    mod.addIncludePath(foo.path("."));
}
