const std = @import("std");

pub fn main(init: std.process.Init) !void {
    var iter = try init.minimal.args.iterateAllocator(std.heap.page_allocator);
    defer iter.deinit();

    const arg0 = iter.next() orelse "read_pe32_arch";
    const binary_path = iter.next() orelse {
        try printUsage(init.io, arg0);
        return;
    };

    try printMachineType(init.io, std.heap.page_allocator, binary_path);
}

fn printUsage(io: anytype, arg0: []const u8) !void {
    var buffer: [512]u8 = undefined;
    var writer = std.Io.File.stderr().writer(io, &buffer);
    const stderr = &writer.interface;
    try stderr.print("Usage: {s} <binary_path>\n", .{arg0});
    try stderr.flush();
}

fn printMachineType(io: anytype, allocator: std.mem.Allocator, binary_path: []const u8) !void {
    const file = try std.Io.Dir.cwd().openFile(io, binary_path, .{});
    defer file.close(io);
    var reader_buffer: [1024]u8 = undefined;
    var reader = file.reader(io, &reader_buffer);
    const content = try reader.interface.allocRemaining(allocator, .limited(2097152));
    defer allocator.free(content);

    var coff = try std.coff.Coff.init(content, false);
    const machine_name = switch (coff.getHeader().machine) {
        .AMD64 => "X64",
        else => |machine| @tagName(machine),
    };

    var buffer: [512]u8 = undefined;
    var writer = std.Io.File.stdout().writer(io, &buffer);
    const stdout = &writer.interface;
    try stdout.print("{s}\n", .{machine_name});
    try stdout.flush();
}
