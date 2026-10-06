const std = @import("std");
const data = @import("import-name-module/data");

pub fn main(init: std.process.Init) void {
    std.Io.File.writeStreamingAll(.stdout(), init.io, data.hello_world) catch unreachable;
}
