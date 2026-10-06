const std = @import("std");
const runfiles = @import("runfiles");
const bazel_builtin = @import("bazel_builtin");

pub fn main(init: std.process.Init) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    const allocator = arena.allocator();
    const io = init.io;

    var r_ = try runfiles.Runfiles.create(.{
        .allocator = allocator,
        .io = io,
        .argv0 = "bazel-bin/runfiles/binary",
    }) orelse return error.RunfilesNotFound;
    defer r_.deinit(allocator);

    const r = r_.withSourceRepo(bazel_builtin.current_repository);

    const rpath = "integration_tests/runfiles/data.txt";

    const file_path = try r.rlocationAlloc(allocator, rpath) orelse {
        std.log.err("Runfiles location '{s}' not found", .{rpath});
        return error.RLocationNotFound;
    };
    defer allocator.free(file_path);

    const file = std.Io.Dir.openFileAbsolute(io, file_path, .{}) catch |e| {
        std.log.err("Failed to open file '{s}': {}", .{ file_path, e });
        return e;
    };
    defer file.close(io);

    var reader_buffer: [4096]u8 = undefined;
    var reader = file.reader(io, &reader_buffer);
    const content = try reader.interface.allocRemaining(allocator, .limited(4096));
    defer allocator.free(content);

    var buffer: [512]u8 = undefined;
    var writer = std.Io.File.stdout().writer(io, &buffer);
    const stdout = &writer.interface;
    try stdout.print("data: {s}", .{content});
    try stdout.flush();
}
