const std = @import("std");
const Translator = @import("translate_c").Translator;

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const value = b.addLibrary(.{
        .name = "tcpkg_value",
        .root_module = b.createModule(.{ .target = target, .optimize = optimize }),
    });
    value.root_module.addCSourceFile(.{ .file = b.path("lib/value.c") });
    value.installHeader(b.path("lib/value.h"), "value.h");

    const translator: Translator = .init(b.dependency("translate_c", .{}), .{
        .c_source_file = b.path("c/tcpkg.h"),
        .target = target,
        .optimize = optimize,
        .link_system_libs = &.{.{ .name = "tclib" }},
    });
    translator.addIncludePath(b.path("include"));
    translator.defineCMacro("TCPKG_ENABLED", null);
    translator.linkLibrary(value);

    const tcpkg = b.addModule("tcpkg", .{ .root_source_file = b.path("src/tcpkg.zig") });
    tcpkg.addImport("c", translator.mod);
}
