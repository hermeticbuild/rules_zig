const builtin = @import("builtin");
const std = @import("std");
const BitContext = @import("integration_testing").BitContext;
const a = std.testing.allocator;
const io = std.testing.io;

fn expectProgram(ctx: BitContext, path: []const u8, expected: []const u8) !void {
    const absolute = try std.fs.path.join(a, &.{ ctx.workspace_path, path });
    defer a.free(absolute);
    const result = try std.process.run(a, io, .{ .argv = &.{absolute} });
    defer a.free(result.stdout);
    defer a.free(result.stderr);
    try std.testing.expect(result.term.success());
    try std.testing.expectEqualStrings(expected, result.stdout);
}

fn build(ctx: BitContext, mode: []const []const u8, extra: []const []const u8) !BitContext.BazelResult {
    var argv: std.array_list.Managed([]const u8) = .init(a);
    defer argv.deinit();
    try argv.appendSlice(&.{ "build", "--@rules_zig//zig/settings:incremental", "--worker_max_instances=ZigIncrementalCompile=1", "--noworker_multiplex", "--experimental_worker_strict_flagfiles", "--worker_verbose" });
    try argv.appendSlice(mode);
    try argv.appendSlice(extra);
    try argv.append("//:incremental");
    return ctx.exec_bazel(.{ .argv = argv.items, .print_on_error = false });
}

fn expectBuild(ctx: BitContext, mode: []const []const u8, extra: []const []const u8) !void {
    const result = try build(ctx, mode, extra);
    defer result.deinit();
    if (!result.success) std.debug.print("{s}\n{s}\n", .{ result.stdout, result.stderr });
    try std.testing.expect(result.success);
}

fn workerLogs(output_base: []const u8) ![]u8 {
    const path = try std.fs.path.join(a, &.{ output_base, "bazel-workers" });
    defer a.free(path);
    var dir = std.Io.Dir.openDirAbsolute(io, path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return a.dupe(u8, ""),
        else => return err,
    };
    defer dir.close(io);
    var result: std.array_list.Managed(u8) = .init(a);
    errdefer result.deinit();
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (!std.mem.endsWith(u8, entry.name, "ZigIncrementalCompile.log")) continue;
        const content = try dir.readFileAlloc(io, entry.name, a, .limited(16 * 1024 * 1024));
        defer a.free(content);
        try result.appendSlice(content);
    }
    return result.toOwnedSlice();
}

fn compilerProcess(output_base: []const u8) ![]u8 {
    var proc = try std.Io.Dir.openDirAbsolute(io, "/proc", .{ .iterate = true });
    defer proc.close(io);
    var it = proc.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .directory) continue;
        _ = std.fmt.parseInt(u32, entry.name, 10) catch continue;
        const cmd_path = try std.fs.path.join(a, &.{ entry.name, "cmdline" });
        defer a.free(cmd_path);
        const command = readProc(proc, cmd_path) catch continue;
        defer a.free(command);
        if (std.mem.find(u8, command, "--listen=-") != null) {
            if (std.mem.find(u8, command, output_base) != null) return std.fs.path.join(a, &.{ "/proc", entry.name });
            std.debug.print("Unmatched compiler {s}: {s}; expected output base {s}\n", .{ entry.name, command, output_base });
        }
    }
    return error.CompilerProcessNotFound;
}

fn readProc(dir: std.Io.Dir, path: []const u8) ![]u8 {
    var file = try dir.openFile(io, path, .{});
    defer file.close(io);
    var buffer: [4096]u8 = undefined;
    var reader = file.readerStreaming(io, &buffer);
    return reader.interface.allocRemaining(a, .limited(1024 * 1024));
}

fn mountNamespace(process: []const u8, buffer: []u8) ![]const u8 {
    const path = try std.fs.path.join(a, &.{ process, "ns/mnt" });
    defer a.free(path);
    const len = try std.Io.Dir.cwd().readLink(io, path, buffer);
    return buffer[0..len];
}

fn expectHardened(ctx: BitContext, process: []const u8) !void {
    var self_ns: [256]u8 = undefined;
    var child_ns: [256]u8 = undefined;
    const self_mount = try mountNamespace("/proc/self", &self_ns);
    const child_mount = try mountNamespace(process, &child_ns);
    std.debug.print("Hardened compiler {s}: test namespace {s}, compiler namespace {s}\n", .{ process, self_mount, child_mount });
    try std.testing.expect(!std.mem.eql(u8, self_mount, child_mount));
    const status_path = try std.fs.path.join(a, &.{ process, "status" });
    defer a.free(status_path);
    const status = try readProc(.cwd(), status_path);
    defer a.free(status);
    var lines = std.mem.splitScalar(u8, status, '\n');
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, "PPid:")) continue;
        const parent = try std.fmt.allocPrint(a, "/proc/{s}", .{std.mem.trim(u8, line[5..], " \t")});
        defer a.free(parent);
        var parent_ns: [256]u8 = undefined;
        try std.testing.expectEqualStrings(try mountNamespace(process, &child_ns), try mountNamespace(parent, &parent_ns));
        break;
    }
    // Look through the compiler's mount namespace at a test-owned file outside
    // its execroot. It must be read-only or hidden, even though the test can edit it.
    const outside = try std.fmt.allocPrint(a, "{s}/root{s}/worker-write-probe", .{ process, ctx.workspace_path });
    defer a.free(outside);
    const file = std.Io.Dir.cwd().createFile(io, outside, .{}) catch |err| switch (err) {
        error.ReadOnlyFileSystem, error.AccessDenied, error.FileNotFound => return,
        else => return err,
    };
    file.close(io);
    return error.HardenedWorkerAllowedOutsideWrite;
}

test "incremental binaries retain current inputs and independent outputs in each worker sandbox" {
    if (builtin.os.tag != .linux or builtin.cpu.arch != .x86_64) return error.SkipZigTest;
    const ctx = try BitContext.init();
    defer ctx.deinit();
    const info = try ctx.exec_bazel(.{ .argv = &.{ "info", "output_base" } });
    defer info.deinit();
    try std.testing.expect(info.success);
    const output_base = std.mem.trim(u8, info.stdout, "\r\n");

    const modes = [_][]const []const u8{
        &.{"--noworker_sandboxing"},
        &.{"--worker_sandboxing"},
        &.{ "--worker_sandboxing", "--experimental_worker_sandbox_hardening" },
        &.{ "--worker_sandboxing", "--experimental_worker_sandbox_hardening", "--experimental_sibling_repository_layout" },
    };
    for (modes, 0..) |mode, mode_index| {
        std.debug.print("Worker mode {d}: {s}\n", .{ mode_index, mode[0] });
        try ctx.writeWorkspaceFile("incremental_leaf.zig", "pub const value: u32 = 41;\n");
        try ctx.writeWorkspaceFile("incremental_message.txt", "hello\n");
        try ctx.writeWorkspaceFile("incremental_generated.txt", "");
        try ctx.writeWorkspaceFile("incremental_external.zig", "pub const bias: u32 = 0;\n");
        try ctx.writeWorkspaceFile("worker-write-probe", "unchanged\n");
        try expectBuild(ctx, mode, &.{});
        try expectProgram(ctx, "bazel-bin/incremental", "41:hello\n");
        // Changing hardening recreates WorkerFactory and deletes older logs.
        const previous_logs = try workerLogs(output_base);
        defer a.free(previous_logs);
        const compiler = try compilerProcess(output_base);
        defer a.free(compiler);
        if (mode_index >= 2) try expectHardened(ctx, compiler);
        var workspace = try ctx.openWorkspace();
        defer workspace.close(io);
        try workspace.copyFile("bazel-bin/incremental", workspace, "saved-program", io, .{});

        try ctx.writeWorkspaceFile("incremental_leaf.zig", "pub const value: u32 = 42;\n");
        try expectBuild(ctx, mode, &.{});
        try expectProgram(ctx, "bazel-bin/incremental", "42:hello\n");
        std.debug.print("Checking retained compiler\n", .{});
        const reused_compiler = try compilerProcess(output_base);
        defer a.free(reused_compiler);
        try std.testing.expectEqualStrings(compiler, reused_compiler);
        try expectProgram(ctx, "saved-program", "41:hello\n");
        try ctx.writeWorkspaceFile("incremental_message.txt", "world\n");
        try expectBuild(ctx, mode, &.{});
        try expectProgram(ctx, "bazel-bin/incremental", "42:world\n");

        try ctx.writeWorkspaceFile("incremental_generated.txt", "generated\n");
        std.debug.print("Checking generated and external inputs\n", .{});
        try expectBuild(ctx, mode, &.{});
        try expectProgram(ctx, "bazel-bin/incremental", "42:world\ngenerated\n");
        // The same tree path changes from a file to a directory and back.
        try ctx.writeWorkspaceFile("incremental_generated.txt", "nested:generated\n");
        try expectBuild(ctx, mode, &.{});
        try expectProgram(ctx, "bazel-bin/incremental", "42:world\ngenerated\n");
        try ctx.writeWorkspaceFile("incremental_generated.txt", "");
        try ctx.writeWorkspaceFile("incremental_external.zig", "pub const bias: u32 = 1;\n");
        try expectBuild(ctx, mode, &.{});
        try expectProgram(ctx, "bazel-bin/incremental", "43:world\n");
        try ctx.writeWorkspaceFile("incremental_external.zig", "pub const bias: u32 = 0;\n");

        try ctx.writeWorkspaceFile("incremental_target.zig", "pub const value: u32 = 42;\n");
        try ctx.symLinkWorkspaceFile("incremental_target.zig", "incremental_leaf.zig");
        try expectBuild(ctx, mode, &.{});
        try expectProgram(ctx, "bazel-bin/incremental", "42:world\n");

        try ctx.writeWorkspaceFile("incremental_leaf.zig", "pub const value: u32 = \"bad\";\n");
        const failed = try build(ctx, mode, &.{});
        defer failed.deinit();
        try std.testing.expect(!failed.success);
        try std.testing.expect(std.mem.find(u8, failed.stderr, "expected type") != null);
        try ctx.writeWorkspaceFile("incremental_leaf.zig", "pub const value: u32 = 43;\n");
        try expectBuild(ctx, mode, &.{});
        try expectProgram(ctx, "bazel-bin/incremental", "43:world\n");
        const logs = try workerLogs(output_base);
        defer a.free(logs);
        const previous_reuse = std.mem.count(u8, previous_logs, "reused=true");
        const current_reuse = std.mem.count(u8, logs, "reused=true");
        std.debug.print("Checking reuse count: {d} -> {d}\n", .{ previous_reuse, current_reuse });
        try std.testing.expect(current_reuse >= previous_reuse + 3);
        try expectBuild(ctx, mode, &.{});
        const unchanged = try workerLogs(output_base);
        defer a.free(unchanged);
        try std.testing.expectEqualStrings(logs, unchanged);

        // Force the same declared action through the nonpersistent adapter.
        try ctx.writeWorkspaceFile("incremental_leaf.zig", "pub const value: u32 = 44;\n");
        try expectBuild(ctx, mode, &.{"--strategy=ZigIncrementalCompile=sandboxed"});
        try expectProgram(ctx, "bazel-bin/incremental", "44:world\n");

        try expectBuild(ctx, mode, &.{ "--@rules_zig//zig/settings:zigopt=--dynamic-linker", "--@rules_zig//zig/settings:zigopt=" });
        try expectProgram(ctx, "bazel-bin/incremental", "44:world\n");

        const conflict = try build(ctx, mode, &.{"--@rules_zig//zig/settings:zigopt=--cache-dir"});
        defer conflict.deinit();
        try std.testing.expect(!conflict.success);
        try std.testing.expect(std.mem.find(u8, conflict.stderr, "owned by rules_zig") != null);
    }
    // Establish a live session, then verify Bazel teardown also ends its compiler.
    const last_mode = modes[modes.len - 1];
    try ctx.writeWorkspaceFile("incremental_leaf.zig", "pub const value: u32 = 45;\n");
    try expectBuild(ctx, last_mode, &.{});
    const current_compiler = try compilerProcess(output_base);
    defer a.free(current_compiler);
    const current_command_path = try std.fs.path.join(a, &.{ current_compiler, "cmdline" });
    defer a.free(current_command_path);
    const current_command = try readProc(.cwd(), current_command_path);
    defer a.free(current_command);
    const executable = current_command[0..std.mem.findScalar(u8, current_command, 0).?];
    const sdk_source = try std.fs.path.join(a, &.{ std.fs.path.dirname(executable).?, "lib/std/std.zig" });
    defer a.free(sdk_source);
    const source_bytes = try std.Io.Dir.cwd().readFileAlloc(io, sdk_source, a, .limited(1024 * 1024));
    defer a.free(source_bytes);
    try ctx.symLinkWorkspaceFile(sdk_source, "incremental_message.txt");
    try ctx.writeWorkspaceFile("incremental_module.zig", "pub const value = @import(\"incremental_leaf.zig\").value;\npub const message = @embedFile(\"incremental_message.txt\")[0..1];\n");
    try expectBuild(ctx, last_mode, &.{});
    const expected = try std.fmt.allocPrint(a, "45:{s}", .{source_bytes[0..1]});
    defer a.free(expected);
    try expectProgram(ctx, "bazel-bin/incremental", expected);
    const compiler = try compilerProcess(output_base);
    defer a.free(compiler);
    const shutdown = try ctx.exec_bazel(.{ .argv = &.{"shutdown"} });
    defer shutdown.deinit();
    try std.testing.expect(shutdown.success);
    const command_path = try std.fs.path.join(a, &.{ compiler, "cmdline" });
    defer a.free(command_path);
    for (0..200) |_| {
        const command = readProc(.cwd(), command_path) catch |err| switch (err) {
            error.FileNotFound => return,
            else => return err,
        };
        defer a.free(command);
        if (std.mem.find(u8, command, "--listen=-") == null) return;
        try std.Io.sleep(io, .fromMilliseconds(25), .awake);
    }
    return error.CompilerSurvivedWorkerShutdown;
}
