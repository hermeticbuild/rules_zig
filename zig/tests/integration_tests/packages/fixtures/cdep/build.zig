const std = @import("std");

pub fn build(b: *std.Build) void {
    const cdep = b.addModule("cdep", .{
        .root_source_file = b.path("src/cdep.zig"),
    });
    cdep.addCSourceFile(.{
        .file = b.path("src/value.c"),
        // The `$` must survive Bazel's Make-variable expansion of `copts`, and
        // the quoted, spaced define its shell tokenization.
        .flags = &.{ "-DSCALE=3", "-DFACTOR=factor$x", "-DGREETING=\"a b\"" },
    });
    cdep.addCSourceFile(.{
        .file = b.path("src/other.c"),
        .flags = &.{"-DSCALE=7"},
    });
    // The trailing `/.` must survive into a valid header glob, not `include/./**`.
    cdep.addIncludePath(b.path("include/."));
}
