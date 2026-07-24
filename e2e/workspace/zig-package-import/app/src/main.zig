const std = @import("std");
const clap = @import("clap");
const xev = @import("xev");
const httpz = @import("httpz");
const sqlite = @import("sqlite");
const zlua = @import("zlua");
const zap = @import("zap");
const bdwgc = @import("bdwgc");
const hiae = @import("hiae");

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
    // `zlua` links the Lua 5.4 C library built from a lazy source-only
    // dependency and translates its headers through the library's emitted
    // include tree; running a script exercises both the translated bindings and
    // the linked C runtime.
    var lua = try zlua.Lua.init(std.heap.page_allocator);
    defer lua.deinit();
    lua.openLibs();
    try lua.doString("result = 6 * 7");
    _ = try lua.getGlobal("result");
    try out.print("ziglua computes: {d}\n", .{try lua.toInteger(-1)});
    // `zap` links the in-tree facil.io C library into its module through
    // `linkLibrary`; calling the C URL parser exercises the linked C runtime.
    const url = "http://example.com:8080/path";
    const parsed = zap.fio.fio_url_parse(url, url.len);
    try out.print("zap parsed host length: {d}\n", .{parsed.host.len});
    // `bdwgc` translates the collector's headers with translate-c's
    // `Translator` and links the C library built by its `bdwgc` dependency;
    // allocating through the translated bindings exercises both.
    bdwgc.init();
    const copy = try bdwgc.strdup("rules_zig");
    try out.print("bdwgc collects: {s} {}\n", .{ copy, bdwgc.isHeapPointer(copy) });
    // `hiae` exposes a pure-Zig HiAE AEAD; computing a MAC over a fixed input
    // exercises the imported module, whose compiled form the importer also
    // emits as the `hiae.artifact` static library.
    const key: [hiae.Hiae.key_length]u8 = @splat(0);
    const nonce: [hiae.Hiae.nonce_length]u8 = @splat(0);
    const tag = hiae.Hiae.mac("rules_zig", key, nonce);
    try out.print("hiae mac: {s}\n", .{std.fmt.bytesToHex(tag, .lower)});
    try out.flush();
}
