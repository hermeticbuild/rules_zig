"""Build the worker through ordinary Zig rules without a worker dependency."""

def _disable_incremental_impl(_, __):
    return {"//zig/settings:incremental": False}

_disable_incremental = transition(
    implementation = _disable_incremental_impl,
    inputs = [],
    outputs = ["//zig/settings:incremental"],
)

def _non_incremental_binary_impl(ctx):
    actual = ctx.attr.actual[DefaultInfo]

    # Executable forwarding rules must own their executable artifact. The build
    # itself is still the ordinary zig_binary action behind this symlink.
    executable = ctx.actions.declare_file(ctx.label.name)
    ctx.actions.symlink(
        output = executable,
        target_file = actual.files_to_run.executable,
        is_executable = True,
    )
    return [DefaultInfo(
        executable = executable,
        runfiles = ctx.runfiles(files = [actual.files_to_run.executable]).merge(actual.default_runfiles),
    )]

non_incremental_binary = rule(
    implementation = _non_incremental_binary_impl,
    executable = True,
    cfg = _disable_incremental,
    attrs = {
        "actual": attr.label(mandatory = True, executable = True, cfg = "target"),
        "_allowlist_function_transition": attr.label(
            default = "@bazel_tools//tools/allowlists/function_transition_allowlist",
        ),
    },
)
