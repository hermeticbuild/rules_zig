//! Experimental singleplex Bazel worker for Zig 0.17's compiler protocol.
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

const Session = struct {
    arena: std.heap.ArenaAllocator,
    key: []const u8,
    root: []const u8,
    cwd: []const u8,
    cache: []const u8,
    inputs: std.StringHashMapUnmanaged([]const u8) = .empty,
    child: std.process.Child,
    reader: Io.File.Reader,
    writer: Io.File.Writer,
    read_buffer: [8192]u8 = undefined,
    write_buffer: [256]u8 = undefined,

    fn destroy(self: *Session, gpa: Allocator, io: Io) void {
        self.child.kill(io);
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
    root: []const u8,
    session: ?*Session = null,
    generation: usize = 0,

    fn reset(self: *Worker) void {
        if (self.session) |s| s.destroy(self.gpa, self.io);
        self.session = null;
    }

    fn start(self: *Worker, key: []const u8, arguments: []const []const u8, inputs: []const Input, request_allocator: Allocator) !*Session {
        self.reset();
        self.generation += 1;
        const s = try self.gpa.create(Session);
        errdefer self.gpa.destroy(s);
        var arena = std.heap.ArenaAllocator.init(self.gpa);
        errdefer arena.deinit();
        const a = arena.allocator();
        const root = try std.fmt.allocPrint(a, "{s}/session-{d}", .{ self.root, self.generation });
        const cwd = try std.fs.path.join(a, &.{ root, "inputs" });
        try Dir.cwd().createDirPath(self.io, cwd);
        errdefer Dir.cwd().deleteTree(self.io, root) catch {};
        const cache = try std.fs.path.join(a, &.{ root, "cache" });
        const global_cache = try std.fs.path.join(a, &.{ self.root, "global-cache" });
        var argv: std.array_list.Managed([]const u8) = .init(a);
        try argv.appendSlice(&.{ self.zig, "build-exe", "--listen=-", "-fincremental", "--cache-dir", cache, "--global-cache-dir", global_cache, "--zig-lib-dir", self.lib });
        try argv.appendSlice(arguments);
        const owned_key = try a.dupe(u8, key);
        s.* = .{
            .arena = arena,
            .key = owned_key,
            .root = root,
            .cwd = cwd,
            .cache = cache,
            .child = undefined,
            .reader = undefined,
            .writer = undefined,
        };
        errdefer s.clearInputs(self.gpa);
        // The compiler resolves module roots during startup, before `update`.
        _ = try self.materialize(s, inputs, request_allocator);
        const child = try std.process.spawn(self.io, .{
            .argv = argv.items,
            .cwd = .{ .path = cwd },
            .stdin = .pipe,
            .stdout = .pipe,
            // Keep stdout exclusively for the binary compiler protocol.
            .stderr = .inherit,
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
        var arguments: std.array_list.Managed([]const u8) = .init(a);
        var output: ?[]const u8 = null;
        var skip_next = false;
        for (request.arguments) |arg| {
            if (skip_next) {
                skip_next = false;
                continue;
            }
            if (std.mem.eql(u8, arg, "--cache-dir") or std.mem.eql(u8, arg, "--global-cache-dir") or std.mem.eql(u8, arg, "--zig-lib-dir")) {
                skip_next = true;
                continue;
            }
            if (std.mem.startsWith(u8, arg, "-femit-bin=")) {
                if (output != null) return error.MultipleOutputs;
                output = arg["-femit-bin=".len..];
                continue;
            }
            if (std.mem.eql(u8, arg, "-fno-incremental") or std.mem.startsWith(u8, arg, "--listen"))
                return error.ConflictingCompilerOption;
            try arguments.append(arg);
        }
        const output_path = output orelse return error.MissingOutput;
        try safePath(output_path);
        try arguments.appendSlice(&.{ "--name", std.fs.path.basename(output_path) });
        const key = try std.json.Stringify.valueAlloc(a, .{ output_path, arguments.items }, .{});
        const reused = self.session != null and std.mem.eql(u8, self.session.?.key, key);
        const started_at = Io.Clock.awake.now(self.io);
        const s = if (reused) self.session.? else try self.start(key, arguments.items, request.inputs, a);
        const copied = if (reused) try self.materialize(s, request.inputs, a) else s.inputs.count();
        const inputs_ready_at = Io.Clock.awake.now(self.io);
        // Artifact names are under our control, independent of Bazel's output path.
        try s.writer.interface.writeStruct(std.zig.Client.Message.Header{ .tag = .update, .bytes_len = 0 }, .little);
        try s.writer.interface.flush();
        var digest: ?[]const u8 = null;
        var undeclared_input = false;
        while (true) {
            const hdr = try s.reader.interface.takeStruct(std.zig.Server.Message.Header, .little);
            if (hdr.bytes_len > 64 * 1024 * 1024) return error.CompilerMessageTooLarge;
            const body = try s.reader.interface.readAllocAll(a, hdr.bytes_len);
            switch (hdr.tag) {
                .zig_version => if (!std.mem.eql(u8, body, "0.17.0")) return error.UnsupportedZigVersion,
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
                            safePath(path[1..]) catch {
                                undeclared_input = true;
                                continue;
                            };
                            if (!s.inputs.contains(path[1..])) undeclared_input = true;
                        }
                    }
                },
                else => {},
            }
        }
        const basename = std.fs.path.basename(output_path);
        const compiled_at = Io.Clock.awake.now(self.io);
        const artifact = try std.fs.path.join(a, &.{ s.cache, "o", digest orelse return error.MissingEmitDigest, basename });
        // Atomic copy, never a hard link: Zig mutates the private artifact in place.
        try Dir.cwd().copyFile(artifact, .cwd(), output_path, self.io, .{ .make_path = true });
        const ms = started_at.untilNow(self.io, .awake).toMilliseconds();
        std.log.info("zig-worker generation={d} reused={} copied={d} duration_ms={d} input_ms={d} compile_ms={d} output_ms={d}", .{
            self.generation,
            reused,
            copied,
            ms,
            started_at.durationTo(inputs_ready_at).toMilliseconds(),
            inputs_ready_at.durationTo(compiled_at).toMilliseconds(),
            compiled_at.untilNow(self.io, .awake).toMilliseconds(),
        });
        return 0;
    }

    fn materialize(self: *Worker, s: *Session, inputs: []const Input, a: Allocator) !usize {
        var present: std.StringHashMapUnmanaged(void) = .empty;
        var copied: usize = 0;
        for (inputs) |input| {
            try safePath(input.path);
            // Toolchain files belong to the worker key, not mutable source state.
            const real = try Dir.cwd().realPathFileAlloc(self.io, input.path, a);
            if (std.mem.eql(u8, real, self.zig) or std.mem.eql(u8, real, self.lib) or
                (std.mem.startsWith(u8, real, self.lib) and real.len > self.lib.len and real[self.lib.len] == std.fs.path.sep)) continue;
            try present.put(a, input.path, {});
            if (s.inputs.get(input.path)) |previous| {
                if (input.digest.len != 0 and std.mem.eql(u8, previous, input.digest)) continue;
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
            copied += 1;
        }
        var removed: std.array_list.Managed([]const u8) = .init(a);
        var keys = s.inputs.keyIterator();
        while (keys.next()) |path| {
            if (!present.contains(path.*)) try removed.append(path.*);
        }
        for (removed.items) |path| {
            const destination = try std.fs.path.join(a, &.{ s.cwd, path });
            try Dir.cwd().deleteFile(self.io, destination);
            const entry = s.inputs.fetchRemove(path).?;
            self.gpa.free(entry.key);
            self.gpa.free(entry.value);
        }
        return copied;
    }
};

fn safePath(path: []const u8) !void {
    if (path.len == 0 or std.fs.path.isAbsolute(path)) return error.InvalidInputPath;
    var parts = std.mem.tokenizeAny(u8, path, "/\\");
    while (parts.next()) |part| if (std.mem.eql(u8, part, "..")) return error.InvalidInputPath;
}

pub fn main(init: std.process.Init) !void {
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
        } else if (std.mem.startsWith(u8, arg, "@")) {
            const contents = try Dir.cwd().readFileAlloc(io, arg[1..], a, .limited(16 * 1024 * 1024));
            var lines = std.mem.splitScalar(u8, contents, '\n');
            while (lines.next()) |line| if (line.len != 0) try flags.append(line);
        } else return error.InvalidStartupArgument;
    }
    const zig = try Dir.cwd().realPathFileAlloc(io, zig_path orelse return error.MissingZigPath, a);
    const lib = try Dir.cwd().realPathFileAlloc(io, lib_path orelse return error.MissingLibPath, a);
    if (!persistent) {
        var argv: std.array_list.Managed([]const u8) = .init(a);
        try argv.appendSlice(&.{ zig, "build-exe" });
        try argv.appendSlice(flags.items);
        var child = try std.process.spawn(io, .{ .argv = argv.items });
        const term = try child.wait(io);
        std.process.exit(if (term.success()) 0 else 1);
    }
    const cwd = try std.process.currentPathAlloc(io, a);
    var nonce: [8]u8 = undefined;
    io.random(&nonce);
    // WorkerExecRoot cleans cwd and its parent between requests. Keep private
    // state one level above that traversal, still under Bazel's output base.
    const root = try std.fmt.allocPrint(a, "{s}/.zig-worker-{x}", .{ std.fs.path.dirname(std.fs.path.dirname(cwd).?).?, &nonce });
    var worker: Worker = .{ .gpa = std.heap.page_allocator, .io = io, .zig = zig, .lib = lib, .root = root };
    defer {
        worker.reset();
        Dir.cwd().deleteTree(io, root) catch {};
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
}
