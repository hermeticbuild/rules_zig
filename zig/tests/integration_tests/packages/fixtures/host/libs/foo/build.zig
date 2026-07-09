pub fn build(b: *@import("std").Build) void {
    const bar = b.dependency("bar", .{});
    const leaf = b.dependency("leaf", .{});
    const foo = b.addModule("foo", .{ .root_source_file = b.path("src/foo.zig") });
    foo.addImport("bar", bar.module("bar"));
    foo.addImport("leaflib", leaf.module("leaf"));
}
