const std = @import("std");

pub fn build(b: *std.Build) void {
    const mod = b.addModule("lazydirect", .{ .root_source_file = b.path("src/lazydirect.zig") });
    mod.addImport("lazyleaf", b.dependency("lazyleaf", .{}).module("lazyleaf"));
}
