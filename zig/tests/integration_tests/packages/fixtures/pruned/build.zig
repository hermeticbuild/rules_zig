pub fn build(b: *@import("std").Build) void {
    _ = b.addModule("pruned", .{ .root_source_file = b.path("src/pruned.zig") });
}
