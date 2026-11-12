const std = @import("std");
const builtin = @import("builtin");

const bazel_builtin = @import("bazel_builtin");
const runfiles = @import("runfiles");

/// https://github.com/zigtools/zls/blob/606a86543362c0072248d8f1ef4a64a5e3f51682/src/build_runner/shared.zig#L6
pub const BuildConfig = struct {
    /// The `dependencies` in `build.zig.zon`.
    dependencies: std.json.ArrayHashMap([]const u8),
    /// The key is the `root_source_file`.
    /// All modules with the same root source file are merged. This limitation may be lifted in the future.
    modules: std.json.ArrayHashMap(Module),
    /// List of all compilations units.
    compilations: []Compile,
    /// The names of all top level steps.
    top_level_steps: []const []const u8,
    available_options: std.json.ArrayHashMap(AvailableOption),

    pub const Module = struct {
        import_table: std.json.ArrayHashMap([]const u8),
        c_macros: []const []const u8,
        include_dirs: []const []const u8,
    };

    pub const Compile = struct {
        /// Key in `BuildConfig.modules`.
        root_module: []const u8,

        // may contain additional information in the future like `target` or `link_libc`.
    };

    /// Equivalent to `std.Build.AvailableOption` which is not accessible because it non-pub.
    pub const AvailableOption = @FieldType(@FieldType(std.Build, "available_options_map").KV, "value");
};

fn processConfigLeaky(allocator: std.mem.Allocator, io: std.Io, config_string: []const u8) !BuildConfig {
    var config = try std.json.parseFromSliceLeaky(BuildConfig, allocator, config_string, .{});
    try canonicalizeModulesLeaky(allocator, io, &config);
    return config;
}

// Neovim canonicalizes the path it sends to ZLS, we need to do the same as ZLS will match against the config we generate.
// We canonicalize the following module paths:
//
// {
//   "modules": {
//     "<module-path>": {
//       "import_table": {
//         "<import-name>": "<module-path>"
//       },
//     },
//   },
// }
fn canonicalizeModulesLeaky(allocator: std.mem.Allocator, io: std.Io, config: *BuildConfig) !void {
    var old_modules = config.modules.map.iterator();
    var new_modules: std.StringArrayHashMapUnmanaged(BuildConfig.Module) = .empty;
    try new_modules.ensureTotalCapacity(allocator, old_modules.len);

    while (old_modules.next()) |entry| {
        const module_name = canonicalizePath(allocator, io, entry.key_ptr.*);
        var module: BuildConfig.Module = entry.value_ptr.*;
        for (module.import_table.map.values()) |*imported_module_path| {
            imported_module_path.* = canonicalizePath(allocator, io, imported_module_path.*);
        }
        try new_modules.put(allocator, module_name, module);
    }

    for (config.compilations) |*compile| {
        compile.root_module = canonicalizePath(allocator, io, compile.root_module);
    }

    config.modules.map = new_modules;
}

fn canonicalizePath(allocator: std.mem.Allocator, io: std.Io, path: []const u8) []const u8 {
    return std.Io.Dir.realPathFileAbsoluteAlloc(io, path, allocator) catch path;
}

// Escapes a value for insertion inside a JSON string literal.
// Needed on Windows, where paths contain backslashes that are invalid
// (or wrongly interpreted) escape sequences in JSON.
fn jsonEscapeLeaky(allocator: std.mem.Allocator, value: []const u8) ![]u8 {
    const step1 = try std.mem.replaceOwned(u8, allocator, value, "\\", "\\\\");
    return std.mem.replaceOwned(u8, allocator, step1, "\"", "\\\"");
}

const ConfigInput = struct { bytes: []u8, path: []const u8 };

fn readConfigFile(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !ConfigInput {
    return .{
        .bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .unlimited),
        .path = try std.Io.Dir.cwd().realPathFileAlloc(io, path, allocator),
    };
}

fn readBuildConfig(
    allocator: std.mem.Allocator,
    io: std.Io,
    init: std.process.Init,
    arg_path: []const u8,
) !ConfigInput {
    if (std.fs.path.isAbsolute(arg_path)) {
        return readConfigFile(allocator, io, arg_path);
    }

    var r_ = try runfiles.Runfiles.create(.{
        .allocator = allocator,
        .io = io,
        .environ_map = init.environ_map,
        .argv = init.minimal.args,
    }) orelse return error.RunfilesNotFound;

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const r = r_.withSourceRepo(bazel_builtin.current_repository);

    if (try r.rlocation(arg_path, &path_buf)) |config_path| {
        return readConfigFile(allocator, io, config_path);
    }

    const stripped = if (std.mem.startsWith(u8, arg_path, "./")) arg_path[2..] else arg_path;
    if (try r.rlocation(stripped, &path_buf)) |config_path| {
        return readConfigFile(allocator, io, config_path);
    }

    // Convenience for testing.
    const output = std.Io.Dir.cwd().readFileAlloc(io, arg_path, allocator, .unlimited) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
    if (output) |content| {
        return .{ .bytes = content, .path = try std.Io.Dir.cwd().realPathFileAlloc(io, arg_path, allocator) };
    }

    return error.BuildConfigNotFound;
}

// Strip the config's execpath from its resolved path to recover the execution
// root of the Bazel invocation that generated it.
fn executionRoot(allocator: std.mem.Allocator, physical_path: []const u8, exec_path: []const u8) ![]const u8 {
    const physical = if (builtin.os.tag == .windows) try std.mem.replaceOwned(u8, allocator, physical_path, "\\", "/") else physical_path;
    const relative = if (builtin.os.tag == .windows) try std.mem.replaceOwned(u8, allocator, exec_path, "\\", "/") else exec_path;
    if (std.fs.path.isAbsolute(relative)) {
        return error.ExpectedRelativeConfigExecPath;
    }
    const suffix = try std.mem.concat(allocator, u8, &.{ "/", relative });
    if (!std.mem.endsWith(u8, physical, suffix)) {
        return error.InvalidConfigProvenance;
    }
    return physical[0 .. physical.len - suffix.len];
}

pub fn main(init: std.process.Init) !void {
    const arena = init.arena;
    const io = init.io;
    const args = try init.minimal.args.toSlice(arena.allocator());

    const build_workspace_directory = init.environ_map.get("BUILD_WORKSPACE_DIRECTORY").?;
    const input = try readBuildConfig(arena.allocator(), io, init, args[1]);
    const execution_root = if (init.environ_map.get("BAZEL_EXECUTION_ROOT")) |value|
        value
    else if (args.len >= 3)
        try executionRoot(arena.allocator(), input.path, args[2])
    else
        return error.MissingConfigExecPath;
    var output = input.bytes;

    // The placeholders sit inside JSON string literals, so the substituted
    // values must be JSON-escaped (Windows paths contain backslashes).
    const workspace_escaped = try jsonEscapeLeaky(arena.allocator(), build_workspace_directory);
    const execution_root_escaped = try jsonEscapeLeaky(arena.allocator(), execution_root);

    output = try std.mem.replaceOwned(
        u8,
        arena.allocator(),
        output,
        "__BUILD_WORKSPACE_DIRECTORY__",
        workspace_escaped,
    );
    output = try std.mem.replaceOwned(
        u8,
        arena.allocator(),
        output,
        "__BAZEL_EXECUTION_ROOT__",
        execution_root_escaped,
    );

    var stdout_buf: [4096]u8 = undefined;
    var writer = std.Io.File.stdout().writer(io, &stdout_buf);
    if (processConfigLeaky(arena.allocator(), io, output)) |config| {
        try std.json.Stringify.value(config, .{}, &writer.interface);
    } else |err| {
        std.log.warn("config processing failed: {s}", .{@errorName(err)});
        try writer.interface.writeAll(output);
    }
    try writer.flush();
}
