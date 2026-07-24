const std = @import("std");

pub fn build(b: *std.Build) void {
    const m = b.addModule("weakdep", .{
        .root_source_file = b.path("src/weakdep.zig"),
        .target = b.standardTargetOptions(.{}),
    });
    m.linkSystemLibrary("weakmath", .{ .weak = true });
}
