pub fn build(b: *@import("std").Build) void {
    _ = b.addModule("usec", .{
        .root_source_file = b.path("src/usec.zig"),
        .link_libc = true,
    });
}
