const std = @import("std");

pub fn build(b: *std.Build) void {
    const m = b.addModule("clashb", .{
        .root_source_file = b.path("src/clashb.zig"),
        .target = b.standardTargetOptions(.{}),
    });
    m.linkSystemLibrary("clash", .{});
}
