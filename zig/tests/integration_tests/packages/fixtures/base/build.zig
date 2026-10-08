pub fn build(b: *@import("std").Build) void {
    _ = b.addModule("base", .{ .root_source_file = b.path("src/base.zig") });
}
