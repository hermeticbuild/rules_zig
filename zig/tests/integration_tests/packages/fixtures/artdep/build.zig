const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});

    // A Zig-root module compiled into a static library and installed, so the
    // importer emits it as a consumable `zig_static_library` artifact target.
    const mod = b.addModule("artdep", .{
        .root_source_file = b.path("src/artdep.zig"),
        .target = target,
    });
    const lib = b.addLibrary(.{
        .name = "artdep",
        .linkage = .static,
        .root_module = mod,
    });
    b.installArtifact(lib);
}
