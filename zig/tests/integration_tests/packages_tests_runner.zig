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
    .{ .name = "lazydirect", .patches = &.{.{ .deps = &.{ "lazyleaf", "lazyunused" } }} },
    .{ .name = "usec" },
    .{ .name = "cdep" },
    .{ .name = "cppdep" },
    .{ .name = "syslibdep" },
    .{ .name = "optdep" },
    .{ .name = "cfgdep" },
    .{ .name = "cvardep" },
    .{ .name = "host", .patches = &.{.{ .manifest = "libs/foo/build.zig.zon", .deps = &.{"leaf"} }} },
    .{ .name = "hostuser", .patches = &.{.{ .deps = &.{"host"} }} },
    .{ .name = "srconly" },
    .{ .name = "genopts" },
    .{ .name = "tgtdep" },
    .{ .name = "patchdep" },
    .{ .name = "aliasmod" },
    .{ .name = "linklib" },
    .{ .name = "camalg" },
    .{ .name = "linkamalg", .patches = &.{.{ .deps = &.{"camalg"} }} },
    .{ .name = "translatec" },
    .{ .name = "emittedinc" },
};

const Consumer = struct {
    manifest: []const u8,
    deps: []const []const u8,
};

// Manifests that resolve dependencies via `zig_packages.from_file`.
const consumers = [_]Consumer{
    .{ .manifest = "build.zig.zon", .deps = &.{ "leaf", "bottom", "top", "libv1", "libfork", "libv2", "multi", "pruned", "symlinked", "lazyhost", "lazydirect", "usec", "cdep", "cppdep", "syslibdep", "optdep", "cfgdep", "cvardep", "host", "srconly", "genopts", "tgtdep", "patchdep", "aliasmod", "linklib", "linkamalg", "translatec", "emittedinc" } },
    .{ .manifest = "child/build.zig.zon", .deps = &.{ "leaf", "libv2", "hostuser" } },
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

    // `cfgdep`'s `configure` matrix links a different system library per
    // optimize mode; building under `-c opt` selects the `rel` cell, so the
    // binary's per-mode assertion exercises both cells.
    const opt_result = try ctx.exec_bazel(.{
        .argv = &[_][]const u8{ "run", "//:binary", "-c", "opt" },
    });
    defer opt_result.deinit();
    try std.testing.expect(opt_result.success);

    // The extracted module graph is exposed per package; assert it against the
    // golden manifests.
    const manifest_result = try ctx.exec_bazel(.{
        .argv = &[_][]const u8{ "test", "//:multi_manifest_test", "//:translatec_manifest_test", "//:cfgdep_manifest_test", "//:cvardep_manifest_test", "//:tgtdep_manifest_test" },
    });
    defer manifest_result.deinit();
    try std.testing.expect(manifest_result.success);
}

// Runs after the positive test above has packed the fixtures and patched the
// consumer manifests. Breaks one thing at a time, asserts the build fails as
// expected, and restores the original.
test "the importer rejects invalid package configurations" {
    const ctx = try BitContext.init();
    defer ctx.deinit();

    // A declared hash that does not match the fetched package.
    try ctx.patchWorkspaceFile("build.zig.zon", &.{.{ "leaf-0.0.0-", "leaf-0.0.0-x" }});
    try expectBuildFailure(ctx, "hash mismatch");
    try ctx.patchWorkspaceFile("build.zig.zon", &.{.{ "leaf-0.0.0-x", "leaf-0.0.0-" }});

    // A path dependency whose `build.zig.zon` is not provided via `from_file`.
    const greeter_manifest = "path_deps/greeter/build.zig.zon";
    try ctx.patchWorkspaceFile(greeter_manifest, &.{.{ "../message", "../../fixtures/leaf" }});
    try expectBuildFailure(ctx, "has no provided manifest");
    try ctx.patchWorkspaceFile(greeter_manifest, &.{.{ "../../fixtures/leaf", "../message" }});

    // `zig_dep` referencing a dependency the manifest does not declare.
    const greeter_build = "path_deps/greeter/BUILD.bazel";
    try ctx.patchWorkspaceFile(greeter_build, &.{
        .{ "\"zig_deps\")", "\"zig_dep\", \"zig_deps\")" },
        .{ "deps = zig_deps()", "deps = [zig_dep(\"nonexistent\")]" },
    });
    try expectBuildFailure(ctx, "declares no dependency");
    try ctx.patchWorkspaceFile(greeter_build, &.{
        .{ "\"zig_dep\", \"zig_deps\")", "\"zig_deps\")" },
        .{ "deps = [zig_dep(\"nonexistent\")]", "deps = zig_deps()" },
    });

    // Package lookups through the hub that must not resolve: a version shared
    // by two packages, and a package the manifest does not declare.
    const lookup = "zig_package_file(\"multi\", \"module_manifest.json\")";
    const ambiguous = "zig_package_file(\"lib\", \"src/lib.zig\", version = \"1.0.0\")";
    try ctx.patchWorkspaceFile("BUILD.bazel", &.{.{ lookup, ambiguous }});
    try expectBuildFailure(ctx, "is ambiguous");
    try ctx.patchWorkspaceFile("BUILD.bazel", &.{.{ ambiguous, lookup }});
    const undeclared = "zig_package_file(\"base\", \"module_manifest.json\")";
    try ctx.patchWorkspaceFile("BUILD.bazel", &.{.{ lookup, undeclared }});
    try expectBuildFailure(ctx, "declares no dependency");
    try ctx.patchWorkspaceFile("BUILD.bazel", &.{.{ undeclared, lookup }});

    // A dependency with a source-only (`build.zig`-less) path dependency.
    try ctx.patchWorkspaceFile("build.zig.zon", &.{.{ "// .srconly", ".srconly" }});
    try expectBuildFailure(ctx, "source-only");
    try ctx.patchWorkspaceFile("build.zig.zon", &.{.{ ".srconly", "// .srconly" }});

    // A required system library with no matching annotation.
    try ctx.patchWorkspaceFile("MODULE.bazel", &.{.{ "name = \"mymath\"", "name = \"mymath-unprovided\"" }});
    try expectBuildFailure(ctx, "system library");
    try ctx.patchWorkspaceFile("MODULE.bazel", &.{.{ "name = \"mymath-unprovided\"", "name = \"mymath\"" }});

    // A disabled system integration leaves the guarded symbol unlinked, though
    // the non-root `child_module` enables it.
    try ctx.patchWorkspaceFile("MODULE.bazel", &.{.{ "system_integration(name = \"optmath\")", "system_integration(name = \"optmath-off\")" }});
    try expectBuildFailure(ctx, "opt_compute");
    try ctx.patchWorkspaceFile("MODULE.bazel", &.{.{ "system_integration(name = \"optmath-off\")", "system_integration(name = \"optmath\")" }});

    // A patch tag that names a package absent from the graph is rejected.
    try ctx.patchWorkspaceFile("MODULE.bazel", &.{.{ "name = \"patchdep\"", "name = \"patchdep-absent\"" }});
    try expectBuildFailure(ctx, "not a URL package");
    try ctx.patchWorkspaceFile("MODULE.bazel", &.{.{ "name = \"patchdep-absent\"", "name = \"patchdep\"" }});
}

fn expectBuildFailure(ctx: BitContext, expected: []const u8) !void {
    const result = try ctx.exec_bazel(.{
        .argv = &[_][]const u8{ "build", "//:binary" },
        .print_on_error = false,
    });
    defer result.deinit();
    if (result.success) {
        std.debug.print("expected build to FAIL (mentioning '{s}') but it succeeded\n", .{expected});
        return error.BuildUnexpectedlySucceeded;
    }
    if (std.mem.indexOf(u8, result.stderr, expected) == null) {
        std.debug.print("expected build failure mentioning '{s}', stderr:\n{s}\n", .{ expected, result.stderr });
        return error.UnexpectedFailureMessage;
    }
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
