"""Analysis tests for dSYM outputs from cc_common.link."""

load("@bazel_features//:features.bzl", "bazel_features")
load("@bazel_skylib//lib:partial.bzl", "partial")
load("@bazel_skylib//lib:sets.bzl", "sets")
load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts", "unittest")
load(
    ":util.bzl",
    "assert_find_action",
    "assert_flag_set",
    "assert_flag_unset",
    "canonical_label",
)

_APPLE_GENERATE_DSYM = "//command_line_option:apple_generate_dsym"
_EXTRA_TOOLCHAINS = "//command_line_option:extra_toolchains"
_STRIP = "//command_line_option:strip"
_TARGET_PLATFORM = "//command_line_option:platforms"
_SETTINGS_USE_CC_COMMON_LINK = canonical_label("@//zig/settings:use_cc_common_link")
_SETTINGS_ZIGOPT = canonical_label("@//zig/settings:zigopt")

_PLATFORM_ZIG_ONLY_X86_64_LINUX = canonical_label("@//zig/tests/platforms:zig-only-x86_64-linux")
_TOOLCHAIN_UNCONSTRAINED_DEFAULT_TEST = canonical_label("@//zig/tests/platforms:unconstrained_default_test_toolchain")
_TOOLCHAIN_ZIG_ONLY_X86_64_LINUX = canonical_label("@//zig/tests/platforms:zig-only-x86_64-linux_toolchain")

def _dsyms_enabled_test_impl(ctx):
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)
    output_groups = target[OutputGroupInfo]

    asserts.true(env, hasattr(output_groups, "dsyms"), "dSYMs should be exposed when the C++ toolchain enables generate_dsym_file.")
    dsyms = output_groups.dsyms.to_list() if hasattr(output_groups, "dsyms") else []
    asserts.equals(env, 1, len(dsyms), "Exactly one dSYM should be exposed.")
    if dsyms:
        dsym = dsyms[0]
        asserts.true(env, dsym.is_directory, "The dSYM should be a directory artifact.")
        asserts.equals(env, target.label.name + ".dSYM", dsym.basename)

        link = assert_find_action(env, "CppLink")
        asserts.true(env, sets.contains(sets.make(link.outputs.to_list()), dsym), "The CppLink action should produce the dSYM.")

        link_variables = link.argv + getattr(link, "env", {}).values()
        asserts.true(
            env,
            any([dsym.path in value for value in link_variables]),
            "The CppLink command line or environment should contain the dSYM path.",
        )

    for action in analysistest.target_actions(env):
        if action.mnemonic in ["ZigBuildLib", "ZigBuildTest"]:
            assert_flag_unset(env, "-fstrip", action.argv)

    return analysistest.end(env)

_dsyms_enabled_test = analysistest.make(
    _dsyms_enabled_test_impl,
    config_settings = {
        _APPLE_GENERATE_DSYM: True,
        _SETTINGS_USE_CC_COMMON_LINK: True,
        _STRIP: "always",
    },
)

def _dsyms_explicit_fstrip_test_impl(ctx):
    env = analysistest.begin(ctx)
    assert_flag_set(env, "-fstrip", assert_find_action(env, "ZigBuildLib").argv)
    return analysistest.end(env)

_dsyms_explicit_fstrip_test = analysistest.make(
    _dsyms_explicit_fstrip_test_impl,
    config_settings = {
        _APPLE_GENERATE_DSYM: True,
        _SETTINGS_USE_CC_COMMON_LINK: True,
        _SETTINGS_ZIGOPT: ["-fstrip"],
        _STRIP: "always",
    },
)

def _dsyms_strip_debug_symbols_test_impl(ctx):
    env = analysistest.begin(ctx)
    asserts.expect_failure(env, "'strip_debug_symbols' cannot be enabled when generating a dSYM")
    return analysistest.end(env)

_dsyms_strip_debug_symbols_test = analysistest.make(
    _dsyms_strip_debug_symbols_test_impl,
    config_settings = {
        _APPLE_GENERATE_DSYM: True,
        _SETTINGS_USE_CC_COMMON_LINK: True,
    },
    expect_failure = True,
)

def _dsyms_disabled_test_impl(ctx):
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)
    output_groups = target[OutputGroupInfo]

    asserts.false(env, hasattr(output_groups, "dsyms"), "dSYMs should not be exposed when generate_dsym_file is disabled.")
    assert_find_action(env, "CppLink")
    assert_flag_set(env, "-fstrip", assert_find_action(env, "ZigBuildLib").argv)

    return analysistest.end(env)

_dsyms_disabled_test = analysistest.make(
    _dsyms_disabled_test_impl,
    config_settings = {
        _APPLE_GENERATE_DSYM: False,
        _SETTINGS_USE_CC_COMMON_LINK: True,
        _STRIP: "always",
    },
)

def _dsyms_without_cc_toolchain_test_impl(ctx):
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)
    output_groups = target[OutputGroupInfo]

    asserts.false(env, hasattr(output_groups, "dsyms"), "A Zig-only target should not expose a dSYM that no action can create.")
    assert_find_action(env, "ZigBuildExe")
    asserts.false(
        env,
        any([action.mnemonic == "CppLink" for action in analysistest.target_actions(env)]),
        "A Zig-only target should not create a CppLink action.",
    )

    return analysistest.end(env)

def _zig_only_config(generate_dsym):
    return {
        _APPLE_GENERATE_DSYM: generate_dsym,
        _EXTRA_TOOLCHAINS: ",".join([
            _TOOLCHAIN_ZIG_ONLY_X86_64_LINUX,
        ] + ([_TOOLCHAIN_UNCONSTRAINED_DEFAULT_TEST] if bazel_features.toolchains.has_default_test_toolchain_type else [])),
        _SETTINGS_USE_CC_COMMON_LINK: False,
        _TARGET_PLATFORM: _PLATFORM_ZIG_ONLY_X86_64_LINUX,
    }

_dsyms_without_cc_toolchain_requested_test = analysistest.make(
    _dsyms_without_cc_toolchain_test_impl,
    config_settings = _zig_only_config(True),
)

_dsyms_without_cc_toolchain_unrequested_test = analysistest.make(
    _dsyms_without_cc_toolchain_test_impl,
    config_settings = _zig_only_config(False),
)

def dsym_test_suite(name):
    unittest.suite(
        name,
        partial.make(_dsyms_enabled_test, name = "dsym_binary_enabled_test", target_under_test = "//zig/tests/simple-binary:binary", size = "small", target_compatible_with = ["@platforms//os:macos"]),
        partial.make(_dsyms_enabled_test, name = "dsym_shared_library_enabled_test", target_under_test = "//zig/tests/simple-shared-library:shared", size = "small", target_compatible_with = ["@platforms//os:macos"]),
        partial.make(_dsyms_enabled_test, name = "dsym_test_enabled_test", target_under_test = "//zig/tests/simple-test:test", size = "small", target_compatible_with = ["@platforms//os:macos"]),
        partial.make(_dsyms_explicit_fstrip_test, name = "dsym_explicit_fstrip_test", target_under_test = "//zig/tests/simple-binary:binary", size = "small", target_compatible_with = ["@platforms//os:macos"]),
        partial.make(_dsyms_strip_debug_symbols_test, name = "dsym_strip_debug_symbols_test", target_under_test = "//zig/tests/strip_debug_symbols:binary-strip", size = "small", target_compatible_with = ["@platforms//os:macos"]),
        partial.make(_dsyms_disabled_test, name = "dsym_binary_disabled_test", target_under_test = "//zig/tests/simple-binary:binary", size = "small"),
        partial.make(_dsyms_without_cc_toolchain_requested_test, name = "dsym_zig_only_requested_test", target_under_test = "//zig/tests/simple-binary:binary", size = "small"),
        partial.make(_dsyms_without_cc_toolchain_unrequested_test, name = "dsym_zig_only_unrequested_test", target_under_test = "//zig/tests/simple-binary:binary", size = "small"),
    )
