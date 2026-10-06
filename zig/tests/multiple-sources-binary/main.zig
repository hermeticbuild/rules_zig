const std = @import("std");

const message = @import("hello.zig").hello ++ " " ++ @import("world.zig").world ++ "\n";

pub fn main(init: std.process.Init) void {
    std.Io.File.writeStreamingAll(.stdout(), init.io, message) catch unreachable;
}
