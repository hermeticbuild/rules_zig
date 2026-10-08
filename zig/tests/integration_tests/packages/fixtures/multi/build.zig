const std = @import("std");

pub fn build(b: *std.Build) void {
    const widget = b.addModule("widget", .{ .root_source_file = b.path("src/widget.zig") });

    const internal = b.createModule(.{ .root_source_file = b.path("src/internal.zig") });

    const multi = b.addModule("multi", .{ .root_source_file = b.path("src/multi.zig") });
    multi.addImport("widget", widget);
    multi.addImport("internal", internal);
}
