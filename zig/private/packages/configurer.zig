//! Configure a Zig package's `build.zig` and emit its public module graph as
//! JSON on stdout, for translation into Bazel `zig_library` targets.
//!
//! Usage: configurer --zig <zig> --build-root <dir>
//!
//! Modeled on `lib/compiler/configurer.zig` of Zig 0.17.0. The package's
//! `build.zig` is provided as the `pkg` module and its dependency table as the
//! `deps` module, both wired in at compile time.

const std = @import("std");
const mem = std.mem;
const process = std.process;
const module_graph = @import("module_graph.zig");

pub const root = @import("pkg");
pub const dependencies = @import("deps");

pub fn main(init: process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;

    requireAvailableDependencies();

    const args = try init.minimal.args.toSlice(arena);

    var zig_exe: ?[]const u8 = null;
    var build_root: ?[]const u8 = null;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (mem.eql(u8, args[i], "--zig")) {
            zig_exe = nextArg(args, &i);
        } else if (mem.eql(u8, args[i], "--build-root")) {
            build_root = nextArg(args, &i);
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

    builder.runPackageScript(root);

    var stdout_buffer: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(io, &stdout_buffer);
    try module_graph.emit(arena, &stdout.interface, builder);
    try stdout.interface.flush();
}

/// The importer fetches the full dependency closure, so every dependency must be
/// available: under Zig 0.17.0, `b.dependency` on an unavailable one emits the
/// binary build configuration and exits 0.
fn requireAvailableDependencies() void {
    for (std.Build.package_map.values()) |entry| {
        if (!entry.available) fatal("lazy dependency '{s}' is unavailable", .{entry.hash});
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
