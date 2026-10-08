pub fn build(b: *@import("std").Build) void {
    _ = b.addModule("symlinked", .{ .root_source_file = b.path("src/symlinked.zig") });
}
