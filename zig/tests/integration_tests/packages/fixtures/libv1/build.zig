pub fn build(b: *@import("std").Build) void {
    _ = b.addModule("lib", .{ .root_source_file = b.path("src/lib.zig") });
}
