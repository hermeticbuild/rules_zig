"""Common implementation of the zig_binary|library|test rules."""

load("@bazel_skylib//lib:paths.bzl", "paths")
load("@build_bazel_rules_android//:cc_common_link.bzl", "cc_common_link")
load("@rules_cc//cc:find_cc_toolchain.bzl", "use_cc_toolchain")
load("@rules_cc//cc/common:cc_common.bzl", "cc_common")
load("@rules_cc//cc/common:cc_helper.bzl", "cc_helper")
load("@rules_cc//cc/common:cc_info.bzl", "CcInfo")
load("//zig/private:cc_helper.bzl", "find_cc_toolchain", "need_translate_c")
load(
    "//zig/private/common:bazel_builtin.bzl",
    "bazel_builtin_module",
    BAZEL_BUILTIN_ATTRS = "ATTRS",
)
load("//zig/private/common:cdeps.bzl", "zig_cdeps_linker_inputs")
load("//zig/private/common:csrcs.bzl", "zig_csrcs")
load("//zig/private/common:data.bzl", "zig_collect_data", "zig_create_runfiles")
load("//zig/private/common:escape_label.bzl", "escape_label")
load(
    "//zig/private/common:exec_groups.bzl",
    "ZIG_EXEC_GROUPS",
    "translate_c_exec_group_toolchain",
    "zig_exec_group_action_kwargs",
    "zig_exec_group_toolchain",
)
load(
    "//zig/private/common:filetypes.bzl",
    "ZIG_C_SOURCE_EXTENSIONS",
    "ZIG_SOURCE_EXTENSIONS",
)
load("//zig/private/common:linker_script.bzl", "zig_linker_script")
load("//zig/private/common:location_expansion.bzl", "location_expansion")
load("//zig/private/common:semver.bzl", "semver")
load("//zig/private/common:translate_c.bzl", "zig_translate_c")
load("//zig/private/common:zig_cache.bzl", "zig_cache_output")
load("//zig/private/common:zig_lib_dir.bzl", "zig_lib_dir")
load(
    "//zig/private/providers:zig_module_info.bzl",
    "ZigModuleInfo",
    "zig_module_info",
    "zig_module_specifications",
)
load(
    "//zig/private/providers:zig_settings_info.bzl",
    "ZigSettingsInfo",
    "zig_settings",
)
load(
    "//zig/private/providers:zig_target_info.bzl",
    "zig_target_platform",
)
load(
    "//zig/private/providers:zig_toolchain_info.bzl",
    "zig_toolchain_executable",
    "zig_toolchain_lib_dir",
)

ATTRS = {
    "_incremental_worker": attr.label(
        default = "//zig/private/worker:tool",
        cfg = config.exec("zig"),
    ),
    "main": attr.label(
        allow_single_file = ZIG_SOURCE_EXTENSIONS,
        doc = """\
The main source file.

If not set, deps must contain exactly one Zig module dependency which will be used as the root module.
Note that in that case, 'srcs', 'extra_srcs' and 'csrcs' must also be empty as they are taken from the root module instead.
""",
        mandatory = False,
    ),
    "srcs": attr.label_list(
        allow_files = ZIG_SOURCE_EXTENSIONS,
        doc = "Other Zig source files required to build the target, e.g. files imported using `@import`.",
        mandatory = False,
    ),
    "extra_srcs": attr.label_list(
        allow_files = True,
        doc = "Other files required to build the target, e.g. files embedded using `@embedFile`.",
        mandatory = False,
    ),
    "extra_docs": attr.label_list(
        allow_files = True,
        doc = "Other files required to generate documentation, e.g. guides referenced using `//!zig-autodoc-guide:`.",
        mandatory = False,
    ),
    "csrcs": attr.label_list(
        allow_files = ZIG_C_SOURCE_EXTENSIONS,
        doc = "C source files required to build the target.",
        mandatory = False,
    ),
    "copts": attr.string_list(
        doc = "C compiler flags required to build the C sources of the target. Subject to location expansion.",
        mandatory = False,
    ),
    "deps": attr.label_list(
        doc = "The list of other modules or C/C++ libraries that the library target depends upon.",
        mandatory = False,
        providers = [[ZigModuleInfo], [CcInfo]],
    ),
    "import_names": attr.label_keyed_string_dict(
        doc = """\
Override the import name under which a dependency is imported.

Maps a dependency in `deps` to the name used to `@import` it from this target's
sources. By default a Zig module dependency is imported under its own
`import_name` or its target name.
""",
        mandatory = False,
        providers = [[ZigModuleInfo]],
    ),
    "compiler_runtime": attr.string(
        doc = """\
Whether to include Zig compiler runtime symbols in the generated output.
The default behavior is to include them in executables and shared libraries.
""",
        mandatory = False,
        values = ["exclude", "include", "default"],
        default = "default",
    ),
    "linker_script": attr.label(
        doc = """\
Custom linker script for the target.

Note, as of Zig version 0.15.1 linker-scripts require the LLVM/LLD backend to be
enabled, see https://github.com/ziglang/zig/issues/25069. Set
`zigopts=["-fllvm", "-flld"]` to that end.
""",
        allow_single_file = True,
        mandatory = False,
    ),
    "strip_debug_symbols": attr.bool(
        doc = "Whether to force passing '-fstrip' to the zig compiler to remove debug symbols. Bazel's `--strip` flag is also supported globally.",
        mandatory = False,
        default = False,
    ),
    "data": attr.label_list(
        allow_files = True,
        doc = "Files required by the target during runtime.",
        mandatory = False,
    ),
    "zigopts": attr.string_list(
        doc = """Additional list of flags passed to the zig compiler. Subject to location expansion.

This is an advanced feature that can conflict with attributes, build settings, and other flags defined by the toolchain itself.
Use this at your own risk of hitting undefined behaviors.
""",
        mandatory = False,
    ),
    "linkopts": attr.string_list(
        doc = "Additional list of flags passed to the linker. Subject to location expansion.",
        mandatory = False,
    ),
    "_settings": attr.label(
        default = "//zig/settings",
        doc = "Zig build settings.",
        providers = [ZigSettingsInfo],
    ),
} | BAZEL_BUILTIN_ATTRS

COMMON_EMIT_ATTRS = {
    "emit_asm": attr.bool(
        doc = "Emit the assembly in the `asm` output group.",
        mandatory = False,
        default = False,
    ),
    "emit_llvm_ir": attr.bool(
        doc = "Emit the LLVM IR in the `llvm_ir` output group.",
        mandatory = False,
        default = False,
    ),
    "emit_llvm_bc": attr.bool(
        doc = "Emit the LLVM bytecode in the `llvm_bc` output group.",
        mandatory = False,
        default = False,
    ),
}

STATIC_LIBRARY_ATTRS = {
    "emit_bin": attr.bool(
        doc = "Emit the binary.",
        mandatory = False,
        default = True,
    ),
} | COMMON_EMIT_ATTRS

SHARED_LIBRARY_ATTRS = {
    "shared_lib_name": attr.string(
        doc = "",
        mandatory = False,
    ),
} | COMMON_EMIT_ATTRS

BINARY_ATTRS = {
    "env": attr.string_dict(
        doc = """\
Additional environment variables to set when executed by `bazel run`.
Subject to location expansion.
NOTE: The environment variables are not set when you run the target outside of Bazel (for example, by manually executing the binary in bazel-bin/).
        """,
        mandatory = False,
    ),
} | COMMON_EMIT_ATTRS

TEST_ATTRS = {
    "env": attr.string_dict(
        doc = """\
Additional environment variables to set when executed by `bazel run` or `bazel test`.
Subject to location expansion.
        """,
        mandatory = False,
    ),
    "env_inherit": attr.string_list(
        doc = """\
Environment variables to inherit from external environment when executed by `bazel test`.
        """,
        mandatory = False,
    ),
    "test_runner": attr.label(
        allow_single_file = ZIG_SOURCE_EXTENSIONS,
        doc = "Optional Zig file to specify a custom test runner",
        mandatory = False,
    ),
} | COMMON_EMIT_ATTRS

TOOLCHAINS = [
    "//zig/target:toolchain_type",
] + use_cc_toolchain(mandatory = False)

EXEC_GROUPS = ZIG_EXEC_GROUPS

FRAGMENTS = ["cpp"]

def _lib_prefix(os):
    return "" if os == "windows" else "lib"

def _static_lib_extension(os):
    return ".lib" if os == "windows" else ".a"

def _shared_lib_extension(os):
    return {
        "windows": ".dll",
        "darwin": ".dylib",
        "macos": ".dylib",
    }.get(os, ".so")

def _executable_extension(os):
    return ".exe" if os == "windows" else ""

def _object_extension(os):
    return ".obj" if os == "windows" else ".o"

def _references_auto_c(root_module):
    """Whether any module imports the automatic `c` module; if none does, skip generating it."""
    contexts = [root_module.module_context] + root_module.transitive_module_contexts.to_list()
    for context in contexts:
        for mapping in context.dependency_mappings:
            if mapping.name == "c" and mapping.canonical_name == "c":
                return True
    return False

def _compile(ctx, *, worker, zigtoolchaininfo, command, global_args, args, outputs, inputs, mnemonic, progress_message, **kwargs):
    """Declare a compilation once; the setting chooses its execution adapter."""
    executable = zig_toolchain_executable(zigtoolchaininfo)
    arguments = command + [global_args, args]
    tools = []
    if worker:
        # Metadata, output paths, ordered compiler arguments, then a framed
        # input list. Prefixing input paths makes the final delimiter unambiguous,
        # even when a compiler operand or an input file is named "--".
        args.add("--")
        args.add_all(inputs, format_each = "input=%s")
        args.use_param_file("@%s", use_always = True)
        args.set_param_file_format("multiline")
        startup = ctx.actions.args()
        startup.add(executable, format = "--zig=%s")
        startup.add(zig_toolchain_lib_dir(zigtoolchaininfo), format = "--lib=%s")
        tools = [executable, zig_toolchain_lib_dir(zigtoolchaininfo)]
        executable = worker
        arguments = [startup, args]
        mnemonic = "ZigIncrementalCompile"
        kwargs["execution_requirements"] = kwargs["execution_requirements"] | {
            "supports-workers": "1",
            "requires-worker-protocol": "json",
            "no-remote-exec": "1",
            "no-remote-cache": "1",
        }
    ctx.actions.run(
        outputs = outputs,
        inputs = inputs,
        executable = executable,
        arguments = arguments,
        tools = tools,
        mnemonic = mnemonic,
        progress_message = progress_message,
        **kwargs
    )

def zig_build_impl(ctx, *, kind):
    """Common implementation for Zig build rules.

    Args:
      ctx: Bazel rule context object.
      kind: String; The kind of the rule, one of `zig_binary`, `zig_static_library`, `zig_shared_library`, `zig_test`.

    Returns:
      List of providers.
    """
    root_module_is_only_dep = len(ctx.attr.deps) == 1 and ZigModuleInfo in ctx.attr.deps[0] and ctx.attr.main == None
    if root_module_is_only_dep:
        if len(ctx.attr.srcs) > 0:
            fail("'srcs' cannot be set without a 'main'. They are taken from the root module defined by the single zig dependency.")
        if len(ctx.attr.extra_srcs) > 0:
            fail("'extra_srcs' cannot be set without a 'main'. They are taken from the root module defined by the single zig dependency.")
        if len(ctx.attr.csrcs) > 0:
            fail("'csrcs' cannot be set without a 'main'. They are taken from the root module defined by the single zig dependency.")
    if kind == "zig_static_library":
        if not (ctx.attr.emit_bin or ctx.attr.emit_asm or ctx.attr.emit_llvm_ir or ctx.attr.emit_llvm_bc):
            fail("At least one emitted output must be enabled.")

    zigtoolchaininfo = zig_exec_group_toolchain(ctx)
    zigtargetinfo = ctx.toolchains["//zig/target:toolchain_type"].zigtargetinfo
    translate_c_toolchain = translate_c_exec_group_toolchain(ctx)
    translatectoolchaininfo = translate_c_toolchain.translatectoolchaininfo if translate_c_toolchain else None

    settings = ctx.attr._settings[ZigSettingsInfo]
    use_cc_common_link = settings.use_cc_common_link
    incremental_worker = None
    if settings.incremental:
        if zigtoolchaininfo.mode != "file" or zigtoolchaininfo.zig_exe.file.basename.endswith(".exe"):
            fail("Incremental compilation requires a hermetic Zig toolchain with a POSIX worker adapter.")
        version = zigtoolchaininfo.zig_version
        if not version.startswith("0.17.") or not semver.gte(version, "0.17.0"):
            fail("Incremental compilation requires Zig 0.17.x (at least 0.17.0).")
        incremental_worker = ctx.attr._incremental_worker[DefaultInfo].files_to_run
        if not incremental_worker.executable:
            fail("Incremental compilation requires the worker tool dependency.")
        if zigtargetinfo.triple.arch != "x86_64" or zigtargetinfo.triple.os != "linux":
            fail("Incremental compilation currently supports x86_64-linux targets only.")
        if ctx.attr.csrcs or ctx.attr.copts or ctx.file.linker_script:
            fail("Incremental compilation requires no C sources/compiler options or linker scripts.")

    cc_toolchain = None
    feature_configuration = None
    generate_dsym_file = False
    if use_cc_common_link and kind != "zig_static_library":
        cc_toolchain, feature_configuration = find_cc_toolchain(ctx, mandatory = True)
        generate_dsym_file = cc_common.is_enabled(
            feature_configuration = feature_configuration,
            feature_name = "generate_dsym_file",
        )

    providers = []
    exported_library_to_link = None
    direct_data = []
    transitive_data = []
    transitive_runfiles = []

    outputs = []
    output_groups = {}

    direct_inputs = []
    transitive_inputs = []

    zig_collect_data(
        data = ctx.attr.data,
        deps = ctx.attr.deps,
        transitive_data = transitive_data,
        transitive_runfiles = transitive_runfiles,
    )

    global_args = ctx.actions.args()
    global_args.use_param_file("@%s")

    # Ordinary compilation receives these defaults through global_args.
    # Worker requests carry them directly, before settings and explicit overrides.
    cc_link_compile_flags = []
    if use_cc_common_link:
        cc_link_compile_flags = [
            # For now, linking with cc_common.link implies linking with libc.
            # But this should probably be made configurable.
            "-lc",
            # This is implied too unless disabled further down.
            # This is because zig compiler-rt ships with __zig_probe_stack which doesn't exist in regular compiler-rt.
            "-fcompiler-rt",
        ]
        global_args.add_all(cc_link_compile_flags)

    if not incremental_worker:
        zig_lib_dir(
            zigtoolchaininfo = zigtoolchaininfo,
            args = global_args,
        )
        zig_cache_output(
            zigtoolchaininfo = zigtoolchaininfo,
            args = global_args,
        )

    location_targets = ctx.attr.data

    bin_output_is_executable = False
    bin_output_name = None
    bin_output = None
    solib_parents = []

    if kind == "zig_binary" or kind == "zig_test":
        bin_output_name = ctx.label.name + _executable_extension(zigtargetinfo.triple.os)
        bin_output = ctx.actions.declare_file(bin_output_name)
        bin_output_is_executable = True

        # Calculate the RPATH components to discover the solib tree.
        # See https://github.com/bazelbuild/bazel/blob/7.0.0/src/main/java/com/google/devtools/build/lib/rules/cpp/LibrariesToLinkCollector.java#L177
        # TODO: Implement case 8b.
        solib_parents = [
            "/".join([".." for _ in ctx.label.package.split("/")]),
            paths.join(bin_output.basename + ".runfiles", ctx.workspace_name),
        ]
    elif kind == "zig_static_library" and ctx.attr.emit_bin:
        bin_output_name = _lib_prefix(zigtargetinfo.triple.os) + ctx.label.name + _static_lib_extension(zigtargetinfo.triple.os)
        bin_output = ctx.actions.declare_file(bin_output_name)
    elif kind == "zig_shared_library":
        if (ctx.attr.shared_lib_name):
            bin_output_name = ctx.attr.shared_lib_name
            bin_output = ctx.actions.declare_file(bin_output_name)
        else:
            bin_output_name = _lib_prefix(zigtargetinfo.triple.os) + ctx.label.name + _shared_lib_extension(zigtargetinfo.triple.os)
            bin_output = ctx.actions.declare_file(bin_output_name)
        solib_parents = [""]

    cc_link_kwargs = {}
    if generate_dsym_file:
        dsym_file = ctx.actions.declare_directory(ctx.label.name + ".dSYM", sibling = bin_output)
        cc_link_kwargs = {
            "additional_outputs": [dsym_file],
            "variables_extension": {"dsym_path": dsym_file.path},
        }
        output_groups["dsyms"] = depset([dsym_file])

    compile_bin_output = bin_output
    cc_static_lib = None
    test_obj = None
    if use_cc_common_link and kind in ["zig_binary", "zig_shared_library"]:
        # Zig produces this archive; the separate C/C++ link produces bin_output.
        cc_static_lib = ctx.actions.declare_file(ctx.label.name + _static_lib_extension(zigtargetinfo.triple.os))
        compile_bin_output = cc_static_lib
    elif use_cc_common_link and kind == "zig_test":
        # Test compilation produces an object; a separate build-lib packages it.
        test_obj = ctx.actions.declare_file(ctx.label.name + _object_extension(zigtargetinfo.triple.os))
        compile_bin_output = test_obj

    # zig_binary, zig_test and zig_shared_library must produce their primary output, so emit_bin is not user configurable and considered true.
    should_emit_bin = bin_output_is_executable or kind == "zig_shared_library" or ctx.attr.emit_bin

    primary_emission = None
    if should_emit_bin:
        outputs.append(bin_output)
        primary_emission = struct(
            kind = "bin",
            file = compile_bin_output,
            flag = "-femit-bin=%s",
        )

    auxiliary_emissions = []
    if ctx.attr.emit_asm:
        auxiliary_emissions.append(struct(
            kind = "asm",
            file = ctx.actions.declare_file(ctx.label.name + ".s"),
            flag = "-femit-asm=%s",
        ))
    if ctx.attr.emit_llvm_ir:
        auxiliary_emissions.append(struct(
            kind = "llvm_ir",
            file = ctx.actions.declare_file(ctx.label.name + ".ll"),
            flag = "-femit-llvm-ir=%s",
        ))

    if ctx.attr.emit_llvm_bc:
        auxiliary_emissions.append(struct(
            kind = "llvm_bc",
            file = ctx.actions.declare_file(ctx.label.name + ".bc"),
            flag = "-femit-llvm-bc=%s",
        ))

    for emission in auxiliary_emissions:
        output_groups[emission.kind] = depset([emission.file])

    emissions = ([primary_emission] if primary_emission else []) + auxiliary_emissions
    emitted_outputs = {emission.kind: emission.file for emission in emissions}
    compile_outputs = emitted_outputs.values()

    args = ctx.actions.args()
    args.use_param_file("@%s")
    if incremental_worker:
        command, output_kind = {
            "zig_binary": ("build-exe", "executable"),
            "zig_test": ("test-obj", "object") if test_obj else ("test", "executable"),
            "zig_static_library": ("build-lib", "static_library"),
            "zig_shared_library": ("build-lib", "shared_library"),
        }["zig_static_library" if cc_static_lib else kind]
        args.add(json.encode({
            "command": command,
            "output_kind": output_kind,
            "name": ctx.attr.deps[0][ZigModuleInfo].canonical_name if root_module_is_only_dep else escape_label(label = ctx.label),
            "outputs": emitted_outputs.keys(),
        }))
        args.add_all(emitted_outputs.values())
        args.add_all(cc_link_compile_flags)
        zig_settings(settings = settings, args = args)
        zig_target_platform(target = zigtargetinfo, args = args)

    if ctx.attr.compiler_runtime == "include":
        args.add("-fcompiler-rt")
    elif ctx.attr.compiler_runtime == "exclude":
        args.add("-fno-compiler-rt")

    if ctx.attr.strip_debug_symbols:
        if generate_dsym_file:
            fail("'strip_debug_symbols' cannot be enabled when generating a dSYM")
        if not settings.strip:
            args.add("-fstrip")

    if kind == "zig_test" and ctx.attr.test_runner:
        args.add("--test-runner", ctx.file.test_runner)
        direct_inputs.append(ctx.file.test_runner)

    copts = location_expansion(
        ctx = ctx,
        targets = location_targets,
        outputs = outputs,
        attribute_name = "copts",
        strings = ctx.attr.copts,
    )

    zig_csrcs(
        copts = copts,
        csrcs = ctx.files.csrcs,
        inputs = direct_inputs,
        args = args,
    )

    zig_linker_script(
        linker_script = ctx.file.linker_script,
        inputs = direct_inputs,
        args = args,
    )

    zigopts = location_expansion(
        ctx = ctx,
        targets = location_targets,
        outputs = outputs,
        attribute_name = "zigopts",
        strings = ctx.attr.zigopts,
    )

    zdeps = []
    cdeps = []
    dep_canonical_names = {}
    for dep in ctx.attr.deps:
        if ZigModuleInfo in dep:
            zdeps.append(dep[ZigModuleInfo])
            dep_canonical_names[dep[ZigModuleInfo].canonical_name] = None
        elif CcInfo in dep:
            cdeps.append(dep[CcInfo])

    import_names = {}
    for dep, import_name in ctx.attr.import_names.items():
        canonical_name = dep[ZigModuleInfo].canonical_name
        if canonical_name not in dep_canonical_names:
            fail("import_names: '{}' must also be listed in deps.".format(dep.label))
        import_names[canonical_name] = import_name

    if root_module_is_only_dep:
        if ctx.attr.import_names:
            fail("import_names has no effect when a single dependency is used as the root module; set `main` to define a module.")
        root_module = ctx.attr.deps[0][ZigModuleInfo]
    else:
        root_module = zig_module_info(
            name = ctx.attr.name,
            canonical_name = escape_label(label = ctx.label),
            main = ctx.file.main,
            srcs = ctx.files.srcs,
            extra_srcs = ctx.files.extra_srcs,
            deps = zdeps + [bazel_builtin_module(ctx)],
            cdeps = cdeps,
            zigopts = zigopts,
            import_names = import_names,
        )

    zig_settings(
        settings = settings,
        args = global_args,
    )

    zig_target_platform(
        target = zigtargetinfo,
        args = global_args,
    )

    c_module = None
    if need_translate_c(root_module.cc_info) and _references_auto_c(root_module):
        c_module = zig_translate_c(
            ctx = ctx,
            name = "c",
            canonical_name = "c",
            zigtoolchaininfo = zigtoolchaininfo,
            global_args = global_args,
            cc_infos = [root_module.cc_info],
            translatectoolchaininfo = translatectoolchaininfo,
        )
        transitive_inputs.append(c_module.transitive_inputs)

    if root_module.cc_info:
        cdeps_inputs = []
        if use_cc_common_link == False:
            # Add all cdeps linker inputs to the sandbox and zig args.
            zig_cdeps_linker_inputs(
                linking_context = root_module.cc_info.linking_context,
                solib_parents = solib_parents,
                os = zigtargetinfo.triple.os,
                inputs = cdeps_inputs,
                args = args,
                data = direct_data,
            )

            if incremental_worker and cdeps_inputs:
                print(
                    "{}: warning: Zig incremental linking may reuse stale native inputs ".format(ctx.label) +
                    "or retain previous link errors. Native input changes do not restart the compiler. " +
                    "Use use_cc_common_link or disable incremental compilation to avoid retained native-link state.",
                )

            transitive_inputs.append(depset(cdeps_inputs))

    if kind == "zig_test" and use_cc_common_link:
        # Zig 0.16's LLVM StackProtector pass crashes for test-obj when
        # compiler-rt provides __stack_chk_fail as an alias.
        # See: https://codeberg.org/ziglang/zig/issues/31702
        # TODO[CK]: Remove once we bump to 0.17.0.
        args.add("-fno-stack-protector")

    zig_module_specifications(
        root_module = root_module,
        args = args,
        c_module = c_module,
    )

    transitive_inputs.append(root_module.transitive_inputs)
    transitive_inputs.append(depset([zigtoolchaininfo.validation]))
    if zigtoolchaininfo.zig_lib.file != None:
        transitive_inputs.append(depset([zigtoolchaininfo.zig_lib.file]))

    inputs = depset(
        direct = direct_inputs,
        transitive = transitive_inputs,
        order = "preorder",
    )

    zig_build_kwargs = dict(
        execution_requirements = {tag: "" for tag in ctx.attr.tags},
        env = {
            "ZIG_GLOBAL_CACHE_DIR": zigtoolchaininfo.zig_cache,
            "ZIG_LOCAL_CACHE_DIR": zigtoolchaininfo.zig_cache,
        },
    ) | zig_exec_group_action_kwargs()

    linkopts = location_expansion(
        ctx = ctx,
        targets = location_targets,
        outputs = outputs,
        attribute_name = "linkopts",
        strings = ctx.attr.linkopts,
    )

    if not use_cc_common_link and kind != "zig_static_library":
        args.add_all(linkopts)

    if not incremental_worker:
        for emission in auxiliary_emissions:
            args.add(emission.file, format = emission.flag)
        if primary_emission:
            args.add(primary_emission.file, format = primary_emission.flag)
        else:
            args.add("-fno-emit-bin")

    compile_kwargs = {
        "worker": incremental_worker,
        "zigtoolchaininfo": zigtoolchaininfo,
        "global_args": global_args,
    } | zig_build_kwargs

    if kind == "zig_binary":
        if use_cc_common_link:
            static_lib = cc_static_lib
            _compile(
                ctx,
                outputs = compile_outputs,
                inputs = inputs,
                command = ["build-lib"],
                args = args,
                mnemonic = "ZigBuildLib",
                progress_message = "zig build-lib %{label}",
                **compile_kwargs
            )

            library_to_link = cc_common.create_library_to_link(
                actions = ctx.actions,
                feature_configuration = feature_configuration,
                cc_toolchain = cc_toolchain,
                static_library = static_lib,
            )
            linking_context = cc_common.create_linking_context(
                linker_inputs = depset([
                    cc_common.create_linker_input(
                        owner = ctx.label,
                        libraries = depset([library_to_link]),
                    ),
                ]),
            )
            link_outputs = cc_common_link(
                actions = ctx.actions,
                feature_configuration = feature_configuration,
                cc_toolchain = cc_toolchain,
                name = ctx.label.name,
                output_type = "executable",
                main_output = bin_output,
                linking_contexts = [linking_context, root_module.cc_info.linking_context],
                user_link_flags = linkopts,
                **cc_link_kwargs
            )
        else:
            _compile(
                ctx,
                outputs = compile_outputs,
                inputs = inputs,
                command = ["build-exe"],
                args = args,
                mnemonic = "ZigBuildExe",
                progress_message = "zig build-exe %{label}",
                **compile_kwargs
            )
    elif kind == "zig_test":
        if use_cc_common_link:
            _compile(
                ctx,
                outputs = compile_outputs,
                inputs = inputs,
                command = ["test-obj", "--test-no-exec"],
                args = args,
                mnemonic = "ZigBuildTest",
                progress_message = "zig test-obj %{label}",
                **compile_kwargs
            )

            archive_emission = struct(
                kind = "bin",
                file = ctx.actions.declare_file(ctx.label.name + _static_lib_extension(zigtargetinfo.triple.os)),
                flag = "-femit-bin=%s",
            )
            static_lib = archive_emission.file
            lib_args = ctx.actions.args()
            if incremental_worker:
                # Source compilation uses worker-owned SDK/cache paths, but
                # packaging the emitted object remains an ordinary Zig action.
                zig_lib_dir(
                    zigtoolchaininfo = zigtoolchaininfo,
                    args = lib_args,
                )
                zig_cache_output(
                    zigtoolchaininfo = zigtoolchaininfo,
                    args = lib_args,
                )
            lib_args.add_all([
                "-fPIC",
                "-fcompiler-rt",
            ])
            lib_args.add(archive_emission.file, format = archive_emission.flag)
            lib_args.add(test_obj)
            _compile(
                ctx,
                outputs = [archive_emission.file],
                inputs = [test_obj, zigtoolchaininfo.validation] + ([zigtoolchaininfo.zig_lib.file] if zigtoolchaininfo.zig_lib.file else []),
                command = ["build-lib"],
                args = lib_args,
                mnemonic = "ZigBuildLib",
                progress_message = "zig build-lib %{label}",
                **(compile_kwargs | {"worker": None})
            )

            library_to_link = cc_common.create_library_to_link(
                actions = ctx.actions,
                feature_configuration = feature_configuration,
                cc_toolchain = cc_toolchain,
                static_library = static_lib,
            )
            linking_context = cc_common.create_linking_context(
                linker_inputs = depset([
                    cc_common.create_linker_input(
                        owner = ctx.label,
                        libraries = depset([library_to_link]),
                    ),
                ]),
            )
            link_outputs = cc_common_link(
                actions = ctx.actions,
                feature_configuration = feature_configuration,
                cc_toolchain = cc_toolchain,
                name = ctx.label.name,
                output_type = "executable",
                main_output = bin_output,
                linking_contexts = [linking_context, root_module.cc_info.linking_context],
                user_link_flags = linkopts,
                **cc_link_kwargs
            )
        else:
            _compile(
                ctx,
                outputs = compile_outputs,
                inputs = inputs,
                command = ["test", "--test-no-exec"],
                args = args,
                mnemonic = "ZigBuildTest",
                progress_message = "zig test %{label}",
                **compile_kwargs
            )
    elif kind == "zig_static_library":
        _compile(
            ctx,
            outputs = compile_outputs,
            inputs = inputs,
            command = ["build-lib"],
            args = args,
            mnemonic = "ZigBuildStaticLib",
            progress_message = "zig build-lib %{label}",
            **compile_kwargs
        )

        if ctx.attr.emit_bin:
            cc_toolchain, feature_configuration = find_cc_toolchain(ctx, mandatory = False)
            if cc_toolchain:
                exported_library_to_link = cc_common.create_library_to_link(
                    actions = ctx.actions,
                    feature_configuration = feature_configuration,
                    cc_toolchain = cc_toolchain,
                    static_library = bin_output,
                )

    elif kind == "zig_shared_library":
        if use_cc_common_link:
            static_lib = cc_static_lib
            _compile(
                ctx,
                outputs = compile_outputs,
                inputs = inputs,
                command = ["build-lib"],
                args = args,
                mnemonic = "ZigBuildLib",
                progress_message = "zig build-lib %{label}",
                **compile_kwargs
            )

            library_to_link = cc_common.create_library_to_link(
                actions = ctx.actions,
                feature_configuration = feature_configuration,
                cc_toolchain = cc_toolchain,
                static_library = static_lib,
                alwayslink = True,
            )
            linking_context = cc_common.create_linking_context(
                linker_inputs = depset([
                    cc_common.create_linker_input(
                        owner = ctx.label,
                        libraries = depset([library_to_link]),
                    ),
                ]),
            )
            link_outputs = cc_common_link(
                actions = ctx.actions,
                feature_configuration = feature_configuration,
                cc_toolchain = cc_toolchain,
                name = ctx.label.name,
                output_type = "dynamic_library",
                main_output = bin_output,
                linking_contexts = [linking_context, root_module.cc_info.linking_context],
                user_link_flags = linkopts,
                **cc_link_kwargs
            )

            exported_library_to_link = link_outputs.library_to_link

        else:
            # By default, Zig build-lib -dynamic sets the SONAME of the shared
            # library based on the name of its main module.
            #
            # This causes issue because the shared library name might:
            # 1. Be set by the user using 'shared_lib_name' attribute.
            # 2. Or default to a name based on the target label.
            #
            # Here we explicitly set the SONAME to match the output filename.
            args.add(bin_output_name, format = "-fsoname=%s")

            _compile(
                ctx,
                outputs = compile_outputs,
                inputs = inputs,
                command = ["build-lib", "-dynamic"],
                args = args,
                mnemonic = "ZigBuildSharedLib",
                progress_message = "zig build-lib -dynamic %{label}",
                **compile_kwargs
            )

            cc_toolchain, feature_configuration = find_cc_toolchain(ctx, mandatory = False)
            if cc_toolchain:
                exported_library_to_link = cc_common.create_library_to_link(
                    actions = ctx.actions,
                    feature_configuration = feature_configuration,
                    cc_toolchain = cc_toolchain,
                    dynamic_library = bin_output,
                )
    else:
        fail("Unknown rule kind '{}'.".format(kind))

    if root_module.cc_info:
        transitive_data.append(depset(cc_helper.get_dynamic_libraries_for_runtime(root_module.cc_info.linking_context, True)))

    providers.extend([
        DefaultInfo(
            executable = bin_output if bin_output_is_executable else None,
            files = depset([bin_output] if should_emit_bin else []),
            runfiles = zig_create_runfiles(
                ctx_runfiles = ctx.runfiles,
                direct_data = direct_data,
                transitive_data = transitive_data,
                transitive_runfiles = transitive_runfiles,
            ),
        ),
    ])

    if exported_library_to_link:
        providers.extend([
            cc_common.merge_cc_infos(
                direct_cc_infos = [
                    CcInfo(
                        linking_context = cc_common.create_linking_context(
                            linker_inputs = depset([
                                cc_common.create_linker_input(
                                    owner = ctx.label,
                                    libraries = depset([exported_library_to_link]),
                                ),
                            ]),
                        ),
                    ),
                ],
                cc_infos = [root_module.cc_info],
            ),
        ])

    if kind in ["zig_binary", "zig_test"]:
        run_environment = RunEnvironmentInfo(
            environment = dict(zip(ctx.attr.env.keys(), location_expansion(
                ctx = ctx,
                targets = location_targets,
                outputs = outputs,
                attribute_name = "env",
                strings = ctx.attr.env.values(),
            ))),
            inherited_environment = getattr(ctx.attr, "env_inherit", []),
        )
        providers.append(run_environment)

    return providers, output_groups
