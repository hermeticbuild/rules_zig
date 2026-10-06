//! Implements repository mappings for bzlmod support as defined in the
//! [updated runfiles design][runfiles-bzlmod].
//!
//! [runfiles-bzlmod]: https://github.com/bazelbuild/proposals/blob/53c5691c3f08011f0abf1d840d5824a3bbe039e2/designs/2022-07-21-locating-runfiles-with-bzlmod.md#2-extend-the-runfiles-libraries-to-take-repository-mappings-into-account

const std = @import("std");
const builtin = @import("builtin");
const testutil = @import("testutil.zig");
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

const ExactMap = ExactHashMapUnmanaged;
const TargetMap = std.StringHashMapUnmanaged([]const u8);
const WildcardMap = std.StringArrayHashMapUnmanaged(TargetMap);

const RepoMapping = @This();

exact_mapping: ExactMap,
wildcard_mapping: WildcardMap,
content: []const u8,

pub const InitError = ParseError || std.Io.File.OpenError || std.Io.Reader.LimitedAllocError || std.Io.Dir.RealPathFileAllocError;

/// Reads the given file into memory and parses the repo-mapping file format.
pub fn init(allocator: std.mem.Allocator, io: std.Io, file_path: []const u8) InitError!RepoMapping {
    const file = std.Io.Dir.cwd().openFile(io, file_path, .{}) catch |e| {
        log.err("Failed to open repository mapping ({s}) at '{s}'", .{
            @errorName(e),
            file_path,
        });
        return e;
    };
    defer file.close(io);
    var buf: [1024]u8 = undefined;
    var file_reader = file.reader(io, &buf);
    const content = try file_reader.interface.allocRemaining(allocator, .unlimited);
    errdefer allocator.free(content);
    const exact_mapping, const wildcard_mapping = try parse(allocator, content, file_path);
    return .{
        .exact_mapping = exact_mapping,
        .wildcard_mapping = wildcard_mapping,
        .content = content,
    };
}

pub fn deinit(self: *RepoMapping, allocator: std.mem.Allocator) void {
    // Free inner maps of wildcard_mapping
    var it = self.wildcard_mapping.iterator();
    while (it.next()) |entry| {
        entry.value_ptr.deinit(allocator);
    }
    self.wildcard_mapping.deinit(allocator);
    self.exact_mapping.deinit(allocator);
    allocator.free(self.content);
}

/// Performs a lookup in the parsed repo-mapping. Returns the given target
/// repository if no entry is found in the mapping but the target is a
/// canonical repository name.
pub fn lookup(self: *const RepoMapping, key: Key) ?[]const u8 {
    if (self.exact_mapping.get(key)) |exact| {
        return exact;
    }

    var it = self.wildcard_mapping.iterator();
    while (it.next()) |entry| {
        const prefix = entry.key_ptr.*;
        const target_map = entry.value_ptr;
        if (key.source.len >= prefix.len and std.mem.startsWith(u8, key.source, prefix)) {
            if (target_map.get(key.target)) |mapping| {
                return mapping;
            }
        }
    }

    const is_canonical = std.mem.indexOfScalar(u8, key.target, '+') != null;
    if (is_canonical)
        return key.target
    else
        return null;
}

const ParseError = error{
    MalformedRepoMapping,
    OutOfMemory,
};

fn parse(allocator: std.mem.Allocator, content: []const u8, file_path: []const u8) ParseError!struct { ExactMap, WildcardMap } {
    var exact_mapping: ExactMap = .{};
    errdefer exact_mapping.deinit(allocator);

    var wildcard_mapping: WildcardMap = .{};
    errdefer {
        var it = wildcard_mapping.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.deinit(allocator);
        }
        wildcard_mapping.deinit(allocator);
    }

    var line_count: usize = 1;
    var lines = std.mem.tokenizeAny(u8, content, "\r\n");
    while (lines.next()) |line| : (line_count += 1) {
        const err_fmt = "Missing {s} in repo mapping {s}:{d}";
        var fields = std.mem.splitScalar(u8, line, ',');
        const source = fields.first();
        const target = fields.next() orelse {
            log.err(err_fmt, .{ "target repository apparent name", file_path, line_count });
            return error.MalformedRepoMapping;
        };
        const mapping = fields.next() orelse {
            log.err(err_fmt, .{ "repository mapping", file_path, line_count });
            return error.MalformedRepoMapping;
        };

        if (source.len == 0 or source[source.len - 1] != '*') {
            try exact_mapping.put(allocator, .{ .source = source, .target = target }, mapping);
        } else {
            // "prefix*"
            const prefix = source[0 .. source.len - 1];

            var gop = try wildcard_mapping.getOrPut(allocator, prefix);
            if (!gop.found_existing) {
                gop.value_ptr.* = TargetMap{};
            }

            try gop.value_ptr.put(allocator, target, mapping);
        }
    }

    return .{
        exact_mapping,
        wildcard_mapping,
    };
}

test "parse empty" {
    const content = "";
    var exact_mapping, var wildcard_mapping = try parse(std.testing.allocator, content, "_repo_mapping");
    defer exact_mapping.deinit(std.testing.allocator);
    defer wildcard_mapping.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), exact_mapping.size);
    try std.testing.expectEqual(@as(usize, 0), wildcard_mapping.entries.len);
}

test "parse mappings" {
    const content =
        \\source_1,target_1,mapping_1
        \\source_2,target_2,mapping_2
        \\source_3,target_3,mapping_3
    ;
    var exact_mapping, var wildcard_mapping = try parse(std.testing.allocator, content, "_repo_mapping");
    defer exact_mapping.deinit(std.testing.allocator);
    defer wildcard_mapping.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 3), exact_mapping.size);
    try std.testing.expectEqual(@as(usize, 0), wildcard_mapping.entries.len);

    try std.testing.expectEqualStrings("mapping_1", exact_mapping.get(.{ .source = "source_1", .target = "target_1" }).?);
    try std.testing.expectEqualStrings("mapping_2", exact_mapping.get(.{ .source = "source_2", .target = "target_2" }).?);
    try std.testing.expectEqualStrings("mapping_3", exact_mapping.get(.{ .source = "source_3", .target = "target_3" }).?);
    try std.testing.expectEqual(@as(?[]const u8, null), exact_mapping.get(.{ .source = "source_missing", .target = "target_missing" }));
}

test "parse compact mappings" {
    const content =
        \\,my_module,_main
        \\my_module++ext+*,my_module,my_module+
        \\my_module++ext+*,repo1,my_module++ext+repo1
    ;
    var exact_mapping, var wildcard_mapping = try parse(std.testing.allocator, content, "_repo_mapping");
    defer {
        exact_mapping.deinit(std.testing.allocator);
        var it = wildcard_mapping.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.*.deinit(std.testing.allocator);
        }
        wildcard_mapping.deinit(std.testing.allocator);
    }

    try std.testing.expectEqual(@as(usize, 1), exact_mapping.size);
    try std.testing.expectEqualStrings("_main", exact_mapping.get(.{ .source = "", .target = "my_module" }).?);

    const prefix_mapping = wildcard_mapping.get("my_module++ext+").?;
    try std.testing.expectEqual(@as(usize, 2), prefix_mapping.size);
    try std.testing.expectEqualStrings("my_module+", prefix_mapping.get("my_module").?);
    try std.testing.expectEqualStrings("my_module++ext+repo1", prefix_mapping.get("repo1").?);
}

test "parse empty source" {
    const content = ",target,mapping";
    var exact_mapping, _ = try parse(std.testing.allocator, content, "_repo_mapping");
    defer exact_mapping.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), exact_mapping.size);
    try std.testing.expectEqualStrings("mapping", exact_mapping.get(.{ .source = "", .target = "target" }).?);
}

test "parse empty target" {
    const content = "source,,mapping";
    var exact_mapping, _ = try parse(std.testing.allocator, content, "_repo_mapping");
    defer exact_mapping.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), exact_mapping.size);
    try std.testing.expectEqualStrings("mapping", exact_mapping.get(.{ .source = "source", .target = "" }).?);
}

test "parse different line endings" {
    const content = "s1,t1,m1\n\ns2,t2,m2\rs3,t3,m3\r\ns4,t4,m4";
    var exact_mapping, _ = try parse(std.testing.allocator, content, "_repo_mapping");
    defer exact_mapping.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 4), exact_mapping.size);
    try std.testing.expectEqualStrings("m1", exact_mapping.get(.{ .source = "s1", .target = "t1" }).?);
    try std.testing.expectEqualStrings("m2", exact_mapping.get(.{ .source = "s2", .target = "t2" }).?);
    try std.testing.expectEqualStrings("m3", exact_mapping.get(.{ .source = "s3", .target = "t3" }).?);
    try std.testing.expectEqualStrings("m4", exact_mapping.get(.{ .source = "s4", .target = "t4" }).?);
}

test "parse missing mapping" {
    const content = "s,t";
    const result = parse(std.testing.allocator, content, "_repo_mapping");
    try std.testing.expectError(error.MalformedRepoMapping, result);
}

test "parse missing target" {
    const content = "s";
    const result = parse(std.testing.allocator, content, "_repo_mapping");
    try std.testing.expectError(error.MalformedRepoMapping, result);
}

pub const Key = struct {
    /// source repository
    source: []const u8,
    /// target repository apparent name
    target: []const u8,

    pub fn format(
        self: Key,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = fmt;
        _ = options;
        try writer.print("({s}, {s})", .{ self.source, self.target });
    }
};

const ExactHashMapUnmanaged = std.HashMapUnmanaged(
    Key,
    []const u8,
    Ctx,
    std.hash_map.default_max_load_percentage,
);

const Ctx = struct {
    pub fn hash(self: @This(), k: Key) u64 {
        _ = self;
        var hasher = std.hash.Wyhash.init(0);
        hasher.update(k.source);
        hasher.update(",");
        hasher.update(k.target);
        return hasher.final();
    }
    pub fn eql(self: @This(), a: Key, b: Key) bool {
        _ = self;
        const eqlSource = std.hash_map.eqlString(a.source, b.source);
        const eqlTarget = std.hash_map.eqlString(a.target, b.target);
        return eqlSource and eqlTarget;
    }
};

test "RepoMapping init from file" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try testutil.tmpWriteFile(tmp.dir, "_repo_mapping",
        \\,my_module,my_workspace
        \\,my_protobuf,protobuf~3.19.2
        \\,my_workspace,my_workspace
        \\protobuf~3.19.2,protobuf,protobuf~3.19.2
    );
    const mapping_path = try testutil.tmpRealpathAlloc(tmp.dir, std.testing.allocator, "_repo_mapping");
    defer std.testing.allocator.free(mapping_path);
    var repo_mapping = try RepoMapping.init(std.testing.allocator, std.testing.io, mapping_path);
    defer repo_mapping.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("my_workspace", repo_mapping.exact_mapping.get(.{ .source = "", .target = "my_module" }).?);
    try std.testing.expectEqualStrings("protobuf~3.19.2", repo_mapping.exact_mapping.get(.{ .source = "", .target = "my_protobuf" }).?);
    try std.testing.expectEqualStrings("my_workspace", repo_mapping.exact_mapping.get(.{ .source = "", .target = "my_workspace" }).?);
    try std.testing.expectEqualStrings("protobuf~3.19.2", repo_mapping.exact_mapping.get(.{ .source = "protobuf~3.19.2", .target = "protobuf" }).?);
}

test "RepoMapping init missing file" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_path = try testutil.tmpRealpathAlloc(tmp.dir, std.testing.allocator, ".");
    defer std.testing.allocator.free(tmp_path);
    const missing_path = try std.fs.path.join(std.testing.allocator, &[_][]const u8{
        tmp_path,
        "_repo_mapping",
    });
    defer std.testing.allocator.free(missing_path);
    const result = RepoMapping.init(std.testing.allocator, std.testing.io, missing_path);
    try std.testing.expectError(error.FileNotFound, result);
}
