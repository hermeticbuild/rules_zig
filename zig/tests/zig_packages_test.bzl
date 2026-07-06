"""Unit tests for the `zig_packages` module extension helpers."""

load("@bazel_skylib//lib:partial.bzl", "partial")
load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load("//zig/private/bzlmod:zig_packages.bzl", "package_name_version")
load("//zig/private/repo:zig_deps_index.bzl", "index_packages", "resolve_version")

def _package_name_version_test_impl(ctx):
    env = unittest.begin(ctx)

    asserts.equals(
        env,
        ("clap", "0.10.0"),
        package_name_version("clap-0.10.0-jv8oCwXlAQBW3ZgQlZ_cLSlp8AR8DBhCoryxNZgUW9ZS"),
    )

    # The version and the digest may contain `-`.
    asserts.equals(
        env,
        ("zls", "0.15.0-dev.129"),
        package_name_version("zls-0.15.0-dev.129-Ux6O2xUBAABN-ZgQlZ_cLSlp8AR8DBhCoryxNZgUW9ZS"),
    )

    return unittest.end(env)

_package_name_version_test = unittest.make(_package_name_version_test_impl)

# Two copies of `lib` 1.0.0 (e.g. two revisions of one release) and `lib` 2.0.0.
_LIB_A = "lib-1.0.0-AAAA"
_LIB_B = "lib-1.0.0-BBBB"
_LIB_2 = "lib-2.0.0-CCCC"
_APP = "app-0.1.0-DDDD"

def _index():
    return index_packages(
        {
            _APP: {"name": "app", "version": "0.1.0", "deps": {"lib": _LIB_B, "lib2": _LIB_2}},
            _LIB_A: {"name": "lib", "version": "1.0.0", "deps": {}},
            _LIB_B: {"name": "lib", "version": "1.0.0", "deps": {}},
            _LIB_2: {"name": "lib", "version": "2.0.0", "deps": {}},
        },
        {key: "@" + key + "//:files" for key in [_APP, _LIB_A, _LIB_B, _LIB_2]},
    )

def _index_packages_test_impl(ctx):
    env = unittest.begin(ctx)

    packages, versions = _index()

    # Packages sharing a name and version stay separate entries.
    asserts.equals(env, "@" + _LIB_A + "//:files", packages[_LIB_A]["files"])
    asserts.equals(env, "@" + _LIB_B + "//:files", packages[_LIB_B]["files"])
    asserts.equals(env, {"lib": _LIB_B, "lib2": _LIB_2}, packages[_APP]["deps"])
    asserts.equals(env, {"1.0.0": [_LIB_A, _LIB_B], "2.0.0": [_LIB_2]}, versions["lib"])

    return unittest.end(env)

_index_packages_test = unittest.make(_index_packages_test_impl)

def _resolve_version_test_impl(ctx):
    env = unittest.begin(ctx)

    _, versions = _index()

    asserts.equals(env, (None, _LIB_2), resolve_version(versions, "lib", "2.0.0"))

    error, key = resolve_version(versions, "lib", "1.0.0")
    asserts.equals(env, None, key)
    asserts.true(env, "ambiguous" in error, error)

    error, key = resolve_version(versions, "lib", "3.0.0")
    asserts.equals(env, None, key)
    asserts.true(env, "unknown version '3.0.0'" in error, error)

    error, key = resolve_version(versions, "nope", "1.0.0")
    asserts.equals(env, None, key)
    asserts.true(env, "unknown Zig package 'nope'" in error, error)

    return unittest.end(env)

_resolve_version_test = unittest.make(_resolve_version_test_impl)

def zig_packages_test_suite(name):
    """Instantiate the zig_packages test suite.

    Args:
      name: the test suite's name.
    """
    unittest.suite(
        name,
        partial.make(_package_name_version_test),
        partial.make(_index_packages_test),
        partial.make(_resolve_version_test),
    )
