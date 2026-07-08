//! Configure a Zig package's `build.zig` under one or more matrix cells and
//! emit each cell's public module graph as JSON on stdout, for translation
//! into Bazel `zig_library` targets. The output has the shape
//! `{"cells": [{"name": ..., "modules": [...]}]}`, one entry per cell.
//!
//! Usage: configurer --zig <zig> --build-root <dir> [--system-integration NAME ...] [--config NAME [--zig-option -DNAME=VALUE ...]]...
//!
//! Each `--config NAME` starts a cell configured under the following
//! `--zig-option -DNAME=VALUE` build options (as `zig build -DNAME=VALUE`
//! would). With no `--config`, the package is configured once under a single
//! unnamed default cell.
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

pub fn main(init: process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;

    const args = try init.minimal.args.toSlice(arena);

    var zig_exe: ?[]const u8 = null;
    var build_root: ?[]const u8 = null;
    var system_integrations: std.ArrayList([]const u8) = .empty;
    var configs: std.ArrayList(Config) = .empty;
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
        } else {
            fatal("unrecognized argument: {s}", .{args[i]});
        }
    }

    // Configure the default cell when no matrix is given.
    if (configs.items.len == 0) try configs.append(arena, .{ .name = "" });

    const zig = zig_exe orelse fatal("missing --zig", .{});
    const build_root_path = build_root orelse fatal("missing --build-root", .{});
    const environ_map = try init.minimal.environ.createMap(arena);

    var cells: std.ArrayList(module_graph.Cell) = .empty;
    var needed: std.array_hash_map.String(void) = .empty;
    for (configs.items) |config| {
        const builder = try module_graph.createBuilder(arena, io, environ_map, zig, build_root_path, dependencies.root_deps);

        for (system_integrations.items) |name| {
            try builder.graph.system_integration_options.put(arena, name, .user_enabled);
        }
        for (config.zig_options.items) |option| {
            const setting = if (mem.startsWith(u8, option, "-D")) option[2..] else fatal("--zig-option requires -DNAME=VALUE, got '{s}'", .{option});
            const eq = mem.indexOfScalar(u8, setting, '=') orelse fatal("--zig-option requires -DNAME=VALUE, got '{s}'", .{option});
            if (try builder.addUserInputOption(setting[0..eq], setting[eq + 1 ..]))
                fatal("invalid --zig-option '{s}'", .{option});
        }

        builder.runPackageScript(root);

        // A cell that requested unavailable lazy dependencies via
        // `lazyDependency` is incomplete; the remaining cells still run to
        // collect all of them at once.
        const cell_needed = builder.graph.needed_lazy_dependencies.keys();
        if (cell_needed.len != 0) {
            for (cell_needed) |hash| try needed.put(arena, hash, {});
            continue;
        }

        markUndeclaredOptions(builder);
        if (builder.invalid_user_input) fatal("the package's build.zig rejected the build options of config '{s}'", .{config.name});

        try cells.append(arena, .{ .name = config.name, .builder = builder });
    }

    var stdout_buffer: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(io, &stdout_buffer);
    if (needed.count() != 0) {
        try writeNeededLazyDependencies(&stdout.interface, needed.keys());
    } else {
        try module_graph.emitCells(arena, &stdout.interface, cells.items);
    }
    try stdout.interface.flush();
}

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
