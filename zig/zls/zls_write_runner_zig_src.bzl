"""Generates the ZLS runner source file."""

load("@aspect_bazel_lib//lib:paths.bzl", "to_rlocation_path")

def zig_toolchain_executable_rpath(ctx, zigtoolchaininfo):
    if zigtoolchaininfo.zig_exe.file != None:
        return to_rlocation_path(ctx, zigtoolchaininfo.zig_exe.file)
    return zigtoolchaininfo.zig_exe.path

def zig_toolchain_lib_rpath(ctx, zigtoolchaininfo):
    if zigtoolchaininfo.zig_lib.file != None:
        return to_rlocation_path(ctx, zigtoolchaininfo.zig_lib.file)
    return zigtoolchaininfo.zig_lib.path

def _zls_write_runner_zig_src_impl(ctx):
    zigtoolchaininfo = ctx.toolchains["@rules_zig//zig:toolchain_type"].zigtoolchaininfo
    zlstoolchaininfo = ctx.toolchains["@rules_zig//zig/zls:toolchain_type"].zlstoolchaininfo

    zig_exe_rpath = zig_toolchain_executable_rpath(ctx, zigtoolchaininfo)
    zig_lib_rpath = zig_toolchain_lib_rpath(ctx, zigtoolchaininfo)

    zls_runner = ctx.outputs.out
    ctx.actions.expand_template(
        output = zls_runner,
        template = ctx.file._runner_tpl,
        substitutions = {
            "__ZIG_EXE_RPATH__": zig_exe_rpath,
            "__ZIG_LIB_RPATH__": zig_lib_rpath,
            "__ZLS_BIN_RPATH__": to_rlocation_path(ctx, zlstoolchaininfo.bin),
            "__ZLS_BUILD_RUNNER_RPATH__": to_rlocation_path(ctx, ctx.file.build_runner),
            "__GLOBAL_CACHE_PATH__": zigtoolchaininfo.zig_cache,
        },
    )

    return [
        DefaultInfo(
            files = depset([zls_runner]),
            runfiles = ctx.runfiles().merge_all([
                ctx.toolchains["@rules_zig//zig:toolchain_type"].default.default_runfiles,
                ctx.toolchains["@rules_zig//zig/zls:toolchain_type"].default.default_runfiles,
            ]),
        ),
    ]

zls_write_runner_zig_src = rule(
    implementation = _zls_write_runner_zig_src_impl,
    attrs = {
        "out": attr.output(
            mandatory = True,
        ),
        "build_runner": attr.label(
            allow_single_file = True,
            mandatory = True,
        ),
        "_runner_tpl": attr.label(
            default = Label("//zig/zls:zls_runner.zig"),
            allow_single_file = True,
        ),
    },
    toolchains = [
        "//zig:toolchain_type",
        "//zig/zls:toolchain_type",
    ],
)
