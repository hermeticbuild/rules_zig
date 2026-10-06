"""Unit tests for starlark helpers
See https://bazel.build/rules/testing#testing-starlark-utilities
"""

load("@bazel_skylib//lib:partial.bzl", "partial")
load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load("//zig/private:versions.bzl", "TOOL_VERSIONS")

def _smoke_test_impl(ctx):
    env = unittest.begin(ctx)
    asserts.equals(env, "0.17.0", TOOL_VERSIONS.keys()[0])
    return unittest.end(env)

_smoke_test = unittest.make(_smoke_test_impl)

def versions_test_suite(name):
    unittest.suite(
        name,
        partial.make(_smoke_test, size = "small"),
    )
