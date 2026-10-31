const std = @import("std");
const module = @import("incremental_module");
const generated = @import("generated_module");
const external = @import("external_module");

pub fn main(init: std.process.Init) !void {
    var buffer: [64]u8 = undefined;
    const message = try std.fmt.bufPrint(&buffer, "{d}:{s}{s}", .{ module.value + external.bias, module.message, generated.message });
    try std.Io.File.stdout().writeStreamingAll(init.io, message);
}
