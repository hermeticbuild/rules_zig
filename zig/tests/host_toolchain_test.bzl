"""Unit tests for the `zig_host_toolchain` repository rule helpers."""

load("@bazel_skylib//lib:partial.bzl", "partial")
load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load(
    "//zig/private/repo:zig_host_toolchain.bzl",
    "host_platform",
    "select_host_zig",
)

def _host_platform_test_impl(ctx):
    env = unittest.begin(ctx)

    asserts.equals(env, (None, "x86_64-linux"), host_platform("linux", "amd64"))
    asserts.equals(env, (None, "x86_64-linux"), host_platform("linux", "x86_64"))
    asserts.equals(env, (None, "aarch64-linux"), host_platform("linux", "aarch64"))
    asserts.equals(env, (None, "aarch64-linux"), host_platform("linux", "arm64"))
    asserts.equals(env, (None, "x86_64-macos"), host_platform("mac os x", "x86_64"))
    asserts.equals(env, (None, "aarch64-macos"), host_platform("Mac OS X", "arm64"))
    asserts.equals(env, (None, "x86_64-windows"), host_platform("windows 10", "amd64"))

    # Unsupported operating system and CPU architecture report an error rather
    # than aborting evaluation.
    error, platform = host_platform("plan9", "amd64")
    asserts.equals(env, None, platform)
    asserts.true(env, "plan9" in error)

    error, platform = host_platform("linux", "riscv64")
    asserts.equals(env, None, platform)
    asserts.true(env, "riscv64" in error)

    return unittest.end(env)

_host_platform_test = unittest.make(_host_platform_test_impl)

def _toolchain(version, exec_platform):
    return struct(
        version = version,
        exec_platform = exec_platform,
        zig = "@zig_{}_{}//:zig".format(version, exec_platform),
    )

_TOOLCHAINS = [
    _toolchain("0.17.0", "x86_64-linux"),
    _toolchain("0.16.0", "x86_64-linux"),
    _toolchain("0.17.0", "aarch64-macos"),
]

def _select_host_zig_test_impl(ctx):
    env = unittest.begin(ctx)

    # Without an override the first registered version for the platform wins.
    asserts.equals(
        env,
        (None, "@zig_0.17.0_x86_64-linux//:zig"),
        select_host_zig(_TOOLCHAINS, "x86_64-linux", None),
    )
    asserts.equals(
        env,
        (None, "@zig_0.17.0_aarch64-macos//:zig"),
        select_host_zig(_TOOLCHAINS, "aarch64-macos", None),
    )

    # An override selects the matching version for the platform.
    asserts.equals(
        env,
        (None, "@zig_0.16.0_x86_64-linux//:zig"),
        select_host_zig(_TOOLCHAINS, "x86_64-linux", "0.16.0"),
    )

    # No toolchain for the platform.
    error, zig = select_host_zig(_TOOLCHAINS, "aarch64-linux", None)
    asserts.equals(env, None, zig)
    asserts.true(env, "aarch64-linux" in error)

    # A requested version that is registered, but not for this platform.
    error, zig = select_host_zig(_TOOLCHAINS, "aarch64-macos", "0.16.0")
    asserts.equals(env, None, zig)
    asserts.true(env, "0.16.0" in error)

    return unittest.end(env)

_select_host_zig_test = unittest.make(_select_host_zig_test_impl)

def host_toolchain_test_suite(name):
    unittest.suite(
        name,
        partial.make(_host_platform_test, size = "small"),
        partial.make(_select_host_zig_test, size = "small"),
    )
