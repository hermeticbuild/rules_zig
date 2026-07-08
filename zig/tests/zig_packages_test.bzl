"""Unit tests for the `zig_packages` module extension helpers."""

load("@bazel_skylib//lib:partial.bzl", "partial")
load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load("//zig/private/bzlmod:zig_packages.bzl", "package_name_version", "select_by_precedence")
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

def _entry(module, key, value):
    return struct(module = module, is_root = module == "root", key = key, value = value, tag = None)

def _select_by_precedence_test_impl(ctx):
    env = unittest.begin(ctx)

    root = _entry("root", "any", "//root")
    dep_specific = _entry("dep", "specific", "//dep")
    other_specific = _entry("other", "specific", "//other")

    # The root module's entry wins even under a less specific key, overriding
    # every dependency module's.
    asserts.equals(
        env,
        (None, root, [dep_specific]),
        select_by_precedence({"specific": [dep_specific], "any": [root]}, ["specific", "any"]),
    )

    # Without a root entry, the most specific dependency entry applies.
    asserts.equals(
        env,
        (None, dep_specific, []),
        select_by_precedence({"specific": [dep_specific], "any": [_entry("dep", "any", "//any")]}, ["specific", "any"]),
    )

    # Equal dependency entries under one key collapse.
    asserts.equals(
        env,
        (None, dep_specific, []),
        select_by_precedence({"specific": [dep_specific, _entry("other", "specific", "//dep")]}, ["specific"]),
    )

    # Disagreeing dependency entries under one key conflict.
    asserts.equals(
        env,
        ((dep_specific, other_specific), None, []),
        select_by_precedence({"specific": [dep_specific, other_specific]}, ["specific"]),
    )

    # The root module settles what would otherwise conflict.
    asserts.equals(
        env,
        (None, root, [dep_specific, other_specific]),
        select_by_precedence({"specific": [dep_specific, other_specific], "any": [root]}, ["specific", "any"]),
    )

    asserts.equals(env, (None, None, []), select_by_precedence({"other": [root]}, ["specific"]))

    return unittest.end(env)

_select_by_precedence_test = unittest.make(_select_by_precedence_test_impl)

# Two copies of `lib` 1.0.0 (e.g. two revisions of one release) and `lib` 2.0.0.
_LIB_A = "lib-1.0.0-AAAA"
_LIB_B = "lib-1.0.0-BBBB"
_LIB_2 = "lib-2.0.0-CCCC"

def _index():
    return index_packages(
        {
            _LIB_A: {"name": "lib", "version": "1.0.0"},
            _LIB_B: {"name": "lib", "version": "1.0.0"},
            _LIB_2: {"name": "lib", "version": "2.0.0"},
        },
        {key: "@" + key + "//:files" for key in [_LIB_A, _LIB_B, _LIB_2]},
    )

def _index_packages_test_impl(ctx):
    env = unittest.begin(ctx)

    packages, versions = _index()

    # Packages sharing a name and version stay separate entries.
    asserts.equals(env, "@" + _LIB_A + "//:files", packages[_LIB_A]["files"])
    asserts.equals(env, "@" + _LIB_B + "//:files", packages[_LIB_B]["files"])
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
        partial.make(_select_by_precedence_test),
        partial.make(_index_packages_test),
        partial.make(_resolve_version_test),
    )
