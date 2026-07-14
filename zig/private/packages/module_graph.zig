//! Walk a configured `std.Build` instance's module import graph and emit the
//! public module set as JSON, for translation into Bazel `zig_library`
//! targets.
//!
//! The emitted JSON has the shape:
//!
//!     {"modules": [{"name": ..., "package": <hash>, "root_source": ...,
//!         "generated_source": ...,  // present only for `b.addOptions()` modules
//!         "link_libc": true, "link_libcpp": true,  // each present only when set
//!         "csrcs": [...], "include_dirs": [...], "system_libs": [...], "unsupported": [...],  // each present only when non-empty
//!         "imports": [{"name": ..., "module": ..., "package": <hash>}]}]}
//!
//! Each JSON object renders the like-named fields of a record type below, which
//! documents them.

const std = @import("std");
const mem = std.mem;
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

fn lazyPathString(arena: Allocator, lazy_path: ?LazyPath) !?[]const u8 {
    const resolved = (try resolvePath(arena, lazy_path)) orelse return null;
    return resolved.sub_path;
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

/// A file path resolved to the package that owns it and its location within
/// that package.
const ResolvedPath = struct {
    /// Empty for the package being configured; a dependency's Zig hash for a
    /// file reached through `dep.path(...)`.
    package: []const u8,
    /// Canonical (see `normalizePath`).
    sub_path: []const u8,
};

const ResolvePathError = Allocator.Error || error{
    /// An absolute `cwd_relative` path names a location on the configuring
    /// machine, which generated targets cannot reference.
    AbsolutePath,
};

/// Resolve a source path; null for a generated one.
fn resolvePath(arena: Allocator, lazy_path: ?LazyPath) ResolvePathError!?ResolvedPath {
    const path = lazy_path orelse return null;
    const resolved: ResolvedPath = switch (path) {
        .src_path => |src| .{ .package = src.owner.pkg_hash, .sub_path = src.sub_path },
        .cwd_relative => |rel| if (std.fs.path.isAbsolute(rel)) return error.AbsolutePath else .{ .package = "", .sub_path = rel },
        .relative => |rel| .{ .package = "", .sub_path = rel.sub_path },
        .dependency => |dep| .{ .package = dep.dependency.builder.pkg_hash, .sub_path = dep.sub_path },
        .generated => return null,
    };
    return .{ .package = resolved.package, .sub_path = try normalizePath(arena, resolved.sub_path) };
}

/// Record `lazy_path`, which `resolvePath` rejected with `err`, as unsupported.
fn reportPath(arena: Allocator, unsupported: *std.StringArrayHashMapUnmanaged(void), lazy_path: LazyPath, err: ResolvePathError) Allocator.Error!void {
    switch (err) {
        error.AbsolutePath => try unsupported.put(arena, try std.fmt.allocPrint(arena, "an absolute path (`{s}`)", .{lazy_path.cwd_relative}), {}),
        error.OutOfMemory => |e| return e,
    }
}

pub const CSource = struct {
    /// The package owning the source file: empty for this package, a
    /// dependency's Zig hash for an out-of-package (`dep.path`) source.
    package: []const u8,
    path: []const u8,
    /// Per-file C flags.
    flags: []const []const u8,
    /// The source language (a `CSourceLanguage` tag), or null to infer it from
    /// the file extension.
    language: ?[]const u8,
};

pub const IncludeDir = struct {
    /// `path`, `path_system`, or `path_after`.
    kind: []const u8,
    /// The package owning the include directory, as for `CSource.package`.
    package: []const u8,
    path: []const u8,
};

pub const Import = struct {
    /// The name the importer uses (`@import(name)`); differs from `module` when
    /// the module is imported under an alias.
    name: []const u8,
    /// The imported module's own registered name.
    module: []const u8,
    /// The package owning the imported module, as for `Module.package`.
    package: []const u8,
};

/// A package module's extracted, configuration-independent shape.
pub const Module = struct {
    /// The module's name in its owning package (see `nameModules`).
    name: []const u8,
    /// The Zig hash of the owning package, or the empty string for the package
    /// being configured.
    package: []const u8,
    /// The root source file within the owning package; null for a generated
    /// root.
    root_source: ?[]const u8,
    /// The source of a module whose root is produced by `b.addOptions()`, which
    /// has no file in the package tree; null for a file-backed module.
    generated_source: ?[]const u8,
    /// Whether the module links the C standard library, by its own setting
    /// (`.link_libc = true`, `linkSystemLibrary("c", .{})`) or through a C
    /// library it links (`linkLibrary`).
    link_libc: bool,
    /// As `link_libc`, for the C++ standard library.
    link_libcpp: bool,
    imports: []const Import,
    /// The module's vendored C sources.
    csrcs: []const CSource,
    /// The module's own include directories.
    include_dirs: []const IncludeDir,
    /// The non-libc system libraries the module links (`linkSystemLibrary`),
    /// each of which the importer requires to be mapped to a `cc_library`.
    system_libs: []const []const u8,
    /// Human-readable descriptions of constructs the importer cannot represent
    /// (assembly, prebuilt objects, generated config headers, linked compile
    /// steps, path options, ...).
    unsupported: []const []const u8,
};

/// If `lazy_path` is the generated output of a `b.addOptions()` step, return
/// that step. Other paths return null.
fn optionsStep(builder: *Build, lazy_path: ?LazyPath) ?*Build.Step.Options {
    const generated = switch (lazy_path orelse return null) {
        .generated => |generated| generated,
        else => return null,
    };
    if (generated.up != 0 or generated.sub_path.len != 0) return null;
    const step = builder.graph.generated_files.items[@backingInt(generated.index)];
    if (step.tag != .options) return null;
    return @fieldParentPtr("step", step);
}

/// The source a `b.addOptions()` step generates at `lazy_path`, or null for
/// other paths. It is fully determined once `build` has run, so the importer,
/// which cannot run build steps, materializes it as a static file.
fn generatedOptionsSource(builder: *Build, lazy_path: ?LazyPath) ?[]const u8 {
    const options = optionsStep(builder, lazy_path) orelse return null;
    return options.contents.items;
}

/// The C fields of a `Module`.
const CInfo = struct {
    csrcs: []const CSource,
    include_dirs: []const IncludeDir,
    system_libs: []const []const u8,
    unsupported: []const []const u8,
    link_libc: bool,
    link_libcpp: bool,
};

const CAccum = struct {
    csrcs: std.StringArrayHashMapUnmanaged(CSource) = .empty,
    include_dirs: std.StringArrayHashMapUnmanaged(IncludeDir) = .empty,
    system_libs: std.StringArrayHashMapUnmanaged(void) = .empty,
    unsupported: std.StringArrayHashMapUnmanaged(void) = .empty,
    link_libc: bool = false,
    link_libcpp: bool = false,
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

fn appendUniqueCSource(arena: Allocator, csrcs: *std.StringArrayHashMapUnmanaged(CSource), source: CSource) !void {
    var c = source;
    c.flags = try nonEmptyFlags(arena, source.flags);
    var key: std.ArrayList(u8) = .empty;
    try key.appendSlice(arena, c.package);
    try key.append(arena, 0);
    try key.appendSlice(arena, c.path);
    try key.append(arena, 0);
    try key.appendSlice(arena, c.language orelse "");
    for (c.flags) |flag| {
        try key.append(arena, 0);
        try key.appendSlice(arena, flag);
    }
    try csrcs.put(arena, key.items, c);
}
fn appendIncludeDir(
    arena: Allocator,
    include_dirs: *std.StringArrayHashMapUnmanaged(IncludeDir),
    unsupported: *std.StringArrayHashMapUnmanaged(void),
    kind: []const u8,
    lazy_path: LazyPath,
) !void {
    const resolved_path = resolvePath(arena, lazy_path) catch |err| return reportPath(arena, unsupported, lazy_path, err);
    if (resolved_path) |resolved| {
        try appendUniqueIncludeDir(arena, include_dirs, .{ .kind = kind, .package = resolved.package, .path = resolved.sub_path });
    } else {
        try unsupported.put(arena, "an include path with a generated location", {});
    }
}

fn appendUniqueIncludeDir(arena: Allocator, include_dirs: *std.StringArrayHashMapUnmanaged(IncludeDir), dir: IncludeDir) !void {
    const key = try std.fmt.allocPrint(arena, "{s}\x00{s}\x00{s}", .{ dir.kind, dir.package, dir.path });
    try include_dirs.put(arena, key, dir);
}

/// Accumulate `module`'s C into `acc`, recursing into the C libraries it links
/// (`linkLibrary`, `addObject`): a package compiles vendored C as such a
/// library and links it into its Zig module.
fn collectCInto(arena: Allocator, acc: *CAccum, module: *Build.Module) !void {
    if (module.link_libc == true) acc.link_libc = true;
    if (module.link_libcpp == true) acc.link_libcpp = true;

    for (module.link_objects.items) |link_object| switch (link_object) {
        .c_source_file => |c| {
            const resolved_path = resolvePath(arena, c.file) catch |err| {
                try reportPath(arena, &acc.unsupported, c.file, err);
                continue;
            };
            if (resolved_path) |resolved| {
                try appendUniqueCSource(arena, &acc.csrcs, .{ .package = resolved.package, .path = resolved.sub_path, .flags = c.flags, .language = languageName(c.language) });
            } else {
                try acc.unsupported.put(arena, "a C source file with a generated path", {});
            }
        },
        .c_source_files => |c| {
            const resolved_path = resolvePath(arena, c.root) catch |err| {
                try reportPath(arena, &acc.unsupported, c.root, err);
                continue;
            };
            if (resolved_path) |resolved| {
                for (c.files) |file| {
                    const path = try normalizePath(arena, try joinPath(arena, resolved.sub_path, file));
                    try appendUniqueCSource(arena, &acc.csrcs, .{ .package = resolved.package, .path = path, .flags = c.flags, .language = languageName(c.language) });
                }
            } else {
                try acc.unsupported.put(arena, "C source files with a generated root", {});
            }
        },
        .system_lib => |lib| try acc.system_libs.put(arena, lib.name, {}),
        .static_path => try acc.unsupported.put(arena, "a precompiled object or static library (`addObjectFile`)", {}),
        .assembly_file => try acc.unsupported.put(arena, "an assembly source file", {}),
        .win32_resource_file => try acc.unsupported.put(arena, "a Win32 resource file", {}),
        .other_step => |compile| {
            if (compile.root_module.root_source_file != null) {
                try acc.unsupported.put(arena, "a linked compile step with its own Zig root source (`linkLibrary` of a Zig library)", {});
            } else {
                try collectCInto(arena, acc, compile.root_module);
            }
        },
    };

    for (module.include_dirs.items) |include_dir| switch (include_dir) {
        .path => |lp| try appendIncludeDir(arena, &acc.include_dirs, &acc.unsupported, "path", lp),
        .path_system => |lp| try appendIncludeDir(arena, &acc.include_dirs, &acc.unsupported, "path_system", lp),
        .path_after => |lp| try appendIncludeDir(arena, &acc.include_dirs, &acc.unsupported, "path_after", lp),
        .embed_path => try acc.unsupported.put(arena, "an embed include path (`addEmbedPath`)", {}),
        .framework_path, .framework_path_system => try acc.unsupported.put(arena, "a framework include path", {}),
        .config_header_step => try acc.unsupported.put(arena, "a generated config header (`addConfigHeader`)", {}),
        // `linkLibrary` pairs this with a `.other_step` link object above, which
        // folds the linked library's own include directories; nothing to add.
        .other_step => {},
    };
}

/// Collect `module`'s C information; `root_source_error` is how `resolvePath`
/// rejected its root source, if it did.
fn collectC(arena: Allocator, builder: *Build, module: *Build.Module, root_source_error: ?ResolvePathError) !CInfo {
    var acc: CAccum = .{};
    if (root_source_error) |err| try reportPath(arena, &acc.unsupported, module.root_source_file.?, err);
    try collectCInto(arena, &acc, module);
    // A path option enters the options source only when the step runs.
    if (optionsStep(builder, module.root_source_file)) |options| {
        if (options.files.items.len + options.directories.items.len + options.untracked_paths.items.len > 0) {
            try acc.unsupported.put(arena, "a path option (`addOptionPath`, `addOptionPathDirectory`, or `addOptionPathUntracked`)", {});
        }
    }
    return .{
        .csrcs = acc.csrcs.values(),
        .include_dirs = acc.include_dirs.values(),
        .system_libs = acc.system_libs.keys(),
        .unsupported = acc.unsupported.keys(),
        .link_libc = acc.link_libc,
        .link_libcpp = acc.link_libcpp,
    };
}

/// Extract the public module graph seeded by the modules registered via
/// `b.addModule`, as configuration-independent `Module` records.
pub fn collectModules(arena: Allocator, builder: *Build) ![]const Module {
    var set: ModuleSet = .empty;
    for (builder.modules.values()) |module| try collect(arena, &set, module);
    var names = try nameModules(arena, &set);

    var result: std.ArrayList(Module) = .empty;
    for (set.keys()) |module| {
        var root_source_error: ?ResolvePathError = null;
        const root_source = lazyPathString(arena, module.root_source_file) catch |err| switch (err) {
            error.AbsolutePath => |e| rejected: {
                root_source_error = e;
                break :rejected null;
            },
            error.OutOfMemory => |e| return e,
        };
        const generated_source = generatedOptionsSource(builder, module.root_source_file);
        // A module with neither a Zig root source nor a generated source is a
        // pure C-library carrier (`b.addLibrary` over C sources only); it is
        // never a `zig_library` and reaches the graph only by being linked, so
        // it is not emitted here: its C folds into the linking module. So is a
        // module rooted in another step's output (e.g. aro's `generateDef`); a
        // dep on it is undeclared, harmless while only a build.zig imports it.
        if (root_source == null and root_source_error == null and generated_source == null) continue;

        var imports: std.ArrayList(Import) = .empty;
        for (module.import_table.keys(), module.import_table.values()) |import_name, imported| {
            try imports.append(arena, .{
                .name = import_name,
                .module = names.get(imported).?,
                .package = imported.owner.pkg_hash,
            });
        }
        const c = try collectC(arena, builder, module, root_source_error);
        try result.append(arena, .{
            .name = names.get(module).?,
            .package = module.owner.pkg_hash,
            .root_source = root_source,
            .generated_source = generated_source,
            .link_libc = c.link_libc,
            .link_libcpp = c.link_libcpp,
            .imports = imports.items,
            .csrcs = c.csrcs,
            .include_dirs = c.include_dirs,
            .system_libs = c.system_libs,
            .unsupported = c.unsupported,
        });
    }
    return result.items;
}

/// Write a module's fields into an already-open JSON object. Fields with a
/// default value (`link_libc` false, empty C lists) are omitted.
fn writeModuleFields(json: *std.json.Stringify, module: Module) !void {
    try json.objectField("name");
    try json.write(module.name);
    try json.objectField("package");
    try json.write(module.package);
    try json.objectField("root_source");
    try json.write(module.root_source);
    if (module.generated_source) |generated| {
        try json.objectField("generated_source");
        try json.write(generated);
    }
    if (module.link_libc) {
        try json.objectField("link_libc");
        try json.write(true);
    }
    if (module.link_libcpp) {
        try json.objectField("link_libcpp");
        try json.write(true);
    }
    if (module.csrcs.len > 0) {
        try json.objectField("csrcs");
        try writeCSources(json, module.csrcs);
    }
    if (module.include_dirs.len > 0) {
        try json.objectField("include_dirs");
        try writeIncludeDirs(json, module.include_dirs);
    }
    if (module.system_libs.len > 0) {
        try json.objectField("system_libs");
        try json.write(module.system_libs);
    }
    if (module.unsupported.len > 0) {
        try json.objectField("unsupported");
        try json.write(module.unsupported);
    }
    try json.objectField("imports");
    try json.write(module.imports);
}

pub fn writeModule(json: *std.json.Stringify, module: Module) !void {
    try json.beginObject();
    try writeModuleFields(json, module);
    try json.endObject();
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
    const modules = try collectModules(arena, builder);
    try json.beginArray();
    for (modules) |module| try writeModule(json, module);
    try json.endArray();
}

/// A package configured under one named build configuration.
pub const Cell = struct {
    /// Empty for the unnamed default configuration.
    name: []const u8,
    modules: []const Module,
};

/// A configuration-dependent module field, merged across cells into a
/// `select()` when its value varies.
const Field = enum { root_source, generated_source, link_libc, link_libcpp, imports, csrcs, include_dirs, system_libs, unsupported };

fn eqlOptStr(a: ?[]const u8, b: ?[]const u8) bool {
    if (a == null or b == null) return (a == null) == (b == null);
    return mem.eql(u8, a.?, b.?);
}

fn eqlStrList(a: []const []const u8, b: []const []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| if (!mem.eql(u8, x, y)) return false;
    return true;
}

fn eqlImports(a: []const Import, b: []const Import) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (!mem.eql(u8, x.name, y.name) or !mem.eql(u8, x.module, y.module) or !mem.eql(u8, x.package, y.package)) return false;
    }
    return true;
}

fn eqlCSources(a: []const CSource, b: []const CSource) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (!mem.eql(u8, x.package, y.package) or !mem.eql(u8, x.path, y.path) or !eqlStrList(x.flags, y.flags) or !eqlOptStr(x.language, y.language)) return false;
    }
    return true;
}

fn eqlIncludeDirs(a: []const IncludeDir, b: []const IncludeDir) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| if (!mem.eql(u8, x.kind, y.kind) or !mem.eql(u8, x.package, y.package) or !mem.eql(u8, x.path, y.path)) return false;
    return true;
}

/// Omits an empty `package`, which marks an in-package path.
fn writeCSources(json: *std.json.Stringify, csrcs: []const CSource) !void {
    try json.beginArray();
    for (csrcs) |c| {
        try json.beginObject();
        if (c.package.len > 0) {
            try json.objectField("package");
            try json.write(c.package);
        }
        try json.objectField("path");
        try json.write(c.path);
        try json.objectField("flags");
        try json.write(c.flags);
        try json.objectField("language");
        try json.write(c.language);
        try json.endObject();
    }
    try json.endArray();
}

fn writeIncludeDirs(json: *std.json.Stringify, include_dirs: []const IncludeDir) !void {
    try json.beginArray();
    for (include_dirs) |d| {
        try json.beginObject();
        try json.objectField("kind");
        try json.write(d.kind);
        if (d.package.len > 0) {
            try json.objectField("package");
            try json.write(d.package);
        }
        try json.objectField("path");
        try json.write(d.path);
        try json.endObject();
    }
    try json.endArray();
}

fn fieldEqual(field: Field, a: Module, b: Module) bool {
    return switch (field) {
        .root_source => eqlOptStr(a.root_source, b.root_source),
        .generated_source => eqlOptStr(a.generated_source, b.generated_source),
        .link_libc => a.link_libc == b.link_libc,
        .link_libcpp => a.link_libcpp == b.link_libcpp,
        .imports => eqlImports(a.imports, b.imports),
        .csrcs => eqlCSources(a.csrcs, b.csrcs),
        .include_dirs => eqlIncludeDirs(a.include_dirs, b.include_dirs),
        .system_libs => eqlStrList(a.system_libs, b.system_libs),
        .unsupported => eqlStrList(a.unsupported, b.unsupported),
    };
}

fn writeField(json: *std.json.Stringify, field: Field, module: Module) !void {
    switch (field) {
        .root_source => try json.write(module.root_source),
        .generated_source => try json.write(module.generated_source),
        .link_libc => try json.write(module.link_libc),
        .link_libcpp => try json.write(module.link_libcpp),
        .imports => try json.write(module.imports),
        .csrcs => try writeCSources(json, module.csrcs),
        .include_dirs => try writeIncludeDirs(json, module.include_dirs),
        .system_libs => try json.write(module.system_libs),
        .unsupported => try json.write(module.unsupported),
    }
}

pub const MergeError = error{ CellModuleMismatch, EmptyMatrix };

/// The configuration matrix merged into per-module field-variance information.
pub const Merged = struct {
    /// In order; `cells[0]` is the fallback.
    cells: []const Cell,
    /// `varying[i]` holds the fields of module `i` that differ across `cells`.
    varying: []const std.EnumSet(Field),
};

/// Merge the cells' module graphs, which must expose the same modules in the
/// same order, into per-module field variance.
pub fn merge(arena: Allocator, cells: []const Cell) (Allocator.Error ||
    MergeError)!Merged {
    if (cells.len == 0) return error.EmptyMatrix;
    const fallback = cells[0].modules;
    for (cells) |cell| {
        if (cell.modules.len != fallback.len) return error.CellModuleMismatch;
        for (cell.modules, fallback) |m, fb| {
            if (!mem.eql(u8, m.name, fb.name) or !mem.eql(u8, m.package, fb.package)) return error.CellModuleMismatch;
        }
    }

    const varying = try arena.alloc(std.EnumSet(Field), fallback.len);
    for (fallback, 0..) |fb, mi| {
        var set: std.EnumSet(Field) = .{};
        for (std.enums.values(Field)) |field| {
            for (cells[1..]) |cell| {
                if (!fieldEqual(field, fb, cell.modules[mi])) {
                    set.insert(field);
                    break;
                }
            }
        }
        varying[mi] = set;
    }
    return .{ .cells = cells, .varying = varying };
}

/// Render a merged matrix as `{"cells": [names], "modules": [...]}`. Every
/// module carries the fallback cell's (`cells[0]`) fields; a field that varies
/// adds a `"select": {"<field>": {"<cell>": <value>}}` overlay with that field's
/// value in every cell.
pub fn writeMerged(writer: *std.Io.Writer, merged: Merged) !void {
    var json: std.json.Stringify = .{ .writer = writer };
    const cells = merged.cells;
    const fallback = cells[0].modules;

    try json.beginObject();
    try json.objectField("cells");
    try json.beginArray();
    for (cells) |cell| try json.write(cell.name);
    try json.endArray();
    try json.objectField("modules");
    try json.beginArray();
    for (fallback, 0..) |fb, mi| {
        try json.beginObject();
        try writeModuleFields(&json, fb);

        const varying = merged.varying[mi];
        if (varying.count() > 0) {
            try json.objectField("select");
            try json.beginObject();
            for (std.enums.values(Field)) |field| {
                if (!varying.contains(field)) continue;
                try json.objectField(@tagName(field));
                try json.beginObject();
                for (cells) |cell| {
                    try json.objectField(cell.name);
                    try writeField(&json, field, cell.modules[mi]);
                }
                try json.endObject();
            }
            try json.endObject();
        }
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

test "folds a linked C library's sources into the linking module" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const build_root = try std.fmt.allocPrint(arena, ".zig-cache/tmp/{s}", .{tmp.sub_path});

    const b = try createBuilder(arena, std.testing.io, .{ .array_hash_map = .empty, .allocator = arena }, "unused-zig", build_root, &.{});

    // A rootless carrier module built into a static library, then linked into a
    // Zig module — the vendored-C-library shape.
    const carrier = b.addModule("carrier", .{ .target = b.graph.host, .link_libc = true });
    carrier.addCSourceFile(.{ .file = b.path("c/impl.c"), .flags = &.{"-DSCALE=3"} });
    carrier.addIncludePath(b.path("c"));
    const lib = b.addLibrary(.{ .name = "carrier", .linkage = .static, .root_module = carrier });

    const consumer = b.addModule("consumer", .{ .root_source_file = b.path("src/consumer.zig") });
    consumer.linkLibrary(lib);

    var out: std.Io.Writer.Allocating = .init(arena);
    try emit(arena, &out.writer, b);

    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, arena, out.written(), .{});
    const modules = parsed.object.get("modules").?.array.items;

    // The rootless carrier is not emitted; only the linking module is.
    try std.testing.expectEqual(1, modules.len);
    const entry = modules[0].object;
    try std.testing.expectEqualStrings("consumer", entry.get("name").?.string);

    // The carrier's C source, include dir, and libc linkage fold into it.
    const csrcs = entry.get("csrcs").?.array.items;
    try std.testing.expectEqual(1, csrcs.len);
    try std.testing.expectEqualStrings("c/impl.c", csrcs[0].object.get("path").?.string);
    try std.testing.expectEqualStrings("-DSCALE=3", csrcs[0].object.get("flags").?.array.items[0].string);
    const incs = entry.get("include_dirs").?.array.items;
    try std.testing.expectEqual(1, incs.len);
    try std.testing.expectEqualStrings("c", incs[0].object.get("path").?.string);
    try std.testing.expectEqual(true, entry.get("link_libc").?.bool);
    try std.testing.expectEqual(null, entry.get("unsupported"));
}

test "collapses a system library the linking module reaches through two C libraries" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const build_root = try std.fmt.allocPrint(arena, ".zig-cache/tmp/{s}", .{tmp.sub_path});

    const b = try createBuilder(arena, std.testing.io, .{ .array_hash_map = .empty, .allocator = arena }, "unused-zig", build_root, &.{});

    const one = b.addModule("one", .{ .target = b.graph.host });
    one.addCSourceFile(.{ .file = b.path("src/one.c") });
    one.linkSystemLibrary("z", .{});
    const two = b.addModule("two", .{ .target = b.graph.host });
    two.addCSourceFile(.{ .file = b.path("src/two.c") });
    two.linkSystemLibrary("z", .{});

    const consumer = b.addModule("consumer", .{ .root_source_file = b.path("src/consumer.zig") });
    consumer.linkLibrary(b.addLibrary(.{ .name = "one", .linkage = .static, .root_module = one }));
    consumer.linkLibrary(b.addLibrary(.{ .name = "two", .linkage = .static, .root_module = two }));

    var out: std.Io.Writer.Allocating = .init(arena);
    try emit(arena, &out.writer, b);

    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, arena, out.written(), .{});
    const entry = parsed.object.get("modules").?.array.items[0].object;
    const system_libs = entry.get("system_libs").?.array.items;
    try std.testing.expectEqual(1, system_libs.len);
    try std.testing.expectEqualStrings("z", system_libs[0].string);
}

test "collapses a C source shared by a module and the C library it links" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const build_root = try std.fmt.allocPrint(arena, ".zig-cache/tmp/{s}", .{tmp.sub_path});

    const b = try createBuilder(arena, std.testing.io, .{ .array_hash_map = .empty, .allocator = arena }, "unused-zig", build_root, &.{});

    const carrier = b.addModule("carrier", .{ .target = b.graph.host });
    carrier.addCSourceFile(.{ .file = b.path("src/impl.c") });
    const lib = b.addLibrary(.{ .name = "carrier", .linkage = .static, .root_module = carrier });

    const consumer = b.addModule("consumer", .{ .root_source_file = b.path("src/consumer.zig") });
    consumer.addCSourceFile(.{ .file = b.path("src/impl.c") });
    consumer.linkLibrary(lib);

    var out: std.Io.Writer.Allocating = .init(arena);
    try emit(arena, &out.writer, b);

    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, arena, out.written(), .{});
    const entry = parsed.object.get("modules").?.array.items[0].object;
    const csrcs = entry.get("csrcs").?.array.items;
    try std.testing.expectEqual(1, csrcs.len);
    try std.testing.expectEqualStrings("src/impl.c", csrcs[0].object.get("path").?.string);
}

test "collapses an include dir shared by a module and the C library it links" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const build_root = try std.fmt.allocPrint(arena, ".zig-cache/tmp/{s}", .{tmp.sub_path});

    const b = try createBuilder(arena, std.testing.io, .{ .array_hash_map = .empty, .allocator = arena }, "unused-zig", build_root, &.{});

    // The vendored-C-library shape where the linking module and the library it
    // links both add the same include directory (`src`).
    const carrier = b.addModule("carrier", .{ .target = b.graph.host });
    carrier.addCSourceFile(.{ .file = b.path("src/impl.c") });
    carrier.addIncludePath(b.path("src"));
    const lib = b.addLibrary(.{ .name = "carrier", .linkage = .static, .root_module = carrier });

    const consumer = b.addModule("consumer", .{ .root_source_file = b.path("src/consumer.zig") });
    consumer.addIncludePath(b.path("src"));
    consumer.linkLibrary(lib);

    var out: std.Io.Writer.Allocating = .init(arena);
    try emit(arena, &out.writer, b);

    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, arena, out.written(), .{});
    const entry = parsed.object.get("modules").?.array.items[0].object;
    const incs = entry.get("include_dirs").?.array.items;
    try std.testing.expectEqual(1, incs.len);
    try std.testing.expectEqualStrings("src", incs[0].object.get("path").?.string);
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

test "rejects linking a library with its own Zig root source" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const build_root = try std.fmt.allocPrint(arena, ".zig-cache/tmp/{s}", .{tmp.sub_path});

    const b = try createBuilder(arena, std.testing.io, .{ .array_hash_map = .empty, .allocator = arena }, "unused-zig", build_root, &.{});

    const zig_lib_mod = b.addModule("ziglib", .{ .root_source_file = b.path("src/ziglib.zig"), .target = b.graph.host });
    const lib = b.addLibrary(.{ .name = "ziglib", .linkage = .static, .root_module = zig_lib_mod });

    const consumer = b.addModule("consumer", .{ .root_source_file = b.path("src/consumer.zig") });
    consumer.linkLibrary(lib);

    var out: std.Io.Writer.Allocating = .init(arena);
    try emit(arena, &out.writer, b);

    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, arena, out.written(), .{});
    const modules = parsed.object.get("modules").?.array.items;
    // `ziglib` has a Zig root, so it is emitted as its own module; the consumer
    // reports the unsupported Zig-library link.
    const consumer_entry = for (modules) |m| {
        if (std.mem.eql(u8, m.object.get("name").?.string, "consumer")) break m.object;
    } else unreachable;
    const unsupported = consumer_entry.get("unsupported").?.array.items;
    try std.testing.expectEqual(1, unsupported.len);
    try std.testing.expect(std.mem.indexOf(u8, unsupported[0].string, "Zig root source") != null);
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

test "reports path options of a generated option module as unsupported" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const build_root = try std.fmt.allocPrint(arena, ".zig-cache/tmp/{s}", .{tmp.sub_path});

    const b = try createBuilder(arena, std.testing.io, .{ .array_hash_map = .empty, .allocator = arena }, "unused-zig", build_root, &.{});

    const plain = b.addOptions();
    plain.addOption(bool, "flag", true);
    _ = b.addModule("plain", .{ .root_source_file = plain.getOutput() });

    const with_path = b.addOptions();
    with_path.addOptionPath("data", b.path("data.txt"));
    _ = b.addModule("with_path", .{ .root_source_file = with_path.getOutput() });

    var out: std.Io.Writer.Allocating = .init(arena);
    try emit(arena, &out.writer, b);

    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, arena, out.written(), .{});
    const modules = parsed.object.get("modules").?.array.items;

    try std.testing.expectEqualStrings("plain", modules[0].object.get("name").?.string);
    try std.testing.expectEqual(null, modules[0].object.get("unsupported"));

    try std.testing.expectEqualStrings("with_path", modules[1].object.get("name").?.string);
    const unsupported = modules[1].object.get("unsupported").?.array.items;
    try std.testing.expectEqual(1, unsupported.len);
    try std.testing.expect(std.mem.indexOf(u8, unsupported[0].string, "addOptionPath") != null);
}

fn testModule(name: []const u8, root: []const u8, link_libc: bool, imports: []const Import) Module {
    return .{
        .name = name,
        .package = "",
        .root_source = root,
        .generated_source = null,
        .link_libc = link_libc,
        .link_libcpp = false,
        .imports = imports,
        .csrcs = &.{},
        .include_dirs = &.{},
        .system_libs = &.{},
        .unsupported = &.{},
    };
}

test "merge marks only the fields that vary across cells" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const imports: []const Import = &.{.{ .name = "a", .module = "a", .package = "h" }};
    // `root_source` and `imports` match; `link_libc` differs between cells.
    const dbg = testModule("foo", "src/foo.zig", false, imports);
    const rel = testModule("foo", "src/foo.zig", true, imports);
    const cells: []const Cell = &.{
        .{ .name = "dbg", .modules = &.{dbg} },
        .{ .name = "rel", .modules = &.{rel} },
    };

    const merged = try merge(arena, cells);
    const varying = merged.varying[0];
    try std.testing.expectEqual(@as(usize, 1), varying.count());
    try std.testing.expect(varying.contains(.link_libc));
    try std.testing.expect(!varying.contains(.root_source));
    try std.testing.expect(!varying.contains(.imports));
}

test "a single cell has no varying fields" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const only = testModule("foo", "src/foo.zig", false, &.{});
    const cells: []const Cell = &.{.{ .name = "", .modules = &.{only} }};

    const merged = try merge(arena, cells);
    try std.testing.expectEqual(@as(usize, 0), merged.varying[0].count());
}

test "merge rejects cells whose module sets differ" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const foo = testModule("foo", "src/foo.zig", false, &.{});
    const bar = testModule("bar", "src/bar.zig", false, &.{});
    const cells: []const Cell = &.{
        .{ .name = "dbg", .modules = &.{foo} },
        .{ .name = "rel", .modules = &.{bar} },
    };

    try std.testing.expectError(error.CellModuleMismatch, merge(arena, cells));
}

test "writeMerged renders a select overlay for the varying fields" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const imports: []const Import = &.{.{ .name = "a", .module = "a", .package = "h" }};
    const dbg = testModule("foo", "src/foo.zig", false, imports);
    const rel = testModule("foo", "src/foo.zig", true, imports);
    const cells: []const Cell = &.{
        .{ .name = "dbg", .modules = &.{dbg} },
        .{ .name = "rel", .modules = &.{rel} },
    };

    const merged = try merge(arena, cells);
    var out: std.Io.Writer.Allocating = .init(arena);
    try writeMerged(&out.writer, merged);

    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, arena, out.written(), .{});
    try std.testing.expectEqualStrings("dbg", parsed.object.get("cells").?.array.items[0].string);

    const module = parsed.object.get("modules").?.array.items[0].object;
    try std.testing.expectEqualStrings("foo", module.get("name").?.string);
    try std.testing.expectEqualStrings("src/foo.zig", module.get("root_source").?.string);

    const select = module.get("select").?.object;
    // Only `link_libc` varies; the constant fields stay out of the overlay.
    try std.testing.expectEqual(@as(usize, 1), select.count());
    const libc = select.get("link_libc").?.object;
    try std.testing.expectEqual(false, libc.get("dbg").?.bool);
    try std.testing.expectEqual(true, libc.get("rel").?.bool);
}
