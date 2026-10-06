const builtin = @import("builtin");
const std = @import("std");

const is_zig_0_16_or_later = builtin.zig_version.major == 0 and builtin.zig_version.minor >= 16;
const is_zig_0_17_or_later = builtin.zig_version.major == 0 and builtin.zig_version.minor >= 17;

const c = if (is_zig_0_17_or_later) @import("c") else @import("cimport").c;

pub const main = if (is_zig_0_16_or_later) main_016 else main_pre_016;

fn main_pre_016() !void {
    const one = c.ceil(0.5);
    const two = c.ceil(1.5);
    var buffer: [512]u8 = undefined;
    var writer = std.fs.File.stdout().writer(&buffer);
    const stdout = &writer.interface;
    try stdout.print("{d}\n", .{one + two});
    try stdout.flush();
}

fn main_016(init: std.process.Init) !void {
    const one = c.ceil(0.5);
    const two = c.ceil(1.5);
    var buffer: [512]u8 = undefined;
    var writer = std.Io.File.stdout().writer(init.io, &buffer);
    const stdout = &writer.interface;
    try stdout.print("{d}\n", .{one + two});
    try stdout.flush();
}

test "One plus two equals three" {
    const one = c.ceil(0.5);
    const two = c.ceil(1.5);
    try std.testing.expectEqual(@as(f64, 3), one + two);
}
