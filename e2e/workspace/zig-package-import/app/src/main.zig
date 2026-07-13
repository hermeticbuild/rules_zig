const std = @import("std");
const clap = @import("clap");
const xev = @import("xev");

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
    try out.flush();
}
