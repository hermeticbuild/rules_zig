const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});

    // A rootless carrier module holding only C sources, compiled into a static
    // library — the shape a package uses to build a vendored C library.
    const carrier = b.addModule("linklib-c", .{
        .target = target,
        .link_libc = true,
    });
    carrier.addCSourceFile(.{
        .file = b.path("c/impl.c"),
        .flags = &.{"-DSCALE=6"},
    });
    carrier.addIncludePath(b.path("c"));
    const lib = b.addLibrary(.{
        .name = "linklib",
        .linkage = .static,
        .root_module = carrier,
    });

    // The public Zig module links the C library; its C sources, include dir,
    // and libc linkage must fold into the module.
    const linklib = b.addModule("linklib", .{
        .root_source_file = b.path("src/linklib.zig"),
    });
    linklib.linkLibrary(lib);
}
