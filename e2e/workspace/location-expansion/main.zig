const std = @import("std");
const builtin = @import("builtin");

extern const rlocationpath: [*:0]const u8;
extern const target: [*:0]const u8;
extern const zig_target: [*:0]const u8;

test "-DRLOCATIONPATH is set" {
    try std.testing.expectStringEndsWith(
        std.mem.sliceTo(rlocationpath, 0),
        "location-expansion/data.txt",
    );
}

test "-DTARGET is set" {
    try std.testing.expectEqualStrings(
        "//location-expansion:test",
        std.mem.sliceTo(target, 0),
    );
}

test "-DZIG_TARGET is set" {
    const actual_target = try builtin.target.linuxTriple(std.testing.allocator);
    defer std.testing.allocator.free(actual_target);
    // TODO revert to an equality check.
    try std.testing.expectStringStartsWith(
        std.mem.sliceTo(zig_target, 0),
        actual_target,
    );
}

test "Env-var TARGET is set" {
    const value = try std.testing.environ.getAlloc(std.testing.allocator, "TARGET");
    defer std.testing.allocator.free(value);
    try std.testing.expectEqualStrings(
        "//location-expansion:test",
        value,
    );
}
