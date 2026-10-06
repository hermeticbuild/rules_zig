const std = @import("std");

export fn sayHello() void {
    std.Io.File.writeStreamingAll(
        .stdout(),
        std.Io.Threaded.global_single_threaded.io(),
        "Hello World!\n",
    ) catch unreachable;
}
