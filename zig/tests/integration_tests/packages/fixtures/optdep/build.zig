const std = @import("std");

pub fn build(b: *std.Build) void {
    const m = b.addModule("optdep", .{
        .root_source_file = b.path("src/optdep.zig"),
        .target = b.standardTargetOptions(.{}),
    });
    if (b.systemIntegrationOption("optmath", .{})) {
        m.linkSystemLibrary("optmath", .{});
    }
}
