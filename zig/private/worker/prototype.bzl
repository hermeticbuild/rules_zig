"""Private experimental binary rule; not part of the rules_zig API."""

load("//zig/private:zig_binary.bzl", "ATTRS", "FRAGMENTS", "TOOLCHAINS")
load("//zig/private/common:zig_build.bzl", "EXEC_GROUPS", "zig_build_impl")

def _impl(ctx):
    providers, output_groups = zig_build_impl(
        ctx,
        kind = "zig_binary",
        incremental_worker = ctx.executable._incremental_worker,
    )
    return providers + [OutputGroupInfo(**output_groups)]

zig_incremental_binary = rule(
    implementation = _impl,
    attrs = ATTRS | {
        "_incremental_worker": attr.label(
            default = "//zig/private/worker:worker",
            executable = True,
            cfg = "exec",
        ),
    },
    executable = True,
    toolchains = TOOLCHAINS,
    exec_groups = EXEC_GROUPS,
    fragments = FRAGMENTS,
)
