const std = @import("std");

pub fn build(b: *std.Build) void {
    _ = b.findProgram(.{ .names = &.{"sh"} });
    _ = b.addModule("findprogram", .{
        .root_source_file = b.path("src/findprogram.zig"),
    });
}
