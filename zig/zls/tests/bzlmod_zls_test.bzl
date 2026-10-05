"""Unit tests for ZLS module extension."""

load("@bazel_skylib//lib:partial.bzl", "partial")
load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load(
    "//zig/zls/private/bzlmod:zls.bzl",
    "handle_toolchain_tags",
    "merge_version_specs",
    "parse_zls_versions_json",
)

def _parse_zls_index_test_impl(ctx):
    env = unittest.begin(ctx)

    content = """\
{
  "0.16.0": {
    "date": "2026-04-16",
    "aarch64-linux": {
      "tarball": "https://builds.zigtools.org/zls-aarch64-linux-0.16.0.tar.xz",
      "shasum": "430cd293d201eb70ae2519dbc96c854bf8791b8df7fc9392e8d2dc9680a2bed7"
    },
    "arm-linux": {
      "tarball": "https://builds.zigtools.org/zls-arm-linux-0.16.0.tar.xz",
      "shasum": "7cf8d11f914127809b89254ad97e4b96d84294370418954a49b78bd623d3c55e"
    }
  }
}
"""
    expected = {
        "0.16.0": {
            "aarch64-linux": struct(
                url = "https://builds.zigtools.org/zls-aarch64-linux-0.16.0.tar.xz",
                sha256 = "430cd293d201eb70ae2519dbc96c854bf8791b8df7fc9392e8d2dc9680a2bed7",
            ),
        },
    }
    result = parse_zls_versions_json(content)
    asserts.equals(env, (None, expected), result)

    content = """\
{
  "0.16.0": {
    "aarch64-linux": {
      "shasum": "430cd293d201eb70ae2519dbc96c854bf8791b8df7fc9392e8d2dc9680a2bed7"
    }
  }
}
"""
    result = parse_zls_versions_json(content)
    asserts.equals(env, "Missing `tarball` field in ZLS version index.", result[0])

    return unittest.end(env)

_parse_zls_index_test = unittest.make(
    _parse_zls_index_test_impl,
)

def _merge_version_specs_test_impl(ctx):
    env = unittest.begin(ctx)

    result = merge_version_specs([
        {
            "0.16.0": {
                "aarch64-linux": struct(url = "url-1", sha256 = "sha-1"),
            },
        },
        {
            "0.16.0": {
                "x86_64-linux": struct(url = "url-2", sha256 = "sha-2"),
            },
        },
    ])

    asserts.equals(
        env,
        {
            "0.16.0": {
                "aarch64-linux": struct(url = "url-1", sha256 = "sha-1"),
                "x86_64-linux": struct(url = "url-2", sha256 = "sha-2"),
            },
        },
        result,
    )

    return unittest.end(env)

_merge_version_specs_test = unittest.make(
    _merge_version_specs_test_impl,
)

def _zls_toolchain_tags_test_impl(ctx):
    env = unittest.begin(ctx)

    result = handle_toolchain_tags([
        struct(
            tags = struct(
                toolchain = [
                    struct(
                        zig_version = "0.16.0",
                        zls_version = "0.17.0-dev.1+abc",
                    ),
                ],
            ),
        ),
    ])
    asserts.equals(env, None, result[0])
    asserts.equals(env, "0.16.0", result[1][0].zig_version)
    asserts.equals(env, "0.17.0-dev.1+abc", result[1][0].zls_version)

    result = handle_toolchain_tags([
        struct(
            tags = struct(
                toolchain = [
                    struct(
                        zig_version = "0.16.0",
                        zls_version = "0.16.0",
                    ),
                    struct(
                        zig_version = "0.16.0",
                        zls_version = "0.17.0-dev.1+abc",
                    ),
                ],
            ),
        ),
    ])
    asserts.equals(env, "You may only specify one ZLS toolchain for Zig SDK version '0.16.0'.", result[0][0])

    return unittest.end(env)

_zls_toolchain_tags_test = unittest.make(
    _zls_toolchain_tags_test_impl,
)

def bzlmod_zls_test_suite(name):
    unittest.suite(
        name,
        partial.make(_parse_zls_index_test, size = "small"),
        partial.make(_merge_version_specs_test, size = "small"),
        partial.make(_zls_toolchain_tags_test, size = "small"),
    )
