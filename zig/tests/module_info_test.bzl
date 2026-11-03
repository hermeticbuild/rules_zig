"""Unit tests for ZigModuleInfo functions.
"""

load("@bazel_skylib//lib:paths.bzl", "paths")
load("@bazel_skylib//rules:diff_test.bzl", "diff_test")
load("//zig/private/common:escape_label.bzl", "escape_label")
load(
    "//zig/private/providers:zig_module_info.bzl",
    "ZigModuleInfo",
    "zig_module_specifications",
)

def _bazel_builtin_canonical_name(label):
    return "bazel_builtin_" + escape_label(label = label)

def _bazel_builtin_file_name(ctx, label):
    return paths.join(
        ctx.bin_dir.path,
        label.workspace_root,
        label.package,
        _bazel_builtin_canonical_name(label) + ".zig",
    )

def _bazel_builtin_mod_flags(ctx, label):
    return ["'-M{}={}'".format(
        _bazel_builtin_canonical_name(label),
        _bazel_builtin_file_name(ctx, label),
    )]

def _bazel_builtin_dep(label):
    return "'bazel_builtin={}'".format(_bazel_builtin_canonical_name(label))

def _expected_cdeps_copts(compilation_context):
    copts = []
    copts.extend(["-D{}".format(d) for d in compilation_context.defines.to_list()])
    copts.extend(["-I{}".format(i) for i in compilation_context.includes.to_list()])
    copts.extend(["-I{}".format(i) for i in compilation_context.quote_includes.to_list()])
    for i in compilation_context.system_includes.to_list():
        copts.extend(["-isystem", i])
    if hasattr(compilation_context, "external_includes"):
        for i in compilation_context.external_includes.to_list():
            copts.extend(["-isystem", i])
    copts.extend(["-F{}".format(i) for i in compilation_context.framework_includes.to_list()])
    return copts

def _write_simple_module_expected_specs_args_impl(ctx):
    mod = ctx.attr.mod[ZigModuleInfo]

    expected = []
    expected.extend(["--dep", _bazel_builtin_dep(ctx.attr.mod.label)])
    expected.extend(["'-M{name}={src}'".format(
        name = mod.canonical_name,
        src = ctx.file.mod_main.path,
    )])
    expected.extend(_bazel_builtin_mod_flags(ctx, ctx.attr.mod.label))

    ctx.actions.write(
        output = ctx.outputs.out,
        content = "\n".join(expected) + "\n",
    )

_write_simple_module_expected_specs_args = rule(
    _write_simple_module_expected_specs_args_impl,
    attrs = {
        "mod": attr.label(providers = [ZigModuleInfo]),
        "mod_main": attr.label(allow_single_file = True),
        "out": attr.output(mandatory = True),
    },
)

def _write_transitive_modules_with_zigopts_expected_args_impl(ctx):
    mods = {
        mod.label.name: mod[ZigModuleInfo]
        for mod in ctx.attr.mods
    }

    mod_mains = {
        mod.label.name: main
        for (mod, main) in zip(ctx.attr.mods, ctx.files.mod_mains)
    }

    bazel_builtins = {
        mod.label.name: struct(
            mod_flags = _bazel_builtin_mod_flags(ctx, mod.label),
            dep = _bazel_builtin_dep(mod.label),
            file = [
                file
                for file in mods[mod.label.name].transitive_inputs.to_list()
                if file.path == _bazel_builtin_file_name(ctx, mod.label)
            ],
        )
        for mod in ctx.attr.mods
    }

    expected = []
    expected.extend([
        "--dep",
        "'a={}'".format(mods["a"].canonical_name),
        "--dep",
        bazel_builtins["b"].dep,
        "-DFOR_MODULE_B",
        "'-M{}={}'".format(mods["b"].canonical_name, mod_mains["b"].path),
    ])

    expected.extend(bazel_builtins["a"].mod_flags)
    expected.extend([
        "--dep",
        bazel_builtins["a"].dep,
        "-DFOR_MODULE_A",
        "'-M{}={}'".format(mods["a"].canonical_name, mod_mains["a"].path),
    ])
    expected.extend(bazel_builtins["b"].mod_flags)

    ctx.actions.write(
        output = ctx.outputs.out,
        content = "\n".join(expected) + "\n",
    )

_write_transitive_modules_with_zigopts_expected_args = rule(
    _write_transitive_modules_with_zigopts_expected_args_impl,
    attrs = {
        "mods": attr.label_list(providers = [ZigModuleInfo]),
        "mod_mains": attr.label_list(allow_files = True),
        "out": attr.output(mandatory = True),
    },
)

def _write_module_specs_args_impl(ctx):
    args = ctx.actions.args()

    c_module = None
    if ctx.attr.cmod:
        c_module = ctx.attr.cmod[ZigModuleInfo]

    zig_module_specifications(
        root_module = ctx.attr.mod[ZigModuleInfo],
        args = args,
        c_module = c_module,
    )

    ctx.actions.write(
        output = ctx.outputs.out,
        content = args,
    )

_write_module_specs_args = rule(
    _write_module_specs_args_impl,
    attrs = {
        "mod": attr.label(providers = [ZigModuleInfo]),
        "cmod": attr.label(providers = [ZigModuleInfo]),
        "out": attr.output(mandatory = True),
    },
)

def _write_nested_module_expected_specs_args_impl(ctx):
    mods = {
        mod.label.name: mod[ZigModuleInfo]
        for mod in ctx.attr.mods
    }

    mod_mains = {
        mod.label.name: main
        for (mod, main) in zip(ctx.attr.mods, ctx.files.mod_mains)
    }

    bazel_builtins = {
        mod.label.name: struct(
            mod_flags = _bazel_builtin_mod_flags(ctx, mod.label),
            dep = _bazel_builtin_dep(mod.label),
            file = [
                file
                for file in mods[mod.label.name].transitive_inputs.to_list()
                if file.path == _bazel_builtin_file_name(ctx, mod.label)
            ],
        )
        for mod in ctx.attr.mods
    }

    expected = []
    expected.extend([
        "--dep",
        "'b={}'".format(mods["b"].canonical_name),
        "--dep",
        "'c={}'".format(mods["c"].canonical_name),
        "--dep",
        "'d={}'".format(mods["d"].canonical_name),
        "--dep",
        bazel_builtins["a"].dep,
        "'-M{}={}'".format(mods["a"].canonical_name, mod_mains["a"].path),
    ])

    expected.extend(bazel_builtins["e"].mod_flags)
    expected.extend([
        "--dep",
        bazel_builtins["e"].dep,
        "'-M{}={}'".format(mods["e"].canonical_name, mod_mains["e"].path),
    ])
    expected.extend(bazel_builtins["b"].mod_flags)
    expected.extend(bazel_builtins["c"].mod_flags)
    expected.extend(bazel_builtins["f"].mod_flags)

    expected.extend([
        "--dep",
        "'e={}'".format(mods["e"].canonical_name),
        "--dep",
        bazel_builtins["f"].dep,
        "'-M{}={}'".format(mods["f"].canonical_name, mod_mains["f"].path),
    ])
    expected.extend(bazel_builtins["d"].mod_flags)
    expected.extend([
        "--dep",
        "'e={}'".format(mods["e"].canonical_name),
        "--dep",
        bazel_builtins["b"].dep,
        "'-M{}={}'".format(mods["b"].canonical_name, mod_mains["b"].path),
    ])
    expected.extend([
        "--dep",
        "'e={}'".format(mods["e"].canonical_name),
        "--dep",
        bazel_builtins["c"].dep,
        "'-M{}={}'".format(mods["c"].canonical_name, mod_mains["c"].path),
    ])
    expected.extend([
        "--dep",
        "'f={}'".format(mods["f"].canonical_name),
        "--dep",
        bazel_builtins["d"].dep,
        "'-M{}={}'".format(mods["d"].canonical_name, mod_mains["d"].path),
    ])
    expected.extend(bazel_builtins["a"].mod_flags)

    ctx.actions.write(
        output = ctx.outputs.out,
        content = "\n".join(expected) + "\n",
    )

_write_nested_module_expected_specs_args = rule(
    _write_nested_module_expected_specs_args_impl,
    attrs = {
        "mods": attr.label_list(providers = [ZigModuleInfo]),
        "mod_mains": attr.label_list(allow_files = True),
        "out": attr.output(mandatory = True),
    },
)

def _write_simple_module_with_c_expected_specs_args_impl(ctx):
    mods = {
        mod.label.name: mod[ZigModuleInfo]
        for mod in ctx.attr.mods
    }

    bazel_builtins = {
        mod.label.name: struct(
            mod_flags = _bazel_builtin_mod_flags(ctx, mod.label),
            dep = _bazel_builtin_dep(mod.label),
            file = [
                file
                for file in mods[mod.label.name].transitive_inputs.to_list()
                if file.path == _bazel_builtin_file_name(ctx, mod.label)
            ],
        )
        for mod in ctx.attr.mods
    }

    expected = []
    expected.extend(["--dep", "'data_c_zig={}'".format(mods["data_c_zig"].canonical_name)])
    expected.extend(["--dep", bazel_builtins["data"].dep])
    expected.extend(["'-M{name}={src}'".format(
        name = mods["data"].canonical_name,
        src = mods["data"].module_context.main.path,
    )])
    expected.extend(["'-M{}={}'".format(mods["data_c_zig"].canonical_name, mods["data_c_zig"].module_context.main.path)])
    expected.extend(bazel_builtins["data"].mod_flags)

    ctx.actions.write(
        output = ctx.outputs.out,
        content = "\n".join(expected) + "\n",
    )

_write_simple_module_with_c_expected_specs_args = rule(
    _write_simple_module_with_c_expected_specs_args_impl,
    attrs = {
        "mods": attr.label_list(providers = [ZigModuleInfo]),
        "mod_mains": attr.label_list(allow_files = True),
        "out": attr.output(mandatory = True),
    },
)

def _write_simple_module_with_global_c_expected_specs_args_impl(ctx):
    mods = {
        mod.label.name: mod[ZigModuleInfo]
        for mod in ctx.attr.mods
    }

    bazel_builtins = {
        mod.label.name: struct(
            mod_flags = _bazel_builtin_mod_flags(ctx, mod.label),
            dep = _bazel_builtin_dep(mod.label),
            file = [
                file
                for file in mods[mod.label.name].transitive_inputs.to_list()
                if file.path == _bazel_builtin_file_name(ctx, mod.label)
            ],
        )
        for mod in ctx.attr.mods
    }

    expected = []

    expected.extend(["--dep", bazel_builtins["data_global_c"].dep])
    expected.extend(["--dep", "'c=c'"])
    expected.extend(_expected_cdeps_copts(mods["data_global_c"].module_context.compilation_context))
    expected.extend(["'-M{name}={src}'".format(
        name = mods["data_global_c"].canonical_name,
        src = mods["data_global_c"].module_context.main.path,
    )])
    expected.extend(bazel_builtins["data_global_c"].mod_flags)
    expected.extend(["'-M{name}={src}'".format(
        name = mods["data_c_zig"].canonical_name,
        src = mods["data_c_zig"].module_context.main.path,
    )])

    ctx.actions.write(
        output = ctx.outputs.out,
        content = "\n".join(expected) + "\n",
    )

_write_simple_module_with_global_c_expected_specs_args = rule(
    _write_simple_module_with_global_c_expected_specs_args_impl,
    attrs = {
        "mods": attr.label_list(providers = [ZigModuleInfo]),
        "mod_mains": attr.label_list(allow_files = True),
        "out": attr.output(mandatory = True),
    },
)

def _write_simple_module_with_import_name_specs_args_impl(ctx):
    mods = {
        mod.label.name: mod[ZigModuleInfo]
        for mod in ctx.attr.mods
    }

    mod_mains = {
        mod.label.name: main
        for (mod, main) in zip(ctx.attr.mods, ctx.files.mod_mains)
    }

    bazel_builtins = {
        mod.label.name: struct(
            mod_flags = _bazel_builtin_mod_flags(ctx, mod.label),
            dep = _bazel_builtin_dep(mod.label),
            file = [
                file
                for file in mods[mod.label.name].transitive_inputs.to_list()
                if file.path == _bazel_builtin_file_name(ctx, mod.label)
            ],
        )
        for mod in ctx.attr.mods
    }

    expected = []

    expected.extend(["--dep", "'import-name-module/data={}'".format(mods["data"].canonical_name)])
    expected.extend(["--dep", bazel_builtins["main"].dep])
    expected.extend(["'-M{canonical_name}={src}'".format(
        canonical_name = mods["main"].canonical_name,
        src = mod_mains["main"].path,
    )])

    expected.extend(bazel_builtins["data"].mod_flags)

    expected.extend(["--dep", bazel_builtins["data"].dep])
    expected.extend(["'-M{}={}'".format(mods["data"].canonical_name, mod_mains["data"].path)])

    expected.extend(bazel_builtins["main"].mod_flags)

    ctx.actions.write(
        output = ctx.outputs.out,
        content = "\n".join(expected) + "\n",
    )

_write_simple_module_with_import_name_specs_args = rule(
    _write_simple_module_with_import_name_specs_args_impl,
    attrs = {
        "mods": attr.label_list(providers = [ZigModuleInfo]),
        "mod_mains": attr.label_list(allow_files = True),
        "out": attr.output(mandatory = True),
    },
)

def module_info_test_suite(name):
    """Generate module info test suite.

    Args:
        name: The name of the test suite.
    """
    _write_simple_module_expected_specs_args(
        name = name + "_simple_expected",
        mod = "//zig/tests/multiple-sources-module:data",
        mod_main = "//zig/tests/multiple-sources-module:data.zig",
        out = name + "_simple_expected.txt",
        tags = ["manual"],
    )

    _write_module_specs_args(
        name = name + "_simple_actual",
        mod = "//zig/tests/multiple-sources-module:data",
        out = name + "_simple_actual.txt",
        tags = ["manual"],
    )

    diff_test(
        name = name + "_simple_diff_test",
        failure_message = "generated module specifications do not match",
        file1 = name + "_simple_expected.txt",
        file2 = name + "_simple_actual.txt",
        size = "small",
    )

    _write_transitive_modules_with_zigopts_expected_args(
        name = name + "_transitive_with_zigopts_expected",
        mods = [
            "//zig/tests/transitive-modules-zigopts:a",
            "//zig/tests/transitive-modules-zigopts:b",
        ],
        mod_mains = [
            "//zig/tests/transitive-modules-zigopts:a.zig",
            "//zig/tests/transitive-modules-zigopts:b.zig",
        ],
        out = name + "_transitive_with_zigopts_expected.txt",
        tags = ["manual"],
    )

    _write_module_specs_args(
        name = name + "_transitive_with_zigopts_actual",
        mod = "//zig/tests/transitive-modules-zigopts:b",
        out = name + "_transitive_with_zigopts_actual.txt",
        tags = ["manual"],
    )

    diff_test(
        name = name + "_transitive_with_zigopts_diff_test",
        failure_message = "generated module specifications do not match",
        file1 = name + "_transitive_with_zigopts_expected.txt",
        file2 = name + "_transitive_with_zigopts_actual.txt",
        size = "small",
    )

    _write_simple_module_with_c_expected_specs_args(
        name = name + "_simple_with_c_expected",
        mods = [
            "//zig/tests/translate-c-modules:data_c_zig",
            "//zig/tests/translate-c-modules:data",
        ],
        mod_mains = [
            "//zig/tests/translate-c-modules:data.zig",
        ],
        out = name + "_simple_with_c_expected.txt",
        tags = ["manual"],
    )

    _write_module_specs_args(
        name = name + "_simple_with_c_actual",
        mod = "//zig/tests/translate-c-modules:data",
        out = name + "_simple_with_c_actual.txt",
        tags = ["manual"],
    )

    diff_test(
        name = name + "_simple_with_c_diff_test",
        failure_message = "generated module specifications do not match",
        file1 = name + "_simple_with_c_expected.txt",
        file2 = name + "_simple_with_c_actual.txt",
        size = "small",
    )

    _write_simple_module_with_global_c_expected_specs_args(
        name = name + "_simple_with_global_c_expected",
        mods = [
            "//zig/tests/translate-c-modules:data_c_zig",
            "//zig/tests/translate-c-modules:data_global_c",
        ],
        mod_mains = [
            "//zig/tests/translate-c-modules:data_global_c.zig",
        ],
        out = name + "_simple_with_global_c_expected.txt",
        tags = ["manual"],
    )

    _write_module_specs_args(
        name = name + "_simple_with_global_c_actual",
        mod = "//zig/tests/translate-c-modules:data_global_c",
        cmod = "//zig/tests/translate-c-modules:data_c_zig",
        out = name + "_simple_with_global_c_actual.txt",
        tags = ["manual"],
    )

    diff_test(
        name = name + "_simple_with_global_c_diff_test",
        failure_message = "generated module specifications do not match",
        file1 = name + "_simple_with_global_c_expected.txt",
        file2 = name + "_simple_with_global_c_actual.txt",
        size = "small",
    )

    _write_nested_module_expected_specs_args(
        name = name + "_nested_expected",
        mods = [
            "//zig/tests/nested-modules:a",
            "//zig/tests/nested-modules:b",
            "//zig/tests/nested-modules:c",
            "//zig/tests/nested-modules:d",
            "//zig/tests/nested-modules:e",
            "//zig/tests/nested-modules:f",
        ],
        mod_mains = [
            "//zig/tests/nested-modules:a.zig",
            "//zig/tests/nested-modules:b.zig",
            "//zig/tests/nested-modules:c.zig",
            "//zig/tests/nested-modules:d.zig",
            "//zig/tests/nested-modules:e.zig",
            "//zig/tests/nested-modules:f.zig",
        ],
        out = name + "_nested_expected.txt",
        tags = ["manual"],
    )

    _write_module_specs_args(
        name = name + "_nested_actual",
        mod = "//zig/tests/nested-modules:a",
        out = name + "_nested_actual.txt",
        tags = ["manual"],
    )

    diff_test(
        name = name + "_nested_diff_test",
        failure_message = "generated module specifications do not match",
        file1 = name + "_nested_expected.txt",
        file2 = name + "_nested_actual.txt",
        size = "small",
    )

    _write_simple_module_with_import_name_specs_args(
        name = name + "_import_name_module_expected",
        mods = [
            "//zig/tests/import-name-module:main",
            "//zig/tests/import-name-module:data",
        ],
        mod_mains = [
            "//zig/tests/import-name-module:main.zig",
            "//zig/tests/import-name-module:data.zig",
        ],
        out = name + "_import_name_module_expected.txt",
        tags = ["manual"],
    )

    _write_module_specs_args(
        name = name + "_import_name_module_actual",
        mod = "//zig/tests/import-name-module:main",
        out = name + "_import_name_module_actual.txt",
        tags = ["manual"],
    )

    diff_test(
        name = name + "_import_name_module_diff_test",
        failure_message = "generated module specifications do not match",
        file1 = name + "_import_name_module_expected.txt",
        file2 = name + "_import_name_module_actual.txt",
        size = "small",
    )

    native.test_suite(
        name = name,
        tests = [
            name + "_simple_diff_test",
            name + "_nested_diff_test",
            name + "_simple_with_c_diff_test",
            name + "_simple_with_global_c_diff_test",
            name + "_import_name_module_diff_test",
            name + "_transitive_with_zigopts_diff_test",
        ],
    )
