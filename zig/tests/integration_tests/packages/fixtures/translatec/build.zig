const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Translate a C header into a Zig module (`b.addTranslateC`); the module's
    // root source is generated at build time from `c/box.h`.
    const box_c = b.addTranslateC(.{
        .root_source_file = b.path("c/box.h"),
        .target = target,
        .optimize = optimize,
    });
    box_c.addIncludePath(b.path("c"));
    box_c.defineCMacro("BOX_ENABLED", null);
    // The `$` must survive Bazel's Make-variable expansion of `copts`.
    box_c.addCFlags(&.{ "-DBOX_SCALE=2", "-DBOX_TAG=\"box$tag\"" });
    box_c.linkSystemLibrary("boxlib", .{});

    // The public Zig module imports the translated header and links the C
    // source that implements it.
    const translatec = b.addModule("translatec", .{
        .root_source_file = b.path("src/translatec.zig"),
    });
    translatec.addImport("c", box_c.addModule("translatec-c"));
    translatec.addCSourceFile(.{ .file = b.path("c/box.c") });
    translatec.addIncludePath(b.path("c"));
}
