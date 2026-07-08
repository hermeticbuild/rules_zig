//! Configure a Zig package's `build.zig` under one or more matrix cells and
//! emit the merged public module graph as JSON on stdout (see
//! `module_graph.writeMerged`), for translation into Bazel `zig_library`
//! targets.
//!
//! Usage: configurer --zig <zig> --build-root <dir> [--system-integration NAME ...] [--config NAME [--zig-option -DNAME=VALUE ...]]...
//!
//! Each `--config NAME` starts a cell configured under the following
//! `--zig-option -DNAME=VALUE` build options (as `zig build -DNAME=VALUE`
//! would). With no `--config`, the package is configured once under a single
//! unnamed default cell.
//!
//! Each cell is configured in a child process of its own (this executable,
//! re-run with `--cell`), as `zig build` configures one configuration per
//! process: a `build.zig` may keep process-global state across `build` calls,
//! such as a step cached in a global variable, which is valid only within the
//! configuration that created it.
//!
//! If `build.zig` requests unavailable lazy dependencies, the output is
//! `{"needed_lazy_dependencies": ["<hash>", ...]}` instead, so the caller can
//! reconfigure with them available.
//!
//! Modeled on `lib/compiler/configurer.zig` of Zig 0.17.0. The package's
//! `build.zig` is provided as the `pkg` module and its dependency table as the
//! `deps` module, both wired in at compile time.
//!
//! Each `--system-integration NAME` pre-enables the named optional system
//! integration before the build runs, so the package's
//! `systemIntegrationOption(NAME)` returns true and its guarded
//! `linkSystemLibrary` calls run (surfacing as `system_libs`).

const std = @import("std");
const mem = std.mem;
const process = std.process;
const module_graph = @import("module_graph.zig");

pub const root = @import("pkg");
pub const dependencies = @import("deps");

/// A configuration matrix cell parsed from the CLI.
const Config = struct {
    /// Empty for the default cell.
    name: []const u8,
    /// The cell's `-DNAME=VALUE` build options.
    zig_options: std.ArrayList([]const u8) = .empty,
};

/// One cell's configuration, passed as JSON from the child process configuring
/// it to the parent merging the cells.
const CellResult = struct {
    /// The unavailable lazy dependencies the cell's `build.zig` requested.
    needed_lazy_dependencies: []const []const u8,
    /// Null when the cell requested lazy dependencies, leaving it incomplete.
    cell: ?module_graph.Cell,
};

pub fn main(init: process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;

    const args = try init.minimal.args.toSlice(arena);

    var zig_exe: ?[]const u8 = null;
    var build_root: ?[]const u8 = null;
    var system_integrations: std.ArrayList([]const u8) = .empty;
    var configs: std.ArrayList(Config) = .empty;
    var cell_process = false;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (mem.eql(u8, args[i], "--zig")) {
            zig_exe = nextArg(args, &i);
        } else if (mem.eql(u8, args[i], "--build-root")) {
            build_root = nextArg(args, &i);
        } else if (mem.eql(u8, args[i], "--system-integration")) {
            try system_integrations.append(arena, nextArg(args, &i));
        } else if (mem.eql(u8, args[i], "--config")) {
            try configs.append(arena, .{ .name = nextArg(args, &i) });
        } else if (mem.eql(u8, args[i], "--zig-option")) {
            if (configs.items.len == 0) try configs.append(arena, .{ .name = "" });
            try configs.items[configs.items.len - 1].zig_options.append(arena, nextArg(args, &i));
        } else if (mem.eql(u8, args[i], "--cell")) {
            cell_process = true;
        } else {
            fatal("unrecognized argument: {s}", .{args[i]});
        }
    }

    // Configure the default cell when no matrix is given.
    if (configs.items.len == 0) try configs.append(arena, .{ .name = "" });

    const zig = zig_exe orelse fatal("missing --zig", .{});
    const build_root_path = build_root orelse fatal("missing --build-root", .{});

    var stdout_buffer: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(io, &stdout_buffer);

    if (cell_process) {
        if (configs.items.len != 1) fatal("--cell requires exactly one config", .{});
        const environ_map = try init.minimal.environ.createMap(arena);
        const result = try configureCell(arena, io, environ_map, zig, build_root_path, system_integrations.items, configs.items[0]);
        try std.json.Stringify.value(result, .{}, &stdout.interface);
        return stdout.interface.flush();
    }

    const self_exe = try process.executablePathAlloc(io, arena);
    var cells: std.ArrayList(module_graph.Cell) = .empty;
    var needed: std.array_hash_map.String(void) = .empty;
    for (configs.items) |config| {
        const output = try configureInChild(arena, io, self_exe, zig, build_root_path, system_integrations.items, config);
        const result = std.json.parseFromSliceLeaky(CellResult, arena, output, .{}) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => CellResult{
                .needed_lazy_dependencies = try configurationUnlazyDeps(arena, output, config.name),
                .cell = null,
            },
        };
        // The remaining cells still run to collect all requested lazy
        // dependencies at once.
        for (result.needed_lazy_dependencies) |hash| try needed.put(arena, hash, {});
        if (result.cell) |cell| try cells.append(arena, cell);
    }

    if (needed.count() != 0) {
        try writeNeededLazyDependencies(&stdout.interface, needed.keys());
        return stdout.interface.flush();
    }

    const merged = module_graph.merge(arena, cells.items) catch |err| switch (err) {
        error.CellModuleMismatch => fatal("the package exposes a different set of modules across configurations", .{}),
        error.EmptyMatrix => unreachable,
        else => |e| return e,
    };

    try module_graph.writeMerged(&stdout.interface, merged);
    try stdout.interface.flush();
}

/// Configure the package under `config` in this process.
fn configureCell(
    arena: mem.Allocator,
    io: std.Io,
    environ_map: process.Environ.Map,
    zig: []const u8,
    build_root: []const u8,
    system_integrations: []const []const u8,
    config: Config,
) !CellResult {
    const builder = try module_graph.createBuilder(arena, io, environ_map, zig, build_root, dependencies.root_deps);

    for (system_integrations) |name| {
        try builder.graph.system_integration_options.put(arena, name, .user_enabled);
    }
    for (config.zig_options.items) |option| {
        const setting = if (mem.startsWith(u8, option, "-D")) option[2..] else fatal("--zig-option requires -DNAME=VALUE, got '{s}'", .{option});
        const eq = mem.indexOfScalar(u8, setting, '=') orelse fatal("--zig-option requires -DNAME=VALUE, got '{s}'", .{option});
        if (try builder.addUserInputOption(setting[0..eq], setting[eq + 1 ..]))
            fatal("invalid --zig-option '{s}'", .{option});
    }

    builder.runPackageScript(root);

    const needed = builder.graph.needed_lazy_dependencies.keys();
    if (needed.len != 0) return .{ .needed_lazy_dependencies = needed, .cell = null };

    markUndeclaredOptions(builder);
    if (builder.invalid_user_input) fatal("the package's build.zig rejected the build options of config '{s}'", .{config.name});

    return .{
        .needed_lazy_dependencies = &.{},
        .cell = .{ .name = config.name, .modules = try module_graph.collectModules(arena, builder) },
    };
}

/// Run `configureCell` for `config` in a child process of this executable
/// (`self_exe`) and return the child's output. The child reports its own
/// failures on the inherited stderr.
fn configureInChild(
    arena: mem.Allocator,
    io: std.Io,
    self_exe: []const u8,
    zig: []const u8,
    build_root: []const u8,
    system_integrations: []const []const u8,
    config: Config,
) ![]const u8 {
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(arena, &.{ self_exe, "--cell", "--zig", zig, "--build-root", build_root });
    for (system_integrations) |name| try argv.appendSlice(arena, &.{ "--system-integration", name });
    try argv.appendSlice(arena, &.{ "--config", config.name });
    for (config.zig_options.items) |option| try argv.appendSlice(arena, &.{ "--zig-option", option });

    var child = try process.spawn(io, .{ .argv = argv.items, .stdin = .ignore, .stdout = .pipe });
    defer child.kill(io);
    var buffer: [4096]u8 = undefined;
    var reader = child.stdout.?.readerStreaming(io, &buffer);
    const output = try reader.interface.allocRemaining(arena, .unlimited);
    const term = try child.wait(io);
    switch (term) {
        .exited => |code| if (code != 0) process.exit(code),
        else => fatal("configuring config '{s}' {f}", .{ config.name, term }),
    }
    return output;
}

/// The lazy dependencies requested by a cell whose `build.zig` called
/// `b.dependency` on an unavailable one, read from the binary
/// `std.Build.Configuration` that call writes to `output` before exiting.
fn configurationUnlazyDeps(arena: mem.Allocator, output: []const u8, config_name: []const u8) ![]const []const u8 {
    var reader: std.Io.Reader = .fixed(output);
    // Arbitrary output decodes to arbitrary section lengths, which may exceed
    // memory as well as the output.
    const configuration = std.Build.Configuration.load(arena, &reader) catch
        fatal(not_a_cell_result, .{config_name});
    if (reader.bufferedLen() != 0 or configuration.unlazy_deps.len == 0) fatal(not_a_cell_result, .{config_name});
    const hashes = try arena.alloc([]const u8, configuration.unlazy_deps.len);
    for (hashes, configuration.unlazy_deps) |*hash, string| hash.* = string.slice(&configuration);
    return hashes;
}

const not_a_cell_result = "configuring config '{s}' printed neither a cell record nor a Zig build configuration";

fn writeNeededLazyDependencies(writer: *std.Io.Writer, hashes: []const []const u8) !void {
    var json: std.json.Stringify = .{ .writer = writer };
    try json.write(.{ .needed_lazy_dependencies = hashes });
}

/// Flag the `-D` options the package's `build.zig` does not declare as invalid
/// user input, which `b.option` flags only for a value of the wrong type.
fn markUndeclaredOptions(builder: *std.Build) void {
    for (builder.user_input_options.keys()) |name| {
        if (!builder.available_options_map.contains(name)) {
            std.log.err("build option '{s}' is not declared by the package's build.zig", .{name});
            builder.invalid_user_input = true;
        }
    }
}

fn nextArg(args: []const [:0]const u8, i: *usize) []const u8 {
    i.* += 1;
    if (i.* >= args.len) fatal("'{s}' requires a value", .{args[i.* - 1]});
    return args[i.*];
}

fn fatal(comptime format: []const u8, args: anytype) noreturn {
    std.debug.print("configurer: " ++ format ++ "\n", args);
    std.process.exit(1);
}
