const std = @import("std");

pub fn build(b: *std.Build) void {
    const m = b.addModule("syslibdep", .{
        .root_source_file = b.path("src/syslibdep.zig"),
        .target = b.standardTargetOptions(.{}),
    });
    m.linkSystemLibrary("mymath", .{});
}
