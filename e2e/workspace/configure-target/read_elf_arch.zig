const std = @import("std");
const elf = std.elf;

pub fn main(init: std.process.Init) !void {
    var iter = try init.minimal.args.iterateAllocator(std.heap.page_allocator);
    defer iter.deinit();

    const arg0 = iter.next() orelse "read_elf_arch";
    const binary_path = iter.next() orelse {
        try printUsage(init.io, arg0);
        return;
    };

    try printMachineType(init.io, binary_path);
}

fn printUsage(io: anytype, arg0: []const u8) !void {
    var buffer: [512]u8 = undefined;
    var writer = std.Io.File.stderr().writer(io, &buffer);
    const stderr = &writer.interface;
    try stderr.print("Usage: {s} <binary_path>\n", .{arg0});
    try stderr.flush();
}

fn printMachineType(io: anytype, binary_path: []const u8) !void {
    const file = try std.Io.Dir.cwd().openFile(io, binary_path, .{});
    defer file.close(io);
    var reader_buffer: [1024]u8 = undefined;
    var reader = file.reader(io, &reader_buffer);
    const elf_header = try elf.Header.read(&reader.interface);

    var buffer: [512]u8 = undefined;
    var writer = std.Io.File.stdout().writer(io, &buffer);
    const stdout = &writer.interface;
    try stdout.print("{s}\n", .{@tagName(elf_header.machine)});
    try stdout.flush();
}
