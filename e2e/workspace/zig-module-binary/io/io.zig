const std = @import("std");

pub fn print(msg: []const u8) void {
    std.Io.File.writeStreamingAll(
        .stdout(),
        std.Io.Threaded.global_single_threaded.io(),
        msg,
    ) catch unreachable;
}
