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
    return buildTarget(ctx, mode, extra, "//:incremental");
}

fn buildTarget(ctx: BitContext, mode: []const []const u8, extra: []const []const u8, target: []const u8) !BitContext.BazelResult {
    var argv: std.array_list.Managed([]const u8) = .init(a);
    defer argv.deinit();
    try argv.appendSlice(&.{ "build", "--@rules_zig//zig/settings:incremental", "--worker_max_instances=ZigIncrementalCompile=1", "--noworker_multiplex", "--experimental_worker_strict_flagfiles", "--worker_verbose" });
    try argv.appendSlice(mode);
    try argv.appendSlice(extra);
    try argv.append(target);
    return ctx.exec_bazel(.{ .argv = argv.items, .print_on_error = false });
}

fn expectTarget(ctx: BitContext, mode: []const []const u8, extra: []const []const u8, target: []const u8) !void {
    const result = try buildTarget(ctx, mode, extra, target);
    defer result.deinit();
    if (!result.success) std.debug.print("{s}\n{s}\n", .{ result.stdout, result.stderr });
    try std.testing.expect(result.success);
}

fn expectFailure(result: BitContext.BazelResult, message: []const u8) !void {
    if (result.success or std.mem.find(u8, result.stderr, message) == null)
        std.debug.print("Expected failure containing '{s}':\n{s}\n{s}\n", .{ message, result.stdout, result.stderr });
    try std.testing.expect(!result.success);
    try std.testing.expect(std.mem.find(u8, result.stderr, message) != null);
}

fn expectTestProgram(ctx: BitContext, success: bool) !void {
    const program = try std.fs.path.join(a, &.{ ctx.workspace_path, "bazel-bin/incremental_test" });
    defer a.free(program);
    const result = try std.process.run(a, io, .{ .argv = &.{program} });
    defer a.free(result.stdout);
    defer a.free(result.stderr);
    try std.testing.expectEqual(success, result.term.success());
    try std.testing.expect(std.mem.find(u8, result.stderr, if (success) "All 1 tests passed" else "TestUnexpectedResult") != null);
}

fn expectLibrary(ctx: BitContext, sdk: []const u8, library: []const u8, expected: []const u8) !void {
    const source = "const std = @import(\"std\");\nextern fn answer() u32;\npub fn main(init: std.process.Init) !void {var buffer: [32]u8 = undefined; const text = try std.fmt.bufPrint(&buffer, \"{d}\\n\", .{answer()}); try std.Io.File.stdout().writeStreamingAll(init.io, text);}\n";
    try ctx.writeWorkspaceFile("library_consumer.zig", source);
    const main = try std.fs.path.join(a, &.{ ctx.workspace_path, "library_consumer.zig" });
    defer a.free(main);
    const lib = try std.fs.path.join(a, &.{ ctx.workspace_path, library });
    defer a.free(lib);
    const sdk_lib = try std.fs.path.join(a, &.{ std.fs.path.dirname(sdk).?, "lib" });
    defer a.free(sdk_lib);
    const cache = try std.fs.path.join(a, &.{ ctx.workspace_path, "consumer-cache" });
    defer a.free(cache);
    const output = try std.fmt.allocPrint(a, "-femit-bin={s}/library_consumer", .{ctx.workspace_path});
    defer a.free(output);
    const result = try std.process.run(a, io, .{ .argv = &.{ sdk, "build-exe", main, lib, "-lc", "-j4", "-rpath", std.fs.path.dirname(lib).?, "--zig-lib-dir", sdk_lib, "--cache-dir", cache, "--global-cache-dir", cache, output } });
    defer a.free(result.stdout);
    defer a.free(result.stderr);
    if (!result.term.success()) std.debug.print("Library consumer failed: {s}\n", .{result.stderr});
    try std.testing.expect(result.term.success());
    try expectProgram(ctx, "library_consumer", expected);
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
        try ctx.writeWorkspaceFile("incremental_leaf.zig", "pub const value: u32 = 46;\n");
        try expectBuild(ctx, mode, &.{ "--strategy=ZigIncrementalCompile=sandboxed", "--@rules_zig//zig/settings:zigopt=--dynamic-linker", "--@rules_zig//zig/settings:zigopt=" });
        try expectProgram(ctx, "bazel-bin/incremental", "46:world\n");
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

test "bounded sessions retain alternating targets and evict the least recently used compiler" {
    if (builtin.os.tag != .linux or builtin.cpu.arch != .x86_64) return error.SkipZigTest;
    const ctx = try BitContext.init();
    defer ctx.deinit();
    defer {
        const shutdown = ctx.exec_bazel(.{ .argv = &.{"shutdown"} }) catch null;
        if (shutdown) |result| result.deinit();
    }
    const info = try ctx.exec_bazel(.{ .argv = &.{ "info", "output_base" } });
    defer info.deinit();
    try std.testing.expect(info.success);
    const output_base = std.mem.trim(u8, info.stdout, "\r\n");
    // BitContext keeps one workspace for the test binary. The preceding
    // sandbox test deliberately changes this module and its embed-file alias.
    try ctx.writeWorkspaceFile("incremental_module.zig", "pub const value = @import(\"incremental_leaf.zig\").value;\npub const message = \"hello\\n\";\n");
    try ctx.writeWorkspaceFile("incremental_generated.txt", "");
    try ctx.writeWorkspaceFile("incremental_external.zig", "pub const bias: u32 = 0;\n");
    const mode = &.{ "--worker_sandboxing", "--experimental_worker_sandbox_hardening" };
    const extra = &.{"--worker_extra_flag=ZigIncrementalCompile=--max-sessions=2"};
    const targets = [_][]const u8{ "//:incremental", "//:incremental_test", "//:incremental", "//:incremental_static", "//:incremental_test" };
    const expected = [_][]const u8{
        "generation=1 reused=false", "generation=2 reused=false", "generation=1 reused=true",
        "generation=3 reused=false", "generation=4 reused=false",
    };
    var first_compiler: ?[]u8 = null;
    defer if (first_compiler) |path| a.free(path);
    for (targets, expected, 0..) |target, record, i| {
        const source = try std.fmt.allocPrint(a, "pub const value: u32 = {d};\n", .{42 + 2 * i});
        defer a.free(source);
        try ctx.writeWorkspaceFile("incremental_leaf.zig", source);
        try ctx.writeWorkspaceFile("incremental_value.zig", source);
        try expectTarget(ctx, mode, extra, target);
        const logs = try workerLogs(output_base);
        defer a.free(logs);
        const start = std.mem.lastIndexOf(u8, logs, "zig-worker generation=") orelse return error.MissingWorkerTelemetry;
        try std.testing.expect(std.mem.startsWith(u8, logs[start..], "zig-worker "));
        try std.testing.expect(std.mem.startsWith(u8, logs[start + "zig-worker ".len ..], record));
        if (i == 0) first_compiler = try compilerProcess(output_base);
        if (i == 2) {
            const command = try std.fs.path.join(a, &.{ first_compiler.?, "cmdline" });
            defer a.free(command);
            const bytes = try readProc(.cwd(), command);
            defer a.free(bytes);
            try std.testing.expect(std.mem.find(u8, bytes, "--listen=-") != null);
            try expectProgram(ctx, "bazel-bin/incremental", "46:hello\n");
        }
        if (std.mem.eql(u8, target, "//:incremental_test")) try expectTestProgram(ctx, true);
    }
    // A was least recently used when the final B arrived. Its process must
    // have been reaped, rather than retained beyond the configured bound.
    const old_command = try std.fs.path.join(a, &.{ first_compiler.?, "cmdline" });
    defer a.free(old_command);
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().openFile(io, old_command, .{}));
    try expectProgram(ctx, "bazel-bin/incremental", "46:hello\n");
}

test "incremental tests and libraries preserve updates and reject unsupported configurations" {
    if (builtin.os.tag != .linux or builtin.cpu.arch != .x86_64) return error.SkipZigTest;
    const ctx = try BitContext.init();
    defer ctx.deinit();
    defer {
        const shutdown = ctx.exec_bazel(.{ .argv = &.{"shutdown"} }) catch null;
        if (shutdown) |result| result.deinit();
    }
    const info = try ctx.exec_bazel(.{ .argv = &.{ "info", "output_base" } });
    defer info.deinit();
    try std.testing.expect(info.success);
    const output_base = std.mem.trim(u8, info.stdout, "\r\n");
    const modes = [_][]const []const u8{
        &.{"--noworker_sandboxing"},
        &.{"--worker_sandboxing"},
        &.{ "--worker_sandboxing", "--experimental_worker_sandbox_hardening" },
    };
    const self_backend = &.{ "--@rules_zig//zig/settings:zigopt=-fno-llvm", "--@rules_zig//zig/settings:zigopt=-fno-lld" };
    const llvm_backend = &.{ "--@rules_zig//zig/settings:zigopt=-fllvm", "--@rules_zig//zig/settings:zigopt=-flld" };
    for (modes, 0..) |mode, index| {
        std.debug.print("Test/library worker mode {d}\n", .{index});
        for ([_][]const []const u8{ self_backend, llvm_backend }) |backend| {
            try ctx.writeWorkspaceFile("incremental_value.zig", "pub const value: u32 = 42;\n");
            try expectTarget(ctx, mode, backend, "//:incremental_test");
            try expectTestProgram(ctx, true);
            const compiler = try compilerProcess(output_base);
            defer a.free(compiler);
            if (index == 2) try expectHardened(ctx, compiler);
            try ctx.writeWorkspaceFile("incremental_value.zig", "pub const value: u32 = 44;\n");
            try expectTarget(ctx, mode, backend, "//:incremental_test");
            try expectTestProgram(ctx, true);
            const reused = try compilerProcess(output_base);
            defer a.free(reused);
            try std.testing.expectEqualStrings(compiler, reused);
            try ctx.writeWorkspaceFile("incremental_value.zig", "pub const value: u32 = 43;\n");
            try expectTarget(ctx, mode, backend, "//:incremental_test");
            try expectTestProgram(ctx, false);
        }
        const compiler = try compilerProcess(output_base);
        defer a.free(compiler);
        const cmd_path = try std.fs.path.join(a, &.{ compiler, "cmdline" });
        defer a.free(cmd_path);
        const command = try readProc(.cwd(), cmd_path);
        defer a.free(command);
        const sdk = command[0..std.mem.findScalar(u8, command, 0).?];
        const targets = [_][]const u8{ "//:incremental_static", "//:incremental_static", "//:incremental_shared" };
        const libraries = [_][]const u8{ "bazel-bin/libincremental_static.a", "bazel-bin/libincremental_static.a", "bazel-bin/libincremental_custom.so" };
        const backends = [_][]const []const u8{ self_backend, llvm_backend, llvm_backend };
        for (targets, libraries, backends) |target, library, backend| {
            try ctx.writeWorkspaceFile("incremental_value.zig", "pub const value: u32 = 42;\n");
            try expectTarget(ctx, mode, backend, target);
            const first = try compilerProcess(output_base);
            defer a.free(first);
            try expectLibrary(ctx, sdk, library, "42\n");
            try ctx.writeWorkspaceFile("incremental_value.zig", "pub const value: u32 = 44;\n");
            try expectTarget(ctx, mode, backend, target);
            const second = try compilerProcess(output_base);
            defer a.free(second);
            try std.testing.expectEqualStrings(first, second);
            try expectLibrary(ctx, sdk, library, "44\n");
            // The non-worker strategy still requests incremental compiler mode.
            try ctx.writeWorkspaceFile("incremental_value.zig", "pub const value: u32 = 46;\n");
            try expectTarget(ctx, mode, &.{ "--strategy=ZigIncrementalCompile=sandboxed", "--@rules_zig//zig/settings:zigopt=-fllvm", "--@rules_zig//zig/settings:zigopt=-flld" }, target);
            try expectLibrary(ctx, sdk, library, "46\n");
        }
    }
    const rejected = [_][]const []const u8{
        &.{},
        self_backend,
        &.{"--@rules_zig//zig/settings:zigopt=-fllvm"},
        &.{ "--@rules_zig//zig/settings:zigopt=-fllvm", "--@rules_zig//zig/settings:zigopt=-flld", "--@rules_zig//zig/settings:zigopt=-fno-lld" },
        &.{ "--@rules_zig//zig/settings:zigopt=-fllvm", "--@rules_zig//zig/settings:zigopt=-flld", "--@rules_zig//zig/settings:zigopt=-fno-llvm" },
    };
    for (rejected) |backend| {
        const result = try buildTarget(ctx, modes[2], backend, "//:incremental_shared");
        defer result.deinit();
        try expectFailure(result, "shared libraries require LLVM (-fllvm or LLVM output) and explicit -flld");
    }
    const platform = try buildTarget(ctx, modes[2], &.{"--platforms=//:aarch64_linux"}, "//:incremental_static");
    defer platform.deinit();
    try expectFailure(platform, "supports x86_64-linux targets only");
    const versioned = try buildTarget(ctx, modes[2], &.{ "--@rules_zig//zig/settings:zigopt=-fllvm", "--@rules_zig//zig/settings:zigopt=-flld", "--@rules_zig//zig/settings:zigopt=--version", "--@rules_zig//zig/settings:zigopt=1.2.3" }, "//:incremental_shared");
    defer versioned.deinit();
    try expectFailure(versioned, "versioned shared-library artifacts (--version) are unsupported");
    try expectTarget(ctx, modes[2], llvm_backend, "//:incremental_shared");
    try ctx.writeWorkspaceFile("incremental_value.zig", "pub const value: u32 = 44;\n");
    const bazel_test = try ctx.exec_bazel(.{ .argv = &.{ "test", "--@rules_zig//zig/settings:incremental", "--worker_sandboxing", "--experimental_worker_sandbox_hardening", "--test_output=errors", "//:incremental_test" } });
    defer bazel_test.deinit();
    try std.testing.expect(bazel_test.success);
}

test "requested outputs follow retained edits and one-shot compilation" {
    if (builtin.os.tag != .linux or builtin.cpu.arch != .x86_64) return error.SkipZigTest;
    const ctx = try BitContext.init();
    defer ctx.deinit();
    defer {
        const shutdown = ctx.exec_bazel(.{ .argv = &.{"shutdown"} }) catch null;
        if (shutdown) |result| result.deinit();
    }
    const info = try ctx.exec_bazel(.{ .argv = &.{ "info", "output_base" } });
    defer info.deinit();
    try std.testing.expect(info.success);
    const output_base = std.mem.trim(u8, info.stdout, "\r\n");
    const mode = &.{ "--worker_sandboxing", "--experimental_worker_sandbox_hardening" };
    const cases = .{
        .{ "binary_outputs", &.{ "s", "ll", "bc" } },
        .{ "test_outputs", &.{"bc"} },
        .{ "static_outputs", &.{ "s", "ll", "bc" } },
        .{ "shared_outputs", &.{"ll"} },
    };
    inline for (cases) |case| {
        const target = "//:" ++ case[0];
        try ctx.writeWorkspaceFile("incremental_value.zig", "pub const value: u32 = 42;\n");
        try expectTarget(ctx, mode, &.{"--output_groups=+asm,+llvm_ir,+llvm_bc"}, target);
        const compiler = try compilerProcess(output_base);
        defer a.free(compiler);
        var workspace = try ctx.openWorkspace();
        defer workspace.close(io);
        inline for (case[1]) |extension| {
            try workspace.copyFile("bazel-bin/" ++ case[0] ++ "." ++ extension, workspace, "saved-" ++ case[0] ++ "." ++ extension, io, .{});
        }
        // All requested files must update, while the previously published copies
        // stay independent of the compiler's mutable cache.
        for ([_]u32{ 44, 46 }) |value| {
            const source = try std.fmt.allocPrint(a, "pub const value: u32 = {d};\n", .{value});
            defer a.free(source);
            try ctx.writeWorkspaceFile("incremental_value.zig", source);
            const strategy: []const u8 = if (value == 44) "--strategy=ZigIncrementalCompile=worker" else "--strategy=ZigIncrementalCompile=sandboxed";
            try expectTarget(ctx, mode, &.{ "--output_groups=+asm,+llvm_ir,+llvm_bc", strategy }, target);
            if (value == 44) {
                const reused = try compilerProcess(output_base);
                defer a.free(reused);
                try std.testing.expectEqualStrings(compiler, reused);
            }
            inline for (case[1]) |extension| {
                const current = try ctx.readWorkspaceFileAlloc("bazel-bin/" ++ case[0] ++ "." ++ extension, 64 * 1024 * 1024);
                defer a.free(current);
                const saved = try ctx.readWorkspaceFileAlloc("saved-" ++ case[0] ++ "." ++ extension, 64 * 1024 * 1024);
                defer a.free(saved);
                try std.testing.expect(current.len > 0);
                try std.testing.expect(!std.mem.eql(u8, current, saved));
                if (comptime std.mem.eql(u8, extension, "bc")) {
                    try std.testing.expect(std.mem.startsWith(u8, current, "BC\xc0\xde"));
                }
                if (comptime std.mem.eql(u8, extension, "ll") and !std.mem.eql(u8, case[0], "binary_outputs")) {
                    const expected = try std.fmt.allocPrint(a, "ret i32 {d}", .{value});
                    defer a.free(expected);
                    try std.testing.expect(std.mem.find(u8, current, expected) != null);
                    try std.testing.expect(std.mem.find(u8, saved, "ret i32 42") != null);
                }
            }
            if (comptime std.mem.eql(u8, case[0], "binary_outputs")) {
                try expectProgram(ctx, "bazel-bin/binary_outputs", if (value == 44) "44\n" else "46\n");
            } else if (comptime std.mem.eql(u8, case[0], "test_outputs")) {
                try expectProgram(ctx, "bazel-bin/test_outputs", "");
            } else if (comptime std.mem.eql(u8, case[0], "static_outputs")) {
                try std.testing.expect(!try ctx.workspaceFileExists("bazel-bin/libstatic_outputs.a"));
            } else {
                const command_path = try std.fs.path.join(a, &.{ compiler, "cmdline" });
                defer a.free(command_path);
                const command = try readProc(.cwd(), command_path);
                defer a.free(command);
                const sdk = command[0..std.mem.findScalar(u8, command, 0).?];
                try expectLibrary(ctx, sdk, "bazel-bin/liboutputs_custom.so", if (value == 44) "44\n" else "46\n");
            }
        }
    }
    const rejected = try buildTarget(ctx, mode, &.{"--@rules_zig//zig/settings:zigopt=-fno-llvm"}, "//:shared_outputs");
    defer rejected.deinit();
    try expectFailure(rejected, "shared libraries require LLVM");
}
