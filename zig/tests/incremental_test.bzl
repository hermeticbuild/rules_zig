"""Analysis checks for the incremental action boundary."""

load("@bazel_skylib//lib:partial.bzl", "partial")
load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts", "unittest")
load("//zig/private/providers:zig_settings_info.bzl", "ZigSettingsInfo")
load(":util.bzl", "assert_find_action", "canonical_label")

_INCREMENTAL = canonical_label("@//zig/settings:incremental")
_PLATFORMS = "//command_line_option:platforms"
_LINUX = canonical_label("@//zig/tests/platforms:x86_64-linux")
_EXEC_PLATFORMS = "//command_line_option:extra_execution_platforms"

def _assert_incremental(env, command, output_kind):
    action = assert_find_action(env, "ZigIncrementalCompile")
    asserts.true(env, action.argv[0].endswith(".worker"), "The adapter must come from the selected SDK toolchain.")
    metadata_args = [arg for arg in action.argv if arg.startswith("{")]
    asserts.equals(env, 1, len(metadata_args), "The action must carry one explicit compilation request: " + str(action.argv))
    if metadata_args:
        metadata = json.decode(metadata_args[0])
        asserts.equals(env, 2, metadata["schema"])
        asserts.equals(env, command, metadata["command"])
        asserts.equals(env, output_kind, metadata["output_kind"])
        header_index = action.argv.index(metadata_args[0])
        asserts.true(env, action.argv[header_index + 1] in [file.path for file in action.outputs.to_list()])
        input_paths = [file.path for file in action.inputs.to_list()]
        for arg in action.argv:
            if arg.startswith("input="):
                asserts.true(env, arg[len("input="):] in input_paths, "The framed request must name declared inputs.")
        asserts.false(env, any([path.endswith(".zig-inputs") or path.endswith(".zig-global.args") or path.endswith(".zig-module.args") for path in input_paths]))
    asserts.false(env, any([arg.startswith("-femit-bin=") for arg in action.argv]))
    asserts.false(env, "--cache-dir" in action.argv)
    asserts.false(env, "--zig-lib-dir" in action.argv)

def _enabled_test_for(command, output_kind):
    def _impl(ctx):
        env = analysistest.begin(ctx)
        _assert_incremental(env, command, output_kind)
        assert_find_action(env, "ZigBuildDocs")
        return analysistest.end(env)

    return analysistest.make(_impl, config_settings = {_INCREMENTAL: True, _PLATFORMS: _LINUX, _EXEC_PLATFORMS: [_LINUX]})

_enabled_test = _enabled_test_for("build-exe", "executable")
_test_compile_test = _enabled_test_for("test", "executable")
_static_test = _enabled_test_for("build-lib", "static_library")
_shared_test = _enabled_test_for("build-lib", "shared_library")

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

def _failure_test(message, settings = {}):
    def _impl(ctx):
        env = analysistest.begin(ctx)
        asserts.expect_failure(env, message)
        return analysistest.end(env)

    return analysistest.make(
        _impl,
        config_settings = {_INCREMENTAL: True, _PLATFORMS: _LINUX, _EXEC_PLATFORMS: [_LINUX]} | settings,
        expect_failure = True,
    )

_unsupported_arch_test = _failure_test(
    "supports x86_64-linux targets only",
    {_PLATFORMS: canonical_label("@//zig/tests/platforms:aarch64-linux")},
)
_unsupported_link_test = _failure_test(
    "use_cc_common_link=False",
    {canonical_label("@//zig/settings:use_cc_common_link"): True},
)
_unsupported_outputs_test = _failure_test("no native dependencies or auxiliary outputs")
_unsupported_sdk_test = _failure_test(
    "requires a hermetic Zig 0.17.0 toolchain",
    {canonical_label("@zig_toolchains//:version"): "0.16.0"},
)

def incremental_test_suite(name):
    unittest.suite(
        name,
        partial.make(_enabled_test, target_under_test = "//zig/tests/simple-binary:binary", size = "small"),
        partial.make(_test_compile_test, target_under_test = "//zig/tests/simple-test:test", size = "small"),
        partial.make(_static_test, target_under_test = "//zig/tests/simple-library:library", size = "small"),
        partial.make(_shared_test, target_under_test = "//zig/tests/simple-shared-library:shared", size = "small"),
        partial.make(_disabled_test, target_under_test = "//zig/tests/simple-binary:binary", size = "small"),
        partial.make(_exec_settings_test, target_under_test = "//zig/tests:exec_settings", size = "small"),
        partial.make(_unsupported_target_test, target_under_test = "//zig/tests/simple-binary:binary", size = "small"),
        partial.make(_unsupported_arch_test, target_under_test = "//zig/tests/simple-binary:binary", size = "small"),
        partial.make(_unsupported_link_test, target_under_test = "//zig/tests/simple-test:test", size = "small"),
        partial.make(_unsupported_outputs_test, target_under_test = "//zig/tests/emit-attr:binary_emit_asm", size = "small"),
        partial.make(_unsupported_outputs_test, target_under_test = "//zig/tests/emit-attr:static_emit_asm_only", size = "small"),
        partial.make(_unsupported_outputs_test, target_under_test = "//zig/tests/emit-attr:shared_emit_asm", size = "small"),
        partial.make(_unsupported_outputs_test, target_under_test = "//zig/tests/emit-attr:test_emit_asm_and_bc", size = "small"),
        partial.make(_unsupported_outputs_test, target_under_test = "//zig/tests/c-sources-binary:without-copts", size = "small"),
        partial.make(_unsupported_sdk_test, target_under_test = "//zig/tests/simple-library:library", size = "small"),
    )
