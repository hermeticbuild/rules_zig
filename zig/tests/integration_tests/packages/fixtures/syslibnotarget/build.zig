const std = @import("std");

pub fn build(b: *std.Build) void {
    // The module omits a target, so `linkSystemLibrary` panics the configurer.
    const m = b.addModule("syslibnotarget", .{
        .root_source_file = b.path("src/syslibnotarget.zig"),
    });
    m.linkSystemLibrary("mymath", .{});
}
