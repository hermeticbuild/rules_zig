//! Resolve a Zig package dependency graph by recursively parsing `build.zig.zon`
//! manifests, and emit the merged graph as JSON on stdout.
//!
//! Usage: resolver <zig> <global-cache> <pkg-dir> <build.zig.zon>...
//!
//! URL dependencies are fetched with `<zig> fetch`, using `<global-cache>` as
//! Zig's global cache, into `<pkg-dir>/<hash>` as Zig lays out a package tree.
//! The remaining arguments are the root manifests to resolve. Resolving
//! manifests here lets path dependencies inside fetched packages resolve
//! relative to the fetched tree.
//!
//! Packages are keyed by their Zig hash (URL dependencies) or by their resolved
//! path (path dependencies), and listed in topological order: a package always
//! precedes any package that lists it as a dependency. The emitted JSON has the
//! shape:
//!
//!     {
//!       "roots": [{"deps": {"<name>": "<key>"}}],
//!       "packages": {"<key>": {"url": ..., "path": ..., "paths": [...], "deps": {"<name>": "<key>"}}}
//!     }

const std = @import("std");
const Zoir = std.zig.Zoir;
const Allocator = std.mem.Allocator;
const Io = std.Io;

pub const Dep = struct {
    name: []const u8,
    url: ?[]const u8 = null,
    hash: ?[]const u8 = null,
    path: ?[]const u8 = null,
};

pub const Manifest = struct {
    deps: []const Dep,
    paths: []const []const u8,
};

pub const ParseError = error{ InvalidZon, NotAStruct } || Allocator.Error;

/// Extract the `dependencies` and `paths` fields of a `build.zig.zon` source.
/// Unknown fields are ignored; a dependency's unset fields stay null.
pub fn parseManifest(arena: Allocator, source: [:0]const u8) ParseError!Manifest {
    const ast = try std.zig.Ast.parse(arena, source, .{ .mode = .zon });
    const zoir = try std.zig.ZonGen.generate(arena, ast, .{});
    if (zoir.compile_errors.len != 0) return error.InvalidZon;

    var deps: std.ArrayList(Dep) = .empty;
    var paths: std.ArrayList([]const u8) = .empty;

    switch (Zoir.Node.Index.root.get(&zoir)) {
        .struct_literal => |fields| for (fields.names, 0..) |name, i| {
            const field = name.get(&zoir);
            const value = fields.vals.at(@intCast(i));
            if (std.mem.eql(u8, field, "dependencies")) {
                try parseDeps(arena, zoir, value, &deps);
            } else if (std.mem.eql(u8, field, "paths")) {
                try parsePaths(arena, zoir, value, &paths);
            }
        },
        else => return error.NotAStruct,
    }

    return .{ .deps = deps.items, .paths = paths.items };
}

fn parseDeps(arena: Allocator, zoir: Zoir, index: Zoir.Node.Index, deps: *std.ArrayList(Dep)) !void {
    const fields = switch (index.get(&zoir)) {
        .struct_literal => |fields| fields,
        else => return,
    };
    for (fields.names, 0..) |name, i| {
        var dep: Dep = .{ .name = name.get(&zoir) };
        switch (fields.vals.at(@intCast(i)).get(&zoir)) {
            .struct_literal => |entry| for (entry.names, 0..) |key, j| {
                const value = entry.vals.at(@intCast(j));
                const field = key.get(&zoir);
                if (std.mem.eql(u8, field, "url")) {
                    dep.url = stringOf(zoir, value);
                } else if (std.mem.eql(u8, field, "hash")) {
                    dep.hash = stringOf(zoir, value);
                } else if (std.mem.eql(u8, field, "path")) {
                    dep.path = stringOf(zoir, value);
                }
            },
            else => {},
        }
        try deps.append(arena, dep);
    }
}

fn parsePaths(arena: Allocator, zoir: Zoir, index: Zoir.Node.Index, paths: *std.ArrayList([]const u8)) !void {
    switch (index.get(&zoir)) {
        .array_literal => |elements| for (0..elements.len) |i| {
            try paths.append(arena, stringOf(zoir, elements.at(@intCast(i))));
        },
        else => {},
    }
}

fn stringOf(zoir: Zoir, index: Zoir.Node.Index) []const u8 {
    return switch (index.get(&zoir)) {
        .string_literal => |string| string,
        else => "",
    };
}

fn readManifest(arena: Allocator, io: Io, path: []const u8) !Manifest {
    const source = try Io.Dir.cwd().readFileAllocOptions(io, path, arena, .unlimited, .of(u8), 0);
    return parseManifest(arena, source) catch |err| switch (err) {
        error.InvalidZon => fatal("'{s}' is not valid ZON", .{path}),
        error.NotAStruct => fatal("'{s}' does not contain a struct literal", .{path}),
        error.OutOfMemory => return err,
    };
}

const Edge = struct {
    name: []const u8,
    key: []const u8,
};

const Package = struct {
    url: ?[]const u8,
    path: ?[]const u8,
    paths: []const []const u8,
    deps: []const Edge,
};

const Resolved = struct {
    key: []const u8,
    url: ?[]const u8,
    path: ?[]const u8,
    dir: []const u8,
};

const Walker = struct {
    arena: Allocator,
    io: Io,
    zig: []const u8,
    /// The environment of `zig fetch`, which selects the global cache through
    /// `ZIG_GLOBAL_CACHE_DIR`.
    fetch_environ: *const std.process.Environ.Map,
    /// Zig's build root for `zig fetch --save`.
    pkg_dir: []const u8,
    packages: std.StringArrayHashMapUnmanaged(Package) = .empty,
    visited: std.StringHashMapUnmanaged(void) = .empty,

    fn resolveDep(walker: *Walker, dep: Dep, parent_dir: []const u8) !Resolved {
        if (dep.url) |url| {
            const declared = dep.hash orelse fatal("URL dependency '{s}' is missing a hash", .{dep.name});
            const hash = try walker.fetch(url);
            if (!std.mem.eql(u8, hash, declared)) {
                fatal("hash mismatch for '{s}':\n  declared: {s}\n  fetched:  {s}", .{ dep.name, declared, hash });
            }
            return .{
                .key = hash,
                .url = url,
                .path = null,
                .dir = try std.fs.path.join(walker.arena, &.{ walker.pkg_dir, hash }),
            };
        }
        if (dep.path) |rel| {
            const dir = try std.fs.path.resolve(walker.arena, &.{ parent_dir, rel });
            return .{ .key = dir, .url = null, .path = dir, .dir = dir };
        }
        fatal("dependency '{s}' has neither a url nor a path", .{dep.name});
    }

    /// Fetch a URL package and return its Zig hash.
    fn fetch(walker: *Walker, url: []const u8) ![]const u8 {
        const result = try std.process.run(walker.arena, walker.io, .{
            .argv = &.{ walker.zig, "fetch", "--pkg-dir", ".", "--save=" ++ fetch_name, url },
            .cwd = .{ .path = walker.pkg_dir },
            .environ_map = walker.fetch_environ,
        });
        switch (result.term) {
            .exited => |code| if (code != 0) fatal("`zig fetch {s}` failed:\n{s}", .{ url, result.stderr }),
            .signal => |sig| fatal("`zig fetch {s}` killed by signal {d}:\nstdout:\n{s}\nstderr:\n{s}", .{ url, sig, result.stdout, result.stderr }),
            else => |term| fatal("`zig fetch {s}` terminated abnormally ({s}):\n{s}", .{ url, @tagName(term), result.stderr }),
        }
        const saved_path = try std.fs.path.join(walker.arena, &.{ walker.pkg_dir, "build.zig.zon" });
        const saved = try readManifest(walker.arena, walker.io, saved_path);
        return savedHash(saved) orelse fatal("`zig fetch {s}` recorded no hash in '{s}'", .{ url, saved_path });
    }

    fn resolveEdges(walker: *Walker, manifest: Manifest, dir: []const u8) ![]const Edge {
        var edges: std.ArrayList(Edge) = .empty;
        for (manifest.deps) |dep| {
            const resolved = try walker.resolveDep(dep, dir);
            try edges.append(walker.arena, .{ .name = dep.name, .key = resolved.key });
            try walker.walk(resolved);
        }
        return edges.items;
    }

    fn walk(walker: *Walker, resolved: Resolved) anyerror!void {
        const gop = try walker.visited.getOrPut(walker.arena, resolved.key);
        if (gop.found_existing) return;

        const manifest_path = try std.fs.path.join(walker.arena, &.{ resolved.dir, "build.zig.zon" });
        const manifest = try readManifest(walker.arena, walker.io, manifest_path);
        const edges = try walker.resolveEdges(manifest, resolved.dir);

        // Append only after the dependencies have been walked, so `packages` ends
        // up in topological order: a package precedes any package depending on it.
        try walker.packages.put(walker.arena, resolved.key, .{
            .url = resolved.url,
            .path = resolved.path,
            .paths = manifest.paths,
            .deps = edges,
        });
    }
};

/// The dependency name `zig fetch --save` records each package under. Explicit,
/// since a package without `build.zig.zon` has no name to default to.
const fetch_name = "package";

/// The hash `zig fetch --save=<fetch_name>` recorded in its build root's
/// manifest.
fn savedHash(manifest: Manifest) ?[]const u8 {
    for (manifest.deps) |dep| {
        if (std.mem.eql(u8, dep.name, fetch_name)) return dep.hash;
    }
    return null;
}

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;

    const args = try init.minimal.args.toSlice(arena);
    if (args.len < 4) fatal("usage: resolver <zig> <global-cache> <pkg-dir> <build.zig.zon>...", .{});

    try init.environ_map.put("ZIG_GLOBAL_CACHE_DIR", args[2]);
    try Io.Dir.cwd().createDirPath(io, args[3]);
    var pkg_dir = try Io.Dir.cwd().openDir(io, args[3], .{});
    defer pkg_dir.close(io);
    try pkg_dir.writeFile(io, .{ .sub_path = "build.zig", .data = "" });

    var walker: Walker = .{
        .arena = arena,
        .io = io,
        .zig = args[1],
        .fetch_environ = init.environ_map,
        .pkg_dir = args[3],
    };

    var roots: std.ArrayList([]const Edge) = .empty;
    for (args[4..]) |root_path| {
        const dir = std.fs.path.dirname(root_path) orelse ".";
        const manifest = try readManifest(arena, io, root_path);
        try roots.append(arena, try walker.resolveEdges(manifest, dir));
    }

    var stdout_buffer: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(io, &stdout_buffer);
    const writer = &stdout.interface;

    var json: std.json.Stringify = .{ .writer = writer };
    try json.beginObject();

    try json.objectField("roots");
    try json.beginArray();
    for (roots.items) |edges| {
        try json.beginObject();
        try json.objectField("deps");
        try writeEdges(&json, edges);
        try json.endObject();
    }
    try json.endArray();

    try json.objectField("packages");
    try json.beginObject();
    for (walker.packages.keys(), walker.packages.values()) |key, package| {
        try json.objectField(key);
        try json.beginObject();
        try json.objectField("url");
        try json.write(package.url);
        try json.objectField("path");
        try json.write(package.path);
        try json.objectField("paths");
        try json.write(package.paths);
        try json.objectField("deps");
        try writeEdges(&json, package.deps);
        try json.endObject();
    }
    try json.endObject();

    try json.endObject();
    try writer.writeByte('\n');
    try writer.flush();
}

fn writeEdges(json: *std.json.Stringify, edges: []const Edge) !void {
    try json.beginObject();
    for (edges) |edge| {
        try json.objectField(edge.name);
        try json.write(edge.key);
    }
    try json.endObject();
}

fn fatal(comptime format: []const u8, args: anytype) noreturn {
    std.debug.print("resolver: " ++ format ++ "\n", args);
    std.process.exit(1);
}

test {
    std.testing.refAllDecls(@This());
}

test "parses url and path dependencies" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const manifest = try parseManifest(arena,
        \\.{
        \\    .name = .example,
        \\    .version = "0.1.0",
        \\    .dependencies = .{
        \\        .clap = .{
        \\            .url = "https://example.com/clap.tar.gz",
        \\            .hash = "clap-0.10.0-jv8oCwXlAQBW3ZgQlZ_cLSlp8AR8DBhCoryxNZgUW9ZS",
        \\            .lazy = true,
        \\        },
        \\        .local = .{ .path = "../local" },
        \\    },
        \\    .paths = .{ "build.zig", "build.zig.zon", "src" },
        \\}
    );

    try std.testing.expectEqual(2, manifest.deps.len);

    const clap = manifest.deps[0];
    try std.testing.expectEqualStrings("clap", clap.name);
    try std.testing.expectEqualStrings("https://example.com/clap.tar.gz", clap.url.?);
    try std.testing.expectEqualStrings("clap-0.10.0-jv8oCwXlAQBW3ZgQlZ_cLSlp8AR8DBhCoryxNZgUW9ZS", clap.hash.?);
    try std.testing.expectEqual(null, clap.path);

    const local = manifest.deps[1];
    try std.testing.expectEqualStrings("local", local.name);
    try std.testing.expectEqual(null, local.url);
    try std.testing.expectEqual(null, local.hash);
    try std.testing.expectEqualStrings("../local", local.path.?);

    try std.testing.expectEqual(3, manifest.paths.len);
    try std.testing.expectEqualStrings("build.zig", manifest.paths[0]);
    try std.testing.expectEqualStrings("src", manifest.paths[2]);
}

test "manifest without dependencies or paths" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const manifest = try parseManifest(arena,
        \\.{
        \\    .name = .example,
        \\    .version = "0.1.0",
        \\}
    );

    try std.testing.expectEqual(0, manifest.deps.len);
    try std.testing.expectEqual(0, manifest.paths.len);
}

test "rejects invalid ZON" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try std.testing.expectError(error.InvalidZon, parseManifest(arena, ".{ .name = }"));
}

test "rejects a manifest that is not a struct literal" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try std.testing.expectError(error.NotAStruct, parseManifest(arena, "42"));
}

fn writeTestManifest(tmp: std.testing.TmpDir, sub_dir: []const u8, content: []const u8) !void {
    try tmp.dir.createDirPath(std.testing.io, sub_dir);
    var dir = try tmp.dir.openDir(std.testing.io, sub_dir, .{});
    defer dir.close(std.testing.io);
    try dir.writeFile(std.testing.io, .{ .sub_path = "build.zig.zon", .data = content });
}

test "walks path dependencies into a topologically ordered, deduplicated graph" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // root depends on a and b; a depends on b (a diamond through b).
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeTestManifest(tmp, "root",
        \\.{
        \\    .name = .root,
        \\    .dependencies = .{
        \\        .a = .{ .path = "../a" },
        \\        .b = .{ .path = "../b" },
        \\    },
        \\}
    );
    try writeTestManifest(tmp, "a",
        \\.{
        \\    .name = .a,
        \\    .dependencies = .{
        \\        .bee = .{ .path = "../b" },
        \\    },
        \\}
    );
    try writeTestManifest(tmp, "b",
        \\.{ .name = .b, .paths = .{"build.zig.zon"} }
    );

    const base = try std.fmt.allocPrint(arena, ".zig-cache/tmp/{s}", .{tmp.sub_path});

    const unused_environ: std.process.Environ.Map = .init(arena);
    var walker: Walker = .{
        .arena = arena,
        .io = std.testing.io,
        .zig = "unused",
        .fetch_environ = &unused_environ,
        .pkg_dir = "unused",
    };
    const root_dir = try std.fs.path.join(arena, &.{ base, "root" });
    const manifest = try readManifest(arena, std.testing.io, try std.fs.path.join(arena, &.{ root_dir, "build.zig.zon" }));
    const root_edges = try walker.resolveEdges(manifest, root_dir);

    const a_key = try std.fs.path.resolve(arena, &.{ base, "a" });
    const b_key = try std.fs.path.resolve(arena, &.{ base, "b" });

    try std.testing.expectEqual(2, root_edges.len);
    try std.testing.expectEqualStrings("a", root_edges[0].name);
    try std.testing.expectEqualStrings(a_key, root_edges[0].key);
    try std.testing.expectEqualStrings("b", root_edges[1].name);
    try std.testing.expectEqualStrings(b_key, root_edges[1].key);

    // b was reached twice but is recorded once, before its dependent a.
    try std.testing.expectEqual(2, walker.packages.count());
    try std.testing.expectEqualStrings(b_key, walker.packages.keys()[0]);
    try std.testing.expectEqualStrings(a_key, walker.packages.keys()[1]);

    const a_package = walker.packages.get(a_key).?;
    try std.testing.expectEqual(1, a_package.deps.len);
    try std.testing.expectEqualStrings("bee", a_package.deps[0].name);
    try std.testing.expectEqualStrings(b_key, a_package.deps[0].key);
    try std.testing.expectEqualStrings(a_key, a_package.path.?);
    try std.testing.expectEqual(null, a_package.url);

    const b_package = walker.packages.get(b_key).?;
    try std.testing.expectEqual(0, b_package.deps.len);
    try std.testing.expectEqual(1, b_package.paths.len);
}

test "reads the hash zig fetch --save recorded" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const manifest = try parseManifest(arena,
        \\.{
        \\    .name = .pkg,
        \\    .version = "0.0.1",
        \\    .dependencies = .{
        \\        .package = .{
        \\            .url = "file:///tmp/a.tar.gz",
        \\            .hash = "N-V-__8AAAcAAACEv4W5dFZNLFHT6by0N8ydd0hHTLqykZS4",
        \\        },
        \\    },
        \\    .minimum_zig_version = "0.17.0",
        \\    .paths = .{""},
        \\    .fingerprint = 0x16f4f95b1e3daacb,
        \\}
    );
    try std.testing.expectEqualStrings("N-V-__8AAAcAAACEv4W5dFZNLFHT6by0N8ydd0hHTLqykZS4", savedHash(manifest).?);
}
