const std = @import("std");

pub fn build(b: *std.Build) void {
    const optimize = b.standardOptimizeOption(.{});
    const translate = b.addTranslateC(.{
        .root_source_file = b.path("c/val.h"),
        .target = b.standardTargetOptions(.{}),
        .optimize = optimize,
    });
    translate.defineCMacro("TCVAR_VALUE", if (optimize == .debug) "33" else "44");
    _ = translate.addModule("tcvardep");
}
