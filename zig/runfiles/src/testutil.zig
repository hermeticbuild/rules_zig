const std = @import("std");

fn ownNoSentinel(allocator: std.mem.Allocator, path_z: [:0]u8) ![]u8 {
    defer allocator.free(path_z);
    return try allocator.dupe(u8, path_z);
}

pub fn tmpWriteFile(dir: anytype, sub_path: []const u8, data: []const u8) !void {
    try dir.writeFile(std.testing.io, .{
        .sub_path = sub_path,
        .data = data,
    });
}

pub fn tmpMakeDir(dir: anytype, sub_path: []const u8) !void {
    try dir.createDir(std.testing.io, sub_path, .default_dir);
}

pub fn tmpMakePath(dir: anytype, sub_path: []const u8) !void {
    try dir.createDirPath(std.testing.io, sub_path);
}

pub fn tmpRealpathAlloc(dir: anytype, allocator: std.mem.Allocator, sub_path: []const u8) ![]u8 {
    return try ownNoSentinel(allocator, try dir.realPathFileAlloc(std.testing.io, sub_path, allocator));
}

pub fn tmpRealpath(dir: anytype, sub_path: []const u8, out_buffer: []u8) ![]const u8 {
    const len = try dir.realPathFile(std.testing.io, sub_path, out_buffer);
    return out_buffer[0..len];
}

pub fn tmpDeleteFile(dir: anytype, sub_path: []const u8) !void {
    try dir.deleteFile(std.testing.io, sub_path);
}

pub fn tmpDeleteDir(dir: anytype, sub_path: []const u8) !void {
    try dir.deleteDir(std.testing.io, sub_path);
}

pub fn tmpSymLink(dir: anytype, target_path: []const u8, sym_link_path: []const u8) !void {
    try dir.symLink(std.testing.io, target_path, sym_link_path, .{});
}

pub fn readAbsoluteFileAlloc(allocator: std.mem.Allocator, path: []const u8, limit: usize) ![]u8 {
    const io = std.testing.io;
    const file = try std.Io.Dir.openFileAbsolute(io, path, .{});
    defer file.close(io);
    var buf: [1024]u8 = undefined;
    var reader = file.reader(io, &buf);
    return try reader.interface.allocRemaining(allocator, .limited(limit));
}
