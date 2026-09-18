"""Analysis tests for rules
See https://bazel.build/rules/testing#testing-rules
"""

load("@bazel_skylib//lib:sets.bzl", "sets")
load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts")
load("@rules_cc//cc/common:cc_info.bzl", "CcInfo")
load("//zig/private/providers:zig_settings_info.bzl", "ZigSettingsInfo")
load(
    ":util.bzl",
    "assert_find_unique_surrounded_arguments",
    "assert_flag_set",
    "assert_flag_unset",
    "canonical_label",
)

_COMPILATION_MODE = "//command_line_option:compilation_mode"
_STRIP = "//command_line_option:strip"
_SETTINGS_USE_CC_COMMON_LINK = canonical_label("@//zig/settings:use_cc_common_link")

def _simple_binary_test_impl(ctx):
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)
    default = target[DefaultInfo]

    executable = default.files_to_run.executable
    asserts.true(executable != None, "zig_binary should produce an executable.")
    asserts.true(sets.contains(sets.make(default.files.to_list()), executable), "zig_binary should return the executable as an output.")
    asserts.true(sets.contains(sets.make(default.default_runfiles.files.to_list()), executable), "zig_binary should return the executable in the runfiles.")

    build = [
        action
        for action in analysistest.target_actions(env)
        if action.mnemonic == "ZigBuildExe"
    ]
    asserts.equals(env, 1, len(build), "zig_binary should generate one ZigBuildExe action.")
    build = build[0]
    asserts.true(sets.contains(sets.make(build.outputs.to_list()), executable), "zig_binary should generate a ZigBuildExe action that generates the binary.")

    return analysistest.end(env)

_simple_binary_test = analysistest.make(_simple_binary_test_impl)

def _test_simple_binary(name):
    _simple_binary_test(
        name = name,
        target_under_test = "//zig/tests/simple-binary:binary",
        size = "small",
    )
    return [":" + name]

def _simple_static_library_test_impl(ctx):
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)
    default = target[DefaultInfo]
    cc = target[CcInfo]
    output_groups = target[OutputGroupInfo]

    linker_inputs = cc.linking_context.linker_inputs.to_list()
    asserts.equals(env, 1, len(linker_inputs), "zig_static_library should generate one linker input.")
    libraries = linker_inputs[0].libraries
    asserts.equals(env, 1, len(libraries), "zig_static_library should generate one library.")
    static = libraries[0].static_library
    asserts.true(env, static != None, "zig_static_library should produce a static library.")
    asserts.true(env, sets.contains(sets.make(default.files.to_list()), static), "zig_static_library should return the static library as an output.")

    compilation_context = cc.compilation_context
    headers = compilation_context.headers.to_list()
    asserts.equals(
        env,
        0,
        len(headers),
        "zig_static_library should not generate a header by default.",
    )

    asserts.false(
        env,
        hasattr(output_groups, "header"),
        "zig_static_library should not generate a header by default.",
    )

    build = [
        action
        for action in analysistest.target_actions(env)
        if action.mnemonic == "ZigBuildStaticLib"
    ]
    asserts.equals(env, 1, len(build), "zig_static_library should generate one ZigBuildStaticLib action.")
    build = build[0]
    asserts.true(env, sets.contains(sets.make(build.outputs.to_list()), static), "zig_static_library should generate a ZigBuildStaticLib action that generates the static library.")

    return analysistest.end(env)

_simple_static_library_test = analysistest.make(_simple_static_library_test_impl)

def _test_simple_static_library(name):
    _simple_static_library_test(
        name = name,
        target_under_test = "//zig/tests/simple-library:library",
        size = "small",
    )
    return [":" + name]

def _transitive_static_library_test_impl(ctx):
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)
    default = target[DefaultInfo]
    indirect_default = ctx.attr.indirect[DefaultInfo]
    cc = target[CcInfo]

    linker_inputs = cc.linking_context.linker_inputs.to_list()
    asserts.equals(env, 2, len(linker_inputs), "zig_static_library should generate two linker inputs.")
    libraries = [lib for input in linker_inputs for lib in input.libraries]
    asserts.equals(env, 2, len(libraries), "zig_static_library should generate two libraries.")
    statics = [lib.static_library for lib in libraries if lib.static_library != None]
    asserts.equals(env, 2, len(statics), "zig_static_library should generate two static libraries.")
    asserts.true(
        env,
        sets.length(sets.intersection(sets.make(default.files.to_list()), sets.make(statics))) != 0,
        "zig_static_library should return the static library as an output.",
    )
    asserts.true(
        env,
        sets.length(sets.intersection(sets.make(indirect_default.files.to_list()), sets.make(statics))) != 0,
        "zig_static_library should capture transitive static library dependencies.",
    )

    return analysistest.end(env)

_transitive_static_library_test = analysistest.make(
    _transitive_static_library_test_impl,
    attrs = {
        "indirect": attr.label(mandatory = True),
    },
)

def _test_transitive_static_library(name):
    _transitive_static_library_test(
        name = name,
        target_under_test = "//zig/tests/transitive-library:direct",
        indirect = "//zig/tests/transitive-library:indirect",
        size = "small",
    )
    return [":" + name]

def _simple_shared_library_test_impl(ctx):
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)
    default = target[DefaultInfo]
    cc = target[CcInfo]

    linker_inputs = cc.linking_context.linker_inputs.to_list()
    asserts.equals(env, 1, len(linker_inputs), "zig_shared_library should generate one linker input.")
    libraries = linker_inputs[0].libraries
    asserts.equals(env, 1, len(libraries), "zig_shared_library should generate one library.")
    dynamic = libraries[0].resolved_symlink_dynamic_library
    asserts.true(env, dynamic != None, "zig_shared_library should produce a dynamic library.")
    asserts.true(env, sets.contains(sets.make(default.files.to_list()), dynamic), "zig_shared_library should return the dynamic library as an output.")

    build = [
        action
        for action in analysistest.target_actions(env)
        if action.mnemonic == "ZigBuildSharedLib"
    ]
    asserts.equals(env, 1, len(build), "zig_shared_library should generate one ZigBuildSharedLib action.")
    build = build[0]
    asserts.true(env, sets.contains(sets.make(build.outputs.to_list()), dynamic), "zig_shared_library should generate a ZigBuildSharedLib action that generates the dynamic library.")

    return analysistest.end(env)

_simple_shared_library_test = analysistest.make(_simple_shared_library_test_impl)

def _test_simple_shared_library(name):
    _simple_shared_library_test(
        name = name,
        target_under_test = "//zig/tests/simple-shared-library:shared",
        size = "small",
    )
    return [":" + name]

def _transitive_shared_library_test_impl(ctx):
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)
    default = target[DefaultInfo]
    indirect_default = ctx.attr.indirect[DefaultInfo]
    cc = target[CcInfo]

    linker_inputs = cc.linking_context.linker_inputs.to_list()
    asserts.equals(env, 2, len(linker_inputs), "zig_shared_library should generate two linker inputs.")
    libraries = [lib for input in linker_inputs for lib in input.libraries]
    asserts.equals(env, 2, len(libraries), "zig_shared_library should generate two libraries.")
    dynamics = []
    for lib in libraries:
        if lib.resolved_symlink_dynamic_library != None:
            dynamics.append(lib.resolved_symlink_dynamic_library)
        elif lib.dynamic_library != None:
            dynamics.append(lib.dynamic_library)
    asserts.equals(env, 2, len(dynamics), "zig_shared_library should generate two dynamic libraries.")
    asserts.true(
        env,
        sets.length(sets.intersection(sets.make(default.files.to_list()), sets.make(dynamics))) != 0,
        "zig_shared_library should return the dynamic library as an output.",
    )
    asserts.true(
        env,
        sets.length(sets.intersection(sets.make(indirect_default.files.to_list()), sets.make(dynamics))) != 0,
        "zig_shared_library should capture transitive dynamic library dependencies.",
    )

    return analysistest.end(env)

_transitive_shared_library_test = analysistest.make(
    _transitive_shared_library_test_impl,
    attrs = {
        "indirect": attr.label(mandatory = True),
    },
)

def _test_transitive_shared_library(name):
    _transitive_shared_library_test(
        name = name,
        target_under_test = "//zig/tests/transitive-shared-library:direct",
        indirect = "//zig/tests/transitive-shared-library:indirect",
        size = "small",
    )
    return [":" + name]

def _multiple_sources_binary_test_impl(ctx):
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)
    default = target[DefaultInfo]

    executable = default.files_to_run.executable
    main = ctx.file.main

    build = [
        action
        for action in analysistest.target_actions(env)
        if action.mnemonic == "ZigBuildExe"
    ]
    asserts.equals(env, 1, len(build), "zig_binary should generate one ZigBuildExe action.")
    build = build[0]

    # The position in the action input and output matters for the progress_message.
    asserts.equals(env, main, build.inputs.to_list()[0], "the main source should be the first input.")
    asserts.equals(env, executable, build.outputs.to_list()[0], "the binary should be the first output.")

    return analysistest.end(env)

_multiple_sources_binary_test = analysistest.make(
    _multiple_sources_binary_test_impl,
    attrs = {
        "main": attr.label(
            allow_single_file = True,
            mandatory = True,
        ),
    },
)

def _test_multiple_sources_binary(name):
    _multiple_sources_binary_test(
        name = name,
        target_under_test = "//zig/tests/multiple-sources-binary:binary",
        main = "//zig/tests/multiple-sources-binary:main.zig",
        size = "small",
    )
    return [":" + name]

def _module_binary_test_impl(ctx):
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)
    default = target[DefaultInfo]

    executable = default.files_to_run.executable
    main = ctx.file.main

    build = [
        action
        for action in analysistest.target_actions(env)
        if action.mnemonic == "ZigBuildExe"
    ]
    asserts.equals(env, 1, len(build), "zig_binary should generate one ZigBuildExe action.")
    build = build[0]

    # The position in the action input and output matters for the progress_message.
    asserts.equals(env, main, build.inputs.to_list()[0], "the main source should be the first input.")
    asserts.equals(env, executable, build.outputs.to_list()[0], "the binary should be the first output.")

    return analysistest.end(env)

_module_binary_test = analysistest.make(
    _module_binary_test_impl,
    attrs = {
        "main": attr.label(
            allow_single_file = True,
            mandatory = True,
        ),
    },
)

def _test_module_binary(name):
    _module_binary_test(
        name = name,
        target_under_test = "//zig/tests/module-binary:binary",
        main = "//zig/tests/module-binary:main.zig",
        size = "small",
    )
    return [":" + name]

def _c_sources_binary_test_impl(ctx):
    env = analysistest.begin(ctx)

    csrcs = ctx.files.csrcs
    copts = ctx.attr.copts

    build = [
        action
        for action in analysistest.target_actions(env)
        if action.mnemonic == "ZigBuildExe"
    ]
    asserts.equals(env, 1, len(build), "zig_binary should generate one ZigBuildExe action.")
    build = build[0]

    for csrc in csrcs:
        asserts.true(
            env,
            sets.contains(sets.make(build.argv), csrc.path),
            "ZigBuildExe argv should contain C source file " + csrc.path,
        )

    if copts:
        build_copts = assert_find_unique_surrounded_arguments(env, "-cflags", "--", build.argv)
        asserts.equals(env, copts, build_copts, "C compiler flags did not match expectations.")
    else:
        assert_flag_unset(env, "-cflags", build.argv)

    return analysistest.end(env)

_c_sources_binary_test = analysistest.make(
    _c_sources_binary_test_impl,
    attrs = {
        "csrcs": attr.label_list(
            allow_files = True,
            mandatory = True,
        ),
        "copts": attr.string_list(
            mandatory = False,
        ),
    },
)

def _test_c_sources_binary(name):
    _c_sources_binary_test(
        name = name + "_with_copts",
        target_under_test = "//zig/tests/c-sources-binary:with-copts",
        csrcs = [
            "//zig/tests/c-sources-binary:symbol_a.c",
            "//zig/tests/c-sources-binary:symbol_b.c",
        ],
        copts = ["-DNUMBER_A=1", "-DNUMBER_B=2"],
        size = "small",
    )
    _c_sources_binary_test(
        name = name + "_without_copts",
        target_under_test = "//zig/tests/c-sources-binary:without-copts",
        csrcs = [
            "//zig/tests/c-sources-binary:symbol_a.c",
            "//zig/tests/c-sources-binary:symbol_b.c",
        ],
        copts = [],
        size = "small",
    )
    return [":" + name + "_with_copts", ":" + name + "_without_copts"]

def _compiler_runtime_test_impl(ctx):
    env = analysistest.begin(ctx)

    build = [
        action
        for action in analysistest.target_actions(env)
        if action.mnemonic in ["ZigBuildExe", "ZigBuildTest", "ZigBuildStaticLib", "ZigBuildSharedLib"]
    ]
    asserts.equals(env, 1, len(build), "Target should have one ZigBuild* action.")
    build = build[0]

    if ctx.attr.compiler_runtime == "include":
        assert_flag_set(env, "-fcompiler-rt", build.argv)
        assert_flag_unset(env, "-fno-compiler-rt", build.argv)
    elif ctx.attr.compiler_runtime == "exclude":
        assert_flag_set(env, "-fno-compiler-rt", build.argv)
        assert_flag_unset(env, "-fcompiler-rt", build.argv)
    else:
        assert_flag_unset(env, "-fcompiler-rt", build.argv)
        assert_flag_unset(env, "-fno-compiler-rt", build.argv)

    return analysistest.end(env)

_compiler_runtime_test = analysistest.make(
    _compiler_runtime_test_impl,
    attrs = {
        "compiler_runtime": attr.string(mandatory = False),
    },
)

def _test_compiler_runtime(name):
    _compiler_runtime_test(
        name = name + "-binary",
        target_under_test = "//zig/tests/compiler_runtime:binary",
        compiler_runtime = None,
        size = "small",
    )
    _compiler_runtime_test(
        name = name + "-library-exclude",
        target_under_test = "//zig/tests/compiler_runtime:library-exclude",
        compiler_runtime = "exclude",
        size = "small",
    )
    _compiler_runtime_test(
        name = name + "-shared-library-default",
        target_under_test = "//zig/tests/compiler_runtime:shared-library-default",
        compiler_runtime = "default",
        size = "small",
    )
    _compiler_runtime_test(
        name = name + "-test-include",
        target_under_test = "//zig/tests/compiler_runtime:test-include",
        compiler_runtime = "include",
        size = "small",
    )
    return [
        name + "-binary",
        name + "-library-exclude",
        name + "-shared-library-default",
        name + "-test-include",
    ]

def _strip_debug_symbols_test_impl(ctx):
    env = analysistest.begin(ctx)

    build = [
        action
        for action in analysistest.target_actions(env)
        if action.mnemonic in ["ZigBuildExe", "ZigBuildTest", "ZigBuildStaticLib", "ZigBuildSharedLib"]
    ]
    asserts.equals(env, 1, len(build), "Target should have one ZigBuild* action.")
    build = build[0]

    if ctx.attr.strip_debug_symbols:
        assert_flag_set(env, "-fstrip", build.argv)
    else:
        assert_flag_unset(env, "-fstrip", build.argv)

    return analysistest.end(env)

_strip_debug_symbols_test = analysistest.make(
    _strip_debug_symbols_test_impl,
    attrs = {
        "strip_debug_symbols": attr.bool(mandatory = False),
    },
    config_settings = {
        _STRIP: "never",
    },
)

def _define_bazel_strip_settings_test(*, strip, compilation_mode, expected_strip):
    def _test_impl(ctx):
        env = analysistest.begin(ctx)

        settings = analysistest.target_under_test(env)[ZigSettingsInfo]
        asserts.equals(env, expected_strip, settings.strip)
        if expected_strip:
            assert_flag_set(env, "-fstrip", settings.args)
        else:
            assert_flag_unset(env, "-fstrip", settings.args)

        return analysistest.end(env)

    return analysistest.make(
        _test_impl,
        config_settings = {
            _COMPILATION_MODE: compilation_mode,
            _STRIP: strip,
        },
    )

_bazel_strip_settings_always_test = _define_bazel_strip_settings_test(
    strip = "always",
    compilation_mode = "opt",
    expected_strip = True,
)
_bazel_strip_settings_never_test = _define_bazel_strip_settings_test(
    strip = "never",
    compilation_mode = "fastbuild",
    expected_strip = False,
)
_bazel_strip_settings_sometimes_fastbuild_test = _define_bazel_strip_settings_test(
    strip = "sometimes",
    compilation_mode = "fastbuild",
    expected_strip = True,
)
_bazel_strip_settings_sometimes_opt_test = _define_bazel_strip_settings_test(
    strip = "sometimes",
    compilation_mode = "opt",
    expected_strip = False,
)

def _define_bazel_strip_action_test(*, strip, compilation_mode, expected_strip):
    def _test_impl(ctx):
        env = analysistest.begin(ctx)

        build = [
            action
            for action in analysistest.target_actions(env)
            if action.mnemonic == "ZigBuildExe"
        ]
        asserts.equals(env, 1, len(build), "Target should have one ZigBuildExe action.")
        build = build[0]

        if expected_strip:
            assert_flag_set(env, "-fstrip", build.argv)
        else:
            assert_flag_unset(env, "-fstrip", build.argv)

        return analysistest.end(env)

    return analysistest.make(
        _test_impl,
        config_settings = {
            _COMPILATION_MODE: compilation_mode,
            _STRIP: strip,
        },
    )

_bazel_strip_action_always_test = _define_bazel_strip_action_test(
    strip = "always",
    compilation_mode = "opt",
    expected_strip = True,
)
_bazel_strip_action_never_test = _define_bazel_strip_action_test(
    strip = "never",
    compilation_mode = "fastbuild",
    expected_strip = False,
)
_bazel_strip_action_sometimes_fastbuild_test = _define_bazel_strip_action_test(
    strip = "sometimes",
    compilation_mode = "fastbuild",
    expected_strip = True,
)
_bazel_strip_action_sometimes_opt_test = _define_bazel_strip_action_test(
    strip = "sometimes",
    compilation_mode = "opt",
    expected_strip = False,
)

def _test_strip_debug_symbols(name):
    _strip_debug_symbols_test(
        name = name + "-binary",
        target_under_test = "//zig/tests/strip_debug_symbols:binary",
        strip_debug_symbols = False,
        size = "small",
    )
    _strip_debug_symbols_test(
        name = name + "-binary-strip",
        target_under_test = "//zig/tests/strip_debug_symbols:binary-strip",
        strip_debug_symbols = True,
        size = "small",
    )
    _strip_debug_symbols_test(
        name = name + "-library-shared-strip",
        target_under_test = "//zig/tests/strip_debug_symbols:library-shared-strip",
        strip_debug_symbols = True,
        size = "small",
    )
    _strip_debug_symbols_test(
        name = name + "-test-strip",
        target_under_test = "//zig/tests/strip_debug_symbols:test-strip",
        strip_debug_symbols = True,
        size = "small",
    )

    return [
        name + "-binary",
        name + "-binary-strip",
        name + "-library-shared-strip",
        name + "-test-strip",
    ]

def _test_bazel_strip(name):
    _bazel_strip_settings_always_test(
        name = name + "-settings-always",
        target_under_test = "//zig/settings",
        size = "small",
    )
    _bazel_strip_settings_never_test(
        name = name + "-settings-never",
        target_under_test = "//zig/settings",
        size = "small",
    )
    _bazel_strip_settings_sometimes_fastbuild_test(
        name = name + "-settings-sometimes-fastbuild",
        target_under_test = "//zig/settings",
        size = "small",
    )
    _bazel_strip_settings_sometimes_opt_test(
        name = name + "-settings-sometimes-opt",
        target_under_test = "//zig/settings",
        size = "small",
    )
    _bazel_strip_action_always_test(
        name = name + "-action-always",
        target_under_test = "//zig/tests/strip_debug_symbols:binary",
        size = "small",
    )
    _bazel_strip_action_never_test(
        name = name + "-action-never",
        target_under_test = "//zig/tests/strip_debug_symbols:binary",
        size = "small",
    )
    _bazel_strip_action_sometimes_fastbuild_test(
        name = name + "-action-sometimes-fastbuild",
        target_under_test = "//zig/tests/strip_debug_symbols:binary",
        size = "small",
    )
    _bazel_strip_action_sometimes_opt_test(
        name = name + "-action-sometimes-opt",
        target_under_test = "//zig/tests/strip_debug_symbols:binary",
        size = "small",
    )

    return [
        name + "-settings-always",
        name + "-settings-never",
        name + "-settings-sometimes-fastbuild",
        name + "-settings-sometimes-opt",
        name + "-action-always",
        name + "-action-never",
        name + "-action-sometimes-fastbuild",
        name + "-action-sometimes-opt",
    ]

def _use_cc_common_link_simple_binary_test_impl(ctx):
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)
    default = target[DefaultInfo]

    executable = default.files_to_run.executable
    asserts.true(executable != None, "zig_binary should produce an executable.")
    asserts.true(sets.contains(sets.make(default.files.to_list()), executable), "zig_binary should return the executable as an output.")
    asserts.true(sets.contains(sets.make(default.default_runfiles.files.to_list()), executable), "zig_binary should return the executable in the runfiles.")

    build = [
        action
        for action in analysistest.target_actions(env)
        if action.mnemonic == "ZigBuildLib"
    ]
    asserts.equals(env, 1, len(build), "zig_binary should generate one ZigBuildLib action.")

    build = [
        action
        for action in analysistest.target_actions(env)
        if action.mnemonic == "CppLink"
    ]
    asserts.equals(env, 1, len(build), "zig_binary should generate one CppLink action.")
    build = build[0]
    asserts.true(sets.contains(sets.make(build.outputs.to_list()), executable), "zig_binary linked with cc_common.link should generate a CppLink action that generates the binary.")

    return analysistest.end(env)

_use_cc_common_link_simple_binary_test = analysistest.make(
    _use_cc_common_link_simple_binary_test_impl,
    config_settings = {
        _SETTINGS_USE_CC_COMMON_LINK: True,
    },
)

def _test_use_cc_common_link_simple_binary(name):
    _use_cc_common_link_simple_binary_test(
        name = name,
        target_under_test = "//zig/tests/simple-binary:binary",
        size = "small",
    )
    return [":" + name]

def rules_test_suite(name):
    """Generate test suite and test targets for common rule analysis tests.

    Args:
      name: String, a unique name for the test-suite target.
    """
    tests = []
    tests += _test_simple_binary(name = "simple_binary_test")
    tests += _test_simple_static_library(name = "simple_static_library_test")
    tests += _test_transitive_static_library(name = "transitive_static_library_test")
    tests += _test_simple_shared_library(name = "simple_shared_library_test")
    tests += _test_transitive_shared_library(name = "transitive_shared_library_test")
    tests += _test_multiple_sources_binary(name = "multiple_sources_binary_test")
    tests += _test_module_binary(name = "module_binary_test")
    tests += _test_c_sources_binary(name = "c_sources_binary_test")
    tests += _test_compiler_runtime(name = "compiler_runtime_test")
    tests += _test_strip_debug_symbols(name = "strip_debug_symbols_test")
    tests += _test_bazel_strip(name = "bazel_strip_test")
    tests += _test_use_cc_common_link_simple_binary(name = "use_cc_common_link_simple_binary_test")
    native.test_suite(
        name = name,
        tests = tests,
    )
