const std = @import("std");

pub fn build(b: *std.Build) void {
    const cppdep = b.addModule("cppdep", .{
        .root_source_file = b.path("src/cppdep.zig"),
        .link_libcpp = true,
    });
    cppdep.addCSourceFile(.{ .file = b.path("src/impl.cpp") });
}
