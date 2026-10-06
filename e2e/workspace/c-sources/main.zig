const std = @import("std");

extern const custom_global_symbol: i32;

export fn getCustomGlobalSymbol() i32 {
    return custom_global_symbol;
}

pub fn main(init: std.process.Init) !void {
    var buffer: [512]u8 = undefined;
    var writer = std.Io.File.stdout().writer(init.io, &buffer);
    const stdout = &writer.interface;
    try stdout.print("{d}\n", .{getCustomGlobalSymbol()});
    try stdout.flush();
}
