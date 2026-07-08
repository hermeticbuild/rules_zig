//! Configure a Zig package's `build.zig` and emit its public module graph as
//! JSON on stdout, for translation into Bazel `zig_library` targets.
//!
//! Usage: configurer --zig <zig> --build-root <dir> [--system-integration NAME ...] [--zig-option -DNAME=VALUE ...]
//!
//! Each `--zig-option -DNAME=VALUE` sets a `build.zig` user option (as `zig
//! build -DNAME=VALUE` would), so a package can be configured under several
//! build settings.
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

pub fn main(init: process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;

    const args = try init.minimal.args.toSlice(arena);

    var zig_exe: ?[]const u8 = null;
    var build_root: ?[]const u8 = null;
    var system_integrations: std.ArrayList([]const u8) = .empty;
    var zig_options: std.ArrayList([]const u8) = .empty;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (mem.eql(u8, args[i], "--zig")) {
            zig_exe = nextArg(args, &i);
        } else if (mem.eql(u8, args[i], "--build-root")) {
            build_root = nextArg(args, &i);
        } else if (mem.eql(u8, args[i], "--system-integration")) {
            try system_integrations.append(arena, nextArg(args, &i));
        } else if (mem.eql(u8, args[i], "--zig-option")) {
            try zig_options.append(arena, nextArg(args, &i));
        } else {
            fatal("unrecognized argument: {s}", .{args[i]});
        }
    }

    const builder = try module_graph.createBuilder(
        arena,
        io,
        try init.minimal.environ.createMap(arena),
        zig_exe orelse fatal("missing --zig", .{}),
        build_root orelse fatal("missing --build-root", .{}),
        dependencies.root_deps,
    );

    for (system_integrations.items) |name| {
        try builder.graph.system_integration_options.put(arena, name, .user_enabled);
    }

    for (zig_options.items) |option| {
        const setting = if (mem.startsWith(u8, option, "-D")) option[2..] else fatal("--zig-option requires -DNAME=VALUE, got '{s}'", .{option});
        const eq = mem.indexOfScalar(u8, setting, '=') orelse fatal("--zig-option requires -DNAME=VALUE, got '{s}'", .{option});
        if (try builder.addUserInputOption(setting[0..eq], setting[eq + 1 ..]))
            fatal("invalid --zig-option '{s}'", .{option});
    }

    builder.runPackageScript(root);

    markUndeclaredOptions(builder);
    if (builder.invalid_user_input) fatal("the package's build.zig rejected the --zig-option build options", .{});

    var stdout_buffer: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(io, &stdout_buffer);
    const needed = builder.graph.needed_lazy_dependencies.keys();
    if (needed.len != 0) {
        try writeNeededLazyDependencies(&stdout.interface, needed);
    } else {
        try module_graph.emit(arena, &stdout.interface, builder);
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
