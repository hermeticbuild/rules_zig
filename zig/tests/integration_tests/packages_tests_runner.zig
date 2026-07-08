const std = @import("std");
const integration_testing = @import("integration_testing");
const BitContext = integration_testing.BitContext;

// A manifest inside a fixture whose URL-dependency placeholders to fill with
// already-packed fixtures' url+hash.
const Patch = struct {
    manifest: []const u8 = "build.zig.zon",
    deps: []const []const u8,
};

const Package = struct {
    name: []const u8,
    patches: []const Patch = &.{},
    // `{target, sym_link_sub_path}`: a symlink to create inside the fixture
    // before packing, since git/jj checkouts do not preserve one.
    symlink: ?[2][]const u8 = null,
};

// Packed in topological order (dependencies first).
const packages = [_]Package{
    .{ .name = "leaf" },
    .{ .name = "base" },
    .{ .name = "bottom", .patches = &.{.{ .deps = &.{"base"} }} },
    .{ .name = "left", .patches = &.{.{ .deps = &.{"bottom"} }} },
    .{ .name = "right", .patches = &.{.{ .deps = &.{"bottom"} }} },
    .{ .name = "top", .patches = &.{.{ .deps = &.{ "left", "right" } }} },
    .{ .name = "libv1" },
    .{ .name = "libfork" },
    .{ .name = "libv2" },
    .{ .name = "multi" },
    .{ .name = "pruned" },
    .{ .name = "symlinked", .symlink = .{ "real.zig", "src/aliased.zig" } },
    .{ .name = "lazyleaf" },
    .{ .name = "lazyunused" },
    .{ .name = "lazyhost", .patches = &.{.{ .deps = &.{ "lazyleaf", "lazyunused" } }} },
    .{ .name = "usec" },
    .{ .name = "cdep" },
    .{ .name = "cppdep" },
    .{ .name = "syslibdep" },
    .{ .name = "optdep" },
};

const Consumer = struct {
    manifest: []const u8,
    deps: []const []const u8,
};

// Manifests that resolve dependencies via `zig_packages.from_file`.
const consumers = [_]Consumer{
    .{ .manifest = "build.zig.zon", .deps = &.{ "leaf", "bottom", "top", "libv1", "libfork", "libv2", "multi", "pruned", "symlinked", "lazyhost", "usec", "cdep", "cppdep", "syslibdep", "optdep" } },
    .{ .manifest = "child/build.zig.zon", .deps = &.{ "leaf", "libv2" } },
};

test "Zig packages are imported from file:// tarballs" {
    const ctx = try BitContext.init();
    defer ctx.deinit();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var urls = std.StringHashMap([]const u8).init(allocator);
    var hashes = std.StringHashMap([]const u8).init(allocator);

    for (packages) |pkg| {
        for (pkg.patches) |patch| {
            const manifest = try std.fmt.allocPrint(allocator, "fixtures/{s}/{s}", .{ pkg.name, patch.manifest });
            try ctx.patchWorkspaceFile(manifest, try depReplacements(allocator, patch.deps, &urls, &hashes));
        }

        if (pkg.symlink) |link| {
            const link_path = try std.fmt.allocPrint(allocator, "fixtures/{s}/{s}", .{ pkg.name, link[1] });
            try ctx.symLinkWorkspaceFile(link[0], link_path);
        }

        const dir = try std.fmt.allocPrint(allocator, "{s}/fixtures/{s}", .{ ctx.workspace_path, pkg.name });
        const tarball = try std.fmt.allocPrint(allocator, "{s}/{s}.tar", .{ ctx.workspace_path, pkg.name });
        const pack = try ctx.exec_bazel(.{
            .argv = &[_][]const u8{ "run", "//tools:pack", "--", dir, tarball },
        });
        defer pack.deinit();
        try std.testing.expect(pack.success);

        try hashes.put(pkg.name, try allocator.dupe(u8, std.mem.trim(u8, pack.stdout, " \t\r\n")));
        try urls.put(pkg.name, try std.fmt.allocPrint(allocator, "file://{s}", .{tarball}));
    }

    for (consumers) |consumer| {
        try ctx.patchWorkspaceFile(consumer.manifest, try depReplacements(allocator, consumer.deps, &urls, &hashes));
    }

    // The importer fetches every package in the graph, including `base`, which
    // is only reachable transitively through `bottom`, and deduplicates
    // `bottom`, which the diamond under `top` reaches twice. Running the
    // binary executes its assertions on the imported values.
    const result = try ctx.exec_bazel(.{
        .argv = &[_][]const u8{ "run", "//:binary" },
    });
    defer result.deinit();
    try std.testing.expect(result.success);

    // The extracted module graph is exposed per package; assert it against the
    // golden manifests.
    const manifest_result = try ctx.exec_bazel(.{
        .argv = &[_][]const u8{ "test", "//:multi_manifest_test" },
    });
    defer manifest_result.deinit();
    try std.testing.expect(manifest_result.success);
}

fn depReplacements(
    allocator: std.mem.Allocator,
    deps: []const []const u8,
    urls: *std.StringHashMap([]const u8),
    hashes: *std.StringHashMap([]const u8),
) ![]const [2][]const u8 {
    const replacements = try allocator.alloc([2][]const u8, deps.len * 2);
    for (deps, 0..) |dep, i| {
        replacements[i * 2] = .{ try placeholder(allocator, dep, "URL"), urls.get(dep).? };
        replacements[i * 2 + 1] = .{ try placeholder(allocator, dep, "HASH"), hashes.get(dep).? };
    }
    return replacements;
}

fn placeholder(allocator: std.mem.Allocator, name: []const u8, kind: []const u8) ![]const u8 {
    const upper = try allocator.alloc(u8, name.len);
    _ = std.ascii.upperString(upper, name);
    return std.fmt.allocPrint(allocator, "__{s}_{s}__", .{ upper, kind });
}
