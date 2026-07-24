//! Walk a configured `std.Build` instance's module import graph and emit the
//! public module set as JSON, for translation into Bazel `zig_library`
//! targets.
//!
//! The emitted JSON has the shape:
//!
//!     {"modules": [{"name": ..., "package": <hash>, "root_source": ...,
//!         "generated_source": ...,  // present only for `b.addOptions()` modules
//!         "link_libc": true, "link_libcpp": true,  // each present only when set
//!         "csrcs": [...], "include_dirs": [...], "system_libs": [...],
//!         "weak_system_libs": [...], "unsupported": [...],  // each only when non-empty
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
/// Maps a module to the Zig hash of the package it belongs to.
const PackageMap = std.AutoHashMapUnmanaged(*Build.Module, []const u8);

/// Collect `module` and every module it transitively imports, deduplicated by
/// identity. `user` is the package using `module`. A translate-c package
/// `Translator`'s module is created by that package's builder yet translates the
/// user's header, so it is recorded in `adopted` as belonging to its first
/// user; its imports serve only the package's own `translate-c` output and are
/// not collected.
fn collect(arena: Allocator, builder: *Build, modules: *ModuleSet, adopted: *PackageMap, user: []const u8, module: *Build.Module) !void {
    const gop = try modules.getOrPut(arena, module);
    if (gop.found_existing) return;
    if (translatorRun(builder, module.root_source_file) != null) {
        try adopted.put(arena, module, user);
        return;
    }
    for (module.import_table.values()) |imported| try collect(arena, builder, modules, adopted, module.owner.pkg_hash, imported);
}

fn modulePackage(adopted: *const PackageMap, module: *Build.Module) []const u8 {
    return adopted.get(module) orelse module.owner.pkg_hash;
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

/// A module whose root source is produced by `b.addTranslateC` or a translate-c
/// package `Translator`: its Zig code is the translation of a C header,
/// generated at build time and absent from the package tree. The header and the
/// search path needed to translate it are emitted so the importer can render a
/// `zig_c_library`, which runs `translate-c` under the build toolchain. The
/// translation's include directories, `link_libc`, and linked libraries fold
/// into the module's ordinary fields.
pub const TranslateC = struct {
    /// The package owning the translated header, as for `CSource.package`.
    header_package: []const u8,
    /// The translated header's path within `header_package`, or within its
    /// `b.addWriteFiles()` directory for a `generated_header`.
    header: []const u8,
    /// The contents of a header written at configure time
    /// (`b.addWriteFiles().add`), which has no file in the package tree; null
    /// for a file-backed header.
    generated_header: ?[]const u8 = null,
};

/// A package module's extracted, configuration-independent shape.
pub const Module = struct {
    /// The module's name in its owning package (see `nameModules`).
    name: []const u8,
    /// The Zig hash of the owning package, or the empty string for the package
    /// being configured. A `Translator` module is owned by the package using it
    /// (see `collect`).
    package: []const u8,
    /// The root source file within the owning package; null for a generated
    /// root.
    root_source: ?[]const u8,
    /// The source of a module whose root is produced by `b.addOptions()`, which
    /// has no file in the package tree; null for a file-backed module.
    generated_source: ?[]const u8,
    /// Present when the module's root is a translated C header; null otherwise.
    /// Mutually exclusive with a file-backed `root_source`.
    translate_c: ?TranslateC,
    /// A translated-C module's raw C flags (`addCFlags`, `defineCMacro`) in
    /// order, less the include paths folded into its `include_dirs`.
    translate_c_flags: []const []const u8,
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
    /// each of which the importer requires to be mapped to a `cc_library`
    /// unless it is in `weak_system_libs`.
    system_libs: []const []const u8,
    /// The subset of `system_libs` linked only weakly (`.weak = true` at every
    /// occurrence), which the importer may omit when unmapped.
    weak_system_libs: []const []const u8,
    /// Human-readable descriptions of constructs the importer cannot represent
    /// (assembly, prebuilt objects, generated config headers, linked compile
    /// steps, path options, ...).
    unsupported: []const []const u8,
};

/// The step generating the file at `lazy_path`; null for a source path or a
/// path relative to a generated file.
fn generatedStep(builder: *Build, lazy_path: ?LazyPath) ?*Build.Step {
    const generated = switch (lazy_path orelse return null) {
        .generated => |generated| generated,
        else => return null,
    };
    if (generated.up != 0 or generated.sub_path.len != 0) return null;
    return builder.graph.generated_files.items[@backingInt(generated.index)];
}

/// If `lazy_path` is the generated output of a `b.addOptions()` step, return
/// that step. Other paths return null.
fn optionsStep(builder: *Build, lazy_path: ?LazyPath) ?*Build.Step.Options {
    const step = generatedStep(builder, lazy_path) orelse return null;
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

/// The contents a `b.addWriteFiles()` step writes at `lazy_path` (`add`), or
/// null for other paths. They are fully determined once `build` has run, so the
/// importer materializes them as a static file.
fn writtenFileContents(builder: *Build, lazy_path: ?LazyPath) ?[]const u8 {
    const generated = switch (lazy_path orelse return null) {
        .generated => |generated| generated,
        else => return null,
    };
    if (generated.up != 0) return null;
    const step = builder.graph.generated_files.items[@backingInt(generated.index)];
    if (step.tag != .write_file) return null;
    const write_file: *Build.Step.WriteFile = @fieldParentPtr("step", step);
    const wc = &builder.graph.wip_configuration;
    var contents: ?[]const u8 = null;
    // A later write to the same path overwrites an earlier one.
    for (write_file.embeds.items) |embed| {
        if (!mem.eql(u8, wc.stringSlice(embed.sub_path), generated.sub_path)) continue;
        contents = wc.string_bytes.items[embed.contents.index..][0..embed.contents.len];
    }
    return contents;
}

fn hasParentSegment(path: []const u8) bool {
    var it = mem.splitScalar(u8, path, '/');
    while (it.next()) |segment| if (mem.eql(u8, segment, "..")) return true;
    return false;
}

/// If `lazy_path` is the generated output of a `b.addTranslateC` step, return
/// that step; the module it roots is a translated-C module. Other paths return
/// null.
fn translateCStep(builder: *Build, lazy_path: ?LazyPath) ?*Build.Step.TranslateC {
    const step = generatedStep(builder, lazy_path) orelse return null;
    if (step.tag != .translate_c) return null;
    return @fieldParentPtr("step", step);
}

/// The Zig hash prefix of the translate-c package
/// (https://codeberg.org/ziglang/translate-c).
const translator_package_prefix = "translate_c-";
/// The name of the translate-c package's executable.
const translator_exe_name = "translate-c";

/// If `lazy_path` is the output of a translate-c package `Translator` (a run of
/// the package's own executable), return that run step. Other paths return null.
fn translatorRun(builder: *Build, lazy_path: ?LazyPath) ?*Build.Step.Run {
    const step = generatedStep(builder, lazy_path) orelse return null;
    const run = step.cast(Build.Step.Run) orelse return null;
    const exe = run.producer orelse return null;
    if (!mem.eql(u8, exe.name, translator_exe_name)) return null;
    if (!mem.startsWith(u8, exe.step.owner.pkg_hash, translator_package_prefix)) return null;
    return run;
}

/// What generates a translated-C module's root.
const Translation = union(enum) {
    /// `b.addTranslateC`.
    step: *Build.Step.TranslateC,
    /// A translate-c package `Translator`.
    translator: *Build.Step.Run,
};

fn translation(builder: *Build, lazy_path: ?LazyPath) ?Translation {
    if (translateCStep(builder, lazy_path)) |step| return .{ .step = step };
    if (translatorRun(builder, lazy_path)) |run| return .{ .translator = run };
    return null;
}

/// Fold a `b.addTranslateC` step's include directories into `acc` and return the
/// translate-c marker and C flags. The step's `link_libc` and any
/// `linkSystemLibrary` are mirrored onto the created module and captured by
/// `collectCInto`; only its include directories, root header, and C flags live
/// solely on the step.
fn foldTranslateC(arena: Allocator, builder: *Build, acc: *CAccum, translate: *Build.Step.TranslateC) !struct { TranslateC, []const []const u8 } {
    for (translate.include_dirs.items) |include_dir| try foldIncludeDir(arena, builder, acc, include_dir);

    const argv = try arena.alloc([]const u8, translate.cc_argv.items.len);
    for (argv, translate.cc_argv.items) |*arg, string| arg.* = builder.graph.wip_configuration.stringSlice(string);
    const c_flags = try foldTranslateCFlags(arena, acc, try packageRoots(arena, builder), try nonEmptyFlags(arena, argv));
    return .{ try translatedHeader(arena, builder, acc, translate.source), c_flags };
}

fn translatedHeader(arena: Allocator, builder: *Build, acc: *CAccum, source: ?LazyPath) !TranslateC {
    if (writtenFileContents(builder, source)) |contents| {
        const sub_path = source.?.generated.sub_path;
        // The importer writes the header beneath a directory of its own, as a
        // Starlark string.
        if (std.fs.path.isAbsolute(sub_path) or hasParentSegment(sub_path)) {
            try reportFlag(arena, acc, "a translate-c root header written at configure time outside its directory (`{s}`)", sub_path);
            return .{ .header_package = "", .header = "" };
        }
        if (!std.unicode.utf8ValidateSlice(contents)) {
            try reportFlag(arena, acc, "a translate-c root header written at configure time with non-UTF-8 contents (`{s}`)", sub_path);
            return .{ .header_package = "", .header = "" };
        }
        return .{
            .header_package = "",
            .header = try normalizePath(arena, sub_path),
            .generated_header = contents,
        };
    }
    const resolved_header = resolvePath(arena, source) catch |err| {
        try reportPath(arena, &acc.unsupported, source.?, err);
        return .{ .header_package = "", .header = "" };
    };
    const header = resolved_header orelse {
        try acc.unsupported.put(arena, "a translate-c root header with a generated path", {});
        return .{ .header_package = "", .header = "" };
    };
    return .{ .header_package = header.package, .header = header.sub_path };
}

/// `Translator` arguments before the `--` separator that `translate-c` under
/// the build toolchain reproduces: the toolchain sets the target and optimize
/// mode, the module carries libc and system library linkage, and the
/// toolchain's output is self-contained, needing none of the package's helper
/// modules whether or not `-fmodule-libs` asks for them.
const translator_default_args = [_][]const u8{ "-lc", "-fmodule-libs", "-fno-module-libs" };
const translator_default_prefixes = [_][]const u8{ "-O=", "--target=", "-mcpu=", "-l=" };

/// `Translator` arguments after the `--` separator that only drive the
/// package's dependency file and warnings.
const translator_ignored_args = [_][]const u8{ "-MD", "-MV", "-MF", "-w" };

/// The `Translator` flag that precedes the Aro resource directory, which the
/// build toolchain's `translate-c` provides itself.
const translator_resource_dir_flag = "-resource-dir";

fn isTranslatorDefault(arg: []const u8) bool {
    for (translator_default_args) |default| {
        if (mem.eql(u8, arg, default)) return true;
    }
    for (translator_default_prefixes) |prefix| {
        if (mem.startsWith(u8, arg, prefix)) return true;
    }
    return false;
}

/// Fold a translate-c package `Translator`'s run arguments into `acc` and return
/// the translate-c marker and C flags, as `foldTranslateC` does. The run is
/// `translate-c <options> -- <C flags> <header> <C flags>`, where a directory
/// is a separate argument after its flag. Options other than the defaults have
/// no counterpart under the build toolchain and are recorded as `unsupported`.
///
/// `zig translate-c` default-initializes struct fields with no option to
/// disable it, while the package's executable does not by default, so the
/// translation accepts a superset of the Zig code the native build accepts.
fn foldTranslator(arena: Allocator, builder: *Build, acc: *CAccum, run: *Build.Step.Run) !struct { TranslateC, []const []const u8 } {
    const argv = run.argv.items;
    var c_argv: std.ArrayList([]const u8) = .empty;
    var header: ?LazyPath = null;
    var separated = false;
    // `argv[0]` is the executable.
    var i: usize = 1;
    while (i < argv.len) : (i += 1) switch (argv[i]) {
        .output_file, .output_file_dep => {},
        .bytes => |arg| {
            if (!separated) {
                if (mem.eql(u8, arg, "--")) {
                    separated = true;
                } else if (!isTranslatorDefault(arg)) {
                    try reportFlag(arena, acc, "a translate-c package option (`{s}`)", arg);
                }
                continue;
            }
            if (i + 1 < argv.len and argv[i + 1] == .decorated_directory) {
                i += 1;
                try foldTranslatorDirectory(arena, builder, acc, arg, argv[i].decorated_directory);
                continue;
            }
            for (translator_ignored_args) |ignored| {
                if (mem.eql(u8, arg, ignored)) break;
            } else try c_argv.append(arena, arg);
        },
        .lazy_path => |path| {
            if (separated and header == null and path.prefix.len == 0 and path.suffix.len == 0) {
                header = path.lazy_path;
            } else {
                try reportFlag(arena, acc, "a translate-c package file option (`{s}`)", path.prefix);
            }
        },
        .decorated_directory => |dir| {
            if (separated or dir.lazy_path != .relative or dir.lazy_path.relative.base != .zig_lib) {
                try reportFlag(arena, acc, "a translate-c package directory option (`{s}`)", dir.prefix);
            }
        },
        else => try acc.unsupported.put(arena, "a translate-c package argument the importer cannot represent", {}),
    };

    const c_flags = try foldTranslateCFlags(arena, acc, try packageRoots(arena, builder), try nonEmptyFlags(arena, c_argv.items));
    return .{ try translatedHeader(arena, builder, acc, header), c_flags };
}

/// Fold a `Translator` directory argument and the `flag` preceding it.
fn foldTranslatorDirectory(arena: Allocator, builder: *Build, acc: *CAccum, flag: []const u8, dir: Build.Step.Run.DecoratedLazyPath) !void {
    if (dir.prefix.len == 0 and dir.suffix.len == 0) {
        if (mem.eql(u8, flag, translator_resource_dir_flag)) return;
        for (include_path_flags) |entry| {
            const include_flag, const kind = entry;
            if (!mem.eql(u8, flag, include_flag)) continue;
            return appendIncludeDir(arena, builder, &acc.include_dirs, &acc.unsupported, kind, dir.lazy_path);
        }
    }
    try reportFlag(arena, acc, "a translate-c package directory option (`{s}`)", flag);
}

/// A package's absolute root directory.
const PackageRoot = struct {
    package: []const u8,
    path: []const u8,
};

/// The roots of the configured package and of every dependency it instantiated.
fn packageRoots(arena: Allocator, builder: *Build) ![]const PackageRoot {
    var roots: std.ArrayList(PackageRoot) = .empty;
    try roots.append(arena, .{ .package = builder.pkg_hash, .path = try builder.root.root_dir.join(arena, &.{builder.root.sub_path}) });
    for (builder.graph.dependency_cache.values()) |dep| {
        const root = dep.builder.root;
        try roots.append(arena, .{ .package = dep.builder.pkg_hash, .path = try root.root_dir.join(arena, &.{root.sub_path}) });
    }
    return roots.items;
}

/// Resolve an absolute `path` to the package with the innermost root containing
/// it; null when no package root contains it.
fn resolveAbsolutePath(roots: []const PackageRoot, path: []const u8) ?ResolvedPath {
    var best: ?ResolvedPath = null;
    var best_len: usize = 0;
    for (roots) |root| {
        if (!mem.startsWith(u8, path, root.path)) continue;
        const rest = path[root.path.len..];
        if (rest.len != 0 and rest[0] != '/') continue;
        if (best != null and root.path.len <= best_len) continue;
        best = .{ .package = root.package, .sub_path = mem.trimStart(u8, rest, "/") };
        best_len = root.path.len;
    }
    return best;
}

/// The value of `flag` at `argv[i.*]`, either joined (`-Ipath`, `--flag=value`)
/// or as the following argument (`-I path`), in which case `i.*` advances past
/// it. Null when `argv[i.*]` is not `flag`.
fn flagValue(argv: []const []const u8, i: *usize, flag: []const u8) error{MissingFlagValue}!?[]const u8 {
    const arg = argv[i.*];
    if (!mem.startsWith(u8, arg, flag)) return null;
    if (arg.len > flag.len) {
        const joined = arg[flag.len..];
        if (mem.startsWith(u8, flag, "--")) {
            return if (joined[0] == '=') joined[1..] else null;
        }
        return joined;
    }
    if (i.* + 1 >= argv.len) return error.MissingFlagValue;
    i.* += 1;
    return argv[i.*];
}

/// Include-path flags and the `IncludeDir.kind` each folds into. A quote include
/// folds as `path`, since `translate_c.bzl` passes quote includes as `-I`.
const include_path_flags = [_]struct { []const u8, []const u8 }{
    .{ "-isystem", "path_system" },
    .{ "-idirafter", "path_after" },
    .{ "-iquote", "path" },
    .{ "-I", "path" },
};

/// Flags taking a value that `translate-c` under the build toolchain cannot
/// honor: the toolchain sets target, CPU, sysroot, and library search paths;
/// framework and embed directories have no `cc_library` counterpart; and a
/// forced include names a file outside the translated header's library.
const unsupported_value_flags = [_][]const u8{
    "-target",
    "--target",
    "-mcpu",
    "--sysroot",
    "-isysroot",
    "-iframework",
    "-F",
    "-framework",
    "--embed-dir",
    "-L",
    "-l",
    "-include",
    "-imacros",
};

/// Value-less flag prefixes unsupported for the same reason.
const unsupported_flag_prefixes = [_][]const u8{ "-O", "-Wl," };

/// Passed-through flags that may take their value as the following argument,
/// which then belongs to the flag (`-D -O3` defines `-O3`).
const separate_value_flags = [_][]const u8{ "-D", "-U", "-x", "-Xclang" };

/// Whether a passed-through argument names a location on the configuring
/// machine, which generated targets cannot reference: an absolute path, alone
/// or after a `=`, or any path under a package root.
fn namesMachinePath(roots: []const PackageRoot, arg: []const u8) bool {
    const value = if (mem.indexOfScalar(u8, arg, '=')) |eq| arg[eq + 1 ..] else arg;
    if (std.fs.path.isAbsolute(arg) or std.fs.path.isAbsolute(value)) return true;
    for (roots) |root| {
        if (mem.indexOf(u8, arg, root.path) != null) return true;
    }
    return false;
}

fn reportFlag(arena: Allocator, acc: *CAccum, comptime format: []const u8, text: []const u8) !void {
    try acc.unsupported.put(arena, try std.fmt.allocPrint(arena, format, .{text}), {});
}

/// Split a translate step's raw C flags: include paths under a package root fold
/// into `acc.include_dirs`, flags the importer cannot represent are recorded as
/// `unsupported`, and the remaining flags are returned in order.
fn foldTranslateCFlags(arena: Allocator, acc: *CAccum, roots: []const PackageRoot, argv: []const []const u8) ![]const []const u8 {
    const missing_value = "a translate-c C flag missing its argument (`{s}`)";
    var c_flags: std.ArrayList([]const u8) = .empty;
    var i: usize = 0;
    args: while (i < argv.len) : (i += 1) {
        const start = i;
        const arg = argv[i];
        if (mem.eql(u8, arg, "-cflags")) {
            try acc.unsupported.put(arena, "a translate-c `-cflags … --` group", {});
            while (i < argv.len and !mem.eql(u8, argv[i], "--")) i += 1;
            continue;
        }
        for (include_path_flags) |entry| {
            const flag, const kind = entry;
            const path = (flagValue(argv, &i, flag) catch {
                try reportFlag(arena, acc, missing_value, arg);
                continue :args;
            }) orelse continue;
            const text = try mem.join(arena, " ", argv[start .. i + 1]);
            if (!std.fs.path.isAbsolute(path)) {
                try reportFlag(arena, acc, "a relative translate-c include path (`{s}`)", text);
            } else if (resolveAbsolutePath(roots, try std.fs.path.resolveAllocPosix(arena, &.{path}))) |resolved| {
                try appendUniqueIncludeDir(arena, &acc.include_dirs, .{ .kind = kind, .package = resolved.package, .path = try normalizePath(arena, resolved.sub_path) });
            } else {
                try reportFlag(arena, acc, "a translate-c include path outside the package tree (`{s}`)", text);
            }
            continue :args;
        }
        for (unsupported_value_flags) |flag| {
            _ = (flagValue(argv, &i, flag) catch {
                try reportFlag(arena, acc, missing_value, arg);
                continue :args;
            }) orelse continue;
            try reportFlag(arena, acc, "a translate-c C flag (`{s}`)", try mem.join(arena, " ", argv[start .. i + 1]));
            continue :args;
        }
        for (unsupported_flag_prefixes) |prefix| {
            if (!mem.startsWith(u8, arg, prefix)) continue;
            try reportFlag(arena, acc, "a translate-c C flag (`{s}`)", arg);
            continue :args;
        }
        for (separate_value_flags) |flag| {
            if (!mem.eql(u8, arg, flag)) continue;
            if (i + 1 >= argv.len) {
                try reportFlag(arena, acc, missing_value, arg);
                continue :args;
            }
            i += 1;
            break;
        }
        const flag = argv[start .. i + 1];
        for (flag) |part| {
            if (!namesMachinePath(roots, part)) continue;
            try reportFlag(arena, acc, "a translate-c C flag naming an absolute path (`{s}`)", try mem.join(arena, " ", flag));
            continue :args;
        }
        try c_flags.appendSlice(arena, flag);
    }
    return c_flags.items;
}

/// The C fields of a `Module`.
const CInfo = struct {
    csrcs: []const CSource,
    include_dirs: []const IncludeDir,
    system_libs: []const []const u8,
    weak_system_libs: []const []const u8,
    unsupported: []const []const u8,
    link_libc: bool,
    link_libcpp: bool,
};

const CAccum = struct {
    csrcs: std.StringArrayHashMapUnmanaged(CSource) = .empty,
    include_dirs: std.StringArrayHashMapUnmanaged(IncludeDir) = .empty,
    // Value is whether the name is so far linked only weakly.
    system_libs: std.StringArrayHashMapUnmanaged(bool) = .empty,
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

/// The source directory that, placed on the include path, makes a header
/// installed as `dest` resolve to the source file at `source`. A header
/// installed under its own name from a directory (`<dir>/<dest>` -> `<dest>`) is
/// found by adding `<dir>`; one installed at the tree root from the package root
/// (`<dest>` -> `<dest>`) by adding the root. A rename or re-nesting the include
/// path cannot express returns null.
fn includeDirForInstall(source: []const u8, dest: []const u8) ?[]const u8 {
    if (mem.eql(u8, source, dest)) return "";
    if (source.len > dest.len + 1 and
        source[source.len - dest.len - 1] == '/' and
        mem.eql(u8, source[source.len - dest.len ..], dest))
    {
        return source[0 .. source.len - dest.len - 1];
    }
    return null;
}

/// The source directories that reproduce, on an include path, the emitted
/// include tree (`getEmittedIncludeTree`) at `lazy_path`; null when `lazy_path`
/// is not one or its layout cannot be reproduced (a renamed or re-nested
/// header, a generated or absolute source).
fn emittedIncludeDirs(arena: Allocator, builder: *Build, lazy_path: LazyPath) !?[]const ResolvedPath {
    const step = generatedStep(builder, lazy_path) orelse return null;
    if (step.tag != .write_file) return null;
    const write_file: *Build.Step.WriteFile = @fieldParentPtr("step", step);

    var dirs: std.StringArrayHashMapUnmanaged(ResolvedPath) = .empty;
    for (write_file.copies.items) |copy| {
        const source = (resolvePath(arena, copy.src_file) catch |err| switch (err) {
            error.AbsolutePath => return null,
            else => |e| return e,
        }) orelse return null;
        const dest = builder.graph.wip_configuration.stringSlice(copy.sub_path);
        const dir = includeDirForInstall(source.sub_path, dest) orelse return null;
        try dirs.put(arena, try resolvedPathKey(arena, source.package, dir), .{ .package = source.package, .sub_path = dir });
    }
    for (write_file.directories.items) |directory| {
        const source = (resolvePath(arena, directory.src_path) catch |err| switch (err) {
            error.AbsolutePath => return null,
            else => |e| return e,
        }) orelse return null;
        // Only a directory installed at the tree root maps to a plain include
        // path (its own source directory).
        if (builder.graph.wip_configuration.stringSlice(directory.sub_path).len != 0) return null;
        try dirs.put(arena, try resolvedPathKey(arena, source.package, source.sub_path), .{ .package = source.package, .sub_path = source.sub_path });
    }
    if (dirs.values().len == 0) return null;
    return dirs.values();
}

fn resolvedPathKey(arena: Allocator, package: []const u8, sub_path: []const u8) ![]const u8 {
    return std.fmt.allocPrint(arena, "{s}\x00{s}", .{ package, sub_path });
}

fn appendIncludeDir(
    arena: Allocator,
    builder: *Build,
    include_dirs: *std.StringArrayHashMapUnmanaged(IncludeDir),
    unsupported: *std.StringArrayHashMapUnmanaged(void),
    kind: []const u8,
    lazy_path: LazyPath,
) !void {
    const resolved_path = resolvePath(arena, lazy_path) catch |err| return reportPath(arena, unsupported, lazy_path, err);
    if (resolved_path) |resolved| {
        try appendUniqueIncludeDir(arena, include_dirs, .{ .kind = kind, .package = resolved.package, .path = resolved.sub_path });
    } else if (try emittedIncludeDirs(arena, builder, lazy_path)) |dirs| {
        for (dirs) |dir| try appendUniqueIncludeDir(arena, include_dirs, .{ .kind = kind, .package = dir.package, .path = dir.sub_path });
    } else {
        try unsupported.put(arena, "an include path with a generated location", {});
    }
}

fn appendUniqueIncludeDir(arena: Allocator, include_dirs: *std.StringArrayHashMapUnmanaged(IncludeDir), dir: IncludeDir) !void {
    const key = try std.fmt.allocPrint(arena, "{s}\x00{s}\x00{s}", .{ dir.kind, dir.package, dir.path });
    try include_dirs.put(arena, key, dir);
}

/// Fold one include directory into `acc`, recording constructs the importer
/// cannot represent as `unsupported`.
fn foldIncludeDir(arena: Allocator, builder: *Build, acc: *CAccum, include_dir: Build.Module.IncludeDir) !void {
    switch (include_dir) {
        .path => |lp| try appendIncludeDir(arena, builder, &acc.include_dirs, &acc.unsupported, "path", lp),
        .path_system => |lp| try appendIncludeDir(arena, builder, &acc.include_dirs, &acc.unsupported, "path_system", lp),
        .path_after => |lp| try appendIncludeDir(arena, builder, &acc.include_dirs, &acc.unsupported, "path_after", lp),
        .embed_path => try acc.unsupported.put(arena, "an embed include path (`addEmbedPath`)", {}),
        .framework_path, .framework_path_system => try acc.unsupported.put(arena, "a framework include path", {}),
        .config_header_step => try acc.unsupported.put(arena, "a generated config header (`addConfigHeader`)", {}),
        // `linkLibrary` pairs this with a `.other_step` link object above, which
        // folds the linked library's own include directories; nothing to add.
        .other_step => {},
    }
}

/// Accumulate `module`'s C into `acc`, recursing into the C libraries it links
/// (`linkLibrary`, `addObject`): a package compiles vendored C as such a
/// library and links it into its Zig module.
fn collectCInto(arena: Allocator, builder: *Build, acc: *CAccum, module: *Build.Module) !void {
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
        // The injected `cc_library` determines linkage under the hermetic
        // CcInfo model, so only `name` and `weak` are captured; `needed`,
        // `use_pkg_config`, `preferred_link_mode`, and `search_strategy` are
        // moot. A name stays weak only while every occurrence is weak.
        .system_lib => |lib| {
            const gop = try acc.system_libs.getOrPut(arena, lib.name);
            gop.value_ptr.* = lib.weak and (!gop.found_existing or gop.value_ptr.*);
        },
        .static_path => try acc.unsupported.put(arena, "a precompiled object or static library (`addObjectFile`)", {}),
        .assembly_file => try acc.unsupported.put(arena, "an assembly source file", {}),
        .win32_resource_file => try acc.unsupported.put(arena, "a Win32 resource file", {}),
        .other_step => |compile| {
            if (compile.root_module.root_source_file != null) {
                try acc.unsupported.put(arena, "a linked compile step with its own Zig root source (`linkLibrary` of a Zig library)", {});
            } else {
                try collectCInto(arena, builder, acc, compile.root_module);
            }
        },
    };

    for (module.include_dirs.items) |include_dir| try foldIncludeDir(arena, builder, acc, include_dir);
}

/// A module's collected C information.
const Collected = struct {
    cinfo: CInfo,
    /// Null unless the module's root is a translation.
    translate_c: ?TranslateC,
    translate_c_flags: []const []const u8,
};

/// Collect `module`'s C information; `translate` is the translation rooting it,
/// if any, and `root_source_error` is how `resolvePath` rejected its root
/// source, if it did.
fn collectC(
    arena: Allocator,
    builder: *Build,
    module: *Build.Module,
    translate: ?Translation,
    root_source_error: ?ResolvePathError,
) !Collected {
    var acc: CAccum = .{};
    if (root_source_error) |err| try reportPath(arena, &acc.unsupported, module.root_source_file.?, err);
    try collectCInto(arena, builder, &acc, module);
    // A path option enters the options source only when the step runs.
    if (optionsStep(builder, module.root_source_file)) |options| {
        if (options.files.items.len + options.directories.items.len + options.untracked_paths.items.len > 0) {
            try acc.unsupported.put(arena, "a path option (`addOptionPath`, `addOptionPathDirectory`, or `addOptionPathUntracked`)", {});
        }
    }
    var translate_c: ?TranslateC = null;
    var translate_c_flags: []const []const u8 = &.{};
    if (translate) |t| translate_c, translate_c_flags = switch (t) {
        .step => |step| try foldTranslateC(arena, builder, &acc, step),
        .translator => |run| try foldTranslator(arena, builder, &acc, run),
    };

    var weak_system_libs: std.ArrayList([]const u8) = .empty;
    for (acc.system_libs.keys(), acc.system_libs.values()) |name, weak| {
        if (weak) try weak_system_libs.append(arena, name);
    }
    return .{
        .cinfo = .{
            .csrcs = acc.csrcs.values(),
            .include_dirs = acc.include_dirs.values(),
            .system_libs = acc.system_libs.keys(),
            .weak_system_libs = weak_system_libs.items,
            .unsupported = acc.unsupported.keys(),
            .link_libc = acc.link_libc,
            .link_libcpp = acc.link_libcpp,
        },
        .translate_c = translate_c,
        .translate_c_flags = translate_c_flags,
    };
}

/// Extract the public module graph seeded by the modules registered via
/// `b.addModule`, as configuration-independent `Module` records.
pub fn collectModules(arena: Allocator, builder: *Build) ![]const Module {
    var set: ModuleSet = .empty;
    var adopted: PackageMap = .empty;
    for (builder.modules.values()) |module| try collect(arena, builder, &set, &adopted, builder.pkg_hash, module);
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
        const translate = translation(builder, module.root_source_file);
        // A module with neither a Zig root source nor a generated one (options or
        // a translated-C header) is a pure C-library carrier (`b.addLibrary` over
        // C sources only); it is never a `zig_library` and reaches the graph only
        // by being linked, so it is not emitted here: its C folds into the
        // linking module. So is a module rooted in another step's output (e.g.
        // aro's `generateDef`); a dep on it is undeclared, harmless while only a
        // build.zig imports it.
        if (root_source == null and root_source_error == null and generated_source == null and translate == null) continue;

        var imports: std.ArrayList(Import) = .empty;
        if (!adopted.contains(module)) for (module.import_table.keys(), module.import_table.values()) |import_name, imported| {
            try imports.append(arena, .{
                .name = import_name,
                .module = names.get(imported).?,
                .package = modulePackage(&adopted, imported),
            });
        };
        const collected = try collectC(arena, builder, module, translate, root_source_error);
        const c = collected.cinfo;
        try result.append(arena, .{
            .name = names.get(module).?,
            .package = modulePackage(&adopted, module),
            .root_source = root_source,
            .generated_source = generated_source,
            .translate_c = collected.translate_c,
            .translate_c_flags = collected.translate_c_flags,
            .link_libc = c.link_libc,
            .link_libcpp = c.link_libcpp,
            .imports = imports.items,
            .csrcs = c.csrcs,
            .include_dirs = c.include_dirs,
            .system_libs = c.system_libs,
            .weak_system_libs = c.weak_system_libs,
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
    if (module.translate_c) |translate| {
        try json.objectField("translate_c");
        try writeTranslateC(json, translate);
    }
    if (module.translate_c_flags.len > 0) {
        try json.objectField("translate_c_flags");
        try json.write(module.translate_c_flags);
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
    if (module.weak_system_libs.len > 0) {
        try json.objectField("weak_system_libs");
        try json.write(module.weak_system_libs);
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
const Field = enum { root_source, generated_source, translate_c, translate_c_flags, link_libc, link_libcpp, imports, csrcs, include_dirs, system_libs, weak_system_libs, unsupported };

fn eqlOptStr(a: ?[]const u8, b: ?[]const u8) bool {
    if (a == null or b == null) return (a == null) == (b == null);
    return mem.eql(u8, a.?, b.?);
}

fn eqlStrList(a: []const []const u8, b: []const []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| if (!mem.eql(u8, x, y)) return false;
    return true;
}

fn eqlTranslateC(a: ?TranslateC, b: ?TranslateC) bool {
    if (a == null or b == null) return (a == null) == (b == null);
    return mem.eql(u8, a.?.header_package, b.?.header_package) and
        mem.eql(u8, a.?.header, b.?.header) and
        eqlOptStr(a.?.generated_header, b.?.generated_header);
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

/// Omits an empty `package`, as `writeCSources` does.
fn writeTranslateC(json: *std.json.Stringify, translate: TranslateC) !void {
    try json.beginObject();
    if (translate.header_package.len > 0) {
        try json.objectField("package");
        try json.write(translate.header_package);
    }
    try json.objectField("header");
    try json.write(translate.header);
    if (translate.generated_header) |contents| {
        try json.objectField("generated_header");
        try json.write(contents);
    }
    try json.endObject();
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
        .translate_c => eqlTranslateC(a.translate_c, b.translate_c),
        .translate_c_flags => eqlStrList(a.translate_c_flags, b.translate_c_flags),
        .link_libc => a.link_libc == b.link_libc,
        .link_libcpp => a.link_libcpp == b.link_libcpp,
        .imports => eqlImports(a.imports, b.imports),
        .csrcs => eqlCSources(a.csrcs, b.csrcs),
        .include_dirs => eqlIncludeDirs(a.include_dirs, b.include_dirs),
        .system_libs => eqlStrList(a.system_libs, b.system_libs),
        .weak_system_libs => eqlStrList(a.weak_system_libs, b.weak_system_libs),
        .unsupported => eqlStrList(a.unsupported, b.unsupported),
    };
}

fn writeField(json: *std.json.Stringify, field: Field, module: Module) !void {
    switch (field) {
        .root_source => try json.write(module.root_source),
        .generated_source => try json.write(module.generated_source),
        .translate_c => if (module.translate_c) |translate| try writeTranslateC(json, translate) else try json.write(null),
        .translate_c_flags => try json.write(module.translate_c_flags),
        .link_libc => try json.write(module.link_libc),
        .link_libcpp => try json.write(module.link_libcpp),
        .imports => try json.write(module.imports),
        .csrcs => try writeCSources(json, module.csrcs),
        .include_dirs => try writeIncludeDirs(json, module.include_dirs),
        .system_libs => try json.write(module.system_libs),
        .weak_system_libs => try json.write(module.weak_system_libs),
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
    try std.testing.expectEqual(null, module.get("weak_system_libs"));
}

test "distinguishes weak system libraries; a strict link wins over a weak one" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const build_root = try std.fmt.allocPrint(arena, ".zig-cache/tmp/{s}", .{tmp.sub_path});

    const b = try createBuilder(arena, std.testing.io, .{ .array_hash_map = .empty, .allocator = arena }, "unused-zig", build_root, &.{});

    const mod = b.addModule("mod", .{ .root_source_file = b.path("src/mod.zig"), .target = b.graph.host });
    mod.linkSystemLibrary("strict", .{});
    mod.linkSystemLibrary("weak", .{ .weak = true });
    // Linked both weakly and strictly: the strict link makes it strict.
    mod.linkSystemLibrary("mixed", .{ .weak = true });
    mod.linkSystemLibrary("mixed", .{});

    var out: std.Io.Writer.Allocating = .init(arena);
    try emit(arena, &out.writer, b);

    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, arena, out.written(), .{});
    const module = parsed.object.get("modules").?.array.items[0].object;

    const system_libs = module.get("system_libs").?.array.items;
    try std.testing.expectEqual(3, system_libs.len);
    try std.testing.expectEqualStrings("strict", system_libs[0].string);
    try std.testing.expectEqualStrings("weak", system_libs[1].string);
    try std.testing.expectEqualStrings("mixed", system_libs[2].string);

    const weak_system_libs = module.get("weak_system_libs").?.array.items;
    try std.testing.expectEqual(1, weak_system_libs.len);
    try std.testing.expectEqualStrings("weak", weak_system_libs[0].string);
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

test "emits a translated-C module's header and include directories" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const build_root = try std.fmt.allocPrint(arena, ".zig-cache/tmp/{s}", .{tmp.sub_path});

    const b = try createBuilder(arena, std.testing.io, .{ .array_hash_map = .empty, .allocator = arena }, "unused-zig", build_root, &.{});

    const translate = b.addTranslateC(.{
        .root_source_file = b.path("c/box.h"),
        .target = b.graph.host,
        .optimize = .debug,
    });
    translate.addIncludePath(b.path("c"));
    translate.defineCMacro("BOX_ENABLED", null);
    const box_c = translate.addModule("boxc");

    const box = b.addModule("box", .{ .root_source_file = b.path("src/box.zig") });
    box.addImport("c", box_c);

    var out: std.Io.Writer.Allocating = .init(arena);
    try emit(arena, &out.writer, b);

    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, arena, out.written(), .{});
    const modules = parsed.object.get("modules").?.array.items;

    const boxc_entry = for (modules) |m| {
        if (std.mem.eql(u8, m.object.get("name").?.string, "boxc")) break m.object;
    } else unreachable;

    // The translated-C module has no file-backed root source; its header and the
    // include directory needed to translate it are emitted.
    try std.testing.expectEqual(std.json.Value.null, boxc_entry.get("root_source").?);
    const translate_c = boxc_entry.get("translate_c").?.object;
    try std.testing.expectEqualStrings("c/box.h", translate_c.get("header").?.string);
    const c_flags = boxc_entry.get("translate_c_flags").?.array.items;
    try std.testing.expectEqual(2, c_flags.len);
    // `defineCMacro(name, null)` defaults the value to 1.
    try std.testing.expectEqualStrings("-D", c_flags[0].string);
    try std.testing.expectEqualStrings("BOX_ENABLED=1", c_flags[1].string);
    try std.testing.expectEqual(null, translate_c.get("package"));

    const incs = boxc_entry.get("include_dirs").?.array.items;
    try std.testing.expectEqual(1, incs.len);
    try std.testing.expectEqualStrings("path", incs[0].object.get("kind").?.string);
    try std.testing.expectEqualStrings("c", incs[0].object.get("path").?.string);
    // `b.addTranslateC` links libc by default.
    try std.testing.expectEqual(true, boxc_entry.get("link_libc").?.bool);
    try std.testing.expectEqual(null, boxc_entry.get("unsupported"));
}

/// Configure a translated-C module `boxc` from `c/box.h` with `cc_argv` as its
/// raw C flags in a package rooted at an absolute `build_root`, and return its
/// emitted entry.
fn emitTranslateCFlags(arena: Allocator, build_root: []const u8, cc_argv: []const []const u8) !std.json.ObjectMap {
    const b = try createBuilder(arena, std.testing.io, .{ .array_hash_map = .empty, .allocator = arena }, "unused-zig", build_root, &.{});

    const translate = b.addTranslateC(.{
        .root_source_file = b.path("c/box.h"),
        .target = b.graph.host,
        .optimize = .debug,
    });
    translate.addCFlags(cc_argv);
    _ = translate.addModule("boxc");

    var out: std.Io.Writer.Allocating = .init(arena);
    try emit(arena, &out.writer, b);

    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, arena, out.written(), .{});
    for (parsed.object.get("modules").?.array.items) |m| {
        if (std.mem.eql(u8, m.object.get("name").?.string, "boxc")) return m.object;
    }
    return error.TestUnexpectedResult;
}

fn absoluteTmpRoot(arena: Allocator, tmp: std.testing.TmpDir) ![]const u8 {
    return std.Io.Dir.cwd().realPathFileAlloc(std.testing.io, try std.fmt.allocPrint(arena, ".zig-cache/tmp/{s}", .{tmp.sub_path}), arena);
}

test "keeps a translated-C module's C flags in order" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const entry = try emitTranslateCFlags(arena, try absoluteTmpRoot(arena, tmp), &.{ "-DBOX_SIZE=4", "-U", "BOX_DEBUG", "-std=c99" });

    const c_flags = entry.get("translate_c_flags").?.array.items;
    try std.testing.expectEqual(4, c_flags.len);
    try std.testing.expectEqualStrings("-DBOX_SIZE=4", c_flags[0].string);
    try std.testing.expectEqualStrings("-U", c_flags[1].string);
    try std.testing.expectEqualStrings("BOX_DEBUG", c_flags[2].string);
    try std.testing.expectEqualStrings("-std=c99", c_flags[3].string);
    try std.testing.expectEqual(null, entry.get("unsupported"));
}

test "drops a translated-C module's empty C flags" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const entry = try emitTranslateCFlags(arena, try absoluteTmpRoot(arena, tmp), &.{ "", "-DBOX_SIZE=4", "" });

    const c_flags = entry.get("translate_c_flags").?.array.items;
    try std.testing.expectEqual(1, c_flags.len);
    try std.testing.expectEqualStrings("-DBOX_SIZE=4", c_flags[0].string);
    try std.testing.expectEqual(null, entry.get("unsupported"));
}

test "folds a translated-C module's include path flags under the package root" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try absoluteTmpRoot(arena, tmp);

    const entry = try emitTranslateCFlags(arena, root, &.{
        try std.fmt.allocPrint(arena, "-I{s}/c/.", .{root}),
        "-isystem",
        try std.fmt.allocPrint(arena, "{s}/sys", .{root}),
        "-DBOX=1",
        "-idirafter",
        try std.fmt.allocPrint(arena, "{s}/after", .{root}),
    });

    const c_flags = entry.get("translate_c_flags").?.array.items;
    try std.testing.expectEqual(1, c_flags.len);
    try std.testing.expectEqualStrings("-DBOX=1", c_flags[0].string);

    const incs = entry.get("include_dirs").?.array.items;
    try std.testing.expectEqual(3, incs.len);
    const expected = [_]struct { []const u8, []const u8 }{
        .{ "path", "c" },
        .{ "path_system", "sys" },
        .{ "path_after", "after" },
    };
    for (incs, expected) |inc, want| {
        try std.testing.expectEqualStrings(want[0], inc.object.get("kind").?.string);
        try std.testing.expectEqualStrings(want[1], inc.object.get("path").?.string);
        try std.testing.expectEqual(null, inc.object.get("package"));
    }
    try std.testing.expectEqual(null, entry.get("unsupported"));
}

test "reports a translated-C module's unsupported C flags" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const entry = try emitTranslateCFlags(arena, try absoluteTmpRoot(arena, tmp), &.{
        "-Iinclude",
        "-isystem",
        "/outside/include",
        "-cflags",
        "-DINSIDE=1",
        "--",
        "-target",
        "x86_64-linux",
        "-mcpu=native",
        "-O2",
        "-lm",
        "-L",
        "/lib",
        "-Wl,--as-needed",
        "-iframework",
        "/Frameworks",
        "--embed-dir=/embed",
        "--sysroot",
        "/sysroot",
        "-DKEPT=1",
    });

    const c_flags = entry.get("translate_c_flags").?.array.items;
    try std.testing.expectEqual(1, c_flags.len);
    try std.testing.expectEqualStrings("-DKEPT=1", c_flags[0].string);
    try std.testing.expectEqual(null, entry.get("include_dirs"));

    const unsupported = entry.get("unsupported").?.array.items;
    const expected = [_][]const u8{
        "a relative translate-c include path (`-Iinclude`)",
        "a translate-c include path outside the package tree (`-isystem /outside/include`)",
        "a translate-c `-cflags … --` group",
        "a translate-c C flag (`-target x86_64-linux`)",
        "a translate-c C flag (`-mcpu=native`)",
        "a translate-c C flag (`-O2`)",
        "a translate-c C flag (`-lm`)",
        "a translate-c C flag (`-L /lib`)",
        "a translate-c C flag (`-Wl,--as-needed`)",
        "a translate-c C flag (`-iframework /Frameworks`)",
        "a translate-c C flag (`--embed-dir=/embed`)",
        "a translate-c C flag (`--sysroot /sysroot`)",
    };
    try std.testing.expectEqual(expected.len, unsupported.len);
    for (unsupported, expected) |actual, want| try std.testing.expectEqualStrings(want, actual.string);
}

test "folds a translated-C module's quote include paths as plain include paths" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try absoluteTmpRoot(arena, tmp);

    const entry = try emitTranslateCFlags(arena, root, &.{
        "-iquote",
        try std.fmt.allocPrint(arena, "{s}/quote", .{root}),
        try std.fmt.allocPrint(arena, "-iquote{s}/joined", .{root}),
    });

    try std.testing.expectEqual(null, entry.get("translate_c_flags"));
    const incs = entry.get("include_dirs").?.array.items;
    try std.testing.expectEqual(2, incs.len);
    for (incs, [_][]const u8{ "quote", "joined" }) |inc, want| {
        try std.testing.expectEqualStrings("path", inc.object.get("kind").?.string);
        try std.testing.expectEqualStrings(want, inc.object.get("path").?.string);
    }
    try std.testing.expectEqual(null, entry.get("unsupported"));
}

test "resolves `..` in a translated-C module's include path before matching the package root" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try absoluteTmpRoot(arena, tmp);
    const escape = try std.fmt.allocPrint(arena, "-I{s}/c/../../escape", .{root});

    const entry = try emitTranslateCFlags(arena, root, &.{
        try std.fmt.allocPrint(arena, "-I{s}/c/../inc", .{root}),
        escape,
    });

    const incs = entry.get("include_dirs").?.array.items;
    try std.testing.expectEqual(1, incs.len);
    try std.testing.expectEqualStrings("inc", incs[0].object.get("path").?.string);
    const unsupported = entry.get("unsupported").?.array.items;
    try std.testing.expectEqual(1, unsupported.len);
    try std.testing.expectEqualStrings(
        try std.fmt.allocPrint(arena, "a translate-c include path outside the package tree (`{s}`)", .{escape}),
        unsupported[0].string,
    );
}

test "keeps a translated-C flag's separate value with the flag" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const argv: []const []const u8 = &.{ "-D", "-O3", "-U", "-target", "-x", "c", "-Xclang", "-fno-builtin" };
    const entry = try emitTranslateCFlags(arena, try absoluteTmpRoot(arena, tmp), argv);

    const c_flags = entry.get("translate_c_flags").?.array.items;
    try std.testing.expectEqual(argv.len, c_flags.len);
    for (c_flags, argv) |actual, want| try std.testing.expectEqualStrings(want, actual.string);
    try std.testing.expectEqual(null, entry.get("unsupported"));
}

test "reports a translated-C module's C flags naming absolute paths" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try absoluteTmpRoot(arena, tmp);
    const define = try std.fmt.allocPrint(arena, "DATA={s}/data", .{root});
    const prefix_map = try std.fmt.allocPrint(arena, "-fmacro-prefix-map={s}=.", .{root});
    const dep_file = try std.fmt.allocPrint(arena, "-Wp,-MD,{s}/box.d", .{root});

    const entry = try emitTranslateCFlags(arena, root, &.{
        "-include",
        "force.h",
        "-imacros/macros.h",
        "-DCONF=/etc/box.conf",
        "-D",
        define,
        prefix_map,
        dep_file,
        "/box/extra.h",
        "-DKEPT=1",
    });

    const c_flags = entry.get("translate_c_flags").?.array.items;
    try std.testing.expectEqual(1, c_flags.len);
    try std.testing.expectEqualStrings("-DKEPT=1", c_flags[0].string);

    const unsupported = entry.get("unsupported").?.array.items;
    const expected = [_][]const u8{
        "a translate-c C flag (`-include force.h`)",
        "a translate-c C flag (`-imacros/macros.h`)",
        "a translate-c C flag naming an absolute path (`-DCONF=/etc/box.conf`)",
        try std.fmt.allocPrint(arena, "a translate-c C flag naming an absolute path (`-D {s}`)", .{define}),
        try std.fmt.allocPrint(arena, "a translate-c C flag naming an absolute path (`{s}`)", .{prefix_map}),
        try std.fmt.allocPrint(arena, "a translate-c C flag naming an absolute path (`{s}`)", .{dep_file}),
        "a translate-c C flag naming an absolute path (`/box/extra.h`)",
    };
    try std.testing.expectEqual(expected.len, unsupported.len);
    for (unsupported, expected) |actual, want| try std.testing.expectEqualStrings(want, actual.string);
}

test "reports a translated-C flag missing its argument" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try absoluteTmpRoot(arena, tmp);

    for ([_][]const u8{ "-I", "-include", "-D" }) |flag| {
        const entry = try emitTranslateCFlags(arena, root, &.{ "-DKEPT=1", flag });

        const c_flags = entry.get("translate_c_flags").?.array.items;
        try std.testing.expectEqual(1, c_flags.len);
        try std.testing.expectEqualStrings("-DKEPT=1", c_flags[0].string);
        const unsupported = entry.get("unsupported").?.array.items;
        try std.testing.expectEqual(1, unsupported.len);
        try std.testing.expectEqualStrings(
            try std.fmt.allocPrint(arena, "a translate-c C flag missing its argument (`{s}`)", .{flag}),
            unsupported[0].string,
        );
    }
}

test "reports a translated-C module's absolute root header as unsupported" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const build_root = try std.fmt.allocPrint(arena, ".zig-cache/tmp/{s}", .{tmp.sub_path});

    const b = try createBuilder(arena, std.testing.io, .{ .array_hash_map = .empty, .allocator = arena }, "unused-zig", build_root, &.{});

    const translate = b.addTranslateC(.{
        .root_source_file = .{ .cwd_relative = "/usr/include/box.h" },
        .target = b.graph.host,
        .optimize = .debug,
    });
    _ = translate.addModule("boxc");

    var out: std.Io.Writer.Allocating = .init(arena);
    try emit(arena, &out.writer, b);

    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, arena, out.written(), .{});
    const entry = parsed.object.get("modules").?.array.items[0].object;
    try std.testing.expectEqualStrings("boxc", entry.get("name").?.string);
    const unsupported = entry.get("unsupported").?.array.items;
    try std.testing.expectEqual(1, unsupported.len);
    try std.testing.expectEqualStrings("an absolute path (`/usr/include/box.h`)", unsupported[0].string);
}

test "expands a compile step's emitted include tree to source include directories" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const build_root = try std.fmt.allocPrint(arena, ".zig-cache/tmp/{s}", .{tmp.sub_path});

    const b = try createBuilder(arena, std.testing.io, .{ .array_hash_map = .empty, .allocator = arena }, "unused-zig", build_root, &.{});

    // A C library that installs a header; its emitted include tree copies the
    // header from `include/box.h` to `box.h`.
    const carrier = b.addModule("carrier", .{ .target = b.graph.host, .link_libc = true });
    carrier.addCSourceFile(.{ .file = b.path("c/box.c") });
    const lib = b.addLibrary(.{ .name = "box", .linkage = .static, .root_module = carrier });
    lib.installHeader(b.path("include/box.h"), "box.h");

    // The translate step reaches the header through the emitted include tree,
    // which the importer maps back to the header's source directory.
    const translate = b.addTranslateC(.{
        .root_source_file = b.path("umbrella/box_all.h"),
        .target = b.graph.host,
        .optimize = .debug,
    });
    translate.addIncludePath(lib.getEmittedIncludeTree());
    const box_c = translate.addModule("boxc");

    const box = b.addModule("box", .{ .root_source_file = b.path("src/box.zig") });
    box.addImport("c", box_c);

    var out: std.Io.Writer.Allocating = .init(arena);
    try emit(arena, &out.writer, b);

    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, arena, out.written(), .{});
    const modules = parsed.object.get("modules").?.array.items;

    const boxc_entry = for (modules) |m| {
        if (std.mem.eql(u8, m.object.get("name").?.string, "boxc")) break m.object;
    } else unreachable;

    // `installHeader(include/box.h, "box.h")` resolves by adding `include` to the
    // include path.
    const incs = boxc_entry.get("include_dirs").?.array.items;
    try std.testing.expectEqual(1, incs.len);
    try std.testing.expectEqualStrings("include", incs[0].object.get("path").?.string);
    try std.testing.expectEqual(null, boxc_entry.get("unsupported"));
}

/// A stand-in for the translate-c package's builder, sharing `b`'s graph.
fn stubTranslateCPackage(b: *Build) !*Build {
    const tc = try Build.create(b.graph, b.root, &.{});
    tc.pkg_hash = translator_package_prefix ++ "2.0.0-stub";
    return tc;
}

/// The run arguments and module of translate-c 2.0.0's `Translator.initInner`
/// (build/Translator.zig) for `header` under its default options, with
/// `options` passed before the `--` separator.
fn stubTranslator(tc: *Build, header: LazyPath, options: []const []const u8) struct { *Build.Module, *Build.Step.Run } {
    const exe = tc.addExecutable(.{
        .name = translator_exe_name,
        .root_module = tc.createModule(.{ .root_source_file = tc.path("src/main.zig"), .target = tc.graph.host }),
    });
    const run = tc.addRunArtifact(exe);
    const output_file = run.addPrefixedOutputFileArg("-o=", "box.zig");
    const mod = tc.createModule(.{ .root_source_file = output_file, .target = tc.graph.host, .optimize = .debug, .link_libc = true });
    run.addArg("-lc");
    run.addPrefixedDirectoryArg("--zig-lib=", .zig_lib);
    run.addArg("-fmodule-libs");
    run.addArgs(options);
    run.addArg("--");
    run.addFileArg(header);
    run.addArgs(&.{ "-MD", "-MV", "-MF" });
    _ = run.addDepFileOutputArg("deps.d");
    mod.addImport("c_builtins", tc.addModule("c_builtins", .{ .root_source_file = tc.path("lib/c_builtins.zig") }));
    mod.addImport("helpers", tc.addModule("helpers", .{ .root_source_file = tc.path("lib/helpers.zig") }));
    run.addArg("-w");
    run.addArg("-resource-dir");
    run.addDirectoryArg(tc.path(""));
    return .{ mod, run };
}

test "emits a translate-c package translation as a module of the package using it" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const build_root = try std.fmt.allocPrint(arena, ".zig-cache/tmp/{s}", .{tmp.sub_path});

    const b = try createBuilder(arena, std.testing.io, .{ .array_hash_map = .empty, .allocator = arena }, "unused-zig", build_root, &.{});
    const box_c, const run = stubTranslator(try stubTranslateCPackage(b), b.path("c/box.h"), &.{});
    // `Translator.addIncludePath` and `Translator.defineCMacro`.
    box_c.addIncludePath(b.path("c"));
    run.addArg("-I");
    run.addDirectoryArg(b.path("c"));
    run.addArg("-DBOX_ENABLED=1");

    const box = b.addModule("box", .{ .root_source_file = b.path("src/box.zig") });
    box.addImport("c", box_c);

    var out: std.Io.Writer.Allocating = .init(arena);
    try emit(arena, &out.writer, b);

    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, arena, out.written(), .{});
    const modules = parsed.object.get("modules").?.array.items;
    // The translate-c package's own modules are not collected.
    try std.testing.expectEqual(2, modules.len);

    const box_entry = modules[0].object;
    try std.testing.expectEqualStrings("box", box_entry.get("name").?.string);
    const imports = box_entry.get("imports").?.array.items;
    try std.testing.expectEqual(1, imports.len);
    try std.testing.expectEqualStrings("c", imports[0].object.get("name").?.string);
    try std.testing.expectEqualStrings("", imports[0].object.get("package").?.string);

    const boxc_entry = modules[1].object;
    try std.testing.expectEqualStrings(imports[0].object.get("module").?.string, boxc_entry.get("name").?.string);
    try std.testing.expectEqualStrings("", boxc_entry.get("package").?.string);
    try std.testing.expectEqual(std.json.Value.null, boxc_entry.get("root_source").?);
    const translate_c = boxc_entry.get("translate_c").?.object;
    try std.testing.expectEqualStrings("c/box.h", translate_c.get("header").?.string);
    try std.testing.expectEqual(null, translate_c.get("package"));
    const c_flags = boxc_entry.get("translate_c_flags").?.array.items;
    try std.testing.expectEqual(1, c_flags.len);
    try std.testing.expectEqualStrings("-DBOX_ENABLED=1", c_flags[0].string);
    const incs = boxc_entry.get("include_dirs").?.array.items;
    try std.testing.expectEqual(1, incs.len);
    try std.testing.expectEqualStrings("c", incs[0].object.get("path").?.string);
    try std.testing.expectEqual(true, boxc_entry.get("link_libc").?.bool);
    try std.testing.expectEqual(0, boxc_entry.get("imports").?.array.items.len);
    try std.testing.expectEqual(null, boxc_entry.get("unsupported"));
}

test "folds a C library linked into a translate-c package translation" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const build_root = try std.fmt.allocPrint(arena, ".zig-cache/tmp/{s}", .{tmp.sub_path});

    const b = try createBuilder(arena, std.testing.io, .{ .array_hash_map = .empty, .allocator = arena }, "unused-zig", build_root, &.{});
    const carrier = b.createModule(.{ .target = b.graph.host, .link_libc = true });
    carrier.addCSourceFile(.{ .file = b.path("lib/box.c") });
    const lib = b.addLibrary(.{ .name = "box", .linkage = .static, .root_module = carrier });
    lib.installHeader(b.path("lib/box.h"), "box.h");

    const box_c, const run = stubTranslator(try stubTranslateCPackage(b), b.path("c/box_all.h"), &.{});
    // `Translator.linkLibrary`.
    box_c.linkLibrary(lib);
    run.addArg("-I");
    run.addDirectoryArg(lib.getEmittedIncludeTree());

    const box = b.addModule("box", .{ .root_source_file = b.path("src/box.zig") });
    box.addImport("c", box_c);

    var out: std.Io.Writer.Allocating = .init(arena);
    try emit(arena, &out.writer, b);

    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, arena, out.written(), .{});
    const boxc_entry = parsed.object.get("modules").?.array.items[1].object;
    const csrcs = boxc_entry.get("csrcs").?.array.items;
    try std.testing.expectEqual(1, csrcs.len);
    try std.testing.expectEqualStrings("lib/box.c", csrcs[0].object.get("path").?.string);
    const incs = boxc_entry.get("include_dirs").?.array.items;
    try std.testing.expectEqual(1, incs.len);
    try std.testing.expectEqualStrings("lib", incs[0].object.get("path").?.string);
    try std.testing.expectEqual(null, boxc_entry.get("unsupported"));
}

test "emits a translated header written at configure time" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const build_root = try std.fmt.allocPrint(arena, ".zig-cache/tmp/{s}", .{tmp.sub_path});

    const b = try createBuilder(arena, std.testing.io, .{ .array_hash_map = .empty, .allocator = arena }, "unused-zig", build_root, &.{});
    const wf = b.addWriteFiles();
    const wrapper = wf.add("include/./wrapper.h", "#include <box.h>\n");

    const box_c, _ = stubTranslator(try stubTranslateCPackage(b), wrapper, &.{});
    const box = b.addModule("box", .{ .root_source_file = b.path("src/box.zig") });
    box.addImport("c", box_c);
    const step_c = b.addTranslateC(.{ .root_source_file = wrapper, .target = b.graph.host, .optimize = .debug });
    _ = step_c.addModule("stepc");

    var out: std.Io.Writer.Allocating = .init(arena);
    try emit(arena, &out.writer, b);

    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, arena, out.written(), .{});
    var translated: usize = 0;
    for (parsed.object.get("modules").?.array.items) |m| {
        const translate_c = (m.object.get("translate_c") orelse continue).object;
        translated += 1;
        try std.testing.expectEqualStrings("include/wrapper.h", translate_c.get("header").?.string);
        try std.testing.expectEqualStrings("#include <box.h>\n", translate_c.get("generated_header").?.string);
        try std.testing.expectEqual(null, m.object.get("unsupported"));
    }
    try std.testing.expectEqual(2, translated);
}

test "reports a translated header written at configure time outside its directory or as non-UTF-8" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const build_root = try std.fmt.allocPrint(arena, ".zig-cache/tmp/{s}", .{tmp.sub_path});

    const b = try createBuilder(arena, std.testing.io, .{ .array_hash_map = .empty, .allocator = arena }, "unused-zig", build_root, &.{});
    const wf = b.addWriteFiles();
    const headers = [_]struct { []const u8, []const u8, []const u8 }{
        .{ "escaping", "../escaping.h", "a translate-c root header written at configure time outside its directory (`../escaping.h`)" },
        .{ "absolute", "/abs.h", "a translate-c root header written at configure time outside its directory (`/abs.h`)" },
        .{ "binary", "binary.h", "a translate-c root header written at configure time with non-UTF-8 contents (`binary.h`)" },
    };
    const contents = [_][]const u8{ "", "", "\xff\n" };
    for (headers, contents) |header, bytes| {
        const name, const sub_path, _ = header;
        const step_c = b.addTranslateC(.{ .root_source_file = wf.add(sub_path, bytes), .target = b.graph.host, .optimize = .debug });
        _ = step_c.addModule(name);
    }

    var out: std.Io.Writer.Allocating = .init(arena);
    try emit(arena, &out.writer, b);

    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, arena, out.written(), .{});
    const modules = parsed.object.get("modules").?.array.items;
    try std.testing.expectEqual(headers.len, modules.len);
    for (headers) |header| {
        const name, _, const message = header;
        const entry = for (modules) |m| {
            if (mem.eql(u8, name, m.object.get("name").?.string)) break m.object;
        } else return error.TestUnexpectedResult;
        try std.testing.expectEqual(null, entry.get("translate_c").?.object.get("generated_header"));
        const unsupported = entry.get("unsupported").?.array.items;
        try std.testing.expectEqual(1, unsupported.len);
        try std.testing.expectEqualStrings(message, unsupported[0].string);
    }
}

test "reports a translate-c package translation's non-default options" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const build_root = try std.fmt.allocPrint(arena, ".zig-cache/tmp/{s}", .{tmp.sub_path});

    const b = try createBuilder(arena, std.testing.io, .{ .array_hash_map = .empty, .allocator = arena }, "unused-zig", build_root, &.{});
    const box_c, const run = stubTranslator(try stubTranslateCPackage(b), b.path("c/box.h"), &.{ "-O=ReleaseFast", "-fno-module-libs", "-fno-default-init" });
    // `Translator.addFrameworkPath`.
    run.addArg("-F");
    run.addDirectoryArg(b.path("frameworks"));
    const box = b.addModule("box", .{ .root_source_file = b.path("src/box.zig") });
    box.addImport("c", box_c);

    var out: std.Io.Writer.Allocating = .init(arena);
    try emit(arena, &out.writer, b);

    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, arena, out.written(), .{});
    const unsupported = parsed.object.get("modules").?.array.items[1].object.get("unsupported").?.array.items;
    try std.testing.expectEqual(2, unsupported.len);
    try std.testing.expect(std.mem.indexOf(u8, unsupported[0].string, "-fno-default-init") != null);
    try std.testing.expect(std.mem.indexOf(u8, unsupported[1].string, "-F") != null);
}

fn testModule(name: []const u8, root: []const u8, link_libc: bool, imports: []const Import) Module {
    return .{
        .name = name,
        .package = "",
        .root_source = root,
        .generated_source = null,
        .translate_c = null,
        .translate_c_flags = &.{},
        .link_libc = link_libc,
        .link_libcpp = false,
        .imports = imports,
        .csrcs = &.{},
        .include_dirs = &.{},
        .system_libs = &.{},
        .weak_system_libs = &.{},
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

test "merge varies a translated-C module's flags apart from its header" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var dbg = testModule("boxc", "", true, &.{});
    dbg.root_source = null;
    dbg.translate_c = .{ .header_package = "", .header = "c/box.h" };
    dbg.translate_c_flags = &.{"-DBOX_DEBUG=1"};
    var rel = dbg;
    rel.translate_c_flags = &.{"-DBOX_DEBUG=0"};
    const cells: []const Cell = &.{
        .{ .name = "dbg", .modules = &.{dbg} },
        .{ .name = "rel", .modules = &.{rel} },
    };

    const merged = try merge(arena, cells);
    try std.testing.expectEqual(@as(usize, 1), merged.varying[0].count());
    try std.testing.expect(merged.varying[0].contains(.translate_c_flags));

    var out: std.Io.Writer.Allocating = .init(arena);
    try writeMerged(&out.writer, merged);
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, arena, out.written(), .{});
    const module = parsed.object.get("modules").?.array.items[0].object;
    try std.testing.expectEqualStrings("c/box.h", module.get("translate_c").?.object.get("header").?.string);
    const flags = module.get("select").?.object.get("translate_c_flags").?.object;
    try std.testing.expectEqualStrings("-DBOX_DEBUG=1", flags.get("dbg").?.array.items[0].string);
    try std.testing.expectEqualStrings("-DBOX_DEBUG=0", flags.get("rel").?.array.items[0].string);
}
