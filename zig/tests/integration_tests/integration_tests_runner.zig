const std = @import("std");
const integration_testing = @import("integration_testing");
const BitContext = integration_testing.BitContext;
const EnvMap = integration_testing.EnvMap;
const Term = std.process.Child.Term;
const removeEnv = integration_testing.removeEnv;

test "zig_binary prints Hello World!" {
    const ctx = try BitContext.init();
    defer ctx.deinit();

    const result = try ctx.exec_bazel(.{
        .argv = &[_][]const u8{ "run", "//:binary" },
    });
    defer result.deinit();

    try std.testing.expect(result.success);
    try std.testing.expectEqualStrings("Hello World!\n", result.stdout);
}

test "succeeding zig_test passes" {
    const ctx = try BitContext.init();
    defer ctx.deinit();

    const result = try ctx.exec_bazel(.{
        .argv = &[_][]const u8{ "test", "//:test-succeeds" },
    });
    defer result.deinit();

    try std.testing.expect(result.success);
}

test "failing zig_test fails" {
    const ctx = try BitContext.init();
    defer ctx.deinit();

    const result = try ctx.exec_bazel(.{
        .argv = &[_][]const u8{ "test", "//:test-fails" },
        .print_on_error = false,
    });
    defer result.deinit();

    // See https://bazel.build/run/scripts for Bazel exit codes.
    try std.testing.expectEqual(Term{ .exited = 3 }, result.term);
}

test "Zig cache directory can be configured" {
    const ctx = try BitContext.init();
    defer ctx.deinit();

    const result = try ctx.exec_bazel(.{
        .argv = &[_][]const u8{
            "cquery",
            "--repo_env=RULES_ZIG_CACHE_PREFIX=/CACHE_OVERRIDE",
            "--output=starlark",
            "--starlark:expr=providers(target)['ToolchainInfo'].zigtoolchaininfo.zig_cache",
            "@rules_zig//zig:resolved_toolchain",
        },
    });
    defer result.deinit();

    try std.testing.expect(result.success);
    try std.testing.expectEqualStrings("/CACHE_OVERRIDE\n", result.stdout);
}

test "target build mode defaults to Debug" {
    const ctx = try BitContext.init();
    defer ctx.deinit();

    const result = try ctx.exec_bazel(.{
        .argv = &[_][]const u8{ "run", "//:print_build_mode" },
    });
    defer result.deinit();

    try std.testing.expect(result.success);
    try std.testing.expectEqualStrings("Debug", result.stdout);
}

test "target build mode follows Bazel opt compilation mode" {
    const ctx = try BitContext.init();
    defer ctx.deinit();

    const result = try ctx.exec_bazel(.{
        .argv = &[_][]const u8{ "run", "-c", "opt", "//:print_build_mode" },
    });
    defer result.deinit();

    try std.testing.expect(result.success);
    try std.testing.expectEqualStrings("ReleaseFast", result.stdout);
}

test "exec build mode defaults to ReleaseSafe" {
    const ctx = try BitContext.init();
    defer ctx.deinit();

    const result = try ctx.exec_bazel(.{
        .argv = &[_][]const u8{ "build", "//:exec_build_mode" },
    });
    defer result.deinit();

    try std.testing.expect(result.success);

    const build_mode = try ctx.readWorkspaceFileAlloc("bazel-bin/exec_build_mode.out", 16);
    defer std.testing.allocator.free(build_mode);
    try std.testing.expectEqualStrings("ReleaseSafe", build_mode);
}

test "target build mode can be set on the command line" {
    const ctx = try BitContext.init();
    defer ctx.deinit();

    const result = try ctx.exec_bazel(.{
        .argv = &[_][]const u8{ "run", "-c", "opt", "--@rules_zig//zig/settings:mode=release_small", "//:print_build_mode" },
    });
    defer result.deinit();

    try std.testing.expect(result.success);
    try std.testing.expectEqualStrings("ReleaseSmall", result.stdout);
}

test "target build mode does not affect exec build mode" {
    const ctx = try BitContext.init();
    defer ctx.deinit();

    const result = try ctx.exec_bazel(.{
        .argv = &[_][]const u8{ "build", "//:exec_build_mode", "--@rules_zig//zig/settings:mode=release_small" },
    });
    defer result.deinit();

    try std.testing.expect(result.success);

    const build_mode = try ctx.readWorkspaceFileAlloc("bazel-bin/exec_build_mode.out", 16);
    defer std.testing.allocator.free(build_mode);
    try std.testing.expectEqualStrings("ReleaseSafe", build_mode);
}

test "can compile to target platform aarch64-linux" {
    const ctx = try BitContext.init();
    defer ctx.deinit();

    const result = try ctx.exec_bazel(.{
        .argv = &[_][]const u8{ "build", "//:binary", "--platforms=:aarch64-linux" },
    });
    defer result.deinit();

    try std.testing.expect(result.success);

    var file = try ctx.openWorkspaceFile("bazel-bin/binary");
    defer BitContext.closeWorkspaceFile(&file);

    var buffer: [1024]u8 = undefined;
    var reader = file.reader(std.testing.io, &buffer);
    const elf_header = try std.elf.Header.read(&reader.interface);

    try std.testing.expectEqual(std.elf.EM.AARCH64, elf_header.machine);
}

fn testBinaryShouldNotContainOutputBase(mode: []const u8) !void {
    const ctx = try BitContext.init();
    defer ctx.deinit();

    const info_result = try ctx.exec_bazel(.{
        .argv = &[_][]const u8{ "info", "output_base" },
    });
    defer info_result.deinit();

    const output_base = std.mem.trim(u8, info_result.stdout, " \n");

    const mode_flag = try std.fmt.allocPrint(
        std.testing.allocator,
        "--@rules_zig//zig/settings:mode={s}",
        .{mode},
    );
    defer std.testing.allocator.free(mode_flag);

    const result = try ctx.exec_bazel(.{
        .argv = &[_][]const u8{ "build", "//:binary", mode_flag },
    });
    defer result.deinit();

    try std.testing.expect(result.success);

    const file_content = try ctx.readWorkspaceFileAlloc("bazel-bin/binary", 64_000_000);
    defer std.testing.allocator.free(file_content);

    if (std.mem.indexOf(u8, file_content, output_base)) |start| {
        var end = start;
        while (std.ascii.isPrint(file_content[end])) : (end += 1) {}
        std.debug.print("\nFound output_base in binary at {}-{}: {s}\n", .{ start, end, file_content[start..end] });
        return error.TestExpectNotFound;
    }
}

test "zig_binary result should not contain the output base path in debug mode" {
    if (true) {
        // TODO[AH] Avoid output base path in debug mode.
        //   See https://github.com/hermeticbuild/rules_zig/issues/79
        return error.SkipZigTest;
    }

    try testBinaryShouldNotContainOutputBase("debug");
}

test "zig_binary result should not contain the output base path in release_safe mode" {
    if (true) {
        // TODO[AH] Avoid output base path in release_safe mode.
        //   See https://github.com/hermeticbuild/rules_zig/issues/79
        return error.SkipZigTest;
    }

    try testBinaryShouldNotContainOutputBase("release_safe");
}

test "zig_binary result should not contain the output base path in release_small mode" {
    try testBinaryShouldNotContainOutputBase("release_small");
}

test "zig_binary result should not contain the output base path in release_fast mode" {
    if (true) {
        // TODO[AH] Avoid output base path in release_fast mode.
        //   See https://github.com/hermeticbuild/rules_zig/issues/79
        return error.SkipZigTest;
    }

    try testBinaryShouldNotContainOutputBase("release_fast");
}

test "zig_target_toolchain attribute dynamic_linker configures the interpreter" {
    if (true) {
        return error.SkipZigTest;
    }

    const ctx = try BitContext.init();
    defer ctx.deinit();

    const result = try ctx.exec_bazel(.{
        .argv = &[_][]const u8{
            "build",
            "//custom_interpreter:binary-custom_interpreter",
            "--extra_toolchains=//custom_interpreter:x86_64-linux-custom_interpreter_toolchain",
        },
    });
    defer result.deinit();

    try std.testing.expect(result.success);

    var file = try ctx.openWorkspaceFile("bazel-bin/custom_interpreter/binary-custom_interpreter");
    defer BitContext.closeWorkspaceFile(&file);

    var buffer: [1024]u8 = undefined;
    var reader = file.reader(std.testing.io, &buffer);
    const elf_header = try std.elf.Header.read(&reader.interface);
    var ph_iter = elf_header.iterateProgramHeaders(&reader);
    var interp: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer interp.deinit();
    while (try ph_iter.next()) |phdr| {
        if (phdr.p_type == std.elf.PT_INTERP) {
            try reader.seekTo(phdr.p_offset);
            _ = try reader.interface.streamDelimiter(&interp.writer, 0);
            try interp.writer.flush();
            break;
        }
    }

    try std.testing.expectEqualStrings("/custom/loader.so", interp.written());
}

test "zig_binary forwards env attribute environment" {
    const ctx = try BitContext.init();
    defer ctx.deinit();

    var extra_env = EnvMap.init(std.testing.allocator);
    defer extra_env.deinit();
    try extra_env.put("ENV_INHERIT", "21");

    const result = try ctx.exec_bazel(.{
        .argv = &[_][]const u8{ "run", "//env-attr:binary" },
        .extra_env = &extra_env,
    });
    defer result.deinit();

    try std.testing.expect(result.success);
    try std.testing.expectEqualStrings(
        \\ENV_ATTR: '42'
        \\ENV_INHERIT: '21'
        \\
    , result.stdout);
}

test "zig_test forwards env attribute environment" {
    const ctx = try BitContext.init();
    defer ctx.deinit();

    var extra_env = EnvMap.init(std.testing.allocator);
    defer extra_env.deinit();
    try extra_env.put("ENV_INHERIT", "21");

    {
        const result = try ctx.exec_bazel(.{
            .argv = &[_][]const u8{ "test", "//env-attr:test" },
            .extra_env = &extra_env,
        });
        defer result.deinit();

        try std.testing.expect(result.success);
    }

    {
        const result = try ctx.exec_bazel(.{
            .argv = &[_][]const u8{ "test", "//env-attr:test-no-inherit" },
            .extra_env = &extra_env,
        });
        defer result.deinit();

        try std.testing.expect(result.success);
    }
}

test "runfiles library supports manifest mode" {
    const ctx = try BitContext.init();
    defer ctx.deinit();

    // Build the binary with runfiles manifest but without runfiles directory.
    // Note, we cannot test the inverse because
    // > Disabling [`--[no]build_runfile_manifests`] implies `--nobuild_runfile_links`.
    // See https://bazel.build/docs/user-manual#build-runfile-manifests.
    // See also https://github.com/bazelbuild/bazel/issues/4177.
    {
        const result = try ctx.exec_bazel(.{
            .argv = &[_][]const u8{
                "build",                   "//runfiles:binary",
                "--enable_runfiles",       "--nolegacy_external_runfiles",
                "--nobuild_runfile_links", "--build_runfile_manifests",
            },
        });
        defer result.deinit();

        try std.testing.expect(result.success);
    }

    // Check that no runfiles tree was generated.
    if (try ctx.workspaceDirExists("bazel-bin/runfiles/binary.runfiles")) {
        return error.RunfilesDirectoryShouldNotExist;
    }

    // Check that the runfiles manifest was generated.
    if (!try ctx.workspaceFileExists("bazel-bin/runfiles/binary.runfiles_manifest")) {
        return error.RunfilesManifestNotFound;
    }

    // Clean up the environment.
    var env_map = try integration_testing.currentEnvMap(std.testing.allocator);
    defer env_map.deinit();
    removeEnv(&env_map, "RUNFILES_DIR");
    removeEnv(&env_map, "RUNFILES_MANIFEST_FILE");

    // Execute the binary.
    const result = try std.process.run(std.testing.allocator, std.testing.io, .{
        .argv = &[_][]const u8{"bazel-bin/runfiles/binary"},
        .cwd = .{ .path = ctx.workspace_path },
        .environ_map = &env_map,
    });
    defer std.testing.allocator.free(result.stdout);
    defer std.testing.allocator.free(result.stderr);

    if (result.stderr.len > 0)
        std.log.warn("stderr: {s}", .{result.stderr});
    try std.testing.expectEqual(Term{ .exited = 0 }, result.term);
    try std.testing.expectEqualStrings("data: Hello World!\n", result.stdout);
}
