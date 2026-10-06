const std = @import("std");
const lib = @import("lib");

const greet = @import("hello");

pub fn main(init: std.process.Init) void {
    std.Io.File.writeStreamingAll(.stdout(), init.io, lib.msg ++ greet.msg) catch unreachable;
}
