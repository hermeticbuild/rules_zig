const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const tgtdep = b.addModule("tgtdep", .{
        .root_source_file = b.path("src/tgtdep.zig"),
        .target = target,
    });
    switch (target.result.os.tag) {
        .windows => tgtdep.linkSystemLibrary("winonly", .{}),
        .macos => tgtdep.linkSystemLibrary("maconly", .{}),
        else => tgtdep.linkSystemLibrary("posixonly", .{}),
    }
}
