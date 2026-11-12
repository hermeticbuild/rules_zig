//! Singleplex Bazel adapter for Zig 0.17's incremental compiler protocol.
const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Dir = Io.Dir;
const Allocator = std.mem.Allocator;

// Route SIGTERM through a self-pipe so cleanup runs outside the signal handler.
// Normal control flow cancels and joins the serving task before stopping Zig
// and removing the worker's private tree.
const Shutdown = struct {
    var requested: std.atomic.Value(bool) = .init(false);
    var notify_fd: std.posix.fd_t = undefined;

    fn init(io: Io) !Io.File {
        const posix = std.posix;
        var fds: [2]posix.fd_t = undefined;
        if (posix.errno(posix.system.pipe(&fds)) != .SUCCESS) return error.SignalPipeFailed;
        errdefer Io.File.closeMany(io, &.{
            .{ .handle = fds[0], .flags = .{ .nonblocking = false } },
            .{ .handle = fds[1], .flags = .{ .nonblocking = false } },
        });
        for (fds) |fd| {
            if (posix.errno(posix.system.fcntl(fd, posix.F.SETFD, @as(usize, posix.FD_CLOEXEC))) != .SUCCESS) {
                return error.SignalPipeFailed;
            }
        }

        notify_fd = fds[1];
        const action: posix.Sigaction = .{
            .handler = .{ .handler = handle },
            .mask = posix.sigemptyset(),
            .flags = posix.SA.RESTART,
        };
        posix.sigaction(.TERM, &action, null);

        // Keep both descriptors until process exit: an in-flight handler must
        // never write to a closed or recycled descriptor. CLOEXEC keeps them
        // out of compiler children.
        return .{ .handle = fds[0], .flags = .{ .nonblocking = false } };
    }

    fn handle(_: std.posix.SIG) callconv(.c) void {
        // Only the first signal writes, so the pipe cannot fill or block.
        if (requested.swap(true, .monotonic)) return;
        const saved_errno = if (builtin.link_libc) std.c._errno().* else 0;
        defer if (builtin.link_libc) {
            std.c._errno().* = saved_errno;
        };
        const byte = [_]u8{0};
        while (std.posix.errno(std.posix.system.write(notify_fd, &byte, byte.len)) == .INTR) {}
    }

    fn wait(file: Io.File, io: Io) !void {
        var byte: [1]u8 = undefined;
        _ = try file.readStreaming(io, &.{&byte});
    }
};

const Input = struct {
    path: []const u8,
    digest: []const u8 = "",
};

const Request = struct {
    arguments: []const []const u8 = &.{},
    inputs: []const Input = &.{},
    requestId: i32 = 0,
    cancel: bool = false,
    sandboxDir: []const u8 = "",
};

const Response = struct {
    requestId: i32,
    exitCode: u8,
    output: []const u8,
};

// These controls come from the action owner, never from a parsed compiler argv.
const OutputKind = enum {
    executable,
    object,
    static_library,
    shared_library,
};

const EmitKind = enum {
    bin,
    @"asm",
    llvm_ir,
    llvm_bc,
};

const EmittedOutput = struct {
    kind: EmitKind,
    path: []const u8,
};

const Compilation = struct {
    command: []const u8,
    output_kind: OutputKind,
    name: []const u8,
    target: []const u8,
    outputs: []const EmittedOutput,
    arguments: []const []const u8,
    input_paths: []const []const u8,

    const Metadata = struct {
        command: []const u8,
        output_kind: OutputKind,
        name: []const u8,
        target: []const u8,
        outputs: []const EmitKind,
    };

    fn parse(a: Allocator, data: []const []const u8) !Compilation {
        if (data.len < 3) {
            return error.InvalidCompilationRequest;
        }

        const metadata = try std.json.parseFromSliceLeaky(Metadata, a, data[0], .{});
        if (metadata.outputs.len == 0 or metadata.outputs.len > data.len - 2) {
            return error.InvalidCompilationRequest;
        }

        const arguments_start = 1 + metadata.outputs.len;
        const outputs = try a.alloc(EmittedOutput, metadata.outputs.len);
        var emitted: std.EnumSet(EmitKind) = .empty;
        for (outputs, metadata.outputs, data[1..arguments_start]) |*output, kind, path| {
            if (emitted.contains(kind)) {
                return error.InvalidCompilationRequest;
            }

            emitted.insert(kind);
            try safePath(path, false);
            output.* = .{ .kind = kind, .path = path };
        }

        if (!emitted.contains(.bin) and metadata.output_kind != .static_library) {
            return error.UnsupportedCompilationRequest;
        }

        if (data.len < arguments_start) return error.InvalidCompilationRequest;

        // Inputs are prefixed records, so the final '--' always frames them,
        // independently of empty arguments or '--' in the compiler vector.
        const boundary = for (0..data.len - arguments_start) |n| {
            const i = data.len - 1 - n;
            if (std.mem.eql(u8, data[i], "--")) break i;
        } else return error.InvalidCompilationRequest;

        const paths = try a.alloc([]const u8, data.len - boundary - 1);
        for (paths, data[boundary + 1 ..]) |*path, record| {
            path.* = std.mem.cutPrefix(u8, record, "input=") orelse return error.InvalidCompilationRequest;
            try safePath(path.*, true);
        }

        const result: Compilation = .{
            .command = metadata.command,
            .output_kind = metadata.output_kind,
            .name = metadata.name,
            .target = metadata.target,
            .outputs = outputs,
            .arguments = data[arguments_start..boundary],
            .input_paths = paths,
        };

        const valid_command = switch (result.output_kind) {
            .executable => std.mem.eql(u8, result.command, "build-exe") or std.mem.eql(u8, result.command, "test"),
            .object => std.mem.eql(u8, result.command, "test-obj"),
            .static_library, .shared_library => std.mem.eql(u8, result.command, "build-lib"),
        };

        if (!valid_command) {
            return error.UnsupportedCompilationRequest;
        }

        if (result.name.len == 0 or !std.mem.eql(u8, std.fs.path.basename(result.name), result.name)) {
            return error.InvalidCompilationName;
        }

        _ = try result.binNameOptions();
        return result;
    }

    fn checkConfiguration(self: Compilation, diagnostics: *Io.Writer) !void {
        if (self.output_kind == .shared_library) {
            const emits_llvm = for (self.outputs) |output| {
                if (output.kind == .llvm_ir or output.kind == .llvm_bc) break true;
            } else false;

            try checkSharedLibraryArgs(self.arguments, emits_llvm, diagnostics);
        }
    }

    fn inputs(self: Compilation, a: Allocator, supplied: []const Input) ![]const Input {
        var digests: std.StringHashMapUnmanaged([]const u8) = .empty;
        defer digests.deinit(a);

        for (supplied) |input| {
            try digests.put(a, input.path, input.digest);
        }

        const result = try a.alloc(Input, self.input_paths.len);
        for (result, self.input_paths) |*input, path| {
            // The action-owned list is authoritative in both execution modes.
            // Missing/empty digests mean copy again, never assume unchanged.
            input.* = .{ .path = path, .digest = digests.get(path) orelse "" };
        }

        return result;
    }

    fn binNameOptions(self: Compilation) !std.zig.BinNameOptions {
        const target = try std.Target.Query.parse(.{ .arch_os_abi = self.target });
        // Naming follows the action's target, never native host defaults.
        const arch = target.cpu_arch orelse return error.InvalidCompilationTarget;
        const os = target.os_tag orelse return error.InvalidCompilationTarget;
        return .{
            .root_name = self.name,
            .cpu_arch = arch,
            .os_tag = os,
            .abi = target.abi orelse std.Target.Abi.default(arch, os),
            .ofmt = std.Target.ObjectFormat.default(os, arch),
            .output_mode = switch (self.output_kind) {
                .executable => .Exe,
                .object => .Obj,
                .static_library, .shared_library => .Lib,
            },
            .link_mode = if (self.output_kind == .shared_library) .dynamic else .static,
        };
    }

    fn artifactName(self: Compilation, a: Allocator, kind: EmitKind) ![]const u8 {
        const artifact: std.zig.EmitArtifact = switch (kind) {
            .bin => .bin,
            .@"asm" => .@"asm",
            .llvm_ir => .llvm_ir,
            .llvm_bc => .llvm_bc,
        };
        return artifact.cacheName(a, try self.binNameOptions());
    }
};

fn checkSharedLibraryArgs(arguments: []const []const u8, emits_llvm: bool, diagnostics: *Io.Writer) !void {
    var llvm = emits_llvm;
    var lld = false;
    // This is a capability check, not a Zig argument parser. Flag-shaped
    // operands can cause false acceptance or rejection; that ambiguity is
    // accepted to avoid maintaining Zig's option-arity table.
    for (arguments) |arg| {
        if (std.mem.eql(u8, arg, "--version")) {
            try diagnostics.writeAll("zig incremental compilation: versioned shared-library artifacts (--version) are unsupported\n");
            return error.UnsupportedSharedLibraryVersion;
        }
        // These global switches use their last occurrence, as in Zig itself.
        if (std.mem.eql(u8, arg, "-fllvm")) llvm = true;
        if (std.mem.eql(u8, arg, "-fno-llvm")) llvm = false;
        if (std.mem.eql(u8, arg, "-flld")) lld = true;
        if (std.mem.eql(u8, arg, "-fno-lld")) lld = false;
    }

    if (!llvm or !lld) {
        try diagnostics.writeAll("zig incremental compilation: shared libraries require LLVM (-fllvm or LLVM output) and explicit -flld; the Zig 0.17 self-hosted shared-library configuration is unsupported\n");
        return error.UnsupportedSharedLibraryBackend;
    }
}

fn readLines(a: Allocator, io: Io, path: []const u8, result: *std.array_list.Managed([]const u8)) !void {
    const contents = try Dir.cwd().readFileAlloc(io, path, a, .limited(16 * 1024 * 1024));
    if (contents.len == 0) {
        return;
    }

    const end = contents.len - @intFromBool(contents[contents.len - 1] == '\n');
    var lines = std.mem.splitScalar(u8, contents[0..end], '\n');
    while (lines.next()) |line| {
        try result.append(line);
    }
}

// User-supplied response files are unsupported. Zig reads their options
// only at startup, so changed contents would not update a reused compiler.
// Nested response files can also discard remaining outer arguments.
// Our generated response file is derived entirely from the session-key argv.
fn appendResponseFile(argv: *std.array_list.Managed([]const u8), io: Io, root: []const u8, arguments: []const []const u8) !void {
    if (arguments.len == 0) {
        return;
    }

    const a = argv.allocator;
    const path = try std.fs.path.join(a, &.{ root, "compiler.args" });
    const file = try Dir.cwd().createFile(io, path, .{});
    defer file.close(io);
    var buffer: [8192]u8 = undefined;
    var flags = file.writer(io, &buffer);
    try writeResponseArguments(&flags.interface, arguments);
    try flags.interface.flush();
    try argv.append(try std.fmt.allocPrint(a, "@{s}", .{path}));
}

fn writeResponseArguments(writer: *Io.Writer, arguments: []const []const u8) !void {
    for (arguments) |arg| {
        try writer.writeByte('"');

        var backslashes: usize = 0;
        for (arg) |c| {
            if (c == '\\') {
                backslashes += 1;
                continue;
            }

            // The response parser halves backslashes only before a quote.
            const count = if (c == '"')
                backslashes * 2 + 1
            else
                backslashes;

            for (0..count) |_| {
                try writer.writeByte('\\');
            }

            backslashes = 0;
            try writer.writeByte(c);
        }

        for (0..backslashes * 2) |_| {
            try writer.writeByte('\\');
        }

        try writer.writeAll("\"\n");
    }
}

const Session = struct {
    arena: std.heap.ArenaAllocator,
    key: []const u8,
    root: []const u8,
    cwd: []const u8,
    artifact_dir: ?[]const u8 = null,
    generation: usize,
    stderr: Io.File,
    stderr_offset: u64 = 0,
    inputs: std.StringHashMapUnmanaged([]const u8) = .empty,
    child: std.process.Child,
    reader: Io.File.Reader,
    writer: Io.File.Writer,
    read_buffer: [8192]u8 = undefined,
    write_buffer: [256]u8 = undefined,

    fn destroy(self: *Session, gpa: Allocator, io: Io) void {
        self.child.kill(io);
        self.stderr.close(io);
        if (self.artifact_dir) |path| Dir.cwd().deleteTree(io, path) catch {};
        Dir.cwd().deleteTree(io, self.root) catch {};
        self.clearInputs(gpa);
        self.arena.deinit();
        gpa.destroy(self);
    }

    fn clearInputs(self: *Session, gpa: Allocator) void {
        var entries = self.inputs.iterator();
        while (entries.next()) |entry| {
            gpa.free(entry.key_ptr.*);
            gpa.free(entry.value_ptr.*);
        }
        self.inputs.deinit(gpa);
    }
};

const Worker = struct {
    gpa: Allocator,
    io: Io,
    zig: []const u8,
    lib: []const u8,
    zig_input: []const u8,
    lib_input: []const u8,
    root: []const u8,
    cache: []const u8,
    session: ?*Session = null,
    generation: usize = 0,
    message_buffer: std.ArrayList(u8) = .empty,

    fn reset(self: *Worker) void {
        if (self.session) |s| s.destroy(self.gpa, self.io);
        self.session = null;
    }

    fn deinit(self: *Worker) void {
        self.reset();
        self.message_buffer.deinit(self.gpa);
    }

    fn start(self: *Worker, compilation: Compilation, key: []const u8, arguments: []const []const u8, inputs: []const Input, request_allocator: Allocator) !*Session {
        self.reset();
        if (Shutdown.requested.load(.monotonic)) return error.Canceled;
        self.generation += 1;

        const s = try self.gpa.create(Session);
        errdefer self.gpa.destroy(s);

        var arena = std.heap.ArenaAllocator.init(self.gpa);
        errdefer arena.deinit();

        const a = arena.allocator();

        const root = try std.fmt.allocPrint(a, "{s}/session-{d}", .{ self.root, self.generation });
        const cwd = try std.fs.path.join(a, &.{ root, "execroot", "main" });
        try Dir.cwd().createDirPath(self.io, cwd);
        errdefer Dir.cwd().deleteTree(self.io, root) catch {};

        // Expose the declared SDK at its logical input paths without copying it.
        // Only these paths are tool-owned; source symlinks into the SDK are still
        // ordinary declared inputs and must be materialized under their aliases.
        for ([_][2][]const u8{ .{ self.zig_input, self.zig }, .{ self.lib_input, self.lib } }) |tool| {
            if (std.fs.path.isAbsolute(tool[0])) {
                continue;
            }

            try safePath(tool[0], true);
            const destination = try std.fs.path.join(a, &.{ cwd, tool[0] });
            try Dir.cwd().createDirPath(self.io, std.fs.path.dirname(destination).?);
            try Dir.cwd().symLink(self.io, tool[1], destination, .{});
        }

        // Zig hashes the root module's include paths into the incremental
        // output directory. An empty directory unique to this session keeps
        // mutable outputs isolated inside the shared cache.
        const empty_include = try std.fs.path.join(a, &.{ root, "empty-include" });
        try Dir.cwd().createDir(self.io, empty_include, .default_dir);

        var argv: std.array_list.Managed([]const u8) = .init(a);
        try argv.appendSlice(&.{
            self.zig,
            compilation.command,
            "--listen=-",
            "-fincremental",
            "--name",
            compilation.name,
            "--cache-dir",
            self.cache,
            "--global-cache-dir",
            self.cache,
            "--zig-lib-dir",
            self.lib,
            "-I",
            empty_include,
        });

        switch (compilation.output_kind) {
            .static_library => try argv.append("-static"),
            .shared_library => try argv.append("-dynamic"),
            .executable => if (std.mem.eql(u8, compilation.command, "test")) try argv.append("--test-no-exec"),
            .object => try argv.append("--test-no-exec"),
        }

        var emit_bin = false;
        for (compilation.outputs) |output| {
            try argv.append(switch (output.kind) {
                .bin => "-femit-bin",
                .@"asm" => "-femit-asm",
                .llvm_ir => "-femit-llvm-ir",
                .llvm_bc => "-femit-llvm-bc",
            });

            if (output.kind == .bin) {
                emit_bin = true;
            }
        }

        if (!emit_bin) {
            try argv.append("-fno-emit-bin");
        }

        // Zig 0.17 cannot encode apostrophes in response files and consumes
        // direct argv before response contents. Use one representation for the
        // entire semantic vector so module dependency ordering stays intact.
        const direct = for (arguments) |arg| {
            if (std.mem.findScalar(u8, arg, '\'') != null) break true;
        } else false;

        // Raw arguments pass through unchanged. They must preserve the adapter's
        // protocol, incremental mode, SDK/cache locations, and output metadata.
        // Conflicting overrides are not validated: they can fail publication,
        // break the protocol, or hang when the compiler stops speaking on stdio.
        if (direct)
            try argv.appendSlice(arguments)
        else
            try appendResponseFile(&argv, self.io, root, arguments);

        const stderr = try Dir.cwd().createFile(self.io, try std.fs.path.join(a, &.{ root, "stderr" }), .{ .read = true });
        errdefer stderr.close(self.io);

        const owned_key = try a.dupe(u8, key);
        s.* = .{
            .arena = arena,
            .key = owned_key,
            .root = root,
            .cwd = cwd,
            .generation = self.generation,
            .stderr = stderr,
            .child = undefined,
            .reader = undefined,
            .writer = undefined,
        };
        errdefer s.clearInputs(self.gpa);

        // The compiler resolves module roots during startup, before `update`.
        _ = try self.materialize(s, inputs, request_allocator, true);

        const child = try std.process.spawn(self.io, .{
            .argv = argv.items,
            .cwd = .{ .path = cwd },
            .stdin = .pipe,
            .stdout = .pipe,
            // A file avoids pipe backpressure while the compiler protocol is read.
            .stderr = .{ .file = stderr },
        });
        s.child = child;
        s.reader = child.stdout.?.readerStreaming(self.io, &s.read_buffer);
        s.writer = child.stdin.?.writerStreaming(self.io, &s.write_buffer);
        self.session = s;

        return s;
    }

    fn execute(self: *Worker, request: Request, a: Allocator, diagnostics: *Io.Writer) !u8 {
        return self.compile(request, a, diagnostics) catch |err| switch (err) {
            error.EndOfStream, error.ReadFailed, error.WriteFailed => {
                // Readers erase Canceled to ReadFailed. Termination must not
                // be mistaken for a dead compiler and start a replacement.
                if (Shutdown.requested.load(.monotonic)) return error.Canceled;
                std.log.warn("zig-worker compiler transport failed ({t}); restarting", .{err});
                self.reset();
                return self.compile(request, a, diagnostics);
            },
            else => return err,
        };
    }

    fn compile(self: *Worker, request: Request, a: Allocator, diagnostics: *Io.Writer) !u8 {
        if (request.requestId != 0 or request.cancel or request.sandboxDir.len != 0) {
            return error.OnlySingleplexSupported;
        }

        const compilation = try Compilation.parse(a, request.arguments);
        try compilation.checkConfiguration(diagnostics);
        const arguments = compilation.arguments;
        const inputs = try compilation.inputs(a, request.inputs);
        const key = try std.json.Stringify.valueAlloc(a, .{
            compilation.command,
            compilation.output_kind,
            compilation.name,
            compilation.target,
            compilation.outputs,
            arguments,
        }, .{});

        var reused = self.session != null and std.mem.eql(u8, self.session.?.key, key);

        const started_at = Io.Clock.awake.now(self.io);
        var s = if (reused)
            self.session.?
        else
            try self.start(compilation, key, arguments, inputs, a);

        const copied = if (reused)
            self.materialize(s, inputs, a, false) catch |err| switch (err) {
                error.InputSetChanged => blk: {
                    // Zig may report historical inputs after they become unreachable.
                    // A changed declared set gets a clean compiler and filesystem view.
                    reused = false;
                    s = try self.start(compilation, key, arguments, inputs, a);
                    break :blk s.inputs.count();
                },
                else => return err,
            }
        else
            s.inputs.count();

        defer self.appendStderr(s, diagnostics) catch {};

        const inputs_ready_at = Io.Clock.awake.now(self.io);

        // Artifact names are under our control, independent of Bazel's output path.
        const client: std.zig.Client = .{ .in = &s.reader.interface, .out = &s.writer.interface };
        try client.serveBodylessMessage(.update);

        var artifact_dir: ?[]const u8 = null;
        var digest_buffer: [std.Build.Cache.hex_digest_len]u8 = undefined;
        var digest_body: [1 + std.Build.Cache.bin_digest_len]u8 = undefined;
        var undeclared_input = false;
        while (true) {
            const hdr = try client.receiveMessage();

            if (hdr.bytes_len > 64 * 1024 * 1024) {
                return error.CompilerMessageTooLarge;
            }

            const body = switch (hdr.tag) {
                .emit_digest => blk: {
                    if (hdr.bytes_len != digest_body.len) {
                        try s.reader.interface.discardAll(hdr.bytes_len);
                        return error.InvalidEmitDigest;
                    }
                    try s.reader.interface.readSliceAll(&digest_body);
                    break :blk &digest_body;
                },
                .zig_version, .error_bundle, .file_system_inputs => blk: {
                    // These bodies are consumed before the next message. Keep
                    // scratch storage across messages, requests, and sessions.
                    try self.message_buffer.resize(self.gpa, hdr.bytes_len);
                    try s.reader.interface.readSliceAll(self.message_buffer.items);
                    break :blk self.message_buffer.items;
                },
                else => {
                    try s.reader.interface.discardAll(hdr.bytes_len);
                    continue;
                },
            };
            switch (hdr.tag) {
                .zig_version => {
                    const version = std.SemanticVersion.parse(body) catch return error.UnsupportedZigVersion;
                    if (version.major != 0 or version.minor != 17 or (version.patch == 0 and version.pre != null)) {
                        return error.UnsupportedZigVersion;
                    }
                },
                .emit_digest => {
                    const digest = try std.fmt.bufPrint(&digest_buffer, "{x}", .{body[1..]});
                    if (s.artifact_dir) |path| {
                        if (!std.mem.eql(u8, std.fs.path.basename(path), digest)) return error.InvalidEmitDigest;
                    } else {
                        s.artifact_dir = try std.fs.path.join(s.arena.allocator(), &.{ self.cache, "o", digest });
                    }
                    artifact_dir = s.artifact_dir;
                },
                .error_bundle => {
                    var bundle = try std.zig.Server.allocErrorBundle(a, body);
                    if (bundle.errorMessageCount() > 0) {
                        try bundle.renderToWriter(.{}, diagnostics);
                        return 1;
                    }

                    if (undeclared_input) {
                        return error.UndeclaredCompilerInput;
                    }

                    break;
                },
                .file_system_inputs => {
                    var paths = std.mem.splitScalar(u8, body, 0);
                    while (paths.next()) |path| {
                        if (path.len == 0) continue;
                        // cwd inputs must belong to this request. SDK and
                        // compiler-generated cache inputs have other prefixes.
                        // Trusting SDK/cache/build-root prefixes assumes their
                        // locations follow the adapter's configuration. Raw
                        // directory overrides can bypass declared-input checks.
                        if (path[0] == 1) {
                            // Zig can report sibling module roots as absolute
                            // paths. Normalize lexically against the staged cwd
                            // before checking membership and containment.
                            const relative = try std.fs.path.relativeAllocPosix(a, s.cwd, s.cwd, path[1..]);
                            safePath(relative, true) catch {
                                try diagnostics.print("zig incremental compilation: unsafe compiler input {s}\n", .{path[1..]});
                                undeclared_input = true;
                                continue;
                            };

                            if (!s.inputs.contains(relative) and !self.isToolInput(relative)) {
                                try diagnostics.print("zig incremental compilation: undeclared compiler input {s}\n", .{path[1..]});
                                undeclared_input = true;
                            }
                        } else if (path[0] < 2 or path[0] > 5) {
                            return error.InvalidCompilerInputPrefix;
                        }
                    }
                },
                else => {},
            }
        }

        const compiled_at = Io.Clock.awake.now(self.io);

        const artifacts = try a.alloc([]const u8, compilation.outputs.len);
        for (artifacts, compilation.outputs) |*artifact, output| {
            artifact.* = try std.fs.path.join(a, &.{
                artifact_dir orelse return error.MissingEmitDigest,
                try compilation.artifactName(a, output.kind),
            });

            Dir.cwd().access(self.io, artifact.*, .{}) catch |err| {
                try diagnostics.print("zig incremental compilation: requested {t} output was not produced: {s} ({t})\n", .{ output.kind, output.path, err });
                return error.MissingCompilerOutput;
            };
        }

        for (artifacts, compilation.outputs) |artifact, output| {
            // Atomic copy, never a hard link: Zig mutates the cached artifact in place.
            try Dir.cwd().copyFile(artifact, .cwd(), output.path, self.io, .{ .make_path = true });
        }

        const ms = started_at.untilNow(self.io, .awake).toMilliseconds();
        std.log.info("zig-worker generation={d} reused={} copied={d} duration_ms={d} input_ms={d} compile_ms={d} output_ms={d}", .{
            s.generation,
            reused,
            copied,
            ms,
            started_at.durationTo(inputs_ready_at).toMilliseconds(),
            inputs_ready_at.durationTo(compiled_at).toMilliseconds(),
            compiled_at.untilNow(self.io, .awake).toMilliseconds(),
        });

        return 0;
    }

    fn materialize(self: *Worker, s: *Session, inputs: []const Input, a: Allocator, fresh: bool) !usize {
        var present: std.StringHashMapUnmanaged(void) = .empty;
        var files: std.array_list.Managed(Input) = .init(a);
        for (inputs) |input| {
            try safePath(input.path, true);

            // Toolchain files belong to the worker key, not mutable source state.
            if (self.isToolInput(input.path)) {
                continue;
            }

            const stat = try Dir.cwd().statFile(self.io, input.path, .{});
            if (stat.kind == .directory) {
                var dir = try Dir.cwd().openDir(self.io, input.path, .{ .iterate = true });
                defer dir.close(self.io);

                var walker = try dir.walk(a);
                defer walker.deinit();

                while (try walker.next(self.io)) |entry| {
                    if (entry.kind == .directory) {
                        continue;
                    }

                    const path = try std.fs.path.join(a, &.{ input.path, entry.path });
                    try present.put(a, path, {});
                    try files.append(.{ .path = path, .digest = input.digest });
                }
            } else {
                try present.put(a, input.path, {});
                try files.append(input);
            }
        }

        if (!fresh) {
            if (present.count() != s.inputs.count()) {
                return error.InputSetChanged;
            }

            for (files.items) |input| if (!s.inputs.contains(input.path)) return error.InputSetChanged;
        }

        var copied: usize = 0;
        for (files.items) |input| copied += try self.materializeFile(s, input, a);

        return copied;
    }

    fn isToolInput(self: *const Worker, path: []const u8) bool {
        return std.mem.eql(u8, path, self.zig_input) or std.mem.eql(u8, path, self.lib_input) or
            (std.mem.startsWith(u8, path, self.lib_input) and path.len > self.lib_input.len and path[self.lib_input.len] == '/');
    }

    fn materializeFile(self: *Worker, s: *Session, input: Input, a: Allocator) !usize {
        if (s.inputs.get(input.path)) |previous| {
            if (input.digest.len != 0 and std.mem.eql(u8, previous, input.digest)) return 0;
        }

        const destination = try std.fs.path.join(a, &.{ s.cwd, input.path });
        // copyFile uses an atomic replacement with a new inode. This invalidates
        // Zig's size/inode/mtime shortcut even for metadata-preserving edits.
        try Dir.cwd().copyFile(input.path, .cwd(), destination, self.io, .{ .make_path = true });

        const new_digest = try self.gpa.dupe(u8, input.digest);
        errdefer self.gpa.free(new_digest);

        if (s.inputs.getPtr(input.path)) |previous| {
            self.gpa.free(previous.*);
            previous.* = new_digest;
        } else {
            const new_path = try self.gpa.dupe(u8, input.path);
            errdefer self.gpa.free(new_path);
            try s.inputs.put(self.gpa, new_path, new_digest);
        }

        return 1;
    }

    fn appendStderr(self: *Worker, s: *Session, diagnostics: *Io.Writer) !void {
        var buffer: [4096]u8 = undefined;
        while (true) {
            const n = try s.stderr.readPositional(self.io, &.{&buffer}, s.stderr_offset);
            if (n == 0) {
                return;
            }

            s.stderr_offset += n;
            try diagnostics.writeAll(buffer[0..n]);
        }
    }
};

fn safePath(path: []const u8, sibling: bool) !void {
    if (path.len == 0 or std.fs.path.isAbsolute(path)) {
        return error.InvalidInputPath;
    }

    // A single leading '..' is Bazel's sibling repository layout. The session
    // cwd is a child of its private execroot, so this remains worker-owned.
    const relative = if (sibling and std.mem.startsWith(u8, path, "../"))
        path[3..]
    else
        path;

    if (relative.len == 0) {
        return error.InvalidInputPath;
    }

    var parts = std.mem.tokenizeAny(u8, relative, "/\\");
    while (parts.next()) |part| if (std.mem.eql(u8, part, "..")) return error.InvalidInputPath;
}

pub fn main(init: std.process.Init) !u8 {
    const a = init.arena.allocator();
    const io = init.io;

    const args = try init.minimal.args.toSlice(a);
    var zig_path: ?[]const u8 = null;
    var lib_path: ?[]const u8 = null;
    var persistent = false;
    var flags: std.array_list.Managed([]const u8) = .init(a);
    for (args[1..]) |arg| {
        if (std.mem.startsWith(u8, arg, "--zig=")) {
            zig_path = arg[6..];
        } else if (std.mem.startsWith(u8, arg, "--lib=")) {
            lib_path = arg[6..];
        } else if (std.mem.eql(u8, arg, "--persistent_worker")) {
            persistent = true;
        } else if (std.mem.cutPrefix(u8, arg, "--compilation-output=")) |path| {
            // Routing identity for Bazel's worker pool, not a compiler option.
            try safePath(path, false);
        } else if (std.mem.startsWith(u8, arg, "@")) {
            try readLines(a, io, arg[1..], &flags);
        } else return error.InvalidStartupArgument;
    }

    const zig = try Dir.cwd().realPathFileAlloc(io, zig_path orelse return error.MissingZigPath, a);
    const lib = try Dir.cwd().realPathFileAlloc(io, lib_path orelse return error.MissingLibPath, a);
    // Bazel sets both cache variables to the same toolchain path for ordinary
    // and incremental actions. Resolve relative overrides before changing cwd.
    const configured_cache = init.environ_map.get("ZIG_LOCAL_CACHE_DIR") orelse return error.MissingCacheDirectory;
    if (persistent and !std.fs.path.isAbsolute(configured_cache)) {
        std.log.err("the Zig cache directory must be absolute for a persistent worker: {s}", .{configured_cache});
        return 1;
    }
    const cache = if (std.fs.path.isAbsolute(configured_cache)) configured_cache else blk: {
        const cwd = try Dir.cwd().realPathFileAlloc(io, ".", a);
        break :blk try std.fs.path.resolve(a, &.{ cwd, configured_cache });
    };

    // Install before creating state so SIGTERM cannot bypass its cleanup.
    const signal_file: ?Io.File = if (builtin.os.tag == .windows) null else try Shutdown.init(io);

    var nonce: [16]u8 = undefined;
    io.random(&nonce);

    // Linux's hardened worker sandbox supplies a worker-private persistent
    // /tmp. Do not derive paths from Bazel's internal worker directory layout,
    // or use an inherited TMPDIR that might point outside the writable sandbox.
    // SIGTERM follows normal cleanup. Without the hardened sandbox, SIGKILL
    // or a process crash can still leave this private directory behind.
    const root = try std.fmt.allocPrint(a, "/tmp/rules-zig-worker-{x}", .{&nonce});
    try Dir.cwd().createDir(io, root, .fromMode(0o700));

    var worker: Worker = .{
        .gpa = init.gpa,
        .io = io,
        .zig = zig,
        .lib = lib,
        .zig_input = zig_path.?,
        .lib_input = lib_path.?,
        .root = root,
        .cache = cache,
    };
    defer {
        worker.deinit();
        Dir.cwd().deleteTree(io, root) catch {};
    }

    if (signal_file) |file| {
        const Result = union(enum) { stopped: anyerror!void, completed: anyerror!u8 };
        var buffer: [2]Result = undefined;
        var tasks: Io.Select(Result) = .init(io, &buffer);
        // Join the serving task before touching its compiler or filesystem.
        defer tasks.cancelDiscard();
        try tasks.concurrent(.stopped, Shutdown.wait, .{ file, io });
        try tasks.concurrent(.completed, serve, .{ &worker, init, persistent, flags.items });
        return switch (try tasks.await()) {
            .stopped => |result| blk: {
                try result;
                break :blk 143;
            },
            .completed => |result| result,
        };
    }
    return serve(&worker, init, persistent, flags.items);
}

fn serve(worker: *Worker, init: std.process.Init, persistent: bool, flags: []const []const u8) !u8 {
    const a = init.arena.allocator();
    const io = init.io;

    if (!persistent) {
        var diagnostics: Io.Writer.Allocating = .init(a);
        const code = worker.execute(.{ .arguments = flags }, a, &diagnostics.writer) catch |err| blk: {
            if (Shutdown.requested.load(.monotonic)) return 143;
            try diagnostics.writer.print("zig incremental compilation: {t}\n", .{err});
            break :blk 1;
        };
        if (Shutdown.requested.load(.monotonic)) return 143;
        try Io.File.stderr().writeStreamingAll(io, diagnostics.written());
        // Return through the cleanup defers, including on a failed request.
        return code;
    }

    const in_buffer = try a.alloc(u8, 16 * 1024 * 1024);
    var out_buffer: [8192]u8 = undefined;
    var stdin = Io.File.stdin().readerStreaming(io, in_buffer);
    var stdout = Io.File.stdout().writerStreaming(io, &out_buffer);

    var request_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer request_arena.deinit();
    while (!Shutdown.requested.load(.monotonic)) {
        const line = try stdin.interface.takeDelimiter('\n') orelse break;
        // Reuse ordinary requests' storage without retaining an outlier forever.
        defer _ = request_arena.reset(.{ .retain_with_limit = 8 * 1024 * 1024 });

        const ra = request_arena.allocator();

        const request = try std.json.parseFromSliceLeaky(Request, ra, line, .{ .ignore_unknown_fields = true });

        var diagnostics: Io.Writer.Allocating = .init(ra);
        const code = worker.execute(request, ra, &diagnostics.writer) catch |err| blk: {
            if (Shutdown.requested.load(.monotonic)) return 143;
            worker.reset();
            try diagnostics.writer.print("zig incremental worker: {t}\n", .{err});
            break :blk 1;
        };

        if (Shutdown.requested.load(.monotonic)) return 143;
        try std.json.Stringify.value(Response{
            .requestId = request.requestId,
            .exitCode = code,
            .output = diagnostics.written(),
        }, .{}, &stdout.interface);

        try stdout.interface.writeByte('\n');
        try stdout.interface.flush();
    }

    return 0;
}

fn expectArtifactName(target: []const u8, output_kind: OutputKind, kind: EmitKind, expected: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const compilation: Compilation = .{
        .command = "",
        .output_kind = output_kind,
        .name = "probe",
        .target = target,
        .outputs = &.{},
        .arguments = &.{},
        .input_paths = &.{},
    };
    try std.testing.expectEqualStrings(expected, try compilation.artifactName(arena.allocator(), kind));
}

test "artifact names follow the compilation target and output kind" {
    try expectArtifactName("x86_64-linux", .executable, .bin, "probe");
    try expectArtifactName("x86_64-windows-msvc", .executable, .bin, "probe.exe");
    try expectArtifactName("x86_64-windows-msvc", .object, .bin, "probe.obj");
    try expectArtifactName("x86_64-windows-msvc", .static_library, .bin, "probe.lib");
    try expectArtifactName("x86_64-windows-msvc", .shared_library, .bin, "probe.dll");
}

test "artifact naming requires explicit architecture and OS" {
    try std.testing.expectError(error.InvalidCompilationTarget, expectArtifactName("native", .executable, .bin, "probe"));
    try std.testing.expectError(error.InvalidCompilationTarget, expectArtifactName("x86_64-native", .executable, .bin, "probe"));
}

const test_metadata =
    \\{"command":"build-lib","output_kind":"static_library","name":"probe","target":"x86_64-linux","outputs":["bin"]}
;

test "request framing uses the last separator and preserves compiler arguments" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const compilation = try Compilation.parse(arena.allocator(), &.{
        test_metadata, "out.a", "", "--", "-Mroot=main.zig", "--", "input=main.zig", "input=--",
    });
    try std.testing.expectEqual(@as(usize, 3), compilation.arguments.len);
    try std.testing.expectEqualStrings("", compilation.arguments[0]);
    try std.testing.expectEqualStrings("--", compilation.arguments[1]);
    try std.testing.expectEqualStrings("-Mroot=main.zig", compilation.arguments[2]);
    try std.testing.expectEqualStrings("main.zig", compilation.input_paths[0]);
    try std.testing.expectEqualStrings("--", compilation.input_paths[1]);
}

test "request framing rejects missing paths and separators" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectError(error.InvalidCompilationRequest, Compilation.parse(a, &.{}));
    try std.testing.expectError(error.InvalidCompilationRequest, Compilation.parse(a, &.{test_metadata}));
    try std.testing.expectError(error.InvalidCompilationRequest, Compilation.parse(a, &.{ test_metadata, "out.a" }));
    try std.testing.expectError(error.InvalidCompilationRequest, Compilation.parse(a, &.{ test_metadata, "out.a", "-Mroot=main.zig" }));
    const compilation = try Compilation.parse(a, &.{ test_metadata, "out.a", "--" });
    try std.testing.expectEqual(@as(usize, 0), compilation.arguments.len);
    try std.testing.expectEqual(@as(usize, 0), compilation.input_paths.len);
}
