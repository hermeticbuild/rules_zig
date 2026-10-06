const std = @import("std");

pub fn main(init: std.process.Init) void {
    std.Io.File.writeStreamingAll(.stdout(), init.io, "Hello World!\n") catch unreachable;
}
