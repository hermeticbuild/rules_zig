"""Implementation of the zig_configure rule."""

load("@bazel_skylib//lib:paths.bzl", "paths")
load("@rules_cc//cc/common:cc_info.bzl", "CcInfo")
load("//zig/private:settings.bzl", "MODE_VALUES", "THREADED_VALUES")

DOC = """\
Transitions a target and its dependencies to a different configuration.

Settings like the build mode, e.g. `ReleaseSafe`, or the target platform,
can be set on the command-line on demand,
e.g. using `--@rules_zig//zig/settings:mode=release_safe`.
By default, target build mode is `auto`: Bazel `dbg` and `fastbuild`
compilation modes map to Zig `Debug`, and Bazel `opt` maps to Zig `ReleaseFast`.

However, you may wish to always build a given target
in a particular configuration,
or you may wish to build a given target in multiple configurations
in a single build, e.g. to generate a multi-platform release bundle.

Use this rule to that end.

You can read more about Bazel configurations and transitions
[here][bazel-config].

[bazel-config]: https://bazel.build/extending/config
"""

BINARY_EXAMPLE = """\

**EXAMPLE**

```bzl
load(
    "@rules_zig//zig:defs.bzl",
    "zig_binary",
    "zig_configure_binary",
)

zig_binary(
    name = "binary",
    main = "main.zig",
    tags = ["manual"],  # optional, exclude from `bazel build //...`.
)

zig_configure_binary(
    name = "binary_debug",
    actual = ":binary",
    mode = "debug",
)
```
"""

LIB_EXAMPLE = """\

**EXAMPLE**

```bzl
load(
    "@rules_zig//zig:defs.bzl",
    "zig_binary",
    "zig_configure",
)

zig_static_library(
    name = "library",
    main = "library.zig",
    tags = ["manual"],  # optional, exclude from `bazel build //...`.
)

zig_configure(
    name = "library_debug",
    actual = ":library",
    mode = "debug",
)
```
"""

TEST_EXAMPLE = """\

**EXAMPLE**

```bzl
load(
    "@rules_zig//zig:defs.bzl",
    "zig_test",
    "zig_configure_test",
)

zig_test(
    name = "test",
    main = "test.zig",
    tags = ["manual"],  # optional, exclude from `bazel build //...`.
)

zig_configure_test(
    name = "test_debug",
    actual = ":test",
    mode = "debug",
)
```
"""

def _zig_transition_impl(settings, attr):
    result = dict(settings)
    if attr.extra_toolchains:
        result["//command_line_option:extra_toolchains"] = ",".join([str(toolchain) for toolchain in attr.extra_toolchains])
    if attr.target:
        result["//command_line_option:platforms"] = str(attr.target)
    if attr.zig_version:
        result["@zig_toolchains//:version"] = str(attr.zig_version)
    if attr.use_cc_common_link != -1:
        result["//zig/settings:use_cc_common_link"] = attr.use_cc_common_link == 1
    if attr.host_use_cc_common_link != -1:
        result["//zig/settings:host_use_cc_common_link"] = attr.host_use_cc_common_link == 1
    if attr.mode:
        result["//zig/settings:mode"] = attr.mode
    if attr.host_mode:
        result["//zig/settings:host_mode"] = attr.host_mode
    if attr.threaded:
        result["//zig/settings:threaded"] = attr.threaded
    if attr.host_threaded:
        result["//zig/settings:host_threaded"] = attr.host_threaded
    if attr.zigopt:
        result["//zig/settings:zigopt"] = attr.zigopt
    if attr.host_zigopt:
        result["//zig/settings:host_zigopt"] = attr.host_zigopt
    if attr.use_standalone_translate_c != -1:
        result["//zig/settings:use_standalone_translate_c"] = attr.use_standalone_translate_c == 1
    if attr.bootstrapped != -1:
        result["//zig/settings:bootstrapped"] = attr.bootstrapped == 1
    return result

_zig_transition = transition(
    implementation = _zig_transition_impl,
    inputs = [
        "//command_line_option:extra_toolchains",
        "//command_line_option:platforms",
        "@zig_toolchains//:version",
        "//zig/settings:use_cc_common_link",
        "//zig/settings:host_use_cc_common_link",
        "//zig/settings:mode",
        "//zig/settings:host_mode",
        "//zig/settings:threaded",
        "//zig/settings:host_threaded",
        "//zig/settings:zigopt",
        "//zig/settings:host_zigopt",
        "//zig/settings:use_standalone_translate_c",
        "//zig/settings:bootstrapped",
    ],
    outputs = [
        "//command_line_option:extra_toolchains",
        "//command_line_option:platforms",
        "@zig_toolchains//:version",
        "//zig/settings:use_cc_common_link",
        "//zig/settings:host_use_cc_common_link",
        "//zig/settings:mode",
        "//zig/settings:host_mode",
        "//zig/settings:threaded",
        "//zig/settings:host_threaded",
        "//zig/settings:zigopt",
        "//zig/settings:host_zigopt",
        "//zig/settings:use_standalone_translate_c",
        "//zig/settings:bootstrapped",
    ],
)

def _make_attrs(*, executable):
    return {
        "actual": attr.label(
            doc = "The target to transition.",
            cfg = _zig_transition,
            executable = executable,
            mandatory = True,
        ),
        "target": attr.label(
            doc = "The target platform, expects a label to a Bazel target platform used to select a `zig_target_toolchain` instance.",
            mandatory = False,
        ),
        "extra_toolchains": attr.label_list(
            doc = "Additional toolchains to consider during toolchain resolution for the transitioned target.",
            mandatory = False,
        ),
        "zig_version": attr.string(
            doc = "The Zig SDK version, must be registered using the `zig` module extension.",
            mandatory = False,
        ),
        "use_cc_common_link": attr.int(
            doc = (
                "Whether to use cc_common.link to link zig binaries, tests and shared libraries. " +
                "For hosted builds that require libc, add `@rules_zig//zig/lib:libc` to the Zig target's `deps`. " +
                "Possible values: [-1, 0, 1]. " +
                "-1 means use current configuration value for //zig/settings:use_cc_common_link. " +
                "0 means do not use cc_common.link (use zig build-exe instead). " +
                "1 means use cc_common.link."
            ),
            mandatory = False,
            values = [-1, 0, 1],
            default = -1,
        ),
        "host_use_cc_common_link": attr.int(
            doc = (
                "Whether to use cc_common.link to link zig binaries, tests and shared libraries in the host configuration. " +
                "For hosted builds that require libc, add `@rules_zig//zig/lib:libc` to the Zig target's `deps`. " +
                "Possible values: [-1, 0, 1]. " +
                "-1 means use current host configuration value for //zig/settings:host_use_cc_common_link. " +
                "0 means do not use cc_common.link (use zig build-exe instead). " +
                "1 means use cc_common.link."
            ),
            mandatory = False,
            values = [-1, 0, 1],
            default = -1,
        ),
        "mode": attr.string(
            doc = "The build mode setting, corresponds to the `-O` Zig compiler flag. `auto` follows Bazel's `--compilation_mode`.",
            mandatory = False,
            values = MODE_VALUES,
        ),
        "host_mode": attr.string(
            doc = "The build mode setting for the host configuration, corresponds to the `-O` Zig compiler flag. `auto` follows Bazel's `--compilation_mode`.",
            mandatory = False,
            values = MODE_VALUES,
        ),
        "threaded": attr.string(
            doc = "The threaded setting, corresponds to the `-fsingle-threaded` Zig compiler flag.",
            mandatory = False,
            values = THREADED_VALUES,
        ),
        "host_threaded": attr.string(
            doc = "The threaded setting for the host configuration, corresponds to the `-fsingle-threaded` Zig compiler flag.",
            mandatory = False,
            values = THREADED_VALUES,
        ),
        "use_standalone_translate_c": attr.int(
            doc = (
                "Whether to use a registered standalone translate-c toolchain for C translation instead of the built-in zig translate-c tool. " +
                "Possible values: [-1, 0, 1]. " +
                "-1 means use current configuration value for //zig/settings:use_standalone_translate_c. " +
                "0 means do not use the standalone translate-c toolchain. " +
                "1 means use the standalone translate-c toolchain."
            ),
            mandatory = False,
            values = [-1, 0, 1],
            default = -1,
        ),
        "zigopt": attr.string_list(
            doc = """
Additional list of flags passed to the zig compiler for all Zig compile actions.

The flags specified by this setting do not override those specified via the `zigopts` attribute of `zig_*` rules.
Instead, they are prepended to the command line before module specific flags.

This is an advanced feature that can conflict with attributes, build settings, and other flags defined by the toolchain itself.
Use this at your own risk of hitting undefined behaviors.
""",
            mandatory = False,
        ),
        "host_zigopt": attr.string_list(
            doc = """
Additional list of flags passed to the zig compiler for all Zig compile actions
when building for the host configuration.

The flags specified by this setting do not override those specified via the `zigopts` attribute of `zig_*` rules.
Instead, they are prepended to the command line before module specific flags.

This is an advanced feature that can conflict with attributes, build settings, and other flags defined by the toolchain itself.
Use this at your own risk of hitting undefined behaviors.
""",
            mandatory = False,
        ),
        "bootstrapped": attr.int(
            doc = (
                "Whether to use a bootstrapped Zig compiler. " +
                "Possible values: [-1, 0, 1]. " +
                "-1 means use current configuration value for //zig/settings:bootstrapped. " +
                "0 means do not use a bootstrapped Zig compiler. " +
                "1 means use a bootstrapped Zig compiler."
            ),
            mandatory = False,
            values = [-1, 0, 1],
            default = -1,
        ),
        "_allowlist_function_transition": attr.label(
            default = "@bazel_tools//tools/allowlists/function_transition_allowlist",
        ),
    }

_FORWARD_PROVIDERS = [
    CcInfo,
    OutputGroupInfo,
]

def _make_zig_configure_rule(*, executable, test):
    _executable = executable

    def _zig_configure_impl(ctx):
        executable = _executable

        if type(ctx.attr.actual) == "list":
            if len(ctx.attr.actual) == 1:
                actual = ctx.attr.actual[0]
            else:
                fail("INTERNAL ERROR: Unexpected 1:n transition encountered.")
        else:
            actual = ctx.attr.actual

        providers = []
        for provider in _FORWARD_PROVIDERS:
            if provider in actual:
                providers.append(actual[provider])

        if executable:
            # Executable rules must create the returned executable artifact
            # themselves. This is required so that Bazel can create the
            # corresponding runfiles tree or manifest next to the produced
            # executable artifact.
            # See https://github.com/bazelbuild/bazel/issues/4170

            actual_executable = actual[DefaultInfo].files_to_run.executable
            (_, extension) = paths.split_extension(actual_executable.path)
            executable = ctx.actions.declare_file(
                ctx.label.name + extension,
            )
            ctx.actions.symlink(
                output = executable,
                target_file = actual_executable,
                is_executable = True,
            )

            # TODO[AH] Add a data attribute for executable rules.
            runfiles = ctx.runfiles(files = [executable, actual_executable])
            runfiles = runfiles.merge(actual[DefaultInfo].default_runfiles)

            providers.append(DefaultInfo(
                executable = executable,
                files = depset(direct = [executable]),
                runfiles = runfiles,
            ))
        else:
            providers.append(actual[DefaultInfo])

        return providers

    example = LIB_EXAMPLE
    if executable:
        example = BINARY_EXAMPLE
    if test:
        example = TEST_EXAMPLE

    return rule(
        _zig_configure_impl,
        attrs = _make_attrs(executable = executable),
        doc = DOC + example,
        executable = executable,
        test = test,
    )

zig_configure = _make_zig_configure_rule(executable = False, test = False)
zig_configure_binary = _make_zig_configure_rule(executable = True, test = False)
zig_configure_test = _make_zig_configure_rule(executable = True, test = True)
