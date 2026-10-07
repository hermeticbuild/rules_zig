//! A stand-in for the translate-c package
//! (https://codeberg.org/ziglang/translate-c, tag 2.0.0) exposing its build
//! API. The importer never runs its executable.

const std = @import("std");

pub const Translator = @import("build/Translator.zig");

pub fn build(b: *std.Build) void {
    _ = b.addModule("c_builtins", .{ .root_source_file = b.path("lib/c_builtins.zig") });
    _ = b.addModule("helpers", .{ .root_source_file = b.path("lib/helpers.zig") });
    b.installArtifact(b.addExecutable(.{
        .name = "translate-c",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = b.standardTargetOptions(.{}),
            .optimize = b.standardOptimizeOption(.{}),
        }),
    }));
    b.addNamedLazyPath("aro_resource_dir", b.path(""));
}
