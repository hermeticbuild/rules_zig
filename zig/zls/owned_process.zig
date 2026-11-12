//! Linux/macOS process ownership. Keep the group leader waitable until cleanup.
const std = @import("std");
const builtin = @import("builtin");

pub const supported = builtin.os.tag == .linux or builtin.os.tag == .macos;
pub var interrupted: std.atomic.Value(bool) = .init(false);
var old_term: std.posix.Sigaction = undefined;
var old_int: std.posix.Sigaction = undefined;

fn interrupt(_: std.posix.SIG) callconv(.c) void {
    interrupted.store(true, .release);
}

pub fn install() void {
    const action: std.posix.Sigaction = .{
        .handler = .{ .handler = interrupt },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(.TERM, &action, &old_term);
    std.posix.sigaction(.INT, &action, &old_int);
}

pub fn restore() void {
    std.posix.sigaction(.TERM, &old_term, null);
    std.posix.sigaction(.INT, &old_int, null);
}

pub fn check() error{Canceled}!void {
    if (interrupted.load(.acquire)) {
        return error.Canceled;
    }
}

pub const tick: std.Io.Timeout = .{ .duration = .{ .raw = .fromMilliseconds(50), .clock = .awake } };

// Zig exposes siginfo_t but not waitid or all of its Darwin flags.
const P_PID = 1;
const darwin_wexited = 0x4;
const darwin_wnowait = 0x20;

extern "c" fn waitid(c_uint, c_uint, *std.c.siginfo_t, c_int) c_int;

pub const Owned = struct {
    child: std.process.Child,
    io: std.Io,
    grace_ms: u64 = 250,

    pub fn spawn(io: std.Io, options: std.process.SpawnOptions) !Owned {
        var opts = options;
        opts.pgid = 0;
        return .{ .child = try std.process.spawn(io, opts), .io = io };
    }

    fn exited(self: *Owned) !bool {
        var info: std.c.siginfo_t = std.mem.zeroes(std.c.siginfo_t);
        const flags = if (builtin.os.tag == .macos)
            darwin_wexited | std.c.W.NOHANG | darwin_wnowait
        else
            std.os.linux.W.EXITED | std.os.linux.W.NOHANG | std.os.linux.W.NOWAIT;
        switch (std.posix.errno(waitid(P_PID, @intCast(self.child.id.?), &info, flags))) {
            .SUCCESS => return if (builtin.os.tag == .macos) info.pid != 0 else info.fields.common.first.piduid.pid != 0,
            .INTR => {
                try check();
                return false;
            },
            else => return error.ChildObservationFailed,
        }
    }

    fn stopGroup(self: *Owned) void {
        const pid = self.child.id orelse return;
        std.posix.kill(-pid, .TERM) catch {};
        std.Io.sleep(self.io, .fromMilliseconds(@intCast(self.grace_ms)), .awake) catch {};
        std.posix.kill(-pid, .KILL) catch {};
    }

    pub fn deinit(self: *Owned) void {
        if (self.child.id == null) {
            return;
        }
        self.stopGroup();
        _ = self.child.wait(self.io) catch {};
    }

    pub fn join(self: *Owned, parent: ?*std.Io.File.MultiReader) !std.process.Child.Term {
        while (true) {
            try check();
            if (parent) |p| try checkParent(p);
            if (try self.exited()) break;
            try std.Io.sleep(self.io, .fromMilliseconds(50), .awake);
        }
        // Even a successful client may leave descendants. Retaining its zombie
        // prevents PGID reuse until this last group operation and the sole reap.
        self.stopGroup();
        return self.child.wait(self.io);
    }
};

pub fn checkParent(input: *std.Io.File.MultiReader) !void {
    input.fill(64, .{ .duration = .{ .raw = .zero, .clock = .awake } }) catch |err| switch (err) {
        error.Timeout => {},
        error.EndOfStream => return error.Canceled,
        else => return err,
    };
    const reader = input.reader(0);
    if (reader.bufferedLen() >= @sizeOf(std.zig.Client.Message.Header)) {
        const header = try reader.takeStruct(std.zig.Client.Message.Header, .little);
        if (header.tag == .exit and header.bytes_len == 0) {
            return error.Canceled;
        }
        return error.UnexpectedEarlyProtocolMessage;
    }
}

pub fn capture(init: std.process.Init, options: std.process.SpawnOptions, parent: ?*std.Io.File.MultiReader) !std.process.RunResult {
    var opts = options;
    opts.stdout = .pipe;
    opts.stderr = .pipe;
    var owned = try Owned.spawn(init.io, opts);
    defer owned.deinit();
    var buffers: std.Io.File.MultiReader.Buffer(2) = undefined;
    var multi: std.Io.File.MultiReader = undefined;
    multi.init(init.arena.allocator(), init.io, buffers.toStreams(), &.{ owned.child.stdout.?, owned.child.stderr.? });
    defer multi.deinit();
    var stopped = false;
    while (true) {
        try check();
        if (parent) |p| try checkParent(p);
        // Descendants can keep the pipes open after the leader exits.
        // Stop the group before waiting for EOF.
        if (!stopped and try owned.exited()) {
            owned.stopGroup();
            stopped = true;
        }
        multi.fill(64, tick) catch |err| switch (err) {
            error.Timeout => continue,
            error.EndOfStream => break,
            else => return err,
        };
        if (multi.reader(0).bufferedLen() > 64 * 1024 * 1024 or multi.reader(1).bufferedLen() > 64 * 1024 * 1024) {
            return error.OutputTooLarge;
        }
    }
    try multi.checkAnyError();
    const term = try owned.join(parent);
    return .{ .term = term, .stdout = try multi.toOwnedSlice(0), .stderr = try multi.toOwnedSlice(1) };
}

pub fn receive(multi: *std.Io.File.MultiReader) !std.zig.Client.Message.Header {
    const reader = multi.reader(0);
    while (reader.bufferedLen() < @sizeOf(std.zig.Client.Message.Header)) {
        try check();
        multi.fill(64, tick) catch |err| switch (err) {
            error.Timeout => continue,
            else => return err,
        };
    }
    const header = try reader.takeStruct(std.zig.Client.Message.Header, .little);
    if (header.bytes_len > 1024 * 1024) {
        return error.ProtocolFrameTooLarge;
    }
    while (reader.bufferedLen() < header.bytes_len) {
        try check();
        multi.fill(64, tick) catch |err| switch (err) {
            error.Timeout => continue,
            else => return err,
        };
    }
    return header;
}
