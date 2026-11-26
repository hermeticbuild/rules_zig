"""Analysis tests for Zig build use_cc_common_link settings."""

load("@bazel_skylib//lib:partial.bzl", "partial")
load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts", "unittest")
load("//zig/private/providers:zig_settings_info.bzl", "ZigSettingsInfo")
load(
    ":util.bzl",
    "assert_find_action",
    "assert_find_actions_in_exact_order",
    "assert_flag_set",
    "assert_flag_unset",
    "canonical_label",
)

_SETTINGS_USE_CC_COMMON_LINK = canonical_label("@//zig/settings:use_cc_common_link")
_SETTINGS_HOST_USE_CC_COMMON_LINK = canonical_label("@//zig/settings:host_use_cc_common_link")
_LINUX_AMD64 = {"//command_line_option:platforms": canonical_label("@//zig/tests/platforms:x86_64-linux")}
_LINUX_AMD64_COMPATIBILITY = [
    "@platforms//os:linux",
    "@platforms//cpu:x86_64",
]

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

_build_exe_use_cc_common_link_cc_test = _define_build_use_cc_common_link_test(["ZigBuildObj", "CppLink"], use_cc_common_link = True)
_build_exe_use_cc_common_link_zig_test = _define_build_use_cc_common_link_test(["ZigBuildExe"], use_cc_common_link = False)

def _static_library_link_setting_test_impl(ctx):
    env = analysistest.begin(ctx)

    archive = assert_find_action(env, "ZigBuildStaticLib")
    if archive:
        assert_flag_unset(env, "-lc", archive.argv)
        assert_flag_unset(env, "-fcompiler-rt", archive.argv)
    asserts.false(env, any([action.mnemonic == "CppLink" for action in analysistest.target_actions(env)]))

    return analysistest.end(env)

_build_static_lib_use_cc_common_link_cc_test = analysistest.make(
    _static_library_link_setting_test_impl,
    config_settings = {_SETTINGS_USE_CC_COMMON_LINK: True},
)
_build_static_lib_use_cc_common_link_zig_test = analysistest.make(
    _static_library_link_setting_test_impl,
    config_settings = {_SETTINGS_USE_CC_COMMON_LINK: False},
)

_build_shared_lib_use_cc_common_link_cc_test = _define_build_use_cc_common_link_test(["ZigBuildObj", "CppLink"], use_cc_common_link = True)
_build_shared_lib_use_cc_common_link_zig_test = _define_build_use_cc_common_link_test(["ZigBuildSharedLib"], use_cc_common_link = False)

_build_test_use_cc_common_link_cc_test = _define_build_use_cc_common_link_test(["ZigBuildTest", "ZigCompilerRuntime", "CppLink"], use_cc_common_link = True)
_build_test_use_cc_common_link_zig_test = _define_build_use_cc_common_link_test(["ZigBuildTest"], use_cc_common_link = False)

def _define_alwayslink_members_test(mnemonic, pic_suffix):
    def _test_impl(ctx):
        env = analysistest.begin(ctx)
        action = assert_find_action(env, mnemonic)
        if action:
            members = [arg for arg in action.argv if arg.endswith(("registration.o", "registration.pic.o"))]
            asserts.equals(env, 1, len(members))
            if members:
                asserts.true(env, members[0].endswith("registration{}.o".format(pic_suffix)))
                assert_flag_set(env, members[0], [file.path for file in action.inputs.to_list()])
            asserts.true(env, any([arg.endswith("libstate{}.a".format(pic_suffix)) for arg in action.argv]))
            asserts.false(env, any([arg.endswith(("libregistration.lo", "libregistration.pic.lo")) for arg in action.argv]))
        return analysistest.end(env)

    # In opt mode the Linux C++ toolchain exposes both archive variants.
    return analysistest.make(
        _test_impl,
        config_settings = _LINUX_AMD64 | {
            "//command_line_option:compilation_mode": "opt",
            _SETTINGS_USE_CC_COMMON_LINK: False,
        },
    )

_alwayslink_members_test = _define_alwayslink_members_test("ZigBuildExe", "")
_shared_alwayslink_members_test = _define_alwayslink_members_test("ZigBuildSharedLib", ".pic")

def _alwayslink_archive_only_test_impl(ctx):
    env = analysistest.begin(ctx)
    asserts.expect_failure(env, "no member objects are available. Use use_cc_common_link for archive-only imports.")
    return analysistest.end(env)

_alwayslink_archive_only_test = analysistest.make(
    _alwayslink_archive_only_test_impl,
    config_settings = _LINUX_AMD64 | {_SETTINGS_USE_CC_COMMON_LINK: False},
    expect_failure = True,
)

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
        partial.make(_alwayslink_members_test, target_under_test = "//zig/tests/alwayslink:binary", size = "small", target_compatible_with = _LINUX_AMD64_COMPATIBILITY),
        partial.make(_shared_alwayslink_members_test, target_under_test = "//zig/tests/alwayslink:shared", size = "small", target_compatible_with = _LINUX_AMD64_COMPATIBILITY),
        partial.make(_alwayslink_archive_only_test, target_under_test = "//zig/tests/alwayslink:archive_only_binary", size = "small", target_compatible_with = _LINUX_AMD64_COMPATIBILITY),
    )
