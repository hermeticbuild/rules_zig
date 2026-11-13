"""Regression test for resolving the same SDK on two execution platforms."""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts")
load("//zig/private:resolved_toolchain.bzl", "resolved_toolchain")
load(":util.bzl", "canonical_label")

_PLATFORMS = ["validation_exec_a", "validation_exec_b"]

def _version_validation_test_impl(ctx):
    env = analysistest.begin(ctx)
    stamps = [
        file.path
        for file in analysistest.target_under_test(env)[DefaultInfo].files.to_list()
        if file.basename.endswith(".version_validation")
    ]
    asserts.equals(env, 2, len({path: None for path in stamps}), "Each execution platform needs its own validation stamp")
    return analysistest.end(env)

_version_validation_test = analysistest.make(
    _version_validation_test_impl,
    config_settings = {
        "//command_line_option:extra_execution_platforms": [
            canonical_label("@//zig/tests:" + platform)
            for platform in _PLATFORMS
        ],
    },
)

def version_validation_test(name):
    """Exercises two resolutions of the same SDK in one target configuration.

    Args:
        name: Name of the regression test.
    """
    native.constraint_setting(name = "validation_exec")
    for platform in _PLATFORMS:
        constraint = ":" + platform + "_constraint"
        native.constraint_value(
            name = platform + "_constraint",
            constraint_setting = ":validation_exec",
        )
        native.platform(
            name = platform,
            constraint_values = [constraint],
            parents = ["@platforms//host"],
        )
        resolved_toolchain(
            name = platform + "_sdk",
            exec_compatible_with = [constraint],
            tags = ["manual"],
        )

    native.filegroup(
        name = "validation_sdks",
        srcs = [":" + platform + "_sdk" for platform in _PLATFORMS],
        tags = ["manual"],
    )
    _version_validation_test(
        name = name,
        size = "small",
        target_under_test = ":validation_sdks",
    )
