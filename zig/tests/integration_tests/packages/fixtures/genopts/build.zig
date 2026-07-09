const std = @import("std");

pub fn build(b: *std.Build) void {
    const options = b.addOptions();
    options.addOption(bool, "feature", true);

    const genopts = b.addModule("genopts", .{
        .root_source_file = b.path("src/root.zig"),
    });
    genopts.addImport("build_options", options.createModule());
}
