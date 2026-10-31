const std = @import("std");
const input = @import("incremental_value.zig");

pub fn main(init: std.process.Init) !void {
    var buffer: [32]u8 = undefined;
    const message = try std.fmt.bufPrint(&buffer, "{d}\n", .{input.value});
    try std.Io.File.stdout().writeStreamingAll(init.io, message);
}
