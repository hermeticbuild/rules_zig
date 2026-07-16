const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // A C library that installs its public header. Its emitted include tree is a
    // generated directory holding `box.h`, assembled from the installed sources.
    const carrier = b.addModule("emittedinc-clib", .{
        .target = target,
        .link_libc = true,
    });
    carrier.addCSourceFile(.{ .file = b.path("c/box.c") });
    carrier.addIncludePath(b.path("include"));
    const lib = b.addLibrary(.{
        .name = "box",
        .linkage = .static,
        .root_module = carrier,
    });
    lib.installHeader(b.path("include/box.h"), "box.h");

    // The translate step reaches the header only through the library's
    // emitted include tree.
    const box_c = b.addTranslateC(.{
        .root_source_file = b.path("umbrella/box_all.h"),
        .target = target,
        .optimize = optimize,
    });
    box_c.addIncludePath(lib.getEmittedIncludeTree());

    const emittedinc = b.addModule("emittedinc", .{
        .root_source_file = b.path("src/emittedinc.zig"),
    });
    emittedinc.addImport("c", box_c.addModule("emittedinc-c"));
    emittedinc.linkLibrary(lib);
}
