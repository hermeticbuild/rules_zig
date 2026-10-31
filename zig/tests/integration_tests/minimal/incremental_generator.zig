const std = @import("std");

pub fn main(init: std.process.Init) !void {
    const a = init.arena.allocator();
    const args = try init.minimal.args.toSlice(a);
    const io = init.io;
    const cwd = std.Io.Dir.cwd();
    const content = try cwd.readFileAlloc(io, args[3], a, .limited(4096));
    const nested = std.mem.startsWith(u8, content, "nested:");
    const asset = if (nested) "message.txt/part" else "message.txt";
    const asset_path = try std.fs.path.join(a, &.{ args[2], asset });
    try cwd.createDirPath(io, std.fs.path.dirname(args[1]).?);
    try cwd.createDirPath(io, std.fs.path.dirname(asset_path).?);
    try cwd.writeFile(io, .{
        .sub_path = args[1],
        .data = try std.fmt.allocPrint(a, "pub const message = @embedFile(\"assets/{s}\");\n", .{asset}),
    });
    try cwd.writeFile(io, .{
        .sub_path = asset_path,
        .data = if (nested) content["nested:".len..] else content,
    });
}
