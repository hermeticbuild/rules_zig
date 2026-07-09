pub fn build(b: *@import("std").Build) void {
    _ = b.addModule("bar", .{ .root_source_file = b.path("src/bar.zig") });
}
