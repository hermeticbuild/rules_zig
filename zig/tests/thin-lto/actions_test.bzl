"""Regression for the raw-bitcode and paired ThinLTO preparation contract."""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts")

def _impl(ctx):
    env = analysistest.begin(ctx)
    actions = analysistest.target_actions(env)
    raw = [action for action in actions if action.mnemonic == "ZigEmitBitcode"]
    prepared = [action for action in actions if action.mnemonic == "ZigThinLTOPrepare"]
    asserts.equals(env, 1, len(raw), "Zig must emit one raw module")
    asserts.equals(env, 1, len(prepared), "Clang must prepare the full and minimized bitcode together")
    if raw and prepared:
        asserts.true(env, "build-obj" in raw[0].argv)
        asserts.true(env, "-ofmt=llvmbc" in raw[0].argv)
        asserts.true(env, "-fno-libllvm" in raw[0].argv)
        asserts.false(env, "-flto=thin" in raw[0].argv)
        asserts.true(env, "-flto=thin" in prepared[0].argv)
        asserts.equals(env, ["library.indexing.o", "library.o"], sorted([file.basename for file in prepared[0].outputs.to_list()]))
        asserts.true(env, raw[0].outputs.to_list()[0] in prepared[0].inputs.to_list())
    return analysistest.end(env)

thin_lto_actions_test = analysistest.make(_impl)

def _disabled_impl(ctx):
    env = analysistest.begin(ctx)
    mnemonics = [action.mnemonic for action in analysistest.target_actions(env)]
    asserts.true(env, "ZigBuildStaticLib" in mnemonics)
    asserts.false(env, "ZigEmitBitcode" in mnemonics)
    asserts.false(env, "ZigThinLTOPrepare" in mnemonics)
    return analysistest.end(env)

thin_lto_disabled_test = analysistest.make(
    _disabled_impl,
    config_settings = {"//command_line_option:features": ["-thin_lto"]},
)

def _backend_flags_impl(ctx):
    env = analysistest.begin(ctx)
    backends = [action for action in analysistest.target_actions(env) if action.mnemonic == "CcLtoBackendCompile"]
    asserts.true(env, len(backends) > 0, "rules_cc must create backend compilations")
    for backend in backends:
        asserts.true(env, "-fno-omit-frame-pointer" in backend.argv, "Backend must retain the preparation's conlyopts")
    return analysistest.end(env)

thin_lto_backend_flags_test = analysistest.make(
    _backend_flags_impl,
    config_settings = {"//command_line_option:conlyopt": ["-fno-omit-frame-pointer"]},
)

def _mismatch_impl(ctx):
    env = analysistest.begin(ctx)
    asserts.expect_failure(env, "ThinLTO target architecture mismatch")
    return analysistest.end(env)

thin_lto_mismatch_test = analysistest.make(
    _mismatch_impl,
    expect_failure = True,
    config_settings = {"//command_line_option:copt": ["--target=riscv64-unknown-linux-gnu"]},
)

def _deployment_conflict_impl(ctx):
    env = analysistest.begin(ctx)
    asserts.expect_failure(env, "Conflicting ThinLTO deployment targets")
    return analysistest.end(env)

thin_lto_deployment_conflict_test = analysistest.make(
    _deployment_conflict_impl,
    expect_failure = True,
    config_settings = {"//command_line_option:copt": ["--target=arm64-apple-macosx13.0", "-mmacosx-version-min=14.0"]},
)
