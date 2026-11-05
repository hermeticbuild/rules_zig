"""Analysis tests for Zig build use_cc_common_link settings."""

load("@bazel_skylib//lib:partial.bzl", "partial")
load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts", "unittest")
load("//zig/private/providers:zig_settings_info.bzl", "ZigSettingsInfo")
load(
    ":util.bzl",
    "assert_find_actions_in_exact_order",
    "canonical_label",
)

_SETTINGS_USE_CC_COMMON_LINK = canonical_label("@//zig/settings:use_cc_common_link")
_SETTINGS_HOST_USE_CC_COMMON_LINK = canonical_label("@//zig/settings:host_use_cc_common_link")

def _define_settings_use_cc_common_link_test(use_cc_common_link):
    def _test_impl(ctx):
        env = analysistest.begin(ctx)

        settings = analysistest.target_under_test(env)[ZigSettingsInfo]
        asserts.equals(env, use_cc_common_link, settings.use_cc_common_link)

        return analysistest.end(env)

    return analysistest.make(
        _test_impl,
        config_settings = {_SETTINGS_USE_CC_COMMON_LINK: use_cc_common_link},
    )

_settings_use_cc_common_link_cc_test = _define_settings_use_cc_common_link_test(use_cc_common_link = True)
_settings_use_cc_common_link_zig_test = _define_settings_use_cc_common_link_test(use_cc_common_link = False)

def _define_exec_settings_use_cc_common_link_test(target_use_cc_common_link, host_use_cc_common_link):
    def _test_impl(ctx):
        env = analysistest.begin(ctx)

        settings = analysistest.target_under_test(env)[ZigSettingsInfo]
        asserts.equals(env, host_use_cc_common_link, settings.use_cc_common_link)

        return analysistest.end(env)

    return analysistest.make(
        _test_impl,
        config_settings = {
            _SETTINGS_USE_CC_COMMON_LINK: target_use_cc_common_link,
            _SETTINGS_HOST_USE_CC_COMMON_LINK: host_use_cc_common_link,
        },
    )

_settings_exec_use_cc_common_link_test = _define_exec_settings_use_cc_common_link_test(False, True)

def _define_build_use_cc_common_link_test(mnemonics, use_cc_common_link):
    def _test_impl(ctx):
        env = analysistest.begin(ctx)

        assert_find_actions_in_exact_order(env, mnemonics)

        return analysistest.end(env)

    return analysistest.make(
        _test_impl,
        config_settings = {_SETTINGS_USE_CC_COMMON_LINK: use_cc_common_link},
    )

_build_exe_use_cc_common_link_cc_test = _define_build_use_cc_common_link_test(["ZigBuildLib", "CppLink"], use_cc_common_link = True)
_build_exe_use_cc_common_link_zig_test = _define_build_use_cc_common_link_test(["ZigBuildExe"], use_cc_common_link = False)

_build_static_lib_use_cc_common_link_cc_test = _define_build_use_cc_common_link_test(["ZigBuildStaticLib"], use_cc_common_link = True)
_build_static_lib_use_cc_common_link_zig_test = _define_build_use_cc_common_link_test(["ZigBuildStaticLib"], use_cc_common_link = False)

_build_shared_lib_use_cc_common_link_cc_test = _define_build_use_cc_common_link_test(["ZigBuildLib", "CppLink"], use_cc_common_link = True)
_build_shared_lib_use_cc_common_link_zig_test = _define_build_use_cc_common_link_test(["ZigBuildSharedLib"], use_cc_common_link = False)

_build_test_use_cc_common_link_cc_test = _define_build_use_cc_common_link_test(["ZigBuildLib", "CppLink"], use_cc_common_link = True)
_build_test_use_cc_common_link_zig_test = _define_build_use_cc_common_link_test(["ZigBuildTest"], use_cc_common_link = False)

def use_cc_common_link_test_suite(name):
    unittest.suite(
        name,
        # Test Zig build mode on the settings target
        partial.make(_settings_use_cc_common_link_cc_test, target_under_test = "//zig/settings", size = "small"),
        partial.make(_settings_use_cc_common_link_zig_test, target_under_test = "//zig/settings", size = "small"),
        # Test Zig exec use_cc_common_link setting uses host_use_cc_common_link instead of use_cc_common_link
        partial.make(_settings_exec_use_cc_common_link_test, target_under_test = "//zig/tests:exec_settings", size = "small"),
        # Test Zig build use_cc_common_link on a binary target
        partial.make(_build_exe_use_cc_common_link_cc_test, target_under_test = "//zig/tests/simple-binary:binary", size = "small"),
        partial.make(_build_exe_use_cc_common_link_zig_test, target_under_test = "//zig/tests/simple-binary:binary", size = "small"),
        # Test Zig build use_cc_common_link on a library target
        partial.make(_build_static_lib_use_cc_common_link_cc_test, target_under_test = "//zig/tests/simple-library:library", size = "small"),
        partial.make(_build_static_lib_use_cc_common_link_zig_test, target_under_test = "//zig/tests/simple-library:library", size = "small"),
        # Test Zig build use_cc_common_link on a shared library target
        partial.make(_build_shared_lib_use_cc_common_link_cc_test, target_under_test = "//zig/tests/simple-shared-library:shared", size = "small"),
        partial.make(_build_shared_lib_use_cc_common_link_zig_test, target_under_test = "//zig/tests/simple-shared-library:shared", size = "small"),
        # Test Zig build use_cc_common_link on a test target
        partial.make(_build_test_use_cc_common_link_cc_test, target_under_test = "//zig/tests/simple-test:test", size = "small"),
        partial.make(_build_test_use_cc_common_link_zig_test, target_under_test = "//zig/tests/simple-test:test", size = "small"),
        # The final link accepts cpp_link-scoped execution properties.
        partial.make(_build_exe_use_cc_common_link_cc_test, target_under_test = "//zig/tests/simple-binary:binary_link_exec_properties", size = "small"),
    )
