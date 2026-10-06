const std = @import("std");

export fn sayHello() void {
    std.Io.File.writeStreamingAll(
        .stdout(),
        std.Io.Threaded.global_single_threaded.io(),
        "Hello World!\n",
    ) catch unreachable;
}

pub fn main(init: std.process.Init) void {
    std.Io.File.writeStreamingAll(.stdout(), init.io, "Hello World!\n") catch unreachable;
}

test "test" {
    try std.testing.expectEqual(2, 1 + 1);
}
