//! Implements the directory based runfiles strategy as defined in the
//! [runfiles design][runfiles-design].
//!
//! [runfiles-design]: https://docs.google.com/document/d/e/2PACX-1vSDIrFnFvEYhKsCMdGdD40wZRBX3m3aZ5HhVj4CtHPmiXKDCxioTUbYsDydjKtFDAzER5eg7OjJWs3V/pub

const std = @import("std");

const RPath = @import("RPath.zig");

const Directory = @This();

path: [:0]const u8,

pub const InitError = std.mem.Allocator.Error || std.Io.Dir.OpenError || std.Io.Dir.RealPathFileAllocError;

pub fn init(allocator: std.mem.Allocator, io: std.Io, path: []const u8) InitError!Directory {
    const absolute = try std.Io.Dir.cwd().realPathFileAlloc(io, path, allocator);
    errdefer allocator.free(absolute);
    // TODO[AH] Implement OS specific normalization, e.g. Windows lower-case.
    return .{ .path = absolute };
}

pub fn deinit(self: *Directory, allocator: std.mem.Allocator) void {
    allocator.free(self.path);
}

pub fn rlocationUnmapped(
    self: *const Directory,
    rpath: RPath,
    out_buffer: []u8,
) error{ WriteFailed, NoSpaceLeft }![]const u8 {
    var writer = std.Io.Writer.fixed(out_buffer);
    try writer.print("{s}", .{self.path});
    if (rpath.repo.len > 0)
        try writer.print("/{s}", .{rpath.repo});
    if (rpath.path.len > 0)
        try writer.print("/{s}", .{rpath.path});
    return writer.buffered();
}

pub fn rlocationUnmappedAlloc(
    self: *const Directory,
    allocator: std.mem.Allocator,
    rpath: RPath,
) error{OutOfMemory}![]const u8 {
    // TODO[AH] Implement OS specific normalization, e.g. Windows lower-case.
    return try std.fs.path.join(allocator, &[_][]const u8{
        self.path,
        rpath.repo,
        rpath.path,
    });
}

test "Directory init and unmapped lookup" {
    const testutil = @import("testutil.zig");
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try testutil.tmpMakePath(tmp.dir, "test.runfiles/my_workspace/some/package");
    try testutil.tmpWriteFile(tmp.dir, "test.runfiles/_repo_mapping", "_repo_mapping");
    try testutil.tmpWriteFile(tmp.dir, "test.runfiles/my_workspace/some/package/some_file", "some_file");

    const cwd_path_absolute = try std.process.currentPathAlloc(std.testing.io, std.testing.allocator);
    defer std.testing.allocator.free(cwd_path_absolute);
    const runfiles_path_absolute = try testutil.tmpRealpathAlloc(tmp.dir, std.testing.allocator, "test.runfiles");
    defer std.testing.allocator.free(runfiles_path_absolute);
    const runfiles_path = try std.fs.path.relative(std.testing.allocator, ".", null, cwd_path_absolute, runfiles_path_absolute);
    defer std.testing.allocator.free(runfiles_path);

    var directory = try Directory.init(std.testing.allocator, std.testing.io, runfiles_path);
    defer directory.deinit(std.testing.allocator);

    {
        const filepath = try directory.rlocationUnmappedAlloc(std.testing.allocator, .{
            .repo = "",
            .path = "_repo_mapping",
        });
        defer std.testing.allocator.free(filepath);
        try std.testing.expect(std.fs.path.isAbsolute(filepath));
        // TODO[AH] test normalized path (no '..', '/' sep, lower-case Windows)
        const content = try testutil.readAbsoluteFileAlloc(std.testing.allocator, filepath, 4096);
        defer std.testing.allocator.free(content);
        try std.testing.expectEqualStrings("_repo_mapping", content);
    }

    {
        const filepath = try directory.rlocationUnmappedAlloc(std.testing.allocator, .{
            .repo = "my_workspace",
            .path = "some/package/some_file",
        });
        defer std.testing.allocator.free(filepath);
        try std.testing.expect(std.fs.path.isAbsolute(filepath));
        // TODO[AH] test normalized path (no '..', '/' sep, lower-case Windows)
        const content = try testutil.readAbsoluteFileAlloc(std.testing.allocator, filepath, 4096);
        defer std.testing.allocator.free(content);
        try std.testing.expectEqualStrings("some_file", content);
    }
}
