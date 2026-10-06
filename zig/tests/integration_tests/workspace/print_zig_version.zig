const std = @import("std");
const builtin = @import("builtin");

pub fn main(init: std.process.Init) void {
    std.Io.File.writeStreamingAll(.stdout(), init.io, builtin.zig_version_string) catch unreachable;
}
