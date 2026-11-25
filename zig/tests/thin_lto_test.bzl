"""Analysis tests for Zig's handoff to the C/C++ ThinLTO pipeline."""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts")
load("@rules_cc//cc/common:cc_info.bzl", "CcInfo")
load(":util.bzl", "assert_find_action", "canonical_label")

_FEATURES = "//command_line_option:features"
_SETTINGS = {
    _FEATURES: ["thin_lto", "-thin_lto_all_linkstatic_use_shared_nonlto_backends"],
    "//command_line_option:platforms": canonical_label("@//zig/tests/platforms:x86_64-linux"),
    canonical_label("@//zig/settings:use_cc_common_link"): False,
    canonical_label("@zig_toolchains//:version"): "0.17.1",
}

def _binary_test_impl(ctx):
    env = analysistest.begin(ctx)
    emit = assert_find_action(env, "ZigEmitBitcode")
    prepare = assert_find_action(env, "ZigThinLTOPrepare")
    runtime = assert_find_action(env, "ZigCompilerRuntime")
    index = assert_find_action(env, "CppLTOIndexing")
    backend = assert_find_action(env, "CcLtoBackendCompile")
    link = assert_find_action(env, "CppLink")
    if emit and prepare and runtime and index and backend and link:
        raw = emit.outputs.to_list()[0]
        asserts.true(env, "--verbose-llvm-bc=" + raw.path in emit.argv)
        asserts.true(env, raw in prepare.inputs.to_list())
        prepared = {file.basename: file for file in prepare.outputs.to_list()}
        asserts.equals(env, ["binary.indexing.o", "binary.o"], sorted(prepared))
        asserts.true(env, "-flto=thin" in prepare.argv)
        asserts.true(env, prepared.get("binary.indexing.o") in index.inputs.to_list())
        asserts.true(env, prepared.get("binary.o") in backend.inputs.to_list())
        asserts.true(env, "-fno-omit-frame-pointer" in prepare.argv)
        asserts.true(env, "-fno-omit-frame-pointer" in backend.argv)
        runtime_object = runtime.outputs.to_list()[0]
        asserts.true(env, runtime_object in link.inputs.to_list())
        asserts.false(env, runtime_object in backend.inputs.to_list())
    return analysistest.end(env)

_binary_test = analysistest.make(
    _binary_test_impl,
    config_settings = _SETTINGS | {"//command_line_option:conlyopt": ["-fno-omit-frame-pointer"]},
)

def _archive_test_impl(ctx):
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)
    prepare = assert_find_action(env, "ZigThinLTOPrepare")
    if prepare:
        full = [file for file in prepare.outputs.to_list() if file.basename == "library.o"][0]
        linker_inputs = target[CcInfo].linking_context.linker_inputs.to_list()
        library = [linker_input for linker_input in linker_inputs if linker_input.owner == target.label][0].libraries[0]
        members = library.objects or library.pic_objects
        asserts.equals(env, [full], members)
        asserts.equals(env, ["liblibrary.a"], [file.basename for file in target[DefaultInfo].files.to_list()])
    return analysistest.end(env)

_archive_test = analysistest.make(_archive_test_impl, config_settings = _SETTINGS)

def _disabled_test_impl(ctx):
    env = analysistest.begin(ctx)
    assert_find_action(env, "ZigBuildExe")
    asserts.false(env, any([action.mnemonic == "ZigThinLTOPrepare" for action in analysistest.target_actions(env)]))
    return analysistest.end(env)

_disabled_test = analysistest.make(
    _disabled_test_impl,
    config_settings = _SETTINGS | {_FEATURES: ["-thin_lto"]},
)

def _incremental_test_impl(ctx):
    env = analysistest.begin(ctx)
    asserts.expect_failure(env, "ThinLTO is incompatible with incremental Zig compilation.")
    return analysistest.end(env)

_incremental_test = analysistest.make(
    _incremental_test_impl,
    expect_failure = True,
    config_settings = _SETTINGS | {canonical_label("@//zig/settings:incremental"): True},
)

def thin_lto_test_suite(name):
    """Declare checks for a configuration with a ThinLTO-capable C++ toolchain.

    Args:
        name: Name of the test suite.
    """

    # Enabled cases require a Clang toolchain with the ThinLTO actions and the
    # rules_cc private API allowlist entry for rules_zig.
    tests = []
    for suffix, test_rule, target in [
        ("binary", _binary_test, "simple-binary:binary"),
        ("archive", _archive_test, "simple-library:library"),
        ("disabled", _disabled_test, "simple-binary:binary"),
        ("incremental", _incremental_test, "simple-binary:binary"),
    ]:
        test_name = name + "_" + suffix
        test_rule(
            name = test_name,
            size = "small",
            tags = ["manual"],
            target_under_test = "//zig/tests/" + target,
        )
        tests.append(test_name)

    native.test_suite(name = name, tags = ["manual"], tests = tests)
