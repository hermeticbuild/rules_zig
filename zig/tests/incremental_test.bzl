"""Analysis checks for the incremental action boundary."""

load("@bazel_skylib//lib:partial.bzl", "partial")
load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts", "unittest")
load("//zig/private/providers:zig_settings_info.bzl", "ZigSettingsInfo")
load(":util.bzl", "assert_find_action", "canonical_label")

_INCREMENTAL = canonical_label("@//zig/settings:incremental")
_PLATFORMS = "//command_line_option:platforms"
_LINUX = canonical_label("@//zig/tests/platforms:x86_64-linux")

def _enabled_impl(ctx):
    env = analysistest.begin(ctx)
    action = assert_find_action(env, "ZigIncrementalCompile")
    asserts.true(env, action.argv[0].endswith(".worker"), "The adapter must come from the selected SDK toolchain.")
    metadata_args = [arg for arg in action.argv if arg.startswith("{")]
    asserts.equals(env, 1, len(metadata_args), "The action must carry one explicit compilation request: " + str(action.argv))
    if metadata_args:
        metadata = json.decode(metadata_args[0])
        asserts.equals(env, 1, metadata["schema"])
        asserts.equals(env, "build-exe", metadata["command"])
        asserts.true(env, metadata["output"].endswith("/binary"))
        input_paths = [file.path for file in action.inputs.to_list()]
        for path in metadata["argument_files"] + [metadata["input_manifest"]]:
            asserts.true(env, path in input_paths, "Request files must be declared action inputs.")
    asserts.false(env, any([arg.startswith("-femit-bin=") for arg in action.argv]))
    asserts.false(env, "--cache-dir" in action.argv)
    asserts.false(env, "--zig-lib-dir" in action.argv)
    assert_find_action(env, "ZigBuildDocs")
    return analysistest.end(env)

_enabled_test = analysistest.make(
    _enabled_impl,
    config_settings = {_INCREMENTAL: True, _PLATFORMS: _LINUX},
)

def _disabled_impl(ctx):
    env = analysistest.begin(ctx)
    action = assert_find_action(env, "ZigBuildExe")
    asserts.true(env, "--cache-dir" in action.argv)
    asserts.true(env, "--zig-lib-dir" in action.argv)
    return analysistest.end(env)

_disabled_test = analysistest.make(_disabled_impl, config_settings = {_INCREMENTAL: False})

def _exec_settings_impl(ctx):
    env = analysistest.begin(ctx)
    asserts.false(env, analysistest.target_under_test(env)[ZigSettingsInfo].incremental, "Execution tools must not inherit target incremental mode.")
    return analysistest.end(env)

_exec_settings_test = analysistest.make(_exec_settings_impl, config_settings = {_INCREMENTAL: True})

def _unsupported_target_impl(ctx):
    env = analysistest.begin(ctx)
    asserts.expect_failure(env, "supports x86_64-linux targets only")
    return analysistest.end(env)

_unsupported_target_test = analysistest.make(
    _unsupported_target_impl,
    config_settings = {
        _INCREMENTAL: True,
        _PLATFORMS: canonical_label("@//zig/tests/platforms:x86_64-windows"),
    },
    expect_failure = True,
)

def incremental_test_suite(name):
    unittest.suite(
        name,
        partial.make(_enabled_test, target_under_test = "//zig/tests/simple-binary:binary", size = "small"),
        partial.make(_disabled_test, target_under_test = "//zig/tests/simple-binary:binary", size = "small"),
        partial.make(_exec_settings_test, target_under_test = "//zig/tests:exec_settings", size = "small"),
        partial.make(_unsupported_target_test, target_under_test = "//zig/tests/simple-binary:binary", size = "small"),
    )
