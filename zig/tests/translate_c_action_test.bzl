"""Analysis tests for translate-c action selection."""

load("@bazel_skylib//lib:partial.bzl", "partial")
load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts", "unittest")
load(":util.bzl", "assert_find_action", "canonical_label")

_SETTINGS_TRANSLATE_C = canonical_label("@//zig/settings:use_standalone_translate_c")
_EXTRA_TOOLCHAINS = "//command_line_option:extra_toolchains"
_COPTS_INCLUDE = "zig/tests/translate-c-action/copts_include.h"

def _contains_exact(args, value):
    for arg in args:
        if arg == value:
            return True
    return False

def _contains_substring(args, value):
    for arg in args:
        if value in arg:
            return True
    return False

def _builtin_translate_c_action_test_impl(ctx):
    env = analysistest.begin(ctx)

    action = assert_find_action(env, "ZigTranslateC")
    asserts.true(
        env,
        _contains_exact(action.argv, "translate-c"),
        "builtin translate-c action should invoke the Zig translate-c subcommand",
    )
    asserts.false(
        env,
        _contains_substring(action.argv, "fake_translate_c"),
        "builtin translate-c action should not invoke the external translate-c executable",
    )

    return analysistest.end(env)

_builtin_translate_c_action_test = analysistest.make(_builtin_translate_c_action_test_impl)

def _external_translate_c_action_test_impl(ctx):
    env = analysistest.begin(ctx)

    action = assert_find_action(env, "ZigTranslateC")
    asserts.false(
        env,
        _contains_exact(action.argv, "translate-c"),
        "external translate-c action should not invoke the Zig translate-c subcommand",
    )
    asserts.true(
        env,
        _contains_substring(action.argv, "fake_translate_c"),
        "external translate-c action should invoke the external translate-c executable",
    )

    return analysistest.end(env)

_external_translate_c_action_test = analysistest.make(
    _external_translate_c_action_test_impl,
    config_settings = {
        _EXTRA_TOOLCHAINS: "//zig/tests/translate-c-action:fake_translate_c_toolchain",
        _SETTINGS_TRANSLATE_C: True,
    },
)

def _external_translate_c_target_test_impl(ctx):
    env = analysistest.begin(ctx)

    argv = assert_find_action(env, "ZigTranslateC").argv
    asserts.true(env, "--" in argv, "expected the translate-c 2.x option separator")
    if "--" in argv:
        asserts.true(
            env,
            "--target=aarch64-linux-gnu.2.17" in argv[:argv.index("--")],
            "translate-c should receive the configured Zig target before the C arguments",
        )

    return analysistest.end(env)

_external_translate_c_target_test = analysistest.make(
    _external_translate_c_target_test_impl,
    config_settings = {
        _EXTRA_TOOLCHAINS: "//zig/tests/translate-c-action:fake_translate_c_toolchain",
        _SETTINGS_TRANSLATE_C: True,
        "//command_line_option:platforms": canonical_label("@//zig/tests/platforms:aarch64-linux"),
        canonical_label("@zig_toolchains//:version"): "0.17.0",
    },
)

def _translate_c_copts_test_impl(ctx):
    env = analysistest.begin(ctx)

    action = assert_find_action(env, "ZigTranslateC")
    argv = action.argv
    asserts.true(
        env,
        _contains_exact(argv, "-DCOPTS_DEFINE=1"),
        "translate-c action should receive the copts define",
    )
    copts_index = argv.index("-DCOPTS_DEFINE=1")
    asserts.equals(env, "-include", argv[copts_index + 1])
    asserts.equals(env, _COPTS_INCLUDE, argv[copts_index + 2])
    asserts.true(
        env,
        _COPTS_INCLUDE in [file.path for file in action.inputs.to_list()],
        "translate-c action should take the file referenced by copts as an input",
    )

    return analysistest.end(env)

_builtin_translate_c_copts_test = analysistest.make(_translate_c_copts_test_impl)

_external_translate_c_copts_test = analysistest.make(
    _translate_c_copts_test_impl,
    config_settings = {
        _EXTRA_TOOLCHAINS: "//zig/tests/translate-c-action:fake_translate_c_toolchain",
        _SETTINGS_TRANSLATE_C: True,
    },
)

def _sdk_frameworks_test(platform, *, expected_sdk = None, expected_include = None, without_cc = False):
    def _test_impl(ctx):
        env = analysistest.begin(ctx)
        argv = assert_find_action(env, "ZigTranslateC").argv
        frameworks = [argv[i + 1] for i, arg in enumerate(argv) if arg == "-iframework"]
        asserts.equals(env, ["/explicit-frameworks"], frameworks)
        launcher = [i for i, arg in enumerate(argv) if arg.endswith(("/sdk_launcher", "/sdk_launcher.exe"))]
        if expected_sdk:
            asserts.equals(env, 1, len(launcher))
            if launcher:
                start = launcher[0] + 1
                asserts.equals(env, expected_sdk, argv[start:start + 2])
        else:
            asserts.equals(env, [], launcher)
        for path in ["/selected-sdk/usr/include", "/link-sdk/usr/include"]:
            asserts.equals(env, path == expected_include, path in argv)
        if without_cc:
            asserts.false(env, any([action.mnemonic == "CppCompile" for action in analysistest.target_actions(env)]))
        return analysistest.end(env)

    extra_toolchains = "//zig/tests/translate-c-action:fake_translate_c_toolchain"
    if without_cc:
        extra_toolchains += ",//zig/tests/translate-c-action:zig_only_target_toolchain"
    return analysistest.make(
        _test_impl,
        config_settings = {
            _EXTRA_TOOLCHAINS: extra_toolchains,
            _SETTINGS_TRANSLATE_C: True,
            "//command_line_option:platforms": canonical_label("@" + platform),
        },
    )

_macos_sdk_frameworks_test = _sdk_frameworks_test("//zig/tests/platforms:aarch64-macos", expected_sdk = ["macosx", "/selected-sdk"])
_macos_sdk_without_cc_test = _sdk_frameworks_test("//zig/tests/translate-c-action:zig-only-macos", expected_sdk = ["macosx", "/selected-sdk"], without_cc = True)
_macos_no_standard_includes_test = _sdk_frameworks_test("//zig/tests/platforms:aarch64-macos")
_linux_sdk_frameworks_test = _sdk_frameworks_test("//zig/tests/platforms:aarch64-linux", expected_include = "/link-sdk/usr/include")
_linux_no_standard_includes_test = _sdk_frameworks_test("//zig/tests/platforms:aarch64-linux")

def translate_c_action_test_suite(name):
    unittest.suite(
        name,
        partial.make(
            _builtin_translate_c_action_test,
            target_under_test = "//zig/tests/translate-c-action:c_module",
            size = "small",
        ),
        partial.make(
            _external_translate_c_action_test,
            target_under_test = "//zig/tests/translate-c-action:c_module",
            size = "small",
        ),
        partial.make(
            _external_translate_c_target_test,
            target_under_test = "//zig/tests/translate-c-action:c_module_cross",
            size = "small",
        ),
        partial.make(
            _builtin_translate_c_copts_test,
            target_under_test = "//zig/tests/translate-c-action:c_module_copts",
            size = "small",
        ),
        partial.make(
            _external_translate_c_copts_test,
            target_under_test = "//zig/tests/translate-c-action:c_module_copts",
            size = "small",
        ),
        partial.make(
            _macos_sdk_frameworks_test,
            target_under_test = "//zig/tests/translate-c-action:c_module_sdk",
            size = "small",
        ),
        partial.make(
            _macos_no_standard_includes_test,
            target_under_test = "//zig/tests/translate-c-action:c_module_no_standard_includes",
            size = "small",
        ),
        partial.make(
            _macos_sdk_without_cc_test,
            target_under_test = "//zig/tests/translate-c-action:c_module_sdk",
            size = "small",
        ),
        partial.make(
            _linux_sdk_frameworks_test,
            target_under_test = "//zig/tests/translate-c-action:c_module_sdk",
            size = "small",
        ),
        partial.make(
            _linux_no_standard_includes_test,
            target_under_test = "//zig/tests/translate-c-action:c_module_no_standard_includes",
            size = "small",
        ),
    )
