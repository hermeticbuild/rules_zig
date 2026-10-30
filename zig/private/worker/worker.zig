//! Singleplex Bazel adapter for Zig 0.17's incremental compiler protocol.
const std = @import("std");
const Io = std.Io;
const Dir = Io.Dir;
const Allocator = std.mem.Allocator;

const Input = struct { path: []const u8, digest: []const u8 = "" };
const Request = struct {
    arguments: []const []const u8 = &.{},
    inputs: []const Input = &.{},
    requestId: i32 = 0,
    cancel: bool = false,
    sandboxDir: []const u8 = "",
};
const Response = struct { requestId: i32, exitCode: u8, output: []const u8 };

// These controls come from the action owner, never from a parsed compiler argv.
const OutputKind = enum { executable, static_library, shared_library };
const EmitKind = enum { bin, @"asm", llvm_ir, llvm_bc };
const EmittedOutput = struct { kind: EmitKind, path: []const u8 };
const Compilation = struct {
    command: []const u8,
    output_kind: OutputKind,
    name: []const u8,
    outputs: []const EmittedOutput,
    arguments: []const []const u8,
    input_paths: []const []const u8,

    const Metadata = struct {
        command: []const u8,
        output_kind: OutputKind,
        name: []const u8,
        outputs: []const EmitKind,
    };

    fn parse(a: Allocator, data: []const []const u8) !Compilation {
        if (data.len < 3) return error.InvalidCompilationRequest;
        const parsed = try std.json.parseFromSlice(Metadata, a, data[0], .{});
        const metadata = parsed.value;
        if (metadata.outputs.len == 0 or metadata.outputs.len > data.len - 2)
            return error.InvalidCompilationRequest;
        const arguments_start = 1 + metadata.outputs.len;
        const outputs = try a.alloc(EmittedOutput, metadata.outputs.len);
        var emitted: std.EnumSet(EmitKind) = .empty;
        for (outputs, metadata.outputs, data[1..arguments_start]) |*output, kind, path| {
            if (emitted.contains(kind)) return error.InvalidCompilationRequest;
            emitted.insert(kind);
            try safePath(path, false);
            output.* = .{ .kind = kind, .path = path };
        }
        if (!emitted.contains(.bin) and metadata.output_kind != .static_library)
            return error.UnsupportedCompilationRequest;
        // Inputs are prefixed records, so the final '--' always frames them,
        // independently of empty arguments or '--' in the compiler vector.
        var boundary = data.len;
        while (boundary > arguments_start) {
            boundary -= 1;
            if (std.mem.eql(u8, data[boundary], "--")) break;
        }
        if (!std.mem.eql(u8, data[boundary], "--")) return error.InvalidCompilationRequest;
        const paths = try a.alloc([]const u8, data.len - boundary - 1);
        for (paths, data[boundary + 1 ..]) |*path, record| {
            path.* = std.mem.cutPrefix(u8, record, "input=") orelse return error.InvalidCompilationRequest;
            try safePath(path.*, true);
        }
        const result: Compilation = .{
            .command = metadata.command,
            .output_kind = metadata.output_kind,
            .name = metadata.name,
            .outputs = outputs,
            .arguments = data[arguments_start..boundary],
            .input_paths = paths,
        };
        const valid_command = switch (result.output_kind) {
            .executable => std.mem.eql(u8, result.command, "build-exe") or std.mem.eql(u8, result.command, "test"),
            .static_library, .shared_library => std.mem.eql(u8, result.command, "build-lib"),
        };
        if (!valid_command)
            return error.UnsupportedCompilationRequest;
        if (result.name.len == 0 or !std.mem.eql(u8, std.fs.path.basename(result.name), result.name))
            return error.InvalidCompilationName;
        return result;
    }

    fn compilerArgs(self: Compilation, diagnostics: *Io.Writer) ![]const []const u8 {
        var i: usize = 0;
        while (i < self.arguments.len) : (i += 1) {
            const arg = self.arguments[i];
            if (reserved(arg) or (self.output_kind != .executable and (std.mem.eql(u8, arg, "-dynamic") or std.mem.eql(u8, arg, "-static")))) {
                try diagnostics.print("zig incremental compilation: option {s} is owned by rules_zig\n", .{arg});
                return error.ConflictingCompilerOption;
            }
            // Check the switch before skipping its value: worker-owned controls
            // must still fail if they reach the request.
            if (optionTakesValue(arg)) {
                i += 1;
            }
        }
        if (self.output_kind == .shared_library) {
            const emits_llvm = for (self.outputs) |output| {
                if (output.kind == .llvm_ir or output.kind == .llvm_bc) break true;
            } else false;
            try checkSharedLibraryArgs(self.arguments, emits_llvm, diagnostics);
        }
        return self.arguments;
    }

    fn inputs(self: Compilation, a: Allocator, supplied: []const Input) ![]const Input {
        var digests: std.StringHashMapUnmanaged([]const u8) = .empty;
        defer digests.deinit(a);
        for (supplied) |input| try digests.put(a, input.path, input.digest);
        const result = try a.alloc(Input, self.input_paths.len);
        for (result, self.input_paths) |*input, path| {
            // The action-owned list is authoritative in both execution modes.
            // Missing/empty digests mean copy again, never assume unchanged.
            input.* = .{ .path = path, .digest = digests.get(path) orelse "" };
        }
        return result;
    }

    fn artifactName(self: Compilation, a: Allocator, kind: EmitKind) ![]const u8 {
        return switch (kind) {
            .bin => switch (self.output_kind) {
                .executable => self.name,
                .static_library => std.fmt.allocPrint(a, "lib{s}.a", .{self.name}),
                .shared_library => std.fmt.allocPrint(a, "lib{s}.so", .{self.name}),
            },
            .@"asm" => std.fmt.allocPrint(a, "{s}.s", .{self.name}),
            .llvm_ir => std.fmt.allocPrint(a, "{s}.ll", .{self.name}),
            .llvm_bc => std.fmt.allocPrint(a, "{s}.bc", .{self.name}),
        };
    }
};

fn checkSharedLibraryArgs(arguments: []const []const u8, emits_llvm: bool, diagnostics: *Io.Writer) !void {
    var llvm = emits_llvm;
    var lld = false;
    var i: usize = 0;
    while (i < arguments.len) : (i += 1) {
        const arg = arguments[i];
        if (std.mem.eql(u8, arg, "--version")) {
            try diagnostics.writeAll("zig incremental compilation: versioned shared-library artifacts (--version) are unsupported\n");
            return error.UnsupportedSharedLibraryVersion;
        }
        if (std.mem.eql(u8, arg, "-cflags") or std.mem.eql(u8, arg, "-rcflags")) {
            try diagnostics.writeAll("zig incremental compilation: native compiler flag groups are unsupported\n");
            return error.UnsupportedNativeCompilerFlags;
        }
        if (optionTakesValue(arg)) {
            i += 1;
            continue;
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

fn optionTakesValue(arg: []const u8) bool {
    // Zig 0.17 src/main.zig's build-command option arity. This read-only
    // capability check must skip operands (even ones named '-flld'). It
    // neither constructs nor changes the compiler's semantic argv.
    for ([_][]const u8{
        "--dep",              "--error-limit",          "-rcincludes",       "--color",
        "--subsystem",        "-O",                     "--force_undefined", "--stack",
        "--image-base",       "--name",                 "-rpath",            "--library-directory",
        "-L",                 "-F",                     "-framework",        "-weak_framework",
        "-needed_framework",  "-install_name",          "-pagezero_size",    "-headerpad",
        "-T",                 "--script",               "-version-script",   "--version-script",
        "--library",          "-l",                     "--needed-library",  "-needed-l",
        "-needed_library",    "-weak_library",          "-weak-l",           "-D",
        "-I",                 "-isystem",               "-iwithsysroot",     "-idirafter",
        "-iframework",        "-iframeworkwithsysroot", "-target",           "-mcpu",
        "-mcmodel",           "--dynamic-linker",       "--sysroot",         "--libc",
        "--test-filter",      "--test-runner",          "--test-cmd",        "--cache-dir",
        "--global-cache-dir", "--zig-lib-dir",          "--build-root",      "--debug-log",
        "--listen",           "--entitlements",         "-z",                "-x",
    }) |option| {
        if (std.mem.eql(u8, arg, option)) {
            return true;
        }
    }
    return false;
}

test "request framing preserves empty operands and delimiter-shaped names" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const compilation = try Compilation.parse(arena.allocator(), &.{
        "{\"command\":\"build-exe\",\"output_kind\":\"executable\",\"name\":\"root\",\"outputs\":[\"bin\"]}",
        "bazel-out/cfg/bin/program",
        "--test-filter",
        "",
        "--",
        "input=operand",
        "--",
        "input=--",
        "input=bazel-out/cfg/bin/generated.zig",
    });
    try std.testing.expectEqualStrings("bazel-out/cfg/bin/program", compilation.outputs[0].path);
    try std.testing.expectEqualSlices([]const u8, &.{ "--test-filter", "", "--", "input=operand" }, compilation.arguments);
    const inputs = try compilation.inputs(arena.allocator(), &.{
        .{ .path = "--", .digest = "opaque" },
        .{ .path = "not-a-declared-input", .digest = "ignored" },
    });
    try std.testing.expectEqual(2, inputs.len);
    try std.testing.expectEqualStrings("opaque", inputs[0].digest);
    try std.testing.expectEqualStrings("bazel-out/cfg/bin/generated.zig", inputs[1].path);
    try std.testing.expectEqualStrings("", inputs[1].digest);
}

test "shared backend checks distinguish switches from option operands" {
    var diagnostics: Io.Writer.Allocating = .init(std.testing.allocator);
    defer diagnostics.deinit();
    try std.testing.expectError(error.UnsupportedSharedLibraryBackend, checkSharedLibraryArgs(&.{ "-fllvm", "-fno-lld", "-rpath", "-flld" }, false, &diagnostics.writer));
    try checkSharedLibraryArgs(&.{ "-fllvm", "-flld", "-rpath", "-fno-llvm" }, false, &diagnostics.writer);
    try checkSharedLibraryArgs(&.{ "-fno-llvm", "-fno-lld", "-fllvm", "-flld" }, false, &diagnostics.writer);
    try std.testing.expectError(error.UnsupportedSharedLibraryVersion, checkSharedLibraryArgs(&.{ "-fllvm", "-flld", "--version", "1.2.3" }, false, &diagnostics.writer));
    try checkSharedLibraryArgs(&.{"-flld"}, true, &diagnostics.writer);
    try std.testing.expectError(error.UnsupportedSharedLibraryBackend, checkSharedLibraryArgs(&.{ "-flld", "-fno-llvm" }, true, &diagnostics.writer));
}

test "reserved controls are rejected as switches, not option values" {
    var diagnostics: Io.Writer.Allocating = .init(std.testing.allocator);
    defer diagnostics.deinit();
    var compilation: Compilation = .{
        .command = "test",
        .output_kind = .executable,
        .name = "root",
        .outputs = &.{.{ .kind = .bin, .path = "out" }},
        .arguments = &.{ "--test-filter", "--cache-dir", "-Mroot=main.zig" },
        .input_paths = &.{"main.zig"},
    };
    try std.testing.expectEqualSlices([]const u8, compilation.arguments, try compilation.compilerArgs(&diagnostics.writer));

    const rejected = [_][]const []const u8{
        &.{ "--cache-dir", "cache" },
        &.{"--cache-dir=cache"},
        &.{ "--global-cache-dir", "cache" },
        &.{ "--zig-lib-dir", "lib" },
        &.{"--listen=-"},
        &.{"-femit-bin=out"},
        &.{ "--test-filter", "--cache-dir", "--cache-dir", "cache" },
        &.{ "--test-filter", "", "--cache-dir", "cache" },
        &.{ "-OReleaseFast", "--cache-dir", "cache" },
    };
    for (rejected) |arguments| {
        compilation.arguments = arguments;
        try std.testing.expectError(error.ConflictingCompilerOption, compilation.compilerArgs(&diagnostics.writer));
    }
}

fn reserved(arg: []const u8) bool {
    if (std.mem.startsWith(u8, arg, "@") or std.mem.startsWith(u8, arg, "-femit-") or std.mem.startsWith(u8, arg, "-fno-emit-")) return true;
    inline for (.{ "--listen", "--cache-dir", "--global-cache-dir", "--zig-lib-dir", "--build-root", "--name", "-fincremental", "-fno-incremental", "--debug-incremental", "--show-builtin" }) |flag| {
        if (std.mem.eql(u8, arg, flag) or (std.mem.startsWith(u8, arg, flag) and arg.len > flag.len and arg[flag.len] == '=')) return true;
    }
    return false;
}

fn readLines(a: Allocator, io: Io, path: []const u8, result: *std.array_list.Managed([]const u8)) !void {
    const contents = try Dir.cwd().readFileAlloc(io, path, a, .limited(16 * 1024 * 1024));
    if (contents.len == 0) return;
    const end = contents.len - @intFromBool(contents[contents.len - 1] == '\n');
    var lines = std.mem.splitScalar(u8, contents[0..end], '\n');
    while (lines.next()) |line| try result.append(line);
}

fn appendResponseFile(argv: *std.array_list.Managed([]const u8), io: Io, root: []const u8, arguments: []const []const u8) !void {
    if (arguments.len == 0) return;
    const a = argv.allocator;
    const path = try std.fs.path.join(a, &.{ root, "compiler.args" });
    var flags: Io.Writer.Allocating = .init(a);
    try writeResponseArguments(&flags.writer, arguments);
    try Dir.cwd().writeFile(io, .{ .sub_path = path, .data = flags.written() });
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
            const count = if (c == '"') backslashes * 2 + 1 else backslashes;
            for (0..count) |_| try writer.writeByte('\\');
            backslashes = 0;
            try writer.writeByte(c);
        }
        for (0..backslashes * 2) |_| try writer.writeByte('\\');
        try writer.writeAll("\"\n");
    }
}

test "response arguments round trip through the compiler parser" {
    const a = std.testing.allocator;
    const arguments = [_][]const u8{ "", "plain", "a b", "tab\tvalue", "#literal", "\"", "\\", "trailing\\", "\\\"", "two\\\\\"quotes", "two\\\\path", "--dep", "dep", "-Mroot=a b.zig", "-Mdep=../dep/main.zig" };
    var flags: Io.Writer.Allocating = .init(a);
    defer flags.deinit();
    try writeResponseArguments(&flags.writer, &arguments);
    var parser = try std.process.Args.IteratorGeneral(.{ .comments = true, .single_quotes = true }).init(a, flags.written());
    defer parser.deinit();
    for (arguments) |expected| try std.testing.expectEqualStrings(expected, parser.next() orelse return error.MissingArgument);
    try std.testing.expect(parser.next() == null);
}

const Session = struct {
    arena: std.heap.ArenaAllocator,
    key: []const u8,
    root: []const u8,
    cwd: []const u8,
    cache: []const u8,
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
    session: ?*Session = null,
    idle_sessions: std.array_list.Managed(*Session),
    max_sessions: usize = 1,
    generation: usize = 0,

    fn reset(self: *Worker) void {
        if (self.session) |s| s.destroy(self.gpa, self.io);
        self.session = null;
    }

    fn deinit(self: *Worker) void {
        self.reset();
        for (self.idle_sessions.items) |s| s.destroy(self.gpa, self.io);
        self.idle_sessions.deinit();
    }

    fn selectSession(self: *Worker, key: []const u8) !void {
        if (self.session) |s| {
            if (std.mem.eql(u8, s.key, key)) return;
            try self.idle_sessions.append(s);
            self.session = null;
        }
        // Idle sessions are ordered least recently used first. The active
        // compiler also counts toward the per-worker bound.
        for (self.idle_sessions.items, 0..) |s, i| {
            if (std.mem.eql(u8, s.key, key)) {
                self.session = self.idle_sessions.orderedRemove(i);
                return;
            }
        }
        if (self.idle_sessions.items.len >= self.max_sessions)
            self.idle_sessions.orderedRemove(0).destroy(self.gpa, self.io);
    }

    fn start(self: *Worker, compilation: Compilation, key: []const u8, arguments: []const []const u8, inputs: []const Input, request_allocator: Allocator) !*Session {
        self.reset();
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
            if (std.fs.path.isAbsolute(tool[0])) continue;
            try safePath(tool[0], true);
            const destination = try std.fs.path.join(a, &.{ cwd, tool[0] });
            try Dir.cwd().createDirPath(self.io, std.fs.path.dirname(destination).?);
            try Dir.cwd().symLink(self.io, tool[1], destination, .{});
        }
        const cache = try std.fs.path.join(a, &.{ root, "cache" });
        const global_cache = try std.fs.path.join(a, &.{ self.root, "global-cache" });
        var argv: std.array_list.Managed([]const u8) = .init(a);
        try argv.appendSlice(&.{ self.zig, compilation.command, "--listen=-", "-fincremental", "--name", compilation.name, "--cache-dir", cache, "--global-cache-dir", global_cache, "--zig-lib-dir", self.lib });
        switch (compilation.output_kind) {
            .static_library => try argv.append("-static"),
            .shared_library => try argv.append("-dynamic"),
            .executable => if (std.mem.eql(u8, compilation.command, "test")) try argv.append("--test-no-exec"),
        }
        var emit_bin = false;
        for (compilation.outputs) |output| {
            try argv.append(switch (output.kind) {
                .bin => "-femit-bin",
                .@"asm" => "-femit-asm",
                .llvm_ir => "-femit-llvm-ir",
                .llvm_bc => "-femit-llvm-bc",
            });
            if (output.kind == .bin) emit_bin = true;
        }
        if (!emit_bin) try argv.append("-fno-emit-bin");
        // Zig 0.17 cannot encode apostrophes in response files and consumes
        // direct argv before response contents. Use one representation for the
        // entire semantic vector so module dependency ordering stays intact.
        const direct = for (arguments) |arg| {
            if (std.mem.findScalar(u8, arg, '\'') != null) break true;
        } else false;
        if (direct) try argv.appendSlice(arguments) else try appendResponseFile(&argv, self.io, root, arguments);
        const stderr = try Dir.cwd().createFile(self.io, try std.fs.path.join(a, &.{ root, "stderr" }), .{ .read = true });
        errdefer stderr.close(self.io);
        const owned_key = try a.dupe(u8, key);
        s.* = .{
            .arena = arena,
            .key = owned_key,
            .root = root,
            .cwd = cwd,
            .cache = cache,
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
                std.log.warn("zig-worker compiler transport failed ({t}); restarting", .{err});
                self.reset();
                return self.compile(request, a, diagnostics);
            },
            else => return err,
        };
    }

    fn compile(self: *Worker, request: Request, a: Allocator, diagnostics: *Io.Writer) !u8 {
        if (request.requestId != 0 or request.cancel or request.sandboxDir.len != 0)
            return error.OnlySingleplexSupported;
        const compilation = try Compilation.parse(a, request.arguments);
        const arguments = try compilation.compilerArgs(diagnostics);
        const inputs = try compilation.inputs(a, request.inputs);
        const key = try std.json.Stringify.valueAlloc(a, .{ compilation.command, compilation.output_kind, compilation.name, compilation.outputs, arguments }, .{});
        try self.selectSession(key);
        var reused = self.session != null and std.mem.eql(u8, self.session.?.key, key);
        const started_at = Io.Clock.awake.now(self.io);
        var s = if (reused) self.session.? else try self.start(compilation, key, arguments, inputs, a);
        const copied = if (reused) self.materialize(s, inputs, a, false) catch |err| blk: {
            if (err != error.InputSetChanged) return err;
            // Zig may report historical inputs after they become unreachable.
            // A changed declared set gets a clean compiler and filesystem view.
            reused = false;
            s = try self.start(compilation, key, arguments, inputs, a);
            break :blk s.inputs.count();
        } else s.inputs.count();
        defer self.appendStderr(s, diagnostics) catch {};
        const inputs_ready_at = Io.Clock.awake.now(self.io);
        // Artifact names are under our control, independent of Bazel's output path.
        const client: std.zig.Client = .{ .in = &s.reader.interface, .out = &s.writer.interface };
        try client.serveBodylessMessage(.update);
        var digest: ?[]const u8 = null;
        var undeclared_input = false;
        while (true) {
            const hdr = try client.receiveMessage();
            if (hdr.bytes_len > 64 * 1024 * 1024) return error.CompilerMessageTooLarge;
            const body = try s.reader.interface.readAllocAll(a, hdr.bytes_len);
            switch (hdr.tag) {
                .zig_version => {
                    const version = std.SemanticVersion.parse(body) catch return error.UnsupportedZigVersion;
                    if (version.major != 0 or version.minor != 17 or (version.patch == 0 and version.pre != null))
                        return error.UnsupportedZigVersion;
                },
                .emit_digest => {
                    if (body.len != 1 + std.Build.Cache.bin_digest_len) return error.InvalidEmitDigest;
                    digest = try std.fmt.allocPrint(a, "{x}", .{body[1..]});
                },
                .error_bundle => {
                    var bundle = try std.zig.Server.allocErrorBundle(a, body);
                    if (bundle.errorMessageCount() > 0) {
                        try bundle.renderToWriter(.{}, diagnostics);
                        return 1;
                    }
                    if (undeclared_input) return error.UndeclaredCompilerInput;
                    break;
                },
                .file_system_inputs => {
                    var paths = std.mem.splitScalar(u8, body, 0);
                    while (paths.next()) |path| {
                        if (path.len == 0) continue;
                        // cwd inputs must belong to this request. SDK and
                        // compiler-generated cache inputs have other prefixes.
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
                        } else if (path[0] < 2 or path[0] > 5) return error.InvalidCompilerInputPrefix;
                    }
                },
                else => {},
            }
        }
        const compiled_at = Io.Clock.awake.now(self.io);
        const artifacts = try a.alloc([]const u8, compilation.outputs.len);
        for (artifacts, compilation.outputs) |*artifact, output| {
            artifact.* = try std.fs.path.join(a, &.{ s.cache, "o", digest orelse return error.MissingEmitDigest, try compilation.artifactName(a, output.kind) });
            Dir.cwd().access(self.io, artifact.*, .{}) catch |err| {
                try diagnostics.print("zig incremental compilation: requested {t} output was not produced: {s} ({t})\n", .{ output.kind, output.path, err });
                return error.MissingCompilerOutput;
            };
        }
        for (artifacts, compilation.outputs) |artifact, output| {
            // Atomic copy, never a hard link: Zig mutates the private artifact in place.
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
            if (self.isToolInput(input.path)) continue;
            const stat = try Dir.cwd().statFile(self.io, input.path, .{});
            if (stat.kind == .directory) {
                var dir = try Dir.cwd().openDir(self.io, input.path, .{ .iterate = true });
                defer dir.close(self.io);
                var walker = try dir.walk(a);
                defer walker.deinit();
                while (try walker.next(self.io)) |entry| {
                    if (entry.kind == .directory) continue;
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
            if (present.count() != s.inputs.count()) return error.InputSetChanged;
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
            if (n == 0) return;
            s.stderr_offset += n;
            try diagnostics.writeAll(buffer[0..n]);
        }
    }
};

fn safePath(path: []const u8, sibling: bool) !void {
    if (path.len == 0 or std.fs.path.isAbsolute(path)) return error.InvalidInputPath;
    // A single leading '..' is Bazel's sibling repository layout. The session
    // cwd is a child of its private execroot, so this remains worker-owned.
    const relative = if (sibling and std.mem.startsWith(u8, path, "../")) path[3..] else path;
    if (relative.len == 0) return error.InvalidInputPath;
    var parts = std.mem.tokenizeAny(u8, relative, "/\\");
    while (parts.next()) |part| if (std.mem.eql(u8, part, "..")) return error.InvalidInputPath;
}

pub fn main(init: std.process.Init) !void {
    std.process.exit(try run(init));
}

fn run(init: std.process.Init) !u8 {
    const a = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(a);
    var zig_path: ?[]const u8 = null;
    var lib_path: ?[]const u8 = null;
    var persistent = false;
    var max_sessions: usize = 1;
    var flags: std.array_list.Managed([]const u8) = .init(a);
    for (args[1..]) |arg| {
        if (std.mem.startsWith(u8, arg, "--zig=")) {
            zig_path = arg[6..];
        } else if (std.mem.startsWith(u8, arg, "--lib=")) {
            lib_path = arg[6..];
        } else if (std.mem.eql(u8, arg, "--persistent_worker")) {
            persistent = true;
        } else if (std.mem.cutPrefix(u8, arg, "--max-sessions=")) |value| {
            max_sessions = try std.fmt.parseInt(usize, value, 10);
            if (max_sessions == 0) return error.InvalidSessionLimit;
        } else if (std.mem.startsWith(u8, arg, "@")) {
            try readLines(a, io, arg[1..], &flags);
        } else return error.InvalidStartupArgument;
    }
    const zig = try Dir.cwd().realPathFileAlloc(io, zig_path orelse return error.MissingZigPath, a);
    const lib = try Dir.cwd().realPathFileAlloc(io, lib_path orelse return error.MissingLibPath, a);
    var nonce: [16]u8 = undefined;
    io.random(&nonce);
    // Linux's hardened worker sandbox supplies a worker-private persistent
    // /tmp. Do not derive paths from Bazel's internal worker directory layout,
    // or use an inherited TMPDIR that might point outside the writable sandbox.
    const root = try std.fmt.allocPrint(a, "/tmp/rules-zig-worker-{x}", .{&nonce});
    try Dir.cwd().createDir(io, root, .fromMode(0o700));
    var worker: Worker = .{
        .gpa = std.heap.page_allocator,
        .io = io,
        .zig = zig,
        .lib = lib,
        .zig_input = zig_path.?,
        .lib_input = lib_path.?,
        .root = root,
        .idle_sessions = .init(std.heap.page_allocator),
        .max_sessions = max_sessions,
    };
    defer {
        worker.deinit();
        Dir.cwd().deleteTree(io, root) catch {};
    }
    if (!persistent) {
        var diagnostics: Io.Writer.Allocating = .init(a);
        const code = worker.execute(.{ .arguments = flags.items }, a, &diagnostics.writer) catch |err| blk: {
            try diagnostics.writer.print("zig incremental compilation: {t}\n", .{err});
            break :blk 1;
        };
        try Io.File.stderr().writeStreamingAll(io, diagnostics.written());
        // Return through the cleanup defers, including on a failed request.
        return code;
    }
    const in_buffer = try a.alloc(u8, 16 * 1024 * 1024);
    var out_buffer: [8192]u8 = undefined;
    var stdin = Io.File.stdin().readerStreaming(io, in_buffer);
    var stdout = Io.File.stdout().writerStreaming(io, &out_buffer);
    while (try stdin.interface.takeDelimiter('\n')) |line| {
        var request_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer request_arena.deinit();
        const ra = request_arena.allocator();
        const parsed = try std.json.parseFromSlice(Request, ra, line, .{ .ignore_unknown_fields = true });
        var diagnostics: Io.Writer.Allocating = .init(ra);
        const code = worker.execute(parsed.value, ra, &diagnostics.writer) catch |err| blk: {
            worker.reset();
            try diagnostics.writer.print("zig incremental worker: {t}\n", .{err});
            break :blk 1;
        };
        const response = try std.json.Stringify.valueAlloc(ra, Response{
            .requestId = parsed.value.requestId,
            .exitCode = code,
            .output = diagnostics.written(),
        }, .{});
        try stdout.interface.writeAll(response);
        try stdout.interface.writeByte('\n');
        try stdout.interface.flush();
    }
    return 0;
}
