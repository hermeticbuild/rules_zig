//! Build-protocol library imported by zls_runner_017.zig.
//! The runner calls serve() for ZLS build requests. For a metadata load,
//! it runs the Bazel printer, serializes the printer's JSON with the Zig
//! SDK, and sends the configuration file's path back to ZLS.

const std = @import("std");
const builtin = @import("builtin");
const owned = @import("owned_process");

const Graph = struct {
    modules: std.json.ArrayHashMap(struct { import_table: std.json.ArrayHashMap([]const u8) }),
    compilations: []const struct { root_module: []const u8 },
};

fn serialize(init: std.process.Init, bytes: []const u8, output: []const u8) !void {
    const allocator = init.arena.allocator();
    const input = try std.json.parseFromSliceLeaky(Graph, allocator, bytes, .{ .ignore_unknown_fields = true });

    var graph: std.Build.Graph = .{
        .io = init.io,
        .arena = allocator,
        .zig_exe = init.environ_map.get("RULES_ZIG_ZLS_SDK").?,
        .environ_map = init.environ_map.*,
        .host = .{ .query = .{}, .result = builtin.target },
        .generated_files = .empty,
        .wip_configuration = .init(allocator),
    };

    // Reserve string-table offset zero for Configuration.String.empty.
    _ = try graph.wip_configuration.addString("");

    const b = try std.Build.create(&graph, .{
        .root_dir = .{ .handle = .cwd(), .path = try std.process.currentPathAlloc(init.io, allocator) },
        .sub_path = "",
    }, &.{});

    var modules: std.StringHashMap(*std.Build.Module) = .init(allocator);
    for (input.modules.map.keys()) |path| {
        if (!std.Io.Dir.path.isAbsolute(path)) {
            return error.ExpectedAbsoluteModulePath;
        }

        const source = std.Io.Dir.openFileAbsolute(init.io, path, .{}) catch |err| {
            std.log.err("Bazel metadata source '{s}': {s}", .{ path, @errorName(err) });
            return err;
        };
        source.close(init.io);

        try modules.put(path, b.createModule(.{
            .root_source_file = graph.cwdRelativePath(path),
            .target = graph.host,
            .optimize = .Debug,
        }));
    }

    for (input.modules.map.keys(), input.modules.map.values()) |path, value| {
        for (value.import_table.map.keys(), value.import_table.map.values()) |name, dependency| {
            modules.get(path).?.addImport(name, modules.get(dependency) orelse return error.MissingImportedModule);
        }
    }

    // The SDK serializer starts from top-level steps. Attach a synthetic
    // object step for each selected root to include its module graph.
    const metadata = b.step("metadata", "Bazel editor metadata; build applications with Bazel");
    for (input.compilations, 0..) |root, index| {
        const object = b.addObject(.{
            .name = b.fmt("metadata-{d}", .{index}),
            .root_module = modules.get(root.root_module) orelse return error.MissingRootModule,
        });
        metadata.dependOn(&object.step);
    }

    const file = try std.Io.Dir.createFileAbsolute(init.io, output, .{ .exclusive = true });
    defer file.close(init.io);

    var buffer: [4096]u8 = undefined;
    var writer = file.writer(init.io, &buffer);
    try std.Build.Serialize.write(b, &graph.wip_configuration, &writer.interface);
    try writer.interface.flush();
}

fn errors(allocator: std.mem.Allocator, message: []const u8) !std.zig.ErrorBundle {
    var wip = try std.zig.ErrorBundle.Wip.init(allocator);
    const location = try wip.addSourceLocation(.{
        .src_path = try wip.addString("build.zig"),
        .line = 0,
        .column = 0,
        .span_start = 0,
        .span_main = 0,
        .span_end = 0,
    });

    try wip.addRootErrorMessage(.{ .msg = try wip.addString(message), .src_loc = location });
    return wip.toOwnedBundle("");
}

pub fn serve(init: std.process.Init, output: []const u8, command: []const []const u8, invocation_supported: bool) !void {
    const allocator = init.arena.allocator();

    var input_buffers: std.Io.File.MultiReader.Buffer(1) = undefined;
    var input: std.Io.File.MultiReader = undefined;
    input.init(allocator, init.io, input_buffers.toStreams(), &.{std.Io.File.stdin()});
    defer input.deinit();

    var out_buffer: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(init.io, &out_buffer);
    var server: std.zig.Server = .{ .in = input.reader(0), .out = &stdout.interface };

    try server.serveMessageHeader(.{ .tag = .bsp_handshake, .bytes_len = @sizeOf(std.zig.Server.Message.Handshake) });
    try stdout.interface.writeStruct(std.zig.Server.Message.Handshake{
        .version = std.zig.Server.build_system_version,
        .flags = .{ .file_system_watch_supported = false },
    }, .little);
    try stdout.interface.flush();

    if (!invocation_supported) {
        try server.serveErrorBundle(.bsp_configuration_failed, try errors(allocator, "Unsupported ZLS build invocation; build applications with Bazel"));
        return;
    }

    const workspace = init.environ_map.get("BUILD_WORKSPACE_DIRECTORY") orelse return error.MissingBuildWorkspace;
    const result = owned.capture(init, .{ .argv = command, .stdin = .ignore, .cwd = .{ .path = workspace } }, &input) catch |err| {
        if (err == error.Canceled) {
            return;
        }
        try server.serveErrorBundle(.bsp_configuration_failed, try errors(allocator, @errorName(err)));
        return;
    };

    if (!result.term.success()) {
        const message = try std.fmt.allocPrint(allocator, "Bazel metadata query failed: {s}", .{result.stderr});
        try server.serveErrorBundle(.bsp_configuration_failed, try errors(allocator, message));
        return;
    }

    serialize(init, result.stdout, output) catch |err| {
        const message = try std.fmt.allocPrint(allocator, "Invalid Bazel metadata: {s}", .{@errorName(err)});
        try server.serveErrorBundle(.bsp_configuration_failed, try errors(allocator, message));
        return;
    };

    try owned.check();
    try server.serveStringMessage(.bsp_configuration, output);

    while (true) {
        const header = owned.receive(&input) catch |err| switch (err) {
            error.EndOfStream, error.Canceled => return,
            else => return err,
        };
        const body = try input.reader(0).take(header.bytes_len);

        switch (header.tag) {
            .exit => {
                if (body.len != 0) {
                    return error.InvalidExitMessage;
                }
                return;
            },
            .bsp_build_steps => {
                var reader: std.Io.Reader = .fixed(body);
                const request = try reader.takeStruct(std.zig.Client.Message.BuildSteps, .little);
                const request_size = @sizeOf(@TypeOf(request)) + @as(usize, request.step_count) * @sizeOf(u32);
                if (body.len != request_size) {
                    return error.InvalidBuildRequest;
                }

                if (request.flags.watch) {
                    try server.serveErrorBundle(.bsp_configuration_failed, try errors(allocator, "Bazel metadata service does not support build-on-save; build applications with Bazel"));
                    return;
                }

                // ZLS expects start and completion messages even for an empty build round.
                try server.serveBodylessMessage(.bsp_build_started);

                for (0..request.step_count) |_| {
                    const index = try reader.takeInt(u32, .little);
                    const bundle = try errors(allocator, "Bazel metadata service cannot execute build steps; build applications with Bazel");
                    try server.serveU32Message(.bsp_step_started, index);

                    const completion: std.zig.Server.Message.BuildStepCompleted = .{
                        .step_index = @fromBackingInt(index),
                        .status = .failure,
                        .generated_files_len = 0,
                        .error_bundle = .{ .extra_len = @intCast(bundle.extra.len), .string_bytes_len = @intCast(bundle.string_bytes.len) },
                    };
                    try server.serveMessageHeader(.{
                        .tag = .bsp_step_completed,
                        .bytes_len = @intCast(@sizeOf(@TypeOf(completion)) + @sizeOf(u32) * bundle.extra.len + bundle.string_bytes.len),
                    });
                    try stdout.interface.writeStruct(completion, .little);
                    try stdout.interface.writeSliceEndian(u32, bundle.extra, .little);
                    try stdout.interface.writeAll(bundle.string_bytes);
                }

                try server.serveBodylessMessage(.bsp_build_completed);
            },
            else => return error.UnsupportedClientMessage,
        }

        try stdout.interface.flush();
    }
}
