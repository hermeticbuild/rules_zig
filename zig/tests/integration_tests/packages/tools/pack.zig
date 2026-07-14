//! Pack a Zig package directory into a tarball and print its package hash.
//!
//! Usage: pack <package-dir> <output.tar>
//!
//! Writes `<output.tar>` (the package rooted under its name) and prints the
//! package hash on stdout, so test fixtures can be referenced by `.url` +
//! `.hash` without invoking `zig fetch`.
//!
//! The hash replicates the Zig package manager (`src/Package/Fetch.zig`
//! `computeHash` + `Package.Hash.init`): per file `sha256(rel_path ++ {0,0} ++
//! content)`, combined by `sha256` over the files sorted by path, formatted as
//! `name-version-base64url(LE id ++ LE size ++ digest[0..25])`. Pinned to the
//! toolchain Zig version.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Zoir = std.zig.Zoir;
const Sha256 = std.crypto.hash.sha2.Sha256;

const Manifest = struct {
    name: []const u8,
    version: []const u8,
    id: u32,
    paths: []const []const u8,
};

const Entry = struct {
    path: []const u8,
    digest: [Sha256.digest_length]u8 = undefined,
    size: u64 = 0,

    fn lessThan(_: void, a: Entry, b: Entry) bool {
        return std.mem.lessThan(u8, a.path, b.path);
    }
};

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;

    const args = try init.minimal.args.toSlice(arena);
    if (args.len != 3) fatal("usage: pack <package-dir> <output.tar>", .{});

    var pkg_dir = try Io.Dir.cwd().openDir(io, args[1], .{ .iterate = true });
    defer pkg_dir.close(io);

    const manifest = try parseManifest(arena, io, pkg_dir);
    const hashed = try hashPackage(arena, io, pkg_dir, manifest.paths);

    try writeTar(io, pkg_dir, manifest.name, hashed.entries, args[2]);

    const size: u32 = std.math.cast(u32, hashed.total) orelse std.math.maxInt(u32);
    const hash = formatHash(arena, manifest, hashed.digest, size);

    var stdout_buffer: [256]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(io, &stdout_buffer);
    try stdout.interface.writeAll(hash);
    try stdout.interface.writeByte('\n');
    try stdout.interface.flush();
}

const Hashed = struct {
    /// The included files, sorted by path, for the tarball.
    entries: []const Entry,
    /// The combined digest over `entries`.
    digest: [Sha256.digest_length]u8,
    /// The total content size of `entries`.
    total: u64,
};

/// Hash the package's included files as the Zig package manager does.
fn hashPackage(arena: Allocator, io: Io, pkg_dir: Io.Dir, paths: []const []const u8) !Hashed {
    var entries: std.ArrayList(Entry) = .empty;
    var walker = try pkg_dir.walk(arena);
    while (try walker.next(io)) |entry| {
        // Directories are not hashed; symlinks (e.g. Bazel-staged fixture files)
        // are dereferenced and treated as regular files via their content.
        if (entry.kind == .directory) continue;
        const path = try arena.dupe(u8, entry.path);
        if (!includePath(paths, path)) continue;
        try entries.append(arena, .{ .path = path });
    }

    for (entries.items) |*entry| {
        const content = try pkg_dir.readFileAlloc(io, entry.path, arena, .unlimited);
        var hasher: Sha256 = .init(.{});
        hasher.update(entry.path);
        // Hard-coded non-executable bit, matching Zig's `computeHash`.
        hasher.update(&.{ 0, 0 });
        hasher.update(content);
        hasher.final(&entry.digest);
        entry.size = content.len;
    }

    std.mem.sortUnstable(Entry, entries.items, {}, Entry.lessThan);

    var combined: Sha256 = .init(.{});
    var total: u64 = 0;
    for (entries.items) |entry| {
        combined.update(&entry.digest);
        total += entry.size;
    }
    var digest: [Sha256.digest_length]u8 = undefined;
    combined.final(&digest);

    return .{ .entries = entries.items, .digest = digest, .total = total };
}

fn formatHash(arena: Allocator, manifest: Manifest, digest: [Sha256.digest_length]u8, size: u32) []const u8 {
    var hashplus: [33]u8 = undefined;
    std.mem.writeInt(u32, hashplus[0..4], manifest.id, .little);
    std.mem.writeInt(u32, hashplus[4..8], size, .little);
    hashplus[8..33].* = digest[0..25].*;

    var encoded: [44]u8 = undefined;
    _ = std.base64.url_safe_no_pad.Encoder.encode(&encoded, &hashplus);

    return std.fmt.allocPrint(arena, "{s}-{s}-{s}", .{ manifest.name, manifest.version, encoded }) catch fatal("out of memory", .{});
}

fn includePath(paths: []const []const u8, sub_path: []const u8) bool {
    for (paths) |path| {
        if (path.len == 0 or std.mem.eql(u8, path, ".")) return true;
        if (std.mem.eql(u8, path, sub_path)) return true;
    }
    var dirname = sub_path;
    while (std.fs.path.dirname(dirname)) |parent| : (dirname = parent) {
        for (paths) |path| {
            if (std.mem.eql(u8, path, parent)) return true;
        }
    }
    return false;
}

fn writeTar(io: Io, pkg_dir: Io.Dir, root: []const u8, entries: []const Entry, out_path: []const u8) !void {
    var out_file = try Io.Dir.cwd().createFile(io, out_path, .{});
    defer out_file.close(io);

    var out_buffer: [64 * 1024]u8 = undefined;
    var out_writer = out_file.writer(io, &out_buffer);

    var tar: std.tar.Writer = .{ .underlying_writer = &out_writer.interface };
    try tar.setRoot(root);
    for (entries) |entry| {
        const content = try pkg_dir.readFileAlloc(io, entry.path, std.heap.page_allocator, .unlimited);
        defer std.heap.page_allocator.free(content);
        try tar.writeFileBytes(entry.path, content, .{});
    }
    try tar.finishPedantically();
    try out_writer.interface.flush();
}

// A package with no `build.zig.zon` (a bare source drop) has no name, version,
// or fingerprint; Zig hashes all its files and renders `N-V-<...>` with a
// sentinel id. Matching this lets fixtures stand in for such dependencies.
const NAKED_ID: u32 = 0x0000_ffff;

fn parseManifest(arena: Allocator, io: Io, pkg_dir: Io.Dir) !Manifest {
    const source = pkg_dir.readFileAllocOptions(io, "build.zig.zon", arena, .unlimited, .of(u8), 0) catch |err| switch (err) {
        error.FileNotFound => return .{ .name = "N", .version = "V", .id = NAKED_ID, .paths = &.{""} },
        else => return err,
    };

    const ast = try std.zig.Ast.parse(arena, source, .{ .mode = .zon });
    const zoir = try std.zig.ZonGen.generate(arena, ast, .{});
    if (zoir.compile_errors.len != 0) fatal("invalid 'build.zig.zon'", .{});

    var name: []const u8 = "";
    var version: []const u8 = "";
    var id: u32 = 0;
    var paths: std.ArrayList([]const u8) = .empty;

    switch (Zoir.Node.Index.root.get(&zoir)) {
        .struct_literal => |fields| for (fields.names, 0..) |field_name, i| {
            const field = field_name.get(&zoir);
            const value = fields.vals.at(@intCast(i));
            if (std.mem.eql(u8, field, "name")) {
                name = enumLiteral(zoir, value);
            } else if (std.mem.eql(u8, field, "version")) {
                version = stringOf(zoir, value);
            } else if (std.mem.eql(u8, field, "fingerprint")) {
                id = @truncate(intOf(zoir, value));
            } else if (std.mem.eql(u8, field, "paths")) {
                switch (value.get(&zoir)) {
                    .array_literal => |elements| for (0..elements.len) |j| {
                        try paths.append(arena, stringOf(zoir, elements.at(@intCast(j))));
                    },
                    else => {},
                }
            }
        },
        else => fatal("'build.zig.zon' does not contain a struct", .{}),
    }

    return .{ .name = name, .version = version, .id = id, .paths = paths.items };
}

fn enumLiteral(zoir: Zoir, index: Zoir.Node.Index) []const u8 {
    return switch (index.get(&zoir)) {
        .enum_literal => |literal| std.mem.sliceTo(zoir.string_bytes[@backingInt(literal)..], 0),
        else => "",
    };
}

fn stringOf(zoir: Zoir, index: Zoir.Node.Index) []const u8 {
    return switch (index.get(&zoir)) {
        .string_literal => |string| string,
        else => "",
    };
}

fn intOf(zoir: Zoir, index: Zoir.Node.Index) u64 {
    return switch (index.get(&zoir)) {
        .int_literal => |int| switch (int) {
            .small => |small| @bitCast(@as(i64, small)),
            .big => |big| big.toInt(u64) catch 0,
        },
        else => 0,
    };
}

fn fatal(comptime format: []const u8, args: anytype) noreturn {
    std.debug.print("pack: " ++ format ++ "\n", args);
    std.process.exit(1);
}
