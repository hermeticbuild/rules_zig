const std = @import("std");

pub fn build(b: *std.Build) void {
    const mod = b.addModule("lazyhost", .{ .root_source_file = b.path("src/lazyhost.zig") });
    if (b.lazyDependency("lazyleaf", .{})) |lazyleaf| {
        mod.addImport("lazyleaf", lazyleaf.module("lazyleaf"));
    }
}
