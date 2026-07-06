pub fn build(b: *@import("std").Build) void {
    _ = b.addModule("leaf", .{ .root_source_file = b.path("src/leaf.zig") });
}
