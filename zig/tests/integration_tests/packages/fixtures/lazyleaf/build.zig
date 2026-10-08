pub fn build(b: *@import("std").Build) void {
    _ = b.addModule("lazyleaf", .{ .root_source_file = b.path("src/lazyleaf.zig") });
}
