"""Create a repository to hold the toolchains

This follows guidance here:
https://docs.bazel.build/versions/main/skylark/deploying.html#registering-toolchains

> Note that in order to resolve toolchains in the analysis phase Bazel needs to
> analyze all toolchain targets that are registered. Bazel will not need to
> analyze all targets referenced by toolchain.toolchain attribute.
>
> If in order to register toolchains you need to perform complex computation in
> the repository, consider splitting the repository with toolchain targets from
> the repository with <LANG>_toolchain targets. Former will be always fetched,
> and the latter will only be fetched when user actually needs to build <LANG> code.

The "complex computation" in our case is simply downloading large artifacts.
This guidance tells us how to avoid that: We put the toolchain targets in the
alias repository with only the toolchain attribute pointing into the
platform-specific repositories.
"""

load("//zig/private/common:semver.bzl", "semver")

DOC = """\
Create a repository that defines toolchain targets for all Zig toolchains.

The properties of each toolchain target are split across multiple attributes.
All the attributes must be ordered such that values corresponding to a single
toolchain are aligned.
"""

ATTRS = {
    "names": attr.string_list(doc = "The name suffixes to assign to the generated toolchain targets. Will be pre-fixed with a counter for ordering."),
    "labels": attr.string_list(doc = "The labels to the toolchain implementation targets."),
    "zig_versions": attr.string_list(doc = "The Zig SDK versions of the corresponding toolchain targets."),
    "exec_platforms": attr.string_list(doc = "The execution platform of each toolchain target, e.g. `x86_64-linux`."),
    "exec_lengths": attr.int_list(doc = "The length of the slice of the `exec_constraints` attribute that corresponds to each toolchain target."),
    "exec_constraints": attr.string_list(doc = "All toolchain execution platform constraints concatenated to a single list."),
    "target_compatible_lengths": attr.int_list(doc = "The length of the slice of the `target_compatible_constraints` attribute that corresponds to each toolchain target."),
    "target_compatible_constraints": attr.string_list(doc = "All toolchain target platform constraints concatenated to a single list."),
    "target_settings_lengths": attr.int_list(doc = "The length of the slice of the `target_settings` attribute that corresponds to each toolchain target."),
    "target_settings": attr.string_list(doc = "All extra toolchain target settings concatenated to a single list."),
}

def sanitize_version(zig_version):
    """Replace any illegal workspace name characters in the Zig version."""
    return zig_version.replace("+", "_P")

def _calc_counter_digits(num):
    """Determine the number of digits required for the counter prefix.

    Uses at least four digits to avoid unnecessary invalidation when the number
    of toolchains changes in slightly in most common use-cases.
    """
    return max(4, len(repr(num)))

def _counter_prefix(count, *, width):
    """Render the counter prefix.

    Args:
      count: int, The counter value.
      width: int, The number of digits to use.
    """
    count_repr = repr(count)
    prefix = "0" * (width - len(count_repr))
    return prefix + count_repr

def _toolchains_repo_impl(repository_ctx):
    len_expected = len(repository_ctx.attr.names)
    len_equal = all([
        len_expected == len(getattr(repository_ctx.attr, attr))
        for attr in ["labels", "zig_versions", "exec_platforms", "exec_lengths", "target_compatible_lengths", "target_settings_lengths"]
    ])
    if not len_equal:
        fail("Lengths of the attributes `names`, `labels`, `zig_versions`, `exec_platforms`, `exec_lengths`, `target_compatible_lengths`, `target_settings_lengths` must match.")

    len_exec_constraints = 0
    for exec_len in repository_ctx.attr.exec_lengths:
        len_exec_constraints += exec_len

    if not len_exec_constraints == len(repository_ctx.attr.exec_constraints):
        fail("Length of the `exec_constraints` attribute must match the sum of `exec_lengths`.")

    len_target_compatible_constraints = 0
    for target_compatible_len in repository_ctx.attr.target_compatible_lengths:
        len_target_compatible_constraints += target_compatible_len

    if not len_target_compatible_constraints == len(repository_ctx.attr.target_compatible_constraints):
        fail("Length of the `target_compatible_constraints` attribute must match the sum of `target_compatible_lengths`.")

    len_target_settings = 0
    for target_settings_len in repository_ctx.attr.target_settings_lengths:
        len_target_settings += target_settings_len

    if not len_target_settings == len(repository_ctx.attr.target_settings):
        fail("Length of the `target_settings` attribute must match the sum of `target_settings_lengths`.")

    if len(repository_ctx.attr.zig_versions) < 1:
        fail("Must specify at least one Zig SDK version in `zig_versions`.")

    build_content = """\
# Generated by toolchains_repo.bzl
#
# These can be registered in the workspace file or passed to --extra_toolchains flag.
# By default all these toolchains are registered by the zig_register_toolchains macro
# so you don't normally need to interact with these targets.

load("@bazel_skylib//lib:selects.bzl", "selects")
load("@bazel_skylib//rules:common_settings.bzl", "string_flag")
"""

    toolchains_content = """\
# Generated by toolchains_repo.bzl
#
# This file is not part of the public API, please do not rely on its contents.

ZIG_TOOLCHAINS = [
"""

    unique_zig_versions = {
        version: None
        for version in repository_ctx.attr.zig_versions
    }.keys()

    build_content += """
# Use this build flag to select the Zig SDK version. E.g.
#
#     $ bazel build --@zig_toolchains//:version=0.16.0 //...
#
string_flag(
    name = "version",
    values = {zig_versions},
    build_setting_default = {default_version},
)
""".format(
        zig_versions = repr(unique_zig_versions),
        default_version = repr(repository_ctx.attr.zig_versions[0]),
    )

    for zig_version in unique_zig_versions:
        build_content += """
# Use this configuration setting in `select` or `target_compatible_with` to
# change the target based on the Zig version or declare compatibility with a
# specific set of versions.
config_setting(
    name = "{zig_version}",
    flag_values = {{
        ":version": "{zig_version}",
    }},
    visibility = ["//visibility:public"],
)
""".format(
            zig_version = zig_version,
        )

    grouped = semver.grouped(unique_zig_versions)
    for grouping in ["major", "minor", "patch"]:
        for group, versions in getattr(grouped, grouping).items():
            build_content += """
# Use this configuration setting in `select` or `target_compatible_with` to
# change the target based on the Zig version or declare compatibility with a
# specific set of versions.
selects.config_setting_group(
    name = "any_{group}.release",
    match_any = {releases},
    visibility = ["//visibility:public"],
)
selects.config_setting_group(
    name = "any_{group}.pre_release",
    match_any = {pre_releases},
    visibility = ["//visibility:public"],
)
selects.config_setting_group(
    name = "any_{group}.",
    match_any = ["any_{group}.release", "any_{group}.pre_release"],
    visibility = ["//visibility:public"],
)
""".format(
                group = group,
                releases = repr(versions.release or ["@platforms//:incompatible"]),
                pre_releases = repr(versions.pre_release or ["@platforms//:incompatible"]),
            )

    counter_digits = _calc_counter_digits(len(repository_ctx.attr.zig_versions))

    zipped = zip(
        repository_ctx.attr.names,
        repository_ctx.attr.labels,
        repository_ctx.attr.zig_versions,
        repository_ctx.attr.exec_platforms,
        repository_ctx.attr.exec_lengths,
        repository_ctx.attr.target_compatible_lengths,
        repository_ctx.attr.target_settings_lengths,
    )
    exec_offset = 0
    target_compatible_offset = 0
    target_settings_offset = 0
    for counter, (name, label, zig_version, exec_platform, exec_len, target_compatible_len, target_settings_len) in enumerate(zipped):
        compatible_with = repository_ctx.attr.exec_constraints[exec_offset:exec_offset + exec_len]
        exec_offset += exec_len
        target_compatible_with = repository_ctx.attr.target_compatible_constraints[target_compatible_offset:target_compatible_offset + target_compatible_len]
        target_compatible_offset += target_compatible_len
        target_settings = [":{}".format(zig_version)] + repository_ctx.attr.target_settings[target_settings_offset:target_settings_offset + target_settings_len]
        target_settings_offset += target_settings_len
        build_content += """
# Declare a toolchain Bazel will select for running the tool in an action
# on the execution platform.
toolchain(
    name = "{prefix}_{name}_toolchain",
    exec_compatible_with = {compatible_with},
    target_compatible_with = {target_compatible_with},
    target_settings = {target_settings},
    toolchain = "{label}",
    toolchain_type = "@rules_zig//zig:toolchain_type",
)
""".format(
            prefix = _counter_prefix(counter, width = counter_digits),
            name = name,
            compatible_with = compatible_with,
            target_compatible_with = target_compatible_with,
            target_settings = target_settings,
            label = label,
        )

        zig_exe = "zig.exe" if "windows" in exec_platform else "zig"
        toolchains_content += """\
    struct(version = "{version}", exec_platform = "{exec_platform}", zig = Label("{zig}")),
""".format(
            version = zig_version,
            exec_platform = exec_platform,
            zig = label.replace("//:zig_toolchain", "//:" + zig_exe),
        )

    # Base BUILD file for this repository
    repository_ctx.file("BUILD.bazel", build_content)

    repository_ctx.file("private/BUILD.bazel", """\
load("@bazel_skylib//:bzl_library.bzl", "bzl_library")

bzl_library(
    name = "toolchains",
    srcs = ["toolchains.bzl"],
    visibility = ["//visibility:public"],
)
""")
    toolchains_content += """\
]
"""
    repository_ctx.file("private/toolchains.bzl", toolchains_content)

toolchains_repo = repository_rule(
    _toolchains_repo_impl,
    doc = DOC,
    attrs = ATTRS,
)
