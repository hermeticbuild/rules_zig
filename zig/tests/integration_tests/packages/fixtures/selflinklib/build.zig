const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});

    // A Zig-root static library installed as an artifact within this same
    // package; the public module below links it, exercising the local
    // linked-artifact wiring (`:<name>.artifact` in the package's repository).
    const impl_mod = b.addModule("selflinklib-impl", .{
        .root_source_file = b.path("src/impl.zig"),
        .target = target,
    });
    const lib = b.addLibrary(.{
        .name = "selflinklib-impl",
        .linkage = .static,
        .root_module = impl_mod,
    });
    b.installArtifact(lib);

    const mod = b.addModule("selflinklib", .{
        .root_source_file = b.path("src/selflinklib.zig"),
        .target = target,
    });
    mod.linkLibrary(lib);
}
