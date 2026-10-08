//! Parse `build.zig.zon` package manifests and emit them as JSON on stdout.
//!
//! Usage: resolver <build.zig.zon>...
//!
//! The emitted JSON is a list with one entry per input manifest:
//!
//!     [{"deps": {"<name>": {"url": ..., "hash": ..., "path": ...}},
//!       "paths": [...]}]
//!
//! A dependency carries either a `url` and `hash` or a `path`; absent fields
//! are null. `paths` lists the package's file inclusion filter.

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

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;

    const args = try init.minimal.args.toSlice(arena);
    if (args.len < 2) fatal("usage: resolver <build.zig.zon>...", .{});

    var manifests: std.ArrayList(Manifest) = .empty;
    for (args[1..]) |path| {
        const source = try Io.Dir.cwd().readFileAllocOptions(io, path, arena, .unlimited, .of(u8), 0);
        const manifest = parseManifest(arena, source) catch |err| switch (err) {
            error.InvalidZon => fatal("'{s}' is not valid ZON", .{path}),
            error.NotAStruct => fatal("'{s}' does not contain a struct literal", .{path}),
            error.OutOfMemory => return err,
        };
        try manifests.append(arena, manifest);
    }

    var stdout_buffer: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(io, &stdout_buffer);
    const writer = &stdout.interface;

    var json: std.json.Stringify = .{ .writer = writer };
    try json.beginArray();
    for (manifests.items) |manifest| {
        try json.beginObject();
        try json.objectField("deps");
        try json.beginObject();
        for (manifest.deps) |dep| {
            try json.objectField(dep.name);
            try json.beginObject();
            try json.objectField("url");
            try json.write(dep.url);
            try json.objectField("hash");
            try json.write(dep.hash);
            try json.objectField("path");
            try json.write(dep.path);
            try json.endObject();
        }
        try json.endObject();
        try json.objectField("paths");
        try json.write(manifest.paths);
        try json.endObject();
    }
    try json.endArray();
    try writer.writeByte('\n');
    try writer.flush();
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
