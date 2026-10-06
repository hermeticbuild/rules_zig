//!zig-autodoc-guide: guide.md

// NOTE: zig-autodoc-guide not supported as of Zig 0.14+,
// see https://ziggit.dev/t/zig-autodoc-render-markdown-files/10314/2

const std = @import("std");
pub const hello_world = @import("hello_world");

/// Prints "Hello World!".
pub fn say_hello_world(io: anytype) !void {
    std.Io.File.writeStreamingAll(.stdout(), io, hello_world.msg ++ "\n") catch unreachable;
}

/// Program entry-point.
/// Prints "Hello World!".
pub fn main(init: std.process.Init) void {
    say_hello_world(init.io) catch unreachable;
}

test hello_world {
    // Hello World message.
    try std.testing.expectEqualStrings("Hello World!", hello_world.msg);
}
