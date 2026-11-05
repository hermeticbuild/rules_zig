const std = @import("std");
const value = @import("value");

pub fn main(init: std.process.Init) void {
    std.Io.File.writeStreamingAll(.stdout(), init.io, value.message) catch unreachable;
}
