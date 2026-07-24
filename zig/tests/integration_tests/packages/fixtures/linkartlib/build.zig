const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});

    // The dependency installs a Zig-root static library; linking its artifact
    // exercises the cross-repository linked-artifact wiring.
    const artlib = b.dependency("artlib", .{});

    const mod = b.addModule("linkartlib", .{
        .root_source_file = b.path("src/linkartlib.zig"),
        .target = target,
    });
    mod.linkLibrary(artlib.artifact("artlib"));
}
