"""Implementation of the zig_toolchain rule."""

load(
    "//zig/private/providers:zig_toolchain_info.bzl",
    "zig_file_toolchain_info",
    "zig_path_toolchain_info",
)

def _zig_bootstrap_transition_impl(_, __):
    return {
        "//zig/settings:bootstrapped": False,
    }

_zig_bootstrap_transition = transition(
    implementation = _zig_bootstrap_transition_impl,
    inputs = [],
    outputs = [
        "//zig/settings:bootstrapped",
    ],
)

DOC = """\
Defines a Zig compiler toolchain.

The Zig compiler toolchain, defined by the `zig_toolchain` rule,
has builtin cross-compilation support.
Meaning, most Zig toolchains can target any platform supported by Zig
independent of the execution platform.

Therefore, there is no need to couple the execution platform
with the target platform, at least not by default.

This rule configures a Zig compiler toolchain
and the corresponding Bazel execution platform constraints
can be declared using the builtin `toolchain` rule.

You will rarely need to invoke this rule directly.
Instead, use the `zig` module extension
provided by `@rules_zig//zig:extensions.bzl`.

Use the target `@rules_zig//zig:resolved_toolchain`
to access the resolved toolchain for the current execution platform.

See https://bazel.build/extending/toolchains#defining-toolchains.
"""

PATH_DOC = """\
Defines a non-hermetic Zig compiler toolchain from absolute paths.

Use this rule when Zig is installed outside Bazel and cannot be exposed as
Bazel files. The executable and library directory paths must be absolute and
available on every execution machine that can run actions using this toolchain.
"""

ATTRS = {
    "exec_target": attr.string(
        doc = "Portable Zig target triple for the SDK execution platform, e.g. x86_64-linux-musl. Required to bootstrap the optional incremental adapter.",
    ),
    "_worker_sources": attr.label(
        default = "//zig/private/worker:sources",
    ),
    "zig_exe": attr.label(
        doc = "A hermetically downloaded Zig executable for the target platform.",
        mandatory = True,
        allow_single_file = True,
        executable = True,
        cfg = "exec",
    ),
    "zig_h": attr.label(
        doc = "The Zig header at the root of the Zig library directory.",
        mandatory = True,
        allow_single_file = True,
    ),
    "zig_lib": attr.label(
        doc = "A source directory containing the hermetic Zig library for the target platform.",
        mandatory = True,
        allow_single_file = True,
    ),
    "zig_version": attr.string(
        doc = "The Zig toolchain's version.",
        mandatory = True,
    ),
    "zig_cache": attr.string(
        doc = "The Zig cache directory prefix. Used for both the global and local cache.",
        mandatory = True,
    ),
}

PATH_ATTRS = {
    "zig_exe_path": attr.string(
        doc = "Absolute path to an existing Zig executable for the target platform.",
        mandatory = True,
    ),
    "zig_lib_path": attr.string(
        doc = "Absolute path to an existing Zig library directory for the target platform.",
        mandatory = True,
    ),
    "zig_version": attr.string(
        doc = "The Zig toolchain's version.",
        mandatory = True,
    ),
    "zig_cache": attr.string(
        doc = "The Zig cache directory prefix. Used for both the global and local cache.",
        mandatory = True,
    ),
}

def _is_absolute_path(path):
    # bazel_skylib paths.is_absolute only supports Unix-style paths.
    return (
        path.startswith("/") or
        path.startswith("\\\\") or
        (len(path) >= 3 and path[1] == ":" and (path[2] == "/" or path[2] == "\\"))
    )

def _validate_absolute_path(*, attr_name, path):
    if not _is_absolute_path(path):
        fail("{} must be an absolute path, got '{}'.".format(attr_name, path))

def _validate_zig_version(ctx, *, zig_exe, tools, zig_version):
    output = ctx.actions.declare_file(ctx.label.name + ".version_validation")
    args = ctx.actions.args()
    args.add_all([zig_exe, zig_version, output])
    ctx.actions.run_shell(
        outputs = [output],
        tools = tools,
        arguments = [args],
        command = "\n".join([
            'actual_version="$("$1" version)"',
            "if [[ $actual_version != $2 ]]; then",
            '  echo "Zig SDK version mismatch. Expected \'$2\' but got \'$actual_version\'." >&2',
            "  exit 1",
            "fi",
            'printf \'\' > "$3"',
        ]),
        mnemonic = "ZigVersionValidation",
        progress_message = "validate Zig SDK version for toolchain %{label}",
    )
    return output

def _zig_toolchain_impl(ctx):
    zig_exe = ctx.executable.zig_exe
    zig_h = ctx.file.zig_h
    zig_lib = ctx.file.zig_lib
    zig_version = ctx.attr.zig_version
    zig_cache = ctx.attr.zig_cache

    validation = _validate_zig_version(
        ctx,
        zig_exe = zig_exe,
        tools = [zig_exe],
        zig_version = zig_version,
    )

    # Validation actions of transitive dependencies do not seem to be picked up
    # by Bazel. So, we need to make the validation output an input of Zig SDK
    # using actions to ensure that it takes place.
    tool_files = [zig_exe, zig_lib, validation]
    incremental_worker = None
    if zig_version == "0.17.0" and ctx.attr.exec_target and not zig_exe.basename.endswith(".exe"):
        # Bootstrap directly from this SDK. A zig_binary dependency here would
        # resolve this toolchain recursively, even with incremental mode off.
        incremental_worker = ctx.actions.declare_file(ctx.label.name + ".worker")
        worker_sources = ctx.attr._worker_sources[DefaultInfo].files
        main = [file for file in worker_sources.to_list() if file.basename == "worker.zig"][0]
        args = ctx.actions.args()
        args.add_all(["build-exe", main, "-target", ctx.attr.exec_target, "-mcpu=baseline", "-O", "ReleaseSafe", "-fstrip"])
        args.add_all(["--zig-lib-dir", zig_lib, "--cache-dir", zig_cache, "--global-cache-dir", zig_cache])
        args.add(incremental_worker, format = "-femit-bin=%s")
        ctx.actions.run(
            executable = zig_exe,
            arguments = [args],
            tools = [zig_exe, zig_lib],
            inputs = depset([validation], transitive = [worker_sources]),
            outputs = [incremental_worker],
            mnemonic = "ZigWorkerBootstrap",
            progress_message = "bootstrap Zig incremental adapter %{label}",
        )
    zigtoolchaininfo = zig_file_toolchain_info(
        zig_exe = zig_exe,
        zig_h = zig_h,
        zig_lib = zig_lib,
        zig_version = zig_version,
        zig_cache = zig_cache,
        validation = validation,
        incremental_worker = incremental_worker,
    )

    # Make the $(tool_BIN) variable available in places like genrules.
    # See https://docs.bazel.build/versions/main/be/make-variables.html#custom_variables
    template_variables = platform_common.TemplateVariableInfo({
        "ZIG_BIN": zig_exe.path,
    })

    default = DefaultInfo(
        files = depset(direct = tool_files),
        runfiles = ctx.runfiles(files = tool_files),
    )

    # Export all the providers inside our ToolchainInfo
    # so the resolved_toolchain rule can grab and re-export them.
    toolchain_info = platform_common.ToolchainInfo(
        zigtoolchaininfo = zigtoolchaininfo,
        template_variables = template_variables,
        default = default,
    )

    return [
        default,
        toolchain_info,
        template_variables,
        OutputGroupInfo(_validation = depset(direct = [validation])),
    ]

def _zig_path_toolchain_impl(ctx):
    zig_exe_path = ctx.attr.zig_exe_path
    zig_lib_path = ctx.attr.zig_lib_path
    zig_version = ctx.attr.zig_version
    zig_cache = ctx.attr.zig_cache

    _validate_absolute_path(attr_name = "zig_exe_path", path = zig_exe_path)
    _validate_absolute_path(attr_name = "zig_lib_path", path = zig_lib_path)

    validation = _validate_zig_version(
        ctx,
        zig_exe = zig_exe_path,
        tools = [],
        zig_version = zig_version,
    )

    zigtoolchaininfo = zig_path_toolchain_info(
        zig_exe_path = zig_exe_path,
        zig_lib_path = zig_lib_path,
        zig_version = zig_version,
        zig_cache = zig_cache,
        validation = validation,
    )

    # Make the $(tool_BIN) variable available in places like genrules.
    # See https://docs.bazel.build/versions/main/be/make-variables.html#custom_variables
    template_variables = platform_common.TemplateVariableInfo({
        "ZIG_BIN": zig_exe_path,
    })

    default = DefaultInfo(
        files = depset(direct = [validation]),
        runfiles = ctx.runfiles(files = [validation]),
    )

    toolchain_info = platform_common.ToolchainInfo(
        zigtoolchaininfo = zigtoolchaininfo,
        template_variables = template_variables,
        default = default,
    )

    return [
        default,
        toolchain_info,
        template_variables,
        OutputGroupInfo(_validation = depset(direct = [validation])),
    ]

zig_toolchain = rule(
    implementation = _zig_toolchain_impl,
    cfg = _zig_bootstrap_transition,
    attrs = ATTRS,
    doc = DOC,
)

zig_path_toolchain = rule(
    implementation = _zig_path_toolchain_impl,
    cfg = _zig_bootstrap_transition,
    attrs = PATH_ATTRS,
    doc = PATH_DOC,
)
