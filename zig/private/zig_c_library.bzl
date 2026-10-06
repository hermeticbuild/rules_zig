"""Implementation of the zig_library rule."""

load("@apple_support//lib:apple_support.bzl", "apple_support")
load("@rules_cc//cc:find_cc_toolchain.bzl", "use_cc_toolchain")
load("@rules_cc//cc/common:cc_info.bzl", "CcInfo")
load(
    "//zig/private/common:bazel_builtin.bzl",
    BAZEL_BUILTIN_ATTRS = "ATTRS",
)
load("//zig/private/common:data.bzl", "zig_collect_data", "zig_create_runfiles")
load(
    "//zig/private/common:exec_groups.bzl",
    "ZIG_EXEC_GROUPS",
    "translate_c_exec_group_toolchain",
    "zig_exec_group_toolchain",
)
load("//zig/private/common:location_expansion.bzl", "location_expansion")
load("//zig/private/common:translate_c.bzl", "zig_translate_c")
load("//zig/private/common:zig_cache.bzl", "zig_cache_output")
load("//zig/private/common:zig_lib_dir.bzl", "zig_lib_dir")

DOC = """\
Defines a Zig C module.

A Zig C module is a Zig module whose C headers dependencies have been translated
to zig using `translate-c`, and which only output defines the module's entry
point.

This rule performs the `translate-c` step but does not perform compilation of
Zig by itself.
Instead, modules are compiled at the use-site.
Zig performs whole program compilation.

**EXAMPLE**

```bzl
load("@rules_zig//zig:defs.bzl", "zig_c_library")

zig_c_library(
    name = "my-module",
    cdeps = [
        ":cc-library",
    ],
)
```
"""

ATTRS = {
    "import_name": attr.string(
        doc = "The import name of the module.",
        mandatory = False,
    ),
    "cdeps": attr.label_list(
        doc = "C dependencies to translate their headers from.",
        mandatory = True,
        providers = [CcInfo],
    ),
    "copts": attr.string_list(
        doc = "C compiler flags passed to `translate-c`. Subject to location and Make variable expansion.",
        mandatory = False,
    ),
    "data": attr.label_list(
        allow_files = True,
        doc = "Files required by the module during runtime.",
        mandatory = False,
    ),
} | BAZEL_BUILTIN_ATTRS | apple_support.action_required_attrs()

TOOLCHAINS = use_cc_toolchain(mandatory = False)

EXEC_GROUPS = ZIG_EXEC_GROUPS

FRAGMENTS = ["apple", "cpp"]

def _zig_c_library_impl(ctx):
    zigtoolchaininfo = zig_exec_group_toolchain(ctx)
    translate_c_toolchain = translate_c_exec_group_toolchain(ctx)
    translatectoolchaininfo = translate_c_toolchain.translatectoolchaininfo if translate_c_toolchain else None

    transitive_data = []
    transitive_runfiles = []

    zig_collect_data(
        data = ctx.attr.data,
        deps = ctx.attr.cdeps,
        transitive_data = transitive_data,
        transitive_runfiles = transitive_runfiles,
    )

    global_args = ctx.actions.args()
    global_args.use_param_file("@%s")

    zig_lib_dir(
        zigtoolchaininfo = zigtoolchaininfo,
        args = global_args,
    )

    zig_cache_output(
        zigtoolchaininfo = zigtoolchaininfo,
        args = global_args,
    )

    default = DefaultInfo(
        runfiles = zig_create_runfiles(
            ctx_runfiles = ctx.runfiles,
            direct_data = [],
            transitive_data = transitive_data,
            transitive_runfiles = transitive_runfiles,
        ),
    )

    copts = location_expansion(
        ctx = ctx,
        targets = ctx.attr.data,
        outputs = [],
        attribute_name = "copts",
        strings = ctx.attr.copts,
    )

    cc_infos = [dep[CcInfo] for dep in ctx.attr.cdeps]
    module = zig_translate_c(
        ctx = ctx,
        name = ctx.attr.import_name or ctx.label.name,
        zigtoolchaininfo = zigtoolchaininfo,
        global_args = global_args,
        cc_infos = cc_infos,
        copts = copts,
        copts_inputs = ctx.files.data,
        translatectoolchaininfo = translatectoolchaininfo,
    )

    return [default, module]

zig_c_library = rule(
    _zig_c_library_impl,
    attrs = ATTRS,
    doc = DOC,
    toolchains = TOOLCHAINS,
    exec_groups = EXEC_GROUPS,
    fragments = FRAGMENTS,
)
