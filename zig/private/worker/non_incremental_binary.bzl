"""Build the worker through ordinary Zig rules without a worker dependency."""

def _disable_worker_impl(_, __):
    return {
        "//zig/settings:incremental": False,
        "//zig/settings:use_worker": False,
    }

_disable_worker = transition(
    implementation = _disable_worker_impl,
    inputs = [],
    outputs = ["//zig/settings:incremental", "//zig/settings:use_worker"],
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
    cfg = _disable_worker,
    attrs = {
        "actual": attr.label(mandatory = True, executable = True, cfg = "target"),
        "_allowlist_function_transition": attr.label(
            default = "@bazel_tools//tools/allowlists/function_transition_allowlist",
        ),
    },
)
