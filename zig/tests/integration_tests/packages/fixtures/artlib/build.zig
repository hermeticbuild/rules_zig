const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});

    // A Zig-root module compiled into a static library and installed, so the
    // importer emits it as a consumable `zig_static_library` artifact a
    // dependent package links through `dep.artifact("artlib")`.
    const mod = b.addModule("artlib", .{
        .root_source_file = b.path("src/artlib.zig"),
        .target = target,
    });
    const lib = b.addLibrary(.{
        .name = "artlib",
        .linkage = .static,
        .root_module = mod,
    });
    b.installArtifact(lib);
}
