const std = @import("std");

pub fn build(b: *std.Build) void {
    const optimize = b.standardOptimizeOption(.{});
    const debug = optimize == .debug;
    const cvardep = b.addModule("cvardep", .{
        .root_source_file = b.path(if (debug) "src/dbg.zig" else "src/rel.zig"),
        .target = b.standardTargetOptions(.{}),
        .optimize = optimize,
    });
    cvardep.addCSourceFile(.{ .file = b.path(if (debug) "c/dbg/impl.c" else "c/rel/impl.c"), .flags = &.{} });
    cvardep.addIncludePath(b.path(if (debug) "c/dbg" else "c/rel"));
}
