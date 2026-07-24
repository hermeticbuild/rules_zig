const std = @import("std");

pub fn build(b: *std.Build) void {
    const m = b.addModule("clasha", .{
        .root_source_file = b.path("src/clasha.zig"),
        .target = b.standardTargetOptions(.{}),
    });
    m.linkSystemLibrary("clash", .{});
}
