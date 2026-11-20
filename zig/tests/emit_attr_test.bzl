"""Analysis tests for Zig emit attributes."""

load("@bazel_skylib//lib:partial.bzl", "partial")
load("@bazel_skylib//lib:sets.bzl", "sets")
load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts", "unittest")
load("@rules_cc//cc/common:cc_info.bzl", "CcInfo")
load(
    ":util.bzl",
    "assert_find_action",
    "assert_flag_set",
    "canonical_label",
)

_SETTINGS_USE_CC_COMMON_LINK = canonical_label("@//zig/settings:use_cc_common_link")

def _find_args_with_prefix(prefix, args):
    return [arg for arg in args if arg.startswith(prefix)]

def _assert_prefixed_arg_unique(env, prefix, args):
    matches = _find_args_with_prefix(prefix, args)
    asserts.equals(env, 1, len(matches), "Expected exactly one '{}' argument.".format(prefix))
    return matches[0] if matches else None

def _assert_prefixed_arg_unset(env, prefix, args):
    matches = _find_args_with_prefix(prefix, args)
    asserts.equals(env, 0, len(matches), "Expected no '{}' arguments.".format(prefix))

def _emit_asm_only_static_library_test_impl(ctx):
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)
    default = target[DefaultInfo]
    output_groups = target[OutputGroupInfo]

    asserts.equals(env, 0, len(default.files.to_list()), "emit_asm-only zig_static_library should not expose a default file.")
    asserts.false(env, CcInfo in target, "emit_asm-only zig_static_library should not export CcInfo.")
    asserts.true(env, hasattr(output_groups, "asm"), "emit_asm-only zig_static_library should expose the asm output group.")

    asm_outputs = output_groups.asm.to_list()
    asserts.equals(env, 1, len(asm_outputs), "emit_asm-only zig_static_library should expose exactly one asm output.")
    asm_output = asm_outputs[0]

    build = assert_find_action(env, "ZigBuildStaticLib")

    assert_flag_set(env, "-fno-emit-bin", build.argv)
    _assert_prefixed_arg_unset(env, "-femit-bin=", build.argv)
    _assert_prefixed_arg_unique(env, "-femit-asm=", build.argv)
    asserts.equals(env, 1, len(build.outputs.to_list()), "emit_asm-only zig_static_library action should only declare the asm output.")
    asserts.true(env, sets.contains(sets.make(build.outputs.to_list()), asm_output), "emit_asm-only zig_static_library should declare the asm output.")

    return analysistest.end(env)

_emit_asm_only_static_library_test = analysistest.make(_emit_asm_only_static_library_test_impl)

def _use_cc_common_link_binary_emit_asm_test_impl(ctx):
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)
    default = target[DefaultInfo]
    output_groups = target[OutputGroupInfo]

    executable = default.files_to_run.executable
    asserts.true(executable != None, "zig_binary should still produce an executable when emit_asm is enabled.")
    asserts.true(env, sets.contains(sets.make(default.files.to_list()), executable), "zig_binary should still expose the executable as the default file.")
    asserts.true(env, hasattr(output_groups, "asm"), "zig_binary should expose the asm output group.")

    asm_outputs = output_groups.asm.to_list()
    asserts.equals(env, 1, len(asm_outputs), "zig_binary should expose exactly one asm output.")
    asm_output = asm_outputs[0]

    build = assert_find_action(env, "ZigBuildObj")

    _assert_prefixed_arg_unique(env, "-femit-asm=", build.argv)
    asserts.true(env, sets.contains(sets.make(build.outputs.to_list()), asm_output), "zig_binary ZigBuildObj action should declare the asm output.")

    return analysistest.end(env)

_use_cc_common_link_binary_emit_asm_test = analysistest.make(
    _use_cc_common_link_binary_emit_asm_test_impl,
    config_settings = {
        _SETTINGS_USE_CC_COMMON_LINK: True,
    },
)

def _zig_binary_emit_asm_test_impl(ctx):
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)
    default = target[DefaultInfo]
    output_groups = target[OutputGroupInfo]

    executable = default.files_to_run.executable
    asserts.true(executable != None, "zig_binary should still produce an executable when emit_asm is enabled.")
    asserts.true(env, sets.contains(sets.make(default.files.to_list()), executable), "zig_binary should still expose the executable as the default file.")
    asserts.true(env, hasattr(output_groups, "asm"), "zig_binary should expose the asm output group.")

    asm_outputs = output_groups.asm.to_list()
    asserts.equals(env, 1, len(asm_outputs), "zig_binary should expose exactly one asm output.")
    asm_output = asm_outputs[0]

    build = assert_find_action(env, "ZigBuildExe")

    _assert_prefixed_arg_unique(env, "-femit-asm=", build.argv)
    asserts.true(env, sets.contains(sets.make(build.outputs.to_list()), asm_output), "zig_binary ZigBuildExe action should declare the asm output.")

    return analysistest.end(env)

_zig_binary_emit_asm_test = analysistest.make(
    _zig_binary_emit_asm_test_impl,
    config_settings = {
        _SETTINGS_USE_CC_COMMON_LINK: False,
    },
)

def _use_cc_common_link_shared_emit_asm_test_impl(ctx):
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)
    default = target[DefaultInfo]
    output_groups = target[OutputGroupInfo]

    dynamic_outputs = default.files.to_list()
    asserts.equals(env, 1, len(dynamic_outputs), "zig_shared_library should still expose one default library file.")
    asserts.true(env, hasattr(output_groups, "asm"), "zig_shared_library should expose the asm output group.")

    asm_outputs = output_groups.asm.to_list()
    asserts.equals(env, 1, len(asm_outputs), "zig_shared_library should expose exactly one asm output.")
    asm_output = asm_outputs[0]

    build = assert_find_action(env, "ZigBuildObj")

    _assert_prefixed_arg_unique(env, "-femit-asm=", build.argv)
    asserts.true(env, sets.contains(sets.make(build.outputs.to_list()), asm_output), "zig_shared_library ZigBuildObj action should declare the asm output.")

    return analysistest.end(env)

_use_cc_common_link_shared_emit_asm_test = analysistest.make(
    _use_cc_common_link_shared_emit_asm_test_impl,
    config_settings = {
        _SETTINGS_USE_CC_COMMON_LINK: True,
    },
)

def _zig_shared_emit_asm_test_impl(ctx):
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)
    default = target[DefaultInfo]
    output_groups = target[OutputGroupInfo]

    dynamic_outputs = default.files.to_list()
    asserts.equals(env, 1, len(dynamic_outputs), "zig_shared_library should still expose one default library file.")
    asserts.true(env, hasattr(output_groups, "asm"), "zig_shared_library should expose the asm output group.")

    asm_outputs = output_groups.asm.to_list()
    asserts.equals(env, 1, len(asm_outputs), "zig_shared_library should expose exactly one asm output.")
    asm_output = asm_outputs[0]

    build = assert_find_action(env, "ZigBuildSharedLib")

    _assert_prefixed_arg_unique(env, "-femit-asm=", build.argv)
    asserts.true(env, sets.contains(sets.make(build.outputs.to_list()), asm_output), "zig_shared_library ZigBuildSharedLib action should declare the asm output.")

    return analysistest.end(env)

_zig_shared_emit_asm_test = analysistest.make(
    _zig_shared_emit_asm_test_impl,
    config_settings = {
        _SETTINGS_USE_CC_COMMON_LINK: False,
    },
)

def _use_cc_common_link_test_emit_outputs_impl(ctx):
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)
    default = target[DefaultInfo]
    output_groups = target[OutputGroupInfo]

    executable = default.files_to_run.executable
    asserts.true(executable != None, "zig_test should still produce an executable when emit outputs are enabled.")
    asserts.true(env, sets.contains(sets.make(default.files.to_list()), executable), "zig_test should still expose the executable as the default file.")
    asserts.true(env, hasattr(output_groups, "asm"), "zig_test should expose the asm output group.")
    asserts.true(env, hasattr(output_groups, "llvm_bc"), "zig_test should expose the llvm_bc output group.")

    asm_output = output_groups.asm.to_list()[0]
    llvm_bc_output = output_groups.llvm_bc.to_list()[0]

    build = assert_find_action(env, "ZigBuildTest")

    _assert_prefixed_arg_unique(env, "-femit-asm=", build.argv)
    _assert_prefixed_arg_unique(env, "-femit-llvm-bc=", build.argv)
    asserts.true(env, sets.contains(sets.make(build.outputs.to_list()), asm_output), "zig_test ZigBuildTest action should declare the asm output.")
    asserts.true(env, sets.contains(sets.make(build.outputs.to_list()), llvm_bc_output), "zig_test ZigBuildTest action should declare the llvm_bc output.")

    return analysistest.end(env)

_use_cc_common_link_test_emit_outputs_test = analysistest.make(
    _use_cc_common_link_test_emit_outputs_impl,
    config_settings = {
        _SETTINGS_USE_CC_COMMON_LINK: True,
    },
)

def _zig_test_emit_outputs_impl(ctx):
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)
    default = target[DefaultInfo]
    output_groups = target[OutputGroupInfo]

    executable = default.files_to_run.executable
    asserts.true(executable != None, "zig_test should still produce an executable when emit outputs are enabled.")
    asserts.true(env, sets.contains(sets.make(default.files.to_list()), executable), "zig_test should still expose the executable as the default file.")
    asserts.true(env, hasattr(output_groups, "asm"), "zig_test should expose the asm output group.")
    asserts.true(env, hasattr(output_groups, "llvm_bc"), "zig_test should expose the llvm_bc output group.")

    asm_output = output_groups.asm.to_list()[0]
    llvm_bc_output = output_groups.llvm_bc.to_list()[0]

    build = assert_find_action(env, "ZigBuildTest")

    _assert_prefixed_arg_unique(env, "-femit-asm=", build.argv)
    _assert_prefixed_arg_unique(env, "-femit-llvm-bc=", build.argv)
    asserts.true(env, sets.contains(sets.make(build.outputs.to_list()), asm_output), "zig_test ZigBuildTest action should declare the asm output.")
    asserts.true(env, sets.contains(sets.make(build.outputs.to_list()), llvm_bc_output), "zig_test ZigBuildTest action should declare the llvm_bc output.")

    return analysistest.end(env)

_zig_test_emit_outputs_test = analysistest.make(
    _zig_test_emit_outputs_impl,
    config_settings = {
        _SETTINGS_USE_CC_COMMON_LINK: False,
    },
)

def emit_attr_test_suite(name):
    unittest.suite(
        name,
        # Test static library emit_asm can be requested without emit_bin.
        partial.make(_emit_asm_only_static_library_test, target_under_test = "//zig/tests/emit-attr:static_emit_asm_only", size = "small"),
        # Test binary emit_asm with and without cc_common.link.
        partial.make(_zig_binary_emit_asm_test, target_under_test = "//zig/tests/emit-attr:binary_emit_asm", size = "small"),
        partial.make(_use_cc_common_link_binary_emit_asm_test, target_under_test = "//zig/tests/emit-attr:binary_emit_asm", size = "small"),
        # Test shared library emit_asm with and without cc_common.link.
        partial.make(_zig_shared_emit_asm_test, target_under_test = "//zig/tests/emit-attr:shared_emit_asm", size = "small"),
        partial.make(_use_cc_common_link_shared_emit_asm_test, target_under_test = "//zig/tests/emit-attr:shared_emit_asm", size = "small"),
        # Test zig_test emit outputs with and without cc_common.link.
        partial.make(_zig_test_emit_outputs_test, target_under_test = "//zig/tests/emit-attr:test_emit_asm_and_bc", size = "small"),
        partial.make(_use_cc_common_link_test_emit_outputs_test, target_under_test = "//zig/tests/emit-attr:test_emit_asm_and_bc", size = "small"),
    )
