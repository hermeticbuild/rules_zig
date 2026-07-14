const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // A source-only dependency with no `build.zig`, providing only C files.
    const amalg = b.dependency("amalg", .{});

    // A rootless carrier module compiling the dependency's C source into a
    // static library, using the dependency's `include` directory as the
    // include path.
    const carrier = b.addModule("linkamalg-c", .{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    carrier.addIncludePath(amalg.path("include"));
    carrier.addCSourceFile(.{ .file = amalg.path("unity/amalg.c") });
    // A local C source using the dependency's include directory.
    carrier.addCSourceFile(.{ .file = b.path("csrc/scaled.c") });
    const lib = b.addLibrary(.{
        .name = "amalg",
        .linkage = .static,
        .root_module = carrier,
    });

    const linkamalg = b.addModule("linkamalg", .{
        .root_source_file = b.path("src/linkamalg.zig"),
    });
    linkamalg.linkLibrary(lib);
}
