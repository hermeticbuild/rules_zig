const std = @import("std");

pub fn build(b: *std.Build) void {
    _ = b.addModule("patchdep", .{
        .root_source_file = b.path("src/patchdep.zig"),
    });

    // The published build.zig does not configure; the consumer's patch removes
    // this line.
    @compileError("patchdep must be patched before it can be configured");
}
