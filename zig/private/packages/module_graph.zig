//! Walk a configured `std.Build` instance's module import graph and emit the
//! public module set as JSON, for translation into Bazel `zig_library`
//! targets.
//!
//! The emitted JSON has the shape:
//!
//!     {"modules": [{"name": ..., "package": <hash>, "root_source": ...,
//!         "link_libc": true, "link_libcpp": true,  // each present only when set
//!         "csrcs": [...], "include_dirs": [...], "system_libs": [...], "unsupported": [...],  // each present only when non-empty
//!         "imports": [{"name": ..., "module": ..., "package": <hash>}]}]}
//!
//! A module's `package` is the Zig hash of the package that owns it, or the
//! empty string for the root package being configured. An import's `package`
//! identifies the owner of the imported module likewise. An import's `name` is
//! the name the importer uses (`@import(name)`), while its `module` is the
//! imported module's own registered name; the two differ when a module is
//! imported under an alias.
//!
//! The `link_libc`/`link_libcpp` fields are emitted (as `true`) only when the
//! module links the C / C++ standard library, e.g. via `b.addModule(..., .{
//! .link_libc = true })` or `module.linkSystemLibrary("c", .{})`; they are
//! omitted otherwise.
//!
//! The `csrcs` field lists the module's vendored C sources, each with its
//! per-file `flags` and an optional `language`. The `include_dirs` field lists
//! the module's own include directories, each tagged by `kind` (`path`,
//! `path_system`, or `path_after`). The `system_libs` field lists the names of
//! non-libc system libraries the module links (`linkSystemLibrary`); the
//! importer requires each to be mapped to a `cc_library`. The `unsupported`
//! field lists human-readable descriptions of C or link constructs the importer
//! cannot represent (assembly, prebuilt objects, generated config headers,
//! linked compile steps, ...).

const std = @import("std");
const Build = std.Build;
const LazyPath = Build.LazyPath;
const Allocator = std.mem.Allocator;

const ModuleSet = std.AutoArrayHashMapUnmanaged(*Build.Module, void);
const NameMap = std.AutoHashMapUnmanaged(*Build.Module, []const u8);

/// Collect `module` and every module it transitively imports, deduplicated by
/// identity.
fn collect(arena: Allocator, modules: *ModuleSet, module: *Build.Module) !void {
    const gop = try modules.getOrPut(arena, module);
    if (gop.found_existing) return;
    for (module.import_table.values()) |imported| try collect(arena, modules, imported);
}

/// Name each module as its owning package registers it, or `__anon_<index>`
/// when it is anonymous (`b.createModule`), so a module's entry and every
/// import edge referencing it agree. Each owner's name table is scanned once,
/// so naming is linear in the number of modules.
fn nameModules(arena: Allocator, modules: *const ModuleSet) !NameMap {
    var names: NameMap = .empty;

    var seen_owners: std.AutoHashMapUnmanaged(*Build, void) = .empty;
    for (modules.keys()) |module| {
        if ((try seen_owners.getOrPut(arena, module.owner)).found_existing) continue;
        var it = module.owner.modules.iterator();
        while (it.next()) |entry| {
            try names.put(arena, entry.value_ptr.*, entry.key_ptr.*);
        }
    }

    for (modules.keys(), 0..) |module, index| {
        if (!names.contains(module)) {
            try names.put(arena, module, try std.fmt.allocPrint(arena, "__anon_{d}", .{index}));
        }
    }

    return names;
}

fn lazyPathString(arena: Allocator, lazy_path: ?LazyPath) ResolvePathError!?[]const u8 {
    const path = lazy_path orelse return null;
    const sub_path = switch (path) {
        .src_path => |src| src.sub_path,
        .cwd_relative => |rel| if (std.fs.path.isAbsolute(rel)) return error.AbsolutePath else rel,
        .relative => |rel| rel.sub_path,
        else => return null,
    };
    return try normalizePath(arena, sub_path);
}

/// Canonicalize a package-relative path, as header globs, `srcs`, and
/// `includes` require: drop `.` and empty segments, so the package root becomes
/// the empty string; `..` is kept.
fn normalizePath(arena: Allocator, path: []const u8) ![]const u8 {
    var segments: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, path, '/');
    while (it.next()) |segment| {
        if (segment.len == 0 or std.mem.eql(u8, segment, ".")) continue;
        try segments.append(arena, segment);
    }
    return std.mem.join(arena, "/", segments.items);
}

const ResolvePathError = Allocator.Error || error{
    /// An absolute `cwd_relative` path names a location on the configuring
    /// machine, which generated targets cannot reference.
    AbsolutePath,
};

/// Record `lazy_path`, which `lazyPathString` rejected with `err`, as unsupported.
fn reportPath(arena: Allocator, unsupported: *std.StringArrayHashMapUnmanaged(void), lazy_path: LazyPath, err: ResolvePathError) Allocator.Error!void {
    switch (err) {
        error.AbsolutePath => try unsupported.put(arena, try std.fmt.allocPrint(arena, "an absolute path (`{s}`)", .{lazy_path.cwd_relative}), {}),
        error.OutOfMemory => |e| return e,
    }
}

const CSource = struct {
    path: []const u8,
    flags: []const []const u8,
    language: ?[]const u8,
};

const IncludeDir = struct {
    kind: []const u8,
    path: []const u8,
};

fn joinPath(arena: Allocator, base: []const u8, sub: []const u8) ![]const u8 {
    if (base.len == 0) return sub;
    return std.fmt.allocPrint(arena, "{s}/{s}", .{ base, sub });
}

fn languageName(language: ?Build.Module.CSourceLanguage) ?[]const u8 {
    return if (language) |l| @tagName(l) else null;
}

/// `flags` without its empty entries. Zig skips an empty C flag, the shape of a
/// package's conditional flag (`if (debug) "-DDEBUG" else ""`), whereas other C
/// compilers read it as an input file with an empty name.
fn nonEmptyFlags(arena: Allocator, flags: []const []const u8) ![]const []const u8 {
    var kept: std.ArrayList([]const u8) = .empty;
    for (flags) |flag| {
        if (flag.len != 0) try kept.append(arena, flag);
    }
    return kept.items;
}

fn appendIncludeDir(
    arena: Allocator,
    include_dirs: *std.ArrayList(IncludeDir),
    unsupported: *std.StringArrayHashMapUnmanaged(void),
    kind: []const u8,
    lazy_path: LazyPath,
) !void {
    const resolved_path = lazyPathString(arena, lazy_path) catch |err| return reportPath(arena, unsupported, lazy_path, err);
    if (resolved_path) |path| {
        try include_dirs.append(arena, .{ .kind = kind, .path = path });
    } else {
        try unsupported.put(arena, "an include path with a generated or out-of-package location", {});
    }
}

/// Emit a module's vendored C sources, include directories, and any C or link
/// constructs the importer cannot represent. `csrcs`, `include_dirs`, and
/// `unsupported` are written only when non-empty. `root_source_error` is how
/// `lazyPathString` rejected the module's root source, if it did.
fn emitC(arena: Allocator, json: *std.json.Stringify, module: *Build.Module, root_source_error: ?ResolvePathError) !void {
    var csrcs: std.ArrayList(CSource) = .empty;
    var include_dirs: std.ArrayList(IncludeDir) = .empty;
    var system_libs: std.ArrayList([]const u8) = .empty;
    var unsupported: std.StringArrayHashMapUnmanaged(void) = .empty;
    if (root_source_error) |err| try reportPath(arena, &unsupported, module.root_source_file.?, err);

    for (module.link_objects.items) |link_object| switch (link_object) {
        .c_source_file => |c| {
            const resolved_path = lazyPathString(arena, c.file) catch |err| {
                try reportPath(arena, &unsupported, c.file, err);
                continue;
            };
            if (resolved_path) |path| {
                try csrcs.append(arena, .{ .path = path, .flags = try nonEmptyFlags(arena, c.flags), .language = languageName(c.language) });
            } else {
                try unsupported.put(arena, "a C source file with a generated or out-of-package path", {});
            }
        },
        .c_source_files => |c| {
            const resolved_path = lazyPathString(arena, c.root) catch |err| {
                try reportPath(arena, &unsupported, c.root, err);
                continue;
            };
            if (resolved_path) |root_path| {
                for (c.files) |file| {
                    const path = try normalizePath(arena, try joinPath(arena, root_path, file));
                    try csrcs.append(arena, .{ .path = path, .flags = try nonEmptyFlags(arena, c.flags), .language = languageName(c.language) });
                }
            } else {
                try unsupported.put(arena, "C source files with a generated or out-of-package root", {});
            }
        },
        .system_lib => |lib| try system_libs.append(arena, lib.name),
        .static_path => try unsupported.put(arena, "a precompiled object or static library (`addObjectFile`)", {}),
        .assembly_file => try unsupported.put(arena, "an assembly source file", {}),
        .win32_resource_file => try unsupported.put(arena, "a Win32 resource file", {}),
        .other_step => try unsupported.put(arena, "a linked compile step (`linkLibrary`/`addObject`)", {}),
    };

    for (module.include_dirs.items) |include_dir| switch (include_dir) {
        .path => |lp| try appendIncludeDir(arena, &include_dirs, &unsupported, "path", lp),
        .path_system => |lp| try appendIncludeDir(arena, &include_dirs, &unsupported, "path_system", lp),
        .path_after => |lp| try appendIncludeDir(arena, &include_dirs, &unsupported, "path_after", lp),
        .embed_path => try unsupported.put(arena, "an embed include path (`addEmbedPath`)", {}),
        .framework_path, .framework_path_system => try unsupported.put(arena, "a framework include path", {}),
        .config_header_step => try unsupported.put(arena, "a generated config header (`addConfigHeader`)", {}),
        .other_step => try unsupported.put(arena, "an include path from a linked compile step", {}),
    };

    if (csrcs.items.len > 0) {
        try json.objectField("csrcs");
        try json.beginArray();
        for (csrcs.items) |c| {
            try json.beginObject();
            try json.objectField("path");
            try json.write(c.path);
            try json.objectField("flags");
            try json.beginArray();
            for (c.flags) |flag| try json.write(flag);
            try json.endArray();
            try json.objectField("language");
            try json.write(c.language);
            try json.endObject();
        }
        try json.endArray();
    }

    if (include_dirs.items.len > 0) {
        try json.objectField("include_dirs");
        try json.beginArray();
        for (include_dirs.items) |inc| {
            try json.beginObject();
            try json.objectField("kind");
            try json.write(inc.kind);
            try json.objectField("path");
            try json.write(inc.path);
            try json.endObject();
        }
        try json.endArray();
    }

    if (system_libs.items.len > 0) {
        try json.objectField("system_libs");
        try json.beginArray();
        for (system_libs.items) |name| try json.write(name);
        try json.endArray();
    }

    if (unsupported.count() > 0) {
        try json.objectField("unsupported");
        try json.beginArray();
        for (unsupported.keys()) |u| try json.write(u);
        try json.endArray();
    }
}

/// Emit `{"modules": [...]}` for the module graph seeded by the modules
/// registered via `b.addModule`.
pub fn emit(arena: Allocator, writer: *std.Io.Writer, builder: *Build) !void {
    var json: std.json.Stringify = .{ .writer = writer };
    try json.beginObject();
    try json.objectField("modules");
    try emitModules(arena, &json, builder);
    try json.endObject();
    try writer.writeByte('\n');
}

/// Emit the module graph as a JSON array of module objects into `json`. The
/// caller writes the enclosing object field.
pub fn emitModules(arena: Allocator, json: *std.json.Stringify, builder: *Build) !void {
    var modules: ModuleSet = .empty;
    for (builder.modules.values()) |module| try collect(arena, &modules, module);

    var names = try nameModules(arena, &modules);

    try json.beginArray();
    for (modules.keys()) |module| {
        var root_source_error: ?ResolvePathError = null;
        const root_source = lazyPathString(arena, module.root_source_file) catch |err| switch (err) {
            error.AbsolutePath => |e| rejected: {
                root_source_error = e;
                break :rejected null;
            },
            error.OutOfMemory => |e| return e,
        };
        try json.beginObject();
        try json.objectField("name");
        try json.write(names.get(module).?);
        try json.objectField("package");
        try json.write(module.owner.pkg_hash);
        try json.objectField("root_source");
        try json.write(root_source);
        if (module.link_libc == true) {
            try json.objectField("link_libc");
            try json.write(true);
        }
        if (module.link_libcpp == true) {
            try json.objectField("link_libcpp");
            try json.write(true);
        }
        try emitC(arena, json, module, root_source_error);
        try json.objectField("imports");
        try json.beginArray();
        for (module.import_table.keys(), module.import_table.values()) |import_name, imported| {
            try json.beginObject();
            try json.objectField("name");
            try json.write(import_name);
            try json.objectField("module");
            try json.write(names.get(imported).?);
            try json.objectField("package");
            try json.write(imported.owner.pkg_hash);
            try json.endObject();
        }
        try json.endArray();
        try json.endObject();
    }
    try json.endArray();
}

/// A package configured under one named build configuration.
pub const Cell = struct {
    /// Empty for the unnamed default configuration.
    name: []const u8,
    builder: *Build,
};

/// Emit `{"cells": [{"name": ..., "modules": [...]}]}`, one entry per cell.
pub fn emitCells(arena: Allocator, writer: *std.Io.Writer, cells: []const Cell) !void {
    var json: std.json.Stringify = .{ .writer = writer };
    try json.beginObject();
    try json.objectField("cells");
    try json.beginArray();
    for (cells) |cell| {
        try json.beginObject();
        try json.objectField("name");
        try json.write(cell.name);
        try json.objectField("modules");
        try emitModules(arena, &json, cell.builder);
        try json.endObject();
    }
    try json.endArray();
    try json.endObject();
    try writer.writeByte('\n');
}

/// Construct a `std.Build` instance rooted at `build_root_path`, ready for
/// `runPackageScript` and `emit`.
pub fn createBuilder(
    arena: Allocator,
    io: std.Io,
    environ_map: std.process.Environ.Map,
    zig_exe: []const u8,
    build_root_path: []const u8,
    dependencies: []const struct { []const u8, []const u8 },
) !*Build {
    const graph = try arena.create(Build.Graph);
    graph.* = .{
        .io = io,
        .arena = arena,
        .environ_map = environ_map,
        .host = .{
            .query = .{},
            .result = try std.zig.system.resolveTargetQuery(io, .{}),
        },
        .generated_files = .empty,
        .zig_exe = zig_exe,
        .wip_configuration = .init(arena),
    };

    // Seed the configuration string table so its reserved sentinels resolve:
    // `.empty` must intern at offset 0 and `.root` at offset 1, before any
    // other string.
    const empty_string = try graph.wip_configuration.addString("");
    const root_string = try graph.wip_configuration.addString("root");
    std.debug.assert(empty_string == .empty);
    std.debug.assert(root_string == .root);

    const build_root: Build.Cache.Path = .{
        .root_dir = .{
            .handle = try std.Io.Dir.cwd().openDir(io, build_root_path, .{}),
            .path = build_root_path,
        },
    };

    return try Build.create(graph, build_root, dependencies);
}

test "emits registered modules and their import edges" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const build_root = try std.fmt.allocPrint(arena, ".zig-cache/tmp/{s}", .{tmp.sub_path});

    const b = try createBuilder(arena, std.testing.io, .{ .array_hash_map = .empty, .allocator = arena }, "unused-zig", build_root, &.{});

    // `util` is imported by `lib` under the alias `helper`.
    const util = b.addModule("util", .{ .root_source_file = b.path("src/util.zig") });
    const lib = b.addModule("lib", .{ .root_source_file = b.path("src/lib.zig") });
    lib.addImport("helper", util);

    var out: std.Io.Writer.Allocating = .init(arena);
    try emit(arena, &out.writer, b);

    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, arena, out.written(), .{});
    const modules = parsed.object.get("modules").?.array.items;
    try std.testing.expectEqual(2, modules.len);

    const util_entry = modules[0].object;
    try std.testing.expectEqualStrings("util", util_entry.get("name").?.string);
    try std.testing.expectEqualStrings("", util_entry.get("package").?.string);
    try std.testing.expectEqualStrings("src/util.zig", util_entry.get("root_source").?.string);
    try std.testing.expectEqual(0, util_entry.get("imports").?.array.items.len);

    const lib_entry = modules[1].object;
    try std.testing.expectEqualStrings("lib", lib_entry.get("name").?.string);
    try std.testing.expectEqualStrings("src/lib.zig", lib_entry.get("root_source").?.string);
    const imports = lib_entry.get("imports").?.array.items;
    try std.testing.expectEqual(1, imports.len);
    try std.testing.expectEqualStrings("helper", imports[0].object.get("name").?.string);
    try std.testing.expectEqualStrings("util", imports[0].object.get("module").?.string);
}

test "synthesizes stable names for anonymous modules" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const build_root = try std.fmt.allocPrint(arena, ".zig-cache/tmp/{s}", .{tmp.sub_path});

    const b = try createBuilder(arena, std.testing.io, .{ .array_hash_map = .empty, .allocator = arena }, "unused-zig", build_root, &.{});

    const anon = b.createModule(.{ .root_source_file = b.path("src/internal.zig") });
    const lib = b.addModule("lib", .{ .root_source_file = b.path("src/lib.zig") });
    lib.addImport("internal", anon);

    var out: std.Io.Writer.Allocating = .init(arena);
    try emit(arena, &out.writer, b);

    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, arena, out.written(), .{});
    const modules = parsed.object.get("modules").?.array.items;
    try std.testing.expectEqual(2, modules.len);

    // The anonymous module's entry and the import edge referencing it agree.
    const anon_name = modules[1].object.get("name").?.string;
    try std.testing.expect(std.mem.startsWith(u8, anon_name, "__anon_"));
    const imports = modules[0].object.get("imports").?.array.items;
    try std.testing.expectEqualStrings("lib", modules[0].object.get("name").?.string);
    try std.testing.expectEqualStrings(anon_name, imports[0].object.get("module").?.string);
}

test "emits link_libc and link_libcpp only for modules that link them" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const build_root = try std.fmt.allocPrint(arena, ".zig-cache/tmp/{s}", .{tmp.sub_path});

    const b = try createBuilder(arena, std.testing.io, .{ .array_hash_map = .empty, .allocator = arena }, "unused-zig", build_root, &.{});

    _ = b.addModule("plain", .{ .root_source_file = b.path("src/plain.zig") });
    _ = b.addModule("withc", .{ .root_source_file = b.path("src/withc.zig"), .link_libc = true });
    _ = b.addModule("withcpp", .{ .root_source_file = b.path("src/withcpp.zig"), .link_libcpp = true });

    var out: std.Io.Writer.Allocating = .init(arena);
    try emit(arena, &out.writer, b);

    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, arena, out.written(), .{});
    const modules = parsed.object.get("modules").?.array.items;

    try std.testing.expectEqualStrings("plain", modules[0].object.get("name").?.string);
    try std.testing.expectEqual(null, modules[0].object.get("link_libc"));
    try std.testing.expectEqual(null, modules[0].object.get("link_libcpp"));

    try std.testing.expectEqualStrings("withc", modules[1].object.get("name").?.string);
    try std.testing.expectEqual(true, modules[1].object.get("link_libc").?.bool);
    try std.testing.expectEqual(null, modules[1].object.get("link_libcpp"));

    try std.testing.expectEqualStrings("withcpp", modules[2].object.get("name").?.string);
    try std.testing.expectEqual(null, modules[2].object.get("link_libc"));
    try std.testing.expectEqual(true, modules[2].object.get("link_libcpp").?.bool);
}

test "emits vendored C sources, include dirs, and unsupported constructs" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const build_root = try std.fmt.allocPrint(arena, ".zig-cache/tmp/{s}", .{tmp.sub_path});

    const b = try createBuilder(arena, std.testing.io, .{ .array_hash_map = .empty, .allocator = arena }, "unused-zig", build_root, &.{});

    const withc = b.addModule("withc", .{ .root_source_file = b.path("src/withc.zig") });
    withc.addCSourceFile(.{ .file = b.path("src/impl.c"), .flags = &.{"-DFOO=1"} });
    withc.addIncludePath(b.path("include"));

    const bad = b.addModule("bad", .{ .root_source_file = b.path("src/bad.zig") });
    bad.addAssemblyFile(b.path("src/boot.s"));

    var out: std.Io.Writer.Allocating = .init(arena);
    try emit(arena, &out.writer, b);

    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, arena, out.written(), .{});
    const modules = parsed.object.get("modules").?.array.items;

    const withc_entry = modules[0].object;
    try std.testing.expectEqualStrings("withc", withc_entry.get("name").?.string);
    const csrcs = withc_entry.get("csrcs").?.array.items;
    try std.testing.expectEqual(1, csrcs.len);
    try std.testing.expectEqualStrings("src/impl.c", csrcs[0].object.get("path").?.string);
    try std.testing.expectEqualStrings("-DFOO=1", csrcs[0].object.get("flags").?.array.items[0].string);
    const incs = withc_entry.get("include_dirs").?.array.items;
    try std.testing.expectEqual(1, incs.len);
    try std.testing.expectEqualStrings("path", incs[0].object.get("kind").?.string);
    try std.testing.expectEqualStrings("include", incs[0].object.get("path").?.string);
    try std.testing.expectEqual(null, withc_entry.get("unsupported"));

    const bad_entry = modules[1].object;
    try std.testing.expectEqualStrings("bad", bad_entry.get("name").?.string);
    const unsupported = bad_entry.get("unsupported").?.array.items;
    try std.testing.expectEqual(1, unsupported.len);
    try std.testing.expect(std.mem.indexOf(u8, unsupported[0].string, "assembly") != null);
}

test "drops a vendored C source's empty flags" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const build_root = try std.fmt.allocPrint(arena, ".zig-cache/tmp/{s}", .{tmp.sub_path});

    const b = try createBuilder(arena, std.testing.io, .{ .array_hash_map = .empty, .allocator = arena }, "unused-zig", build_root, &.{});

    const withc = b.addModule("withc", .{ .root_source_file = b.path("src/withc.zig") });
    withc.addCSourceFiles(.{ .files = &.{"src/impl.c"}, .flags = &.{ "", "-DFOO=1", "" } });

    var out: std.Io.Writer.Allocating = .init(arena);
    try emit(arena, &out.writer, b);

    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, arena, out.written(), .{});
    const csrcs = parsed.object.get("modules").?.array.items[0].object.get("csrcs").?.array.items;
    try std.testing.expectEqual(1, csrcs.len);
    const flags = csrcs[0].object.get("flags").?.array.items;
    try std.testing.expectEqual(1, flags.len);
    try std.testing.expectEqualStrings("-DFOO=1", flags[0].string);
}

test "normalizePath collapses redundant `.` and empty segments" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try std.testing.expectEqualStrings("dir", try normalizePath(arena, "dir/."));
    try std.testing.expectEqualStrings("a/b", try normalizePath(arena, "a//b"));
    try std.testing.expectEqualStrings("src/impl.c", try normalizePath(arena, "src/./impl.c"));
    try std.testing.expectEqualStrings("", try normalizePath(arena, "."));
    try std.testing.expectEqualStrings("", try normalizePath(arena, ""));
    try std.testing.expectEqualStrings("a/../b", try normalizePath(arena, "a/../b"));
}

test "normalizes redundant path segments in C sources and include dirs" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const build_root = try std.fmt.allocPrint(arena, ".zig-cache/tmp/{s}", .{tmp.sub_path});

    const b = try createBuilder(arena, std.testing.io, .{ .array_hash_map = .empty, .allocator = arena }, "unused-zig", build_root, &.{});

    const m = b.addModule("m", .{ .root_source_file = b.path("src/m.zig") });
    m.addCSourceFile(.{ .file = b.path("src/./impl.c"), .flags = &.{} });
    m.addIncludePath(b.path("include/."));

    var out: std.Io.Writer.Allocating = .init(arena);
    try emit(arena, &out.writer, b);

    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, arena, out.written(), .{});
    const entry = parsed.object.get("modules").?.array.items[0].object;
    try std.testing.expectEqualStrings("src/impl.c", entry.get("csrcs").?.array.items[0].object.get("path").?.string);
    try std.testing.expectEqualStrings("include", entry.get("include_dirs").?.array.items[0].object.get("path").?.string);
}

test "reports absolute include paths and C sources as unsupported" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const build_root = try std.fmt.allocPrint(arena, ".zig-cache/tmp/{s}", .{tmp.sub_path});

    const b = try createBuilder(arena, std.testing.io, .{ .array_hash_map = .empty, .allocator = arena }, "unused-zig", build_root, &.{});

    const m = b.addModule("m", .{ .root_source_file = b.path("src/m.zig") });
    m.addCSourceFile(.{ .file = .{ .cwd_relative = "/usr/src/impl.c" }, .flags = &.{} });
    m.addIncludePath(.{ .cwd_relative = "/usr/include/x" });
    m.addIncludePath(.{ .cwd_relative = "include" });

    var out: std.Io.Writer.Allocating = .init(arena);
    try emit(arena, &out.writer, b);

    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, arena, out.written(), .{});
    const entry = parsed.object.get("modules").?.array.items[0].object;
    try std.testing.expectEqual(null, entry.get("csrcs"));
    const incs = entry.get("include_dirs").?.array.items;
    try std.testing.expectEqual(1, incs.len);
    try std.testing.expectEqualStrings("include", incs[0].object.get("path").?.string);
    const unsupported = entry.get("unsupported").?.array.items;
    try std.testing.expectEqual(2, unsupported.len);
    try std.testing.expectEqualStrings("an absolute path (`/usr/src/impl.c`)", unsupported[0].string);
    try std.testing.expectEqualStrings("an absolute path (`/usr/include/x`)", unsupported[1].string);
}

test "reports an absolute module root source as unsupported" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const build_root = try std.fmt.allocPrint(arena, ".zig-cache/tmp/{s}", .{tmp.sub_path});

    const b = try createBuilder(arena, std.testing.io, .{ .array_hash_map = .empty, .allocator = arena }, "unused-zig", build_root, &.{});

    _ = b.addModule("m", .{ .root_source_file = .{ .cwd_relative = "/usr/src/m.zig" } });

    var out: std.Io.Writer.Allocating = .init(arena);
    try emit(arena, &out.writer, b);

    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, arena, out.written(), .{});
    const entry = parsed.object.get("modules").?.array.items[0].object;
    try std.testing.expectEqual(.null, std.meta.activeTag(entry.get("root_source").?));
    const unsupported = entry.get("unsupported").?.array.items;
    try std.testing.expectEqual(1, unsupported.len);
    try std.testing.expectEqualStrings("an absolute path (`/usr/src/m.zig`)", unsupported[0].string);
}

test "reports an absolute C source root as unsupported" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const build_root = try std.fmt.allocPrint(arena, ".zig-cache/tmp/{s}", .{tmp.sub_path});

    const b = try createBuilder(arena, std.testing.io, .{ .array_hash_map = .empty, .allocator = arena }, "unused-zig", build_root, &.{});

    const m = b.addModule("m", .{ .root_source_file = b.path("src/m.zig") });
    m.addCSourceFiles(.{ .root = .{ .cwd_relative = "/usr/src" }, .files = &.{"impl.c"} });

    var out: std.Io.Writer.Allocating = .init(arena);
    try emit(arena, &out.writer, b);

    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, arena, out.written(), .{});
    const entry = parsed.object.get("modules").?.array.items[0].object;
    try std.testing.expectEqual(null, entry.get("csrcs"));
    const unsupported = entry.get("unsupported").?.array.items;
    try std.testing.expectEqual(1, unsupported.len);
    try std.testing.expectEqualStrings("an absolute path (`/usr/src`)", unsupported[0].string);
}

test "collapses repeated identical unsupported-construct messages" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const build_root = try std.fmt.allocPrint(arena, ".zig-cache/tmp/{s}", .{tmp.sub_path});

    const b = try createBuilder(arena, std.testing.io, .{ .array_hash_map = .empty, .allocator = arena }, "unused-zig", build_root, &.{});

    const bad = b.addModule("bad", .{ .root_source_file = b.path("src/bad.zig") });
    bad.addAssemblyFile(b.path("src/one.s"));
    bad.addAssemblyFile(b.path("src/two.s"));

    var out: std.Io.Writer.Allocating = .init(arena);
    try emit(arena, &out.writer, b);

    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, arena, out.written(), .{});
    const entry = parsed.object.get("modules").?.array.items[0].object;
    const unsupported = entry.get("unsupported").?.array.items;
    try std.testing.expectEqual(1, unsupported.len);
    try std.testing.expect(std.mem.indexOf(u8, unsupported[0].string, "assembly") != null);
}

test "emits the system libraries a module links" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const build_root = try std.fmt.allocPrint(arena, ".zig-cache/tmp/{s}", .{tmp.sub_path});

    const b = try createBuilder(arena, std.testing.io, .{ .array_hash_map = .empty, .allocator = arena }, "unused-zig", build_root, &.{});

    // `linkSystemLibrary` requires the module to carry a resolved target.
    const mod = b.addModule("mod", .{ .root_source_file = b.path("src/mod.zig"), .target = b.graph.host });
    mod.linkSystemLibrary("mymath", .{});

    var out: std.Io.Writer.Allocating = .init(arena);
    try emit(arena, &out.writer, b);

    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, arena, out.written(), .{});
    const module = parsed.object.get("modules").?.array.items[0].object;
    const system_libs = module.get("system_libs").?.array.items;
    try std.testing.expectEqual(1, system_libs.len);
    try std.testing.expectEqualStrings("mymath", system_libs[0].string);
}
