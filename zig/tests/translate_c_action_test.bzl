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
            _builtin_translate_c_copts_test,
            target_under_test = "//zig/tests/translate-c-action:c_module_copts",
            size = "small",
        ),
        partial.make(
            _external_translate_c_copts_test,
            target_under_test = "//zig/tests/translate-c-action:c_module_copts",
            size = "small",
        ),
    )
