"""Unit tests for semantic version helpers."""

load("@bazel_skylib//lib:partial.bzl", "partial")
load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load("//zig/private/common:semver.bzl", "semver")

def _grouped_test_impl(ctx):
    env = unittest.begin(ctx)

    actual = semver.grouped(["1.0.0", "2.0.0"])
    asserts.equals(
        env,
        {
            "1": struct(
                release = ["1.0.0"],
                pre_release = [],
            ),
            "2": struct(
                release = ["2.0.0"],
                pre_release = [],
            ),
        },
        actual.major,
    )
    asserts.equals(
        env,
        {
            "1.0": struct(
                release = ["1.0.0"],
                pre_release = [],
            ),
            "2.0": struct(
                release = ["2.0.0"],
                pre_release = [],
            ),
        },
        actual.minor,
    )
    asserts.equals(
        env,
        {
            "1.0.0": struct(
                release = ["1.0.0"],
                pre_release = [],
            ),
            "2.0.0": struct(
                release = ["2.0.0"],
                pre_release = [],
            ),
        },
        actual.patch,
    )

    actual = semver.grouped(["1.0.0", "1.1.0"])
    asserts.equals(
        env,
        {
            "1": struct(
                release = ["1.0.0", "1.1.0"],
                pre_release = [],
            ),
        },
        actual.major,
    )
    asserts.equals(
        env,
        {
            "1.0": struct(
                release = ["1.0.0"],
                pre_release = [],
            ),
            "1.1": struct(
                release = ["1.1.0"],
                pre_release = [],
            ),
        },
        actual.minor,
    )
    asserts.equals(
        env,
        {
            "1.0.0": struct(
                release = ["1.0.0"],
                pre_release = [],
            ),
            "1.1.0": struct(
                release = ["1.1.0"],
                pre_release = [],
            ),
        },
        actual.patch,
    )

    actual = semver.grouped(["1.0.0", "1.0.1"])
    asserts.equals(
        env,
        {
            "1": struct(
                release = ["1.0.0", "1.0.1"],
                pre_release = [],
            ),
        },
        actual.major,
    )
    asserts.equals(
        env,
        {
            "1.0": struct(
                release = ["1.0.0", "1.0.1"],
                pre_release = [],
            ),
        },
        actual.minor,
    )
    asserts.equals(
        env,
        {
            "1.0.0": struct(
                release = ["1.0.0"],
                pre_release = [],
            ),
            "1.0.1": struct(
                release = ["1.0.1"],
                pre_release = [],
            ),
        },
        actual.patch,
    )

    actual = semver.grouped(["1.0.0-", "1.0.1-rc1"])
    asserts.equals(
        env,
        {
            "1": struct(
                release = [],
                pre_release = ["1.0.0-", "1.0.1-rc1"],
            ),
        },
        actual.major,
    )
    asserts.equals(
        env,
        {
            "1.0": struct(
                release = [],
                pre_release = ["1.0.0-", "1.0.1-rc1"],
            ),
        },
        actual.minor,
    )
    asserts.equals(
        env,
        {
            "1.0.0": struct(
                release = [],
                pre_release = ["1.0.0-"],
            ),
            "1.0.1": struct(
                release = [],
                pre_release = ["1.0.1-rc1"],
            ),
        },
        actual.patch,
    )

    return unittest.end(env)

_grouped_test = unittest.make(_grouped_test_impl)

def _sorted_test_impl(ctx):
    env = unittest.begin(ctx)

    asserts.equals(
        env,
        ["1.0.0", "2.0.0", "10.0.0"],
        semver.sorted(["2.0.0", "10.0.0", "1.0.0"]),
    )

    asserts.equals(
        env,
        ["1.0.0", "2.0.0", "2.1.0", "2.1.1"],
        semver.sorted(["2.1.1", "2.0.0", "2.1.0", "1.0.0"]),
    )

    asserts.equals(
        env,
        ["2.1.1", "2.1.0", "2.0.0", "1.0.0"],
        semver.sorted(["2.1.1", "2.0.0", "2.1.0", "1.0.0"], reverse = True),
    )

    asserts.equals(
        env,
        ["1.0.0-alpha", "1.0.0"],
        semver.sorted(["1.0.0", "1.0.0-alpha"]),
    )

    asserts.equals(
        env,
        ["1.0.0-0", "1.0.0-1", "1.0.0-alpha"],
        semver.sorted(["1.0.0-1", "1.0.0-alpha", "1.0.0-0"]),
    )

    asserts.equals(
        env,
        ["1.0.0-1.2", "1.0.0-1.2.3"],
        semver.sorted(["1.0.0-1.2.3", "1.0.0-1.2"]),
    )

    asserts.equals(
        env,
        ["1.0.0-alpha", "1.0.0-alpha.1", "1.0.0-alpha.beta", "1.0.0-beta", "1.0.0-beta.2", "1.0.0-beta.11", "1.0.0-rc.1", "1.0.0"],
        semver.sorted(["1.0.0", "1.0.0-rc.1", "1.0.0-beta.11", "1.0.0-alpha.beta", "1.0.0-beta", "1.0.0-alpha", "1.0.0-alpha.1", "1.0.0-beta.2"]),
    )

    asserts.equals(
        env,
        ["1.0.0+5", "1.0.1", "1.0.2+4"],
        semver.sorted(["1.0.2+4", "1.0.1", "1.0.0+5"]),
    )

    return unittest.end(env)

_sorted_test = unittest.make(_sorted_test_impl)

def _gte_test_impl(ctx):
    env = unittest.begin(ctx)

    asserts.true(env, semver.gte("0.16.0", "0.16.0"))
    asserts.true(env, semver.gte("0.16.1", "0.16.0"))
    asserts.true(env, semver.gte("0.17.0-dev.135+9df02121d", "0.16.0"))
    asserts.true(env, semver.gte("1.0.0", "0.16.0"))

    asserts.false(env, semver.gte("0.15.2", "0.16.0"))
    asserts.false(env, semver.gte("0.16.0-dev.1", "0.16.0"))

    return unittest.end(env)

_gte_test = unittest.make(_gte_test_impl)

def semver_test_suite(name):
    unittest.suite(
        name,
        partial.make(_grouped_test, size = "small"),
        partial.make(_sorted_test, size = "small"),
        partial.make(_gte_test, size = "small"),
    )
