const std = @import("std");
const clap = @import("clap");
const xev = @import("xev");
const httpz = @import("httpz");
const sqlite = @import("sqlite");

// Parameters declared with the imported `clap` package, resolved at comptime.
const params = clap.parseParamsComptime(
    \\-h, --help        Display this help and exit.
    \\-n, --name <str>  Name to greet.
    \\
);

pub fn main(init: std.process.Init) !void {
    var buffer: [256]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(init.io, &buffer);
    const out = &stdout.interface;
    try out.print("clap declares {d} parameters\n", .{params.len});
    // `xev` selects its event-loop backend from the target at comptime; the
    // printed value differs per platform, exercising the imported module.
    try out.print("libxev backend: {s}\n", .{@tagName(xev.backend)});
    // `httpz` pulls in its transitive `metrics` and `websocket` packages and a
    // generated `build` options module; referencing both exercises the stack.
    const methods = @typeInfo(httpz.Method).@"enum".field_names.len;
    try out.print("httpz methods: {d}\n", .{methods});
    try out.print("httpz blocking: {}\n", .{httpz.blockingMode()});
    // `sqlite` links the SQLite C amalgamation from a source-only dependency
    // and reaches it through a translate-c module it imports as `c`; the
    // version number comes from `sqlite3.h`, exercising the C include path.
    try out.print("sqlite version: {d}\n", .{sqlite.c.SQLITE_VERSION_NUMBER});
    try out.flush();
}
