"""Analysis tests for Zig worker compilation."""

load("@bazel_skylib//lib:partial.bzl", "partial")
load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts", "unittest")
load(":util.bzl", "assert_find_action", "canonical_label")

_INCREMENTAL = canonical_label("@//zig/settings:incremental")
_USE_WORKER = canonical_label("@//zig/settings:use_worker")
_VERSION = canonical_label("@zig_toolchains//:version")
_PLATFORMS = "//command_line_option:platforms"
_EXEC_PLATFORMS = "//command_line_option:extra_execution_platforms"
_TOOLCHAINS = "//command_line_option:extra_toolchains"
_LINUX = canonical_label("@//zig/tests/platforms:x86_64-linux")

# Keep positive cases independent of the SDK selected by the surrounding CI job.
# In particular, a Windows target must still use a supported execution toolchain
# when checking the target-OS restriction.
_SETTINGS = {
    _INCREMENTAL: True,
    _VERSION: "0.17.1",
    _PLATFORMS: _LINUX,
    _EXEC_PLATFORMS: [canonical_label("@buildbuddy_toolchain//:platform_linux_x86_64")],
    canonical_label("@//zig/settings:use_cc_common_link"): False,
}

_CC_SETTINGS = _SETTINGS | {
    canonical_label("@//zig/settings:use_cc_common_link"): True,
    _TOOLCHAINS: [canonical_label("@buildbuddy_toolchain//:cc_toolchain")],
}

def _disabled_test_impl(ctx):
    env = analysistest.begin(ctx)

    assert_find_action(env, "ZigBuildExe")
    worker_actions = ["ZigIncrementalCompile", "ZigWorkerCompile"]
    asserts.equals(env, [], [action for action in analysistest.target_actions(env) if action.mnemonic in worker_actions])

    return analysistest.end(env)

_disabled_test = analysistest.make(
    _disabled_test_impl,
    config_settings = _SETTINGS | {_INCREMENTAL: False},
)

def _binary_test_impl(ctx):
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)
    compile = assert_find_action(env, "ZigIncrementalCompile")
    asserts.true(env, "--incremental" in compile.argv)

    metadata = json.decode([arg for arg in compile.argv if arg.startswith("{")][0])
    asserts.equals(env, compile.argv[compile.argv.index("-target") + 1], metadata.get("target"))

    executable = target[DefaultInfo].files_to_run.executable
    asserts.equals(env, [executable], target[DefaultInfo].files.to_list())
    asserts.equals(env, [executable], compile.outputs.to_list())

    asserts.equals(env, ["--compilation-output=" + executable.path], [arg for arg in compile.argv if arg.startswith("--compilation-output=")])

    return analysistest.end(env)

_binary_test = analysistest.make(_binary_test_impl, config_settings = _SETTINGS)

_both_flags_test = analysistest.make(
    _binary_test_impl,
    config_settings = _SETTINGS | {_USE_WORKER: True},
)

def _ordinary_worker_test_impl(ctx):
    env = analysistest.begin(ctx)
    compile = assert_find_action(env, "ZigWorkerCompile")
    asserts.false(env, "--incremental" in compile.argv)
    return analysistest.end(env)

_ordinary_worker_test = analysistest.make(
    _ordinary_worker_test_impl,
    config_settings = _SETTINGS | {
        _INCREMENTAL: False,
        _USE_WORKER: True,
        _PLATFORMS: canonical_label("@//zig/tests/platforms:aarch64-linux"),
    },
)

def _test_binary_test_impl(ctx):
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)
    compile = assert_find_action(env, "ZigIncrementalCompile")

    executable = target[DefaultInfo].files_to_run.executable
    asserts.equals(env, [executable], target[DefaultInfo].files.to_list())
    asserts.equals(env, [executable], compile.outputs.to_list())

    return analysistest.end(env)

_test_binary_test = analysistest.make(_test_binary_test_impl, config_settings = _SETTINGS)

def _static_library_test_impl(ctx):
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)
    compile = assert_find_action(env, "ZigIncrementalCompile")

    libraries = target[DefaultInfo].files.to_list()
    asserts.equals(env, 1, len(libraries))
    asserts.equals(env, libraries, compile.outputs.to_list())

    return analysistest.end(env)

_static_library_test = analysistest.make(_static_library_test_impl, config_settings = _SETTINGS)

def _shared_library_test_impl(ctx):
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)
    compile = assert_find_action(env, "ZigIncrementalCompile")

    libraries = target[DefaultInfo].files.to_list()
    asserts.equals(env, 1, len(libraries))
    asserts.equals(env, libraries, compile.outputs.to_list())

    return analysistest.end(env)

_shared_library_test = analysistest.make(_shared_library_test_impl, config_settings = _SETTINGS)

def _cc_binary_handoff_test_impl(ctx):
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)
    compile = assert_find_action(env, "ZigIncrementalCompile")
    link = assert_find_action(env, "CppLink")

    archives = compile.outputs.to_list()
    asserts.equals(env, 1, len(archives))
    asserts.true(env, archives[0] in link.inputs.to_list(), "The separate link must consume the worker's archive.")

    executable = target[DefaultInfo].files_to_run.executable
    asserts.equals(env, [executable], target[DefaultInfo].files.to_list())
    asserts.true(env, executable in link.outputs.to_list())

    native_inputs = [file for file in link.inputs.to_list() if file.owner == Label("//zig/tests/incremental:native")]
    asserts.true(env, bool(native_inputs), "The separate link must consume the native library.")
    for file in native_inputs:
        asserts.false(env, file in compile.inputs.to_list(), "Native libraries belong to the separate link.")
    asserts.true(env, "-Wl,-z,now" in link.argv)
    asserts.false(env, "-Wl,-z,now" in compile.argv)

    return analysistest.end(env)

_cc_binary_handoff_test = analysistest.make(_cc_binary_handoff_test_impl, config_settings = _CC_SETTINGS)

def _cc_test_handoff_test_impl(ctx):
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)
    compile = assert_find_action(env, "ZigIncrementalCompile")
    archive = assert_find_action(env, "ZigBuildLib")
    link = assert_find_action(env, "CppLink")

    for flag in ["--zig-lib-dir", "--cache-dir", "--global-cache-dir"]:
        asserts.equals(env, 1, len([arg for arg in archive.argv if arg == flag]), "Ordinary packaging needs exactly one {}.".format(flag))
        asserts.false(env, flag in compile.argv, "The worker owns its SDK/cache paths; {} must not leak into the request.".format(flag))

    objects = compile.outputs.to_list()
    asserts.equals(env, 1, len(objects))
    asserts.true(env, objects[0] in archive.inputs.to_list(), "Ordinary archive packaging must consume the worker's test object.")

    archives = archive.outputs.to_list()
    asserts.equals(env, 1, len(archives))
    asserts.true(env, archives[0] in link.inputs.to_list(), "The separate link must consume the packaged test archive.")

    executable = target[DefaultInfo].files_to_run.executable
    asserts.equals(env, [executable], target[DefaultInfo].files.to_list())
    asserts.true(env, executable in link.outputs.to_list())

    return analysistest.end(env)

_cc_test_handoff_test = analysistest.make(_cc_test_handoff_test_impl, config_settings = _CC_SETTINGS)

def _cc_shared_handoff_test_impl(ctx):
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)
    compile = assert_find_action(env, "ZigIncrementalCompile")
    link = assert_find_action(env, "CppLink")

    archives = compile.outputs.to_list()
    asserts.equals(env, 1, len(archives))
    asserts.true(env, archives[0] in link.inputs.to_list(), "The separate link must consume the worker's archive.")

    libraries = target[DefaultInfo].files.to_list()
    asserts.equals(env, 1, len(libraries))
    asserts.true(env, libraries[0] in link.outputs.to_list(), "The exposed shared library must come from the separate link.")

    return analysistest.end(env)

_cc_shared_handoff_test = analysistest.make(_cc_shared_handoff_test_impl, config_settings = _CC_SETTINGS)

def _auxiliary_outputs_test_impl(ctx):
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)
    output_groups = target[OutputGroupInfo]
    compile = assert_find_action(env, "ZigIncrementalCompile")
    link = assert_find_action(env, "CppLink")

    asm = output_groups.asm.to_list()
    llvm_ir = output_groups.llvm_ir.to_list()
    llvm_bc = output_groups.llvm_bc.to_list()
    asserts.equals(env, 1, len(asm))
    asserts.equals(env, 1, len(llvm_ir))
    asserts.equals(env, 1, len(llvm_bc))
    auxiliary = asm + llvm_ir + llvm_bc
    asserts.equals(env, ["--compilation-output=" + compile.outputs.to_list()[0].path], [arg for arg in compile.argv if arg.startswith("--compilation-output=")])
    for file in auxiliary:
        asserts.true(env, file in compile.outputs.to_list(), "Auxiliary outputs belong to compilation, not linking.")
        asserts.false(env, file in link.outputs.to_list())

    archives = [file for file in compile.outputs.to_list() if file not in auxiliary]
    asserts.equals(env, 1, len(archives))
    asserts.true(env, archives[0] in link.inputs.to_list())

    executable = target[DefaultInfo].files_to_run.executable
    asserts.equals(env, [executable], target[DefaultInfo].files.to_list())
    asserts.true(env, executable in link.outputs.to_list())

    return analysistest.end(env)

_auxiliary_outputs_test = analysistest.make(_auxiliary_outputs_test_impl, config_settings = _CC_SETTINGS)

def _auxiliary_only_test_impl(ctx):
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)
    output_groups = target[OutputGroupInfo]
    compile = assert_find_action(env, "ZigIncrementalCompile")

    asserts.equals(env, [], target[DefaultInfo].files.to_list())

    asm = output_groups.asm.to_list()
    llvm_ir = output_groups.llvm_ir.to_list()
    llvm_bc = output_groups.llvm_bc.to_list()
    asserts.equals(env, 1, len(asm))
    asserts.equals(env, 1, len(llvm_ir))
    asserts.equals(env, 1, len(llvm_bc))
    asserts.equals(env, 3, len(compile.outputs.to_list()))
    asserts.equals(env, ["--compilation-output=" + compile.outputs.to_list()[0].path], [arg for arg in compile.argv if arg.startswith("--compilation-output=")])
    for file in asm + llvm_ir + llvm_bc:
        asserts.true(env, file in compile.outputs.to_list(), "The worker must produce the requested auxiliary outputs without an archive.")

    return analysistest.end(env)

_auxiliary_only_test = analysistest.make(_auxiliary_only_test_impl, config_settings = _SETTINGS)

def _unsupported_version_test_impl(ctx):
    env = analysistest.begin(ctx)
    asserts.expect_failure(env, "requires Zig 0.17.x")
    return analysistest.end(env)

_unsupported_version_test = analysistest.make(
    _unsupported_version_test_impl,
    config_settings = _SETTINGS | {_VERSION: "0.16.0"},
    expect_failure = True,
)

def _unsupported_arch_test_impl(ctx):
    env = analysistest.begin(ctx)
    asserts.expect_failure(env, "supports x86_64-linux targets only")
    return analysistest.end(env)

_unsupported_arch_test = analysistest.make(
    _unsupported_arch_test_impl,
    config_settings = _SETTINGS | {_PLATFORMS: canonical_label("@//zig/tests/platforms:aarch64-linux")},
    expect_failure = True,
)

def _unsupported_os_test_impl(ctx):
    env = analysistest.begin(ctx)
    asserts.expect_failure(env, "supports x86_64-linux targets only")
    return analysistest.end(env)

_unsupported_os_test = analysistest.make(
    _unsupported_os_test_impl,
    config_settings = _SETTINGS | {_PLATFORMS: canonical_label("@//zig/tests/platforms:x86_64-windows")},
    expect_failure = True,
)

def _unsupported_execution_toolchain_test_impl(ctx):
    env = analysistest.begin(ctx)
    asserts.expect_failure(env, "requires a hermetic Zig toolchain with a POSIX worker adapter")
    return analysistest.end(env)

_unsupported_execution_toolchain_test = analysistest.make(
    _unsupported_execution_toolchain_test_impl,
    config_settings = _SETTINGS | {_TOOLCHAINS: [canonical_label("@//zig/tests/path-toolchain:path_zig_toolchain")]},
    expect_failure = True,
)

def _unsupported_c_sources_test_impl(ctx):
    env = analysistest.begin(ctx)
    asserts.expect_failure(env, "requires no C sources/compiler options or linker scripts")
    return analysistest.end(env)

_unsupported_c_sources_test = analysistest.make(
    _unsupported_c_sources_test_impl,
    config_settings = _SETTINGS,
    expect_failure = True,
)

def incremental_test_suite(name):
    unittest.suite(
        name,
        # Test action selection and primary output ownership.
        partial.make(_disabled_test, target_under_test = "//zig/tests/incremental:binary", size = "small"),
        partial.make(_ordinary_worker_test, target_under_test = "//zig/tests/incremental:c_sources", size = "small"),
        partial.make(_binary_test, target_under_test = "//zig/tests/incremental:binary", size = "small"),
        partial.make(_both_flags_test, target_under_test = "//zig/tests/incremental:binary", size = "small"),
        partial.make(_test_binary_test, target_under_test = "//zig/tests/incremental:test_binary", size = "small"),
        partial.make(_static_library_test, target_under_test = "//zig/tests/incremental:static_library", size = "small"),
        partial.make(_shared_library_test, target_under_test = "//zig/tests/incremental:shared_library", size = "small"),
        # Test the archive and test-object handoffs to cc_common.link.
        partial.make(_cc_binary_handoff_test, target_under_test = "//zig/tests/incremental:native_binary", size = "small"),
        partial.make(_cc_test_handoff_test, target_under_test = "//zig/tests/incremental:test_binary", size = "small"),
        partial.make(_cc_shared_handoff_test, target_under_test = "//zig/tests/incremental:shared_library", size = "small"),
        # Test auxiliary output ownership with a separate link and without a binary.
        partial.make(_auxiliary_outputs_test, target_under_test = "//zig/tests/incremental:auxiliary_outputs", size = "small"),
        partial.make(_auxiliary_only_test, target_under_test = "//zig/tests/incremental:auxiliary_only", size = "small"),
        # Test deliberate configuration restrictions.
        partial.make(_unsupported_version_test, target_under_test = "//zig/tests/incremental:binary", size = "small"),
        partial.make(_unsupported_arch_test, target_under_test = "//zig/tests/incremental:binary", size = "small"),
        partial.make(_unsupported_os_test, target_under_test = "//zig/tests/incremental:binary", size = "small"),
        partial.make(_unsupported_execution_toolchain_test, target_under_test = "//zig/tests/incremental:binary", size = "small"),
        partial.make(_unsupported_c_sources_test, target_under_test = "//zig/tests/incremental:c_sources", size = "small"),
    )
