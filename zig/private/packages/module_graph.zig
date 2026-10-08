//! Walk a configured `std.Build` instance's module import graph and emit the
//! public module set as JSON, for translation into Bazel `zig_library`
//! targets.
//!
//! The emitted JSON has the shape:
//!
//!     {"modules": [{"name": ..., "package": <hash>, "root_source": ...,
//!         "imports": [{"name": ..., "module": ..., "package": <hash>}]}]}
//!
//! A module's `package` is the Zig hash of the package that owns it, or the
//! empty string for the root package being configured. An import's `package`
//! identifies the owner of the imported module likewise. An import's `name` is
//! the name the importer uses (`@import(name)`), while its `module` is the
//! imported module's own registered name; the two differ when a module is
//! imported under an alias.

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

fn lazyPathString(lazy_path: ?LazyPath) ?[]const u8 {
    const path = lazy_path orelse return null;
    return switch (path) {
        .src_path => |src| src.sub_path,
        .cwd_relative => |rel| rel,
        .relative => |rel| rel.sub_path,
        else => null,
    };
}

/// Emit the module graph seeded by the modules registered via `b.addModule`.
pub fn emit(arena: Allocator, writer: *std.Io.Writer, builder: *Build) !void {
    var modules: ModuleSet = .empty;
    for (builder.modules.values()) |module| try collect(arena, &modules, module);

    var names = try nameModules(arena, &modules);

    var json: std.json.Stringify = .{ .writer = writer };
    try json.beginObject();
    try json.objectField("modules");
    try json.beginArray();
    for (modules.keys()) |module| {
        try json.beginObject();
        try json.objectField("name");
        try json.write(names.get(module).?);
        try json.objectField("package");
        try json.write(module.owner.pkg_hash);
        try json.objectField("root_source");
        try json.write(lazyPathString(module.root_source_file));
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
