pub fn build(b: *@import("std").Build) void {
    const bar = b.dependency("bar", .{});
    const leaf = b.dependency("leaf", .{});
    const foo = b.addModule("foo", .{ .root_source_file = b.path("src/foo.zig") });
    foo.addImport("bar", bar.module("bar"));
    foo.addImport("leaflib", leaf.module("leaf"));
    // A vendored C source whose include directory is the package root
    // (`b.path(".")`): as a sub-tree dependency `foo` is rendered under its
    // sub-path, and the root include must not leave a trailing slash that would
    // make an invalid header glob.
    foo.addCSourceFile(.{ .file = b.path("csrc/offset.c"), .flags = &.{} });
    foo.addIncludePath(b.path("."));
}
