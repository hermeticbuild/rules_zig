"""Real generated and external inputs for worker integration tests."""

def _generated_impl(ctx):
    main = ctx.actions.declare_file("generated/main.zig")
    assets = ctx.actions.declare_directory("generated/assets")
    ctx.actions.run(
        executable = ctx.executable._generator,
        arguments = [main.path, assets.path, ctx.file.source.path],
        inputs = [ctx.file.source],
        outputs = [main, assets],
    )
    return [DefaultInfo(files = depset([main])), OutputGroupInfo(assets = depset([assets]))]

incremental_generated = rule(
    implementation = _generated_impl,
    attrs = {
        "source": attr.label(allow_single_file = True),
        "_generator": attr.label(default = "//:incremental_generator", executable = True, cfg = "exec"),
    },
)

def _dependency_impl(ctx):
    ctx.symlink(ctx.path(ctx.attr.source), "value.zig")
    ctx.file("BUILD.bazel", 'exports_files(["value.zig"])\n')

incremental_dependency = repository_rule(
    implementation = _dependency_impl,
    attrs = {"source": attr.label(allow_single_file = True)},
    local = True,
)
