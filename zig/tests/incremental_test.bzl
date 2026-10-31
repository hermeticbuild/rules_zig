"""Analysis checks for the incremental action boundary."""

load("@bazel_skylib//lib:partial.bzl", "partial")
load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts", "unittest")
load("//zig/private/providers:zig_settings_info.bzl", "ZigSettingsInfo")
load(":util.bzl", "assert_find_action", "canonical_label")

_INCREMENTAL = canonical_label("@//zig/settings:incremental")
_PLATFORMS = "//command_line_option:platforms"
_LINUX = canonical_label("@//zig/tests/platforms:x86_64-linux")
_EXEC_PLATFORMS = "//command_line_option:extra_execution_platforms"
_CC_SETTINGS = {
    _EXEC_PLATFORMS: [_LINUX, canonical_label("@buildbuddy_toolchain//:platform_linux_x86_64")],
    "//command_line_option:extra_toolchains": [canonical_label("@buildbuddy_toolchain//:cc_toolchain")],
}

_WorkerGraphInfo = provider(
    doc = "Worker compilations reached through the configured tool dependency.",
    fields = ["compilations"],
)

def _worker_graph_impl(target, ctx):
    compilations = []
    if target.label == Label("//zig/private/worker:worker"):
        compilations.append(struct(
            kind = ctx.rule.kind,
            incremental = ctx.rule.attr._settings[ZigSettingsInfo].incremental,
            actions = target.actions,
        ))
    for name in ["_incremental_worker", "actual"]:
        dependency = getattr(ctx.rule.attr, name, None)
        if dependency and _WorkerGraphInfo in dependency:
            compilations.extend(dependency[_WorkerGraphInfo].compilations)
    return [_WorkerGraphInfo(compilations = compilations)]

_worker_graph = aspect(
    implementation = _worker_graph_impl,
    attr_aspects = ["_incremental_worker", "actual"],
)

def _assert_incremental(env, command, output_kind, outputs, link = None, archive = None):
    action = assert_find_action(env, "ZigIncrementalCompile")
    executables = [file for file in action.inputs.to_list() if file.path == action.argv[0]]
    asserts.equals(env, [Label("//zig/private/worker:configured_worker")], [file.owner for file in executables], "The adapter must come through the worker configuration transition.")
    workers = analysistest.target_under_test(env)[_WorkerGraphInfo].compilations
    asserts.equals(env, 1, len(workers), "The graph must contain exactly one worker compilation.")
    for worker in workers:
        asserts.equals(env, "zig_binary", worker.kind)
        asserts.false(env, worker.incremental)
        builds = [action for action in worker.actions if action.mnemonic == "ZigBuildExe"]
        asserts.equals(env, 1, len(builds))
        for build in builds:
            asserts.true(env, "-mcpu=baseline" in build.argv)
            asserts.true(env, "x86_64-linux-gnu.2.17" in build.argv, "The worker must target the selected execution platform.")
    metadata_args = [arg for arg in action.argv if arg.startswith("{")]
    asserts.equals(env, 1, len(metadata_args), "The action must carry one explicit compilation request: " + str(action.argv))
    if metadata_args:
        metadata = json.decode(metadata_args[0])
        asserts.equals(env, command, metadata["command"])
        asserts.equals(env, output_kind, metadata["output_kind"])
        asserts.equals(env, outputs, metadata["outputs"])
        header_index = action.argv.index(metadata_args[0])
        output_paths = action.argv[header_index + 1:header_index + 1 + len(outputs)]
        asserts.equals(env, sorted([file.path for file in action.outputs.to_list()]), sorted(output_paths))
        target = analysistest.target_under_test(env)
        for kind, path in zip(outputs, output_paths):
            if kind == "bin" and link:
                consumer = archive if archive else link
                asserts.true(env, path in [file.path for file in consumer.inputs.to_list()], "The next action must consume the worker's primary output.")
                for file in target[DefaultInfo].files.to_list():
                    asserts.true(env, file in link.outputs.to_list(), "The final output must come from the C/C++ link.")
                    asserts.false(env, file.path in output_paths)
            else:
                files = target[DefaultInfo].files if kind == "bin" else getattr(target[OutputGroupInfo], kind)
                asserts.equals(env, [path], [file.path for file in files.to_list()])
        input_paths = [file.path for file in action.inputs.to_list()]
        for arg in action.argv:
            if arg.startswith("input="):
                asserts.true(env, arg[len("input="):] in input_paths, "The framed request must name declared inputs.")
        asserts.false(env, any([path.endswith(".zig-inputs") or path.endswith(".zig-global.args") or path.endswith(".zig-module.args") for path in input_paths]))
    asserts.false(env, any([arg.startswith("-femit-") or arg.startswith("-fno-emit-") for arg in action.argv]))
    asserts.false(env, "--cache-dir" in action.argv)
    asserts.false(env, "--global-cache-dir" in action.argv)
    asserts.false(env, "--zig-lib-dir" in action.argv)

def _enabled_test_for(command, output_kind, outputs = ["bin"], settings = {}):
    def _impl(ctx):
        env = analysistest.begin(ctx)
        _assert_incremental(env, command, output_kind, outputs)
        assert_find_action(env, "ZigBuildDocs")
        return analysistest.end(env)

    return analysistest.make(_impl, config_settings = {_INCREMENTAL: True, _PLATFORMS: _LINUX, _EXEC_PLATFORMS: [_LINUX]} | settings, extra_target_under_test_aspects = [_worker_graph])

_enabled_test = _enabled_test_for("build-exe", "executable")
_test_compile_test = _enabled_test_for("test", "executable")
_static_test = _enabled_test_for("build-lib", "static_library")
_static_cc_link_test = _enabled_test_for("build-lib", "static_library", settings = {canonical_label("@//zig/settings:use_cc_common_link"): True})
_shared_test = _enabled_test_for("build-lib", "shared_library")
_binary_asm_test = _enabled_test_for("build-exe", "executable", ["bin", "asm"])
_static_asm_only_test = _enabled_test_for("build-lib", "static_library", ["asm"])
_shared_asm_test = _enabled_test_for("build-lib", "shared_library", ["bin", "asm"])
_test_asm_bc_test = _enabled_test_for("test", "executable", ["bin", "asm", "llvm_bc"])

def _bindings_impl(ctx):
    env = analysistest.begin(ctx)
    _assert_incremental(env, "build-exe", "executable", ["bin"])
    action = assert_find_action(env, "ZigIncrementalCompile")
    bindings = [file for file in action.inputs.to_list() if file.basename.endswith("_c.zig")]
    asserts.equals(env, 1, len(bindings), "Generated bindings must be a declared worker input.")
    return analysistest.end(env)

_bindings_test = analysistest.make(
    _bindings_impl,
    config_settings = _CC_SETTINGS | {
        _INCREMENTAL: True,
        _PLATFORMS: _LINUX,
        canonical_label("@//zig/settings:use_standalone_translate_c"): True,
        "//command_line_option:extra_toolchains": [
            canonical_label("@buildbuddy_toolchain//:cc_toolchain"),
            canonical_label("@//zig/tests/translate-c-action:fake_translate_c_toolchain"),
        ],
    },
    extra_target_under_test_aspects = [_worker_graph],
)

def _cc_link_test_for(outputs, native_library = False):
    def _impl(ctx):
        env = analysistest.begin(ctx)
        link = assert_find_action(env, "CppLink")
        _assert_incremental(env, "build-lib", "static_library", outputs, link = link)
        compile = assert_find_action(env, "ZigIncrementalCompile")
        asserts.true(env, "-lc" in compile.argv)
        asserts.true(env, "-fcompiler-rt" in compile.argv)
        asserts.true(env, compile.argv.index("-fcompiler-rt") < compile.argv.index("-fno-compiler-rt"), "Explicit options must follow the C/C++ link defaults.")
        if native_library:
            native_inputs = [file for file in link.inputs.to_list() if file.owner in [
                Label("//zig/tests/translate-c-action:native_library"),
                Label("//zig/tests/translate-c-action:native_archive"),
            ]]
            asserts.true(env, bool(native_inputs), "The C/C++ link must consume the native dependency.")
            for file in native_inputs:
                asserts.false(env, file in compile.inputs.to_list(), "Native libraries belong to the separate link action.")
                asserts.false(env, file.path in compile.argv)
        return analysistest.end(env)

    return analysistest.make(
        _impl,
        config_settings = _CC_SETTINGS | {
            _INCREMENTAL: True,
            _PLATFORMS: _LINUX,
            canonical_label("@//zig/settings:use_cc_common_link"): True,
            canonical_label("@//zig/settings:zigopt"): ["-fno-compiler-rt"],
            canonical_label("@//zig/settings:use_standalone_translate_c"): True,
            "//command_line_option:extra_toolchains": [
                canonical_label("@buildbuddy_toolchain//:cc_toolchain"),
                canonical_label("@//zig/tests/translate-c-action:fake_translate_c_toolchain"),
            ],
        },
        extra_target_under_test_aspects = [_worker_graph],
    )

_cc_link_outputs_test = _cc_link_test_for(["bin", "asm"])
_cc_link_native_test = _cc_link_test_for(["bin"], native_library = True)

def _cc_link_test_object_impl(ctx):
    env = analysistest.begin(ctx)
    archive = assert_find_action(env, "ZigBuildLib")
    link = assert_find_action(env, "CppLink")
    _assert_incremental(env, "test-obj", "object", ["bin", "asm", "llvm_bc"], link = link, archive = archive)

    asserts.equals(env, "build-lib", archive.argv[1])
    asserts.true(env, "--zig-lib-dir" in archive.argv)
    asserts.true(env, "--cache-dir" in archive.argv)
    asserts.true(env, "--global-cache-dir" in archive.argv)
    asserts.true(env, "-fPIC" in archive.argv)
    asserts.true(env, "-fcompiler-rt" in archive.argv)
    for file in archive.outputs.to_list():
        asserts.true(env, file in link.inputs.to_list(), "The C/C++ link must consume the ordinary archive.")
    asserts.equals(env, 1, len(archive.outputs.to_list()), "Auxiliary outputs belong to test-object compilation.")

    return analysistest.end(env)

_cc_link_test_object_test = analysistest.make(
    _cc_link_test_object_impl,
    config_settings = _CC_SETTINGS | {
        _INCREMENTAL: True,
        _PLATFORMS: _LINUX,
        canonical_label("@//zig/settings:use_cc_common_link"): True,
    },
    extra_target_under_test_aspects = [_worker_graph],
)

def _cc_linkopts_impl(ctx):
    env = analysistest.begin(ctx)
    compile = assert_find_action(env, "ZigIncrementalCompile")
    linkopts = ["-Wl,-z,now", "-Wl,-z,lazy"]
    for option in linkopts:
        asserts.false(env, option in compile.argv, "Linker options must not reach the worker.")
    links = [action for action in analysistest.target_actions(env) if action.mnemonic == "CppLink"]
    asserts.equals(env, 1 if ctx.attr.links else 0, len(links))
    for link in links:
        asserts.equals(env, linkopts, [arg for arg in link.argv if arg in linkopts], "The separate link must preserve option order.")
    for action in analysistest.target_actions(env):
        if action.mnemonic == "ZigBuildLib":
            for option in linkopts:
                asserts.false(env, option in action.argv, "Test archive packaging must not receive linker options.")
    return analysistest.end(env)

_cc_linkopts_test = analysistest.make(
    _cc_linkopts_impl,
    config_settings = _CC_SETTINGS | {
        _INCREMENTAL: True,
        _PLATFORMS: _LINUX,
        canonical_label("@//zig/settings:use_cc_common_link"): True,
    },
    attrs = {"links": attr.bool(default = True)},
)

def _zig_linkopts_impl(ctx):
    env = analysistest.begin(ctx)
    compile = assert_find_action(env, "ZigIncrementalCompile")
    linkopts = ["-z", "now", "-z", "lazy"]
    asserts.equals(
        env,
        linkopts if ctx.attr.links else [],
        [arg for arg in compile.argv if arg in linkopts],
        "Direct Zig linking must preserve option order; static libraries ignore linker options.",
    )
    asserts.equals(env, [], [action for action in analysistest.target_actions(env) if action.mnemonic == "CppLink"])
    return analysistest.end(env)

_zig_linkopts_test = analysistest.make(
    _zig_linkopts_impl,
    config_settings = {
        _INCREMENTAL: True,
        _PLATFORMS: _LINUX,
        _EXEC_PLATFORMS: [_LINUX],
        canonical_label("@//zig/settings:use_cc_common_link"): False,
    },
    attrs = {"links": attr.bool(default = True)},
)

def _disabled_impl(ctx):
    env = analysistest.begin(ctx)
    action = assert_find_action(env, "ZigBuildExe")
    asserts.true(env, "--cache-dir" in action.argv)
    asserts.true(env, "--zig-lib-dir" in action.argv)
    asserts.equals(env, [], analysistest.target_under_test(env)[_WorkerGraphInfo].compilations, "Ordinary builds must have no worker dependency.")
    return analysistest.end(env)

_disabled_test = analysistest.make(_disabled_impl, config_settings = {_INCREMENTAL: False}, extra_target_under_test_aspects = [_worker_graph])

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
_unsupported_native_test = _failure_test("no C sources/compiler options")
_unsupported_sdk_test = _failure_test(
    "requires Zig 0.17.x",
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
        partial.make(_cc_link_test_object_test, target_under_test = "//zig/tests/emit-attr:test_emit_asm_and_bc", size = "small"),
        partial.make(_binary_asm_test, target_under_test = "//zig/tests/emit-attr:binary_emit_asm", size = "small"),
        partial.make(_static_asm_only_test, target_under_test = "//zig/tests/emit-attr:static_emit_asm_only", size = "small"),
        partial.make(_shared_asm_test, target_under_test = "//zig/tests/emit-attr:shared_emit_asm", size = "small"),
        partial.make(_test_asm_bc_test, target_under_test = "//zig/tests/emit-attr:test_emit_asm_and_bc", size = "small"),
        partial.make(_unsupported_native_test, target_under_test = "//zig/tests/c-sources-binary:without-copts", size = "small"),
        partial.make(_unsupported_sdk_test, target_under_test = "//zig/tests/simple-library:library", size = "small"),
        partial.make(_bindings_test, target_under_test = "//zig/tests/translate-c-action:automatic_bindings", size = "small"),
        partial.make(_bindings_test, target_under_test = "//zig/tests/translate-c-action:explicit_bindings", size = "small"),
        partial.make(_bindings_test, target_under_test = "//zig/tests/translate-c-action:native_library_binary", size = "small"),
        partial.make(_bindings_test, target_under_test = "//zig/tests/translate-c-action:native_flags_binary", size = "small"),
        partial.make(_bindings_test, target_under_test = "//zig/tests/translate-c-action:native_inputs_binary", size = "small"),
        partial.make(_cc_link_outputs_test, target_under_test = "//zig/tests/emit-attr:binary_emit_asm", size = "small"),
        partial.make(_cc_link_outputs_test, target_under_test = "//zig/tests/emit-attr:shared_emit_asm", size = "small"),
        partial.make(_cc_link_native_test, target_under_test = "//zig/tests/translate-c-action:native_library_binary", size = "small"),
        partial.make(_static_cc_link_test, target_under_test = "//zig/tests/simple-library:library", size = "small"),
        partial.make(_cc_link_native_test, target_under_test = "//zig/tests/translate-c-action:native_archive_binary", size = "small"),
        partial.make(_cc_linkopts_test, target_under_test = "//zig/tests/linkopts-attr:binary", size = "small"),
        partial.make(_cc_linkopts_test, target_under_test = "//zig/tests/linkopts-attr:test", size = "small"),
        partial.make(_cc_linkopts_test, target_under_test = "//zig/tests/linkopts-attr:shared", size = "small"),
        partial.make(_cc_linkopts_test, target_under_test = "//zig/tests/linkopts-attr:static", links = False, size = "small"),
        partial.make(_zig_linkopts_test, target_under_test = "//zig/tests/linkopts-attr:zig_binary", size = "small"),
        partial.make(_zig_linkopts_test, target_under_test = "//zig/tests/linkopts-attr:zig_test", size = "small"),
        partial.make(_zig_linkopts_test, target_under_test = "//zig/tests/linkopts-attr:zig_shared", size = "small"),
        partial.make(_zig_linkopts_test, target_under_test = "//zig/tests/linkopts-attr:zig_static", links = False, size = "small"),
    )
