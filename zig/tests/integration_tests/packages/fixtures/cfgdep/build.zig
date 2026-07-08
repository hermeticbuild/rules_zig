const std = @import("std");

/// Process-global state that survives across `build` calls, as aro's
/// `generateDef` caches its generator.
var generator: ?*std.Build.Step.Compile = null;

pub fn build(b: *std.Build) void {
    const optimize = b.standardOptimizeOption(.{});
    const cfgdep = b.addModule("cfgdep", .{
        .root_source_file = b.path("src/cfgdep.zig"),
        .target = b.standardTargetOptions(.{}),
        .optimize = optimize,
    });
    if (optimize == .debug) {
        cfgdep.linkSystemLibrary("dbgonly", .{});
    } else {
        cfgdep.linkSystemLibrary("relonly", .{});
    }

    const gen = generator orelse gen: {
        generator = b.addExecutable(.{
            .name = "gen",
            .root_module = b.createModule(.{ .root_source_file = b.path("gen/gen.zig"), .target = b.graph.host }),
        });
        break :gen generator.?;
    };
    _ = b.addRunArtifact(gen);
}
