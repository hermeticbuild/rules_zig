//! Append the standard Apple SDK search paths to a standalone translate-c invocation.

const std = @import("std");

const SdkSettings = struct {
    Version: []const u8 = "",
    SupportedTargets: std.json.ArrayHashMap(SupportedTarget) = .{},

    const SupportedTarget = struct {
        SystemPrefix: ?[]const u8 = null,
    };

    fn prefix(settings: SdkSettings, platform: []const u8) []const u8 {
        const targets = settings.SupportedTargets.map;
        if (targets.get(platform)) |target| {
            return settings.targetPrefix(platform, target);
        }
        if (targets.count() == 0) return legacyPrefix(platform);

        // A single shared prefix also applies to targets omitted by the SDK.
        const first = settings.targetPrefix(targets.keys()[0], targets.values()[0]);
        for (targets.keys()[1..], targets.values()[1..]) |key, target| {
            if (!std.mem.eql(u8, first, settings.targetPrefix(key, target))) return "";
        }
        return first;
    }

    fn targetPrefix(settings: SdkSettings, platform: []const u8, target: SupportedTarget) []const u8 {
        var version = std.mem.splitScalar(u8, settings.Version, '.');
        const major = std.fmt.parseInt(u32, version.next() orelse "", 10) catch 0;
        const minor = std.fmt.parseInt(u32, version.next() orelse "", 10) catch 0;
        // Match Clang's DarwinSDKInfo handling of the iOSSupport prefix.
        // https://clang.llvm.org/doxygen/DarwinSDKInfo_8cpp_source.html#l00221
        if (std.mem.eql(u8, platform, "iosmac") and major < 99) return "";
        if (target.SystemPrefix) |system_prefix| return system_prefix;
        if (major < 22 or (major == 22 and minor == 0)) return legacyPrefix(platform);
        return "";
    }
};

fn legacyPrefix(platform: []const u8) []const u8 {
    return if (std.mem.eql(u8, platform, "driverkit")) "/System/DriverKit" else "";
}

fn sdkPrefix(arena: std.mem.Allocator, io: std.Io, root: []const u8, platform: []const u8) ![]const u8 {
    const settings_path = try std.fs.path.join(arena, &.{ root, "SDKSettings.json" });
    const content = std.Io.Dir.cwd().readFileAlloc(io, settings_path, arena, .unlimited) catch |err| switch (err) {
        error.FileNotFound => return legacyPrefix(platform),
        else => return err,
    };
    const settings = try std.json.parseFromSliceLeaky(SdkSettings, arena, content, .{
        .ignore_unknown_fields = true,
    });
    return settings.prefix(platform);
}

fn appendSdkIncludes(arena: std.mem.Allocator, argv: *std.ArrayList([]const u8), root: []const u8, prefix: []const u8) !void {
    const relative_prefix = std.mem.trimStart(u8, prefix, "/\\");
    var components = std.mem.splitAny(u8, relative_prefix, "/\\");
    while (components.next()) |component| {
        if (std.mem.eql(u8, component, "..") or std.mem.indexOfScalar(u8, component, ':') != null) {
            return error.InvalidSdkSystemPrefix;
        }
    }
    const sdk = try std.fs.path.join(arena, &.{ root, relative_prefix });

    for ([_][]const u8{ "usr/local/include", "usr/include" }) |path| {
        try argv.appendSlice(arena, &.{ "-isystem", try std.fs.path.join(arena, &.{ sdk, path }) });
    }
    for ([_][]const u8{ "System/Library/Frameworks", "System/Library/SubFrameworks", "Library/Frameworks" }) |path| {
        try argv.appendSlice(arena, &.{ "-iframework", try std.fs.path.join(arena, &.{ sdk, path }) });
    }
}

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    if (args.len < 4) return error.MissingTranslateCInvocation;
    const root = args[2];
    const prefix = sdkPrefix(arena, init.io, root, args[1]) catch |err| {
        std.log.err("reading SDKSettings.json in '{s}': {t}", .{ root, err });
        return err;
    };

    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(arena, args[3..]);
    try appendSdkIncludes(arena, &argv, root, prefix);

    var child = try std.process.spawn(init.io, .{ .argv = argv.items });
    const term = try child.wait(init.io);
    switch (term) {
        .exited => |code| std.process.exit(code),
        else => return error.TranslateCTerminated,
    }
}

test "select the target's SDK prefix" {
    const allocator = std.testing.allocator;
    const settings = try std.json.parseFromSlice(SdkSettings, allocator,
        \\{"Version":"26.5","SupportedTargets":{
        \\  "macosx":{"SystemPrefix":"/Custom/Platform"},
        \\  "iosmac":{"SystemPrefix":"/System/iOSSupport"}
        \\}}
    , .{});
    defer settings.deinit();
    try std.testing.expectEqualStrings("/Custom/Platform", settings.value.prefix("macosx"));
    try std.testing.expectEqualStrings("", settings.value.prefix("iosmac"));
    try std.testing.expectEqualStrings("", settings.value.prefix("iphoneos"));
    try std.testing.expectEqualStrings("/System/DriverKit", (SdkSettings{}).prefix("driverkit"));
}

test "append SDK headers and frameworks after explicit arguments" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(arena, &.{ "-iframework", "explicit frameworks" });
    try appendSdkIncludes(arena, &argv, "test SDK", "/MetadataPrefix");

    const expected = [_][]const u8{
        "-iframework", "explicit frameworks",
        "-isystem",    "usr/local/include",
        "-isystem",    "usr/include",
        "-iframework", "System/Library/Frameworks",
        "-iframework", "System/Library/SubFrameworks",
        "-iframework", "Library/Frameworks",
    };
    try std.testing.expectEqual(expected.len, argv.items.len);
    for (argv.items, expected, 0..) |arg, value, i| {
        const expected_arg = if (i > 1 and i % 2 == 1)
            try std.fs.path.join(arena, &.{ "test SDK", "MetadataPrefix", value })
        else
            value;
        try std.testing.expectEqualStrings(expected_arg, arg);
    }
    try std.testing.expectError(error.InvalidSdkSystemPrefix, appendSdkIncludes(arena, &argv, "test SDK", "/../outside"));
}
