//! Implements the manifest based runfiles strategy as defined in the
//! [runfiles design][runfiles-design].
//!
//! [runfiles-design]: https://docs.google.com/document/d/e/2PACX-1vSDIrFnFvEYhKsCMdGdD40wZRBX3m3aZ5HhVj4CtHPmiXKDCxioTUbYsDydjKtFDAzER5eg7OjJWs3V/pub

const std = @import("std");
const builtin = @import("builtin");
// TODO[AH] factor out common utility code.
const log = if (builtin.is_test)
    // Downgrade `err` to `warn` for tests.
    // Zig fails any test that does `log.err`, but we want to test those code paths here.
    // See https://github.com/ziglang/zig/issues/5738#issuecomment-1466902082.
    //
    // TODO[AH] Consider the diagnostic pattern instead.
    // See https://github.com/ziglang/zig/issues/2647#issuecomment-589829306
    struct {
        const base = std.log.scoped(.runfiles);
        const err = warn;
        const warn = base.warn;
        const info = base.info;
        const debug = base.debug;
    }
else
    std.log.scoped(.runfiles);

const RPath = @import("RPath.zig");

const Manifest = @This();

mapping: HashMapUnmanaged,
content: []const u8,
path: [:0]const u8,

pub const InitError = ParseError || std.mem.Allocator.Error || std.Io.File.OpenError || std.Io.Reader.LimitedAllocError || std.Io.Dir.RealPathFileAllocError;

pub fn init(allocator: std.mem.Allocator, io: std.Io, path: []const u8) InitError!Manifest {
    const file = std.Io.Dir.cwd().openFile(io, path, .{}) catch |e| {
        log.err("Failed to open runfiles manifest ({s}) at '{s}'", .{
            @errorName(e),
            path,
        });
        return e;
    };
    defer file.close(io);
    var buf: [1024]u8 = undefined;
    var file_reader = file.reader(io, &buf);
    const content = try file_reader.interface.allocRemaining(allocator, .unlimited);
    errdefer allocator.free(content);
    const mapping = try parse(allocator, content);
    return .{
        .mapping = mapping,
        .content = content,
        .path = try std.Io.Dir.cwd().realPathFileAlloc(io, path, allocator),
    };
}

pub fn deinit(self: *Manifest, allocator: std.mem.Allocator) void {
    self.mapping.deinit(allocator);
    allocator.free(self.content);
    allocator.free(self.path);
}

pub fn rlocationUnmapped(self: *const Manifest, rpath: RPath) ?[]const u8 {
    return self.mapping.get(rpath);
}

const ParseError = error{
    OutOfMemory,
};

fn parse(allocator: std.mem.Allocator, content: []const u8) ParseError!HashMapUnmanaged {
    var result: HashMapUnmanaged = .{};
    errdefer result.deinit(allocator);
    var lines = std.mem.tokenizeAny(u8, content, "\r\n");
    while (lines.next()) |line| {
        var fields = std.mem.splitScalar(u8, line, ' ');
        const key = RPath.init(fields.first());
        const value = fields.rest();
        try result.put(allocator, key, value);
    }
    return result;
}

test "parse empty" {
    const content = "";
    var mapping = try parse(std.testing.allocator, content);
    defer mapping.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), mapping.size);
}

test "parse mappings" {
    const content =
        \\first/key /first/value
        \\second/key /second/value
        \\third/key /third/value
    ;
    var mapping = try parse(std.testing.allocator, content);
    defer mapping.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 3), mapping.size);
    try std.testing.expectEqualStrings("/first/value", mapping.get(RPath.init("first/key")).?);
    try std.testing.expectEqualStrings("/second/value", mapping.get(RPath.init("second/key")).?);
    try std.testing.expectEqualStrings("/third/value", mapping.get(RPath.init("third/key")).?);
    try std.testing.expectEqual(@as(?[]const u8, null), mapping.get(RPath.init("missing/key")));
}

test "parse empty value" {
    const content = "key \n";
    var mapping = try parse(std.testing.allocator, content);
    defer mapping.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), mapping.size);
    try std.testing.expectEqualStrings("", mapping.get(RPath.init("key")).?);
}

test "parse empty value without separator" {
    const content = "key\n";
    var mapping = try parse(std.testing.allocator, content);
    defer mapping.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), mapping.size);
    try std.testing.expectEqualStrings("", mapping.get(RPath.init("key")).?);
}

test "parse value with spaces" {
    const content = "key C:/Some Path/With Spaces\n";
    var mapping = try parse(std.testing.allocator, content);
    defer mapping.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), mapping.size);
    try std.testing.expectEqualStrings("C:/Some Path/With Spaces", mapping.get(RPath.init("key")).?);
}

test "parse different line endings" {
    const content = "k1 v1\n\nk2 v2\rk3 v3\r\nk4 v4";
    var mapping = try parse(std.testing.allocator, content);
    defer mapping.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 4), mapping.size);
    try std.testing.expectEqualStrings("v1", mapping.get(RPath.init("k1")).?);
    try std.testing.expectEqualStrings("v2", mapping.get(RPath.init("k2")).?);
    try std.testing.expectEqualStrings("v3", mapping.get(RPath.init("k3")).?);
    try std.testing.expectEqualStrings("v4", mapping.get(RPath.init("k4")).?);
}

const HashMapUnmanaged = std.HashMapUnmanaged(
    RPath,
    []const u8,
    RPath.HashMapContext,
    std.hash_map.default_max_load_percentage,
);

test "RunfilesManifest init unmapped lookup" {
    const testutil = @import("testutil.zig");
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try testutil.tmpWriteFile(tmp.dir, "test.runfiles_manifest",
        \\my_workspace/some/package/some_file /absolute/path/to/some/package/some_file
        \\_repo_mapping /absolute/path/to/_repo_mapping
    );

    const runfiles_path = try testutil.tmpRealpathAlloc(tmp.dir, std.testing.allocator, "test.runfiles_manifest");
    defer std.testing.allocator.free(runfiles_path);

    var manifest = try Manifest.init(std.testing.allocator, std.testing.io, runfiles_path);
    defer manifest.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings(runfiles_path, manifest.path);

    {
        const filepath = manifest.rlocationUnmapped(.{
            .repo = "",
            .path = "_repo_mapping",
        }).?;
        try std.testing.expectEqualStrings("/absolute/path/to/_repo_mapping", filepath);
    }

    {
        const filepath = manifest.rlocationUnmapped(.{
            .repo = "my_workspace",
            .path = "some/package/some_file",
        }).?;
        try std.testing.expectEqualStrings("/absolute/path/to/some/package/some_file", filepath);
    }

    {
        const result = manifest.rlocationUnmapped(.{
            .repo = "missing_workspace",
            .path = "missing/path",
        });
        try std.testing.expectEqual(@as(?[]const u8, null), result);
    }
}

test "RunfilesManifest init missing file" {
    const testutil = @import("testutil.zig");
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_path = try testutil.tmpRealpathAlloc(tmp.dir, std.testing.allocator, ".");
    defer std.testing.allocator.free(tmp_path);

    const missing_path = try std.fs.path.join(std.testing.allocator, &[_][]const u8{
        tmp_path,
        "missing.runfiles_manitest",
    });
    defer std.testing.allocator.free(missing_path);

    const result = Manifest.init(std.testing.allocator, std.testing.io, missing_path);
    try std.testing.expectError(error.FileNotFound, result);
}
