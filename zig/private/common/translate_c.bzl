"""Handle translate-c pass."""

load("@apple_support//lib:apple_support.bzl", "apple_support")
load("@bazel_skylib//lib:paths.bzl", "paths")
load("@rules_cc//cc:action_names.bzl", "ACTION_NAMES")
load("@rules_cc//cc/common:cc_common.bzl", "cc_common")
load("@rules_cc//cc/common:cc_info.bzl", "CcInfo")
load("//zig/private:cc_helper.bzl", "find_cc_toolchain")
load("//zig/private/common:escape_label.bzl", "escape_label", "escape_label_str")
load(
    "//zig/private/common:exec_groups.bzl",
    "translate_c_exec_group_action_kwargs",
    "zig_exec_group_action_kwargs",
)
load("//zig/private/common:semver.bzl", "semver")
load("//zig/private/providers:zig_module_info.bzl", "zig_module_info")
load(
    "//zig/private/providers:zig_toolchain_info.bzl",
    "zig_toolchain_executable_path",
    "zig_toolchain_lib_dir_path",
)

_DEFAULT_SYSROOT_INCLUDE_DIRS = [
    paths.join("usr", "include"),
]

_APPLE_DEFAULT_TOOLCHAIN_INCLUDE_DIRS = _DEFAULT_SYSROOT_INCLUDE_DIRS + [
    paths.join("usr", "lib", "clang", str(version), "include")
    for version in range(15, 22)
]

# translate-c >= 2.0.0, which requires Zig >= 0.17.0, takes its own options
# before `--` and the input file and C options after it, and requires
# `--zig-lib`.
_TRANSLATE_C_2_MIN_ZIG_VERSION = "0.17.0"

_TRANSLATED_ARGS = {
    "-internal-isystem": "-isystem",
}

_FILTERED_ARGS = [
    "-Xclang",
]

def _sanitize_commandline(args):
    ret = []
    for arg in args:
        if arg in _TRANSLATED_ARGS:
            ret.append(_TRANSLATED_ARGS[arg])
            continue
        elif arg in _FILTERED_ARGS:
            continue
        for prefix, replacement in _TRANSLATED_ARGS.items():
            if arg.startswith(prefix):
                ret.append(replacement + arg[len(prefix):])
                continue
        for prefix in _FILTERED_ARGS:
            if arg.startswith(prefix):
                continue
        ret.append(arg)
    return ret

def _extract_sysroot(command_line):
    sysroot = None
    waiting_for_sysroot = False

    for arg in command_line:
        if waiting_for_sysroot:
            return arg
        elif arg == "-isysroot":
            waiting_for_sysroot = True
        elif arg.startswith("-isysroot"):
            # rare compact form: -isysroot/path
            return arg[len("-isysroot"):]
        elif arg.startswith("--sysroot="):
            return arg[len("--sysroot="):]

    if waiting_for_sysroot:
        fail("-isysroot without following path in command_line")

    return sysroot

def _include_path_for_file(file):
    if (file.is_source == False):
        virtual_include_prefix = "/_virtual_includes/{}/".format(file.owner.name)
        virtual_include_idx = file.path.find(virtual_include_prefix)
        if (virtual_include_idx > 0):
            return file.path[virtual_include_idx + len(virtual_include_prefix):]
    if (file.owner.repo_name):
        return file.path.removeprefix(file.owner.workspace_root + "/")
    return file.path

def _is_local_config_apple_cc(cc_toolchain):
    return cc_toolchain and "local_config_apple_cc" in cc_toolchain.compiler_executable

def _builtin_translate_c(*, ctx, zigtoolchaininfo, global_args, compilation_context, output_prefix):
    inputs = []
    transitive_inputs = [compilation_context.headers]

    hdr = ctx.actions.declare_file("{}{}_c.h".format(output_prefix, ctx.label.name))
    ctx.actions.write(hdr, "\n".join([
        '#include "{}"'.format(hdr.path)
        for hdr in compilation_context.direct_public_headers
    ]))
    inputs.append(hdr)

    args = ctx.actions.args()
    args.add(hdr)
    args.add("-lc")
    args.add_all(compilation_context.defines, format_each = "-D%s")
    args.add("-I.")
    args.add_all(compilation_context.includes, format_each = "-I%s")

    # Note, Zig does not support `-iquote` as of Zig 0.12.0
    # args.add_all(compilation_context.quote_includes, format_each = "-iquote%s")
    args.add_all(compilation_context.quote_includes, format_each = "-I%s")
    args.add_all(compilation_context.system_includes, before_each = "-isystem")

    # Added in Bazel 7, see https://github.com/bazelbuild/bazel/commit/a6ef0b341a8ffe8ab27e5ace79d8eaae158c422b
    args.add_all(getattr(compilation_context, "external_includes", []), before_each = "-isystem")
    args.add_all(compilation_context.framework_includes, format_each = "-F%s")

    # If there is a CC toolchain, add builtin directories.
    # This allows including to extra headers provided directly by the toolchain.
    # E.g. <os/log.h> on macOS.
    cc_toolchain, _ = find_cc_toolchain(ctx, mandatory = False)
    if cc_toolchain:
        transitive_inputs.append(cc_toolchain.all_files)
        args.add_all(cc_toolchain.built_in_include_directories, before_each = "-isystem")

    zig_out = ctx.actions.declare_file("{}{}_c.zig".format(output_prefix, ctx.label.name))
    inputs.extend([zigtoolchaininfo.validation])
    if zigtoolchaininfo.zig_lib.file != None:
        inputs.append(zigtoolchaininfo.zig_lib.file)

    ctx.actions.run_shell(
        command = "${{@}} > {}".format(zig_out.path),
        inputs = depset(
            direct = inputs,
            transitive = transitive_inputs,
        ),
        outputs = [zig_out],
        arguments = [zig_toolchain_executable_path(zigtoolchaininfo), "translate-c", global_args, args],
        mnemonic = "ZigTranslateC",
        progress_message = "zig translate-c %{label}",
        execution_requirements = {tag: "" for tag in ctx.attr.tags},
        env = {
            "ZIG_GLOBAL_CACHE_DIR": zigtoolchaininfo.zig_cache,
            "ZIG_LIB_DIR": zig_toolchain_lib_dir_path(zigtoolchaininfo),
            "ZIG_LOCAL_CACHE_DIR": zigtoolchaininfo.zig_cache,
        },
        tools = [zigtoolchaininfo.zig_exe.file] if zigtoolchaininfo.zig_exe.file else [],
        **zig_exec_group_action_kwargs()
    )

    return zig_out, []

def _external_translate_c(*, ctx, zigtoolchaininfo, translatectoolchaininfo, compilation_context, output_prefix):
    inputs = []
    transitive_inputs = [compilation_context.headers]

    hdrs = compilation_context.direct_public_headers

    # If there is a CC toolchain, add builtin directories.
    # This allows including to extra headers provided directly by the toolchain.
    # E.g. <os/log.h> on macOS.
    cc_toolchain, cc_feature_configuration = find_cc_toolchain(
        ctx,
        mandatory = False,
        disabled_features = ["thin_lto"],
    )

    # Detect if the toolchain is the local apple cc toolchain since it requires
    # special handling to get the builtin headers included.
    is_local_apple_cc = _is_local_config_apple_cc(cc_toolchain)
    if cc_toolchain:
        toolchain_defines_hdr = ctx.actions.declare_file("{}{}.toolchain_defines_hdr.c".format(output_prefix, ctx.label.name))
        ctx.actions.write(toolchain_defines_hdr, "")

        _, cc_results = cc_common.compile(
            actions = ctx.actions,
            feature_configuration = cc_feature_configuration,
            cc_toolchain = cc_toolchain,
            srcs = [toolchain_defines_hdr],
            name = ctx.label.name,
            # -fblocks is by default on darwin. but gcc doesn't handle it so best undef the macro manually.
            user_compile_flags = ["-x", "c", "-E", "-dM", "-D__building_module(x)=0", "-U__BLOCKS__"],
            disallow_pic_outputs = True,
        )

        hdrs = cc_results.objects + hdrs
        transitive_inputs.append(depset(direct = cc_results.objects))

    hdr = ctx.actions.declare_file("{}{}_c.h".format(output_prefix, ctx.label.name))
    ctx.actions.write(hdr, "\n".join([
        '#include "{}"'.format(_include_path_for_file(hdr))
        for hdr in hdrs
    ]))
    inputs.append(hdr)

    zig_out = ctx.actions.declare_file("{}{}_c.zig".format(output_prefix, ctx.label.name))

    args = ctx.actions.args()
    args.add("-fmodule-libs")
    if semver.gte(zigtoolchaininfo.zig_version, _TRANSLATE_C_2_MIN_ZIG_VERSION):
        args.add(zig_out, format = "-o=%s")
        args.add(zig_toolchain_lib_dir_path(zigtoolchaininfo), format = "--zig-lib=%s")
        args.add("--")
        if zigtoolchaininfo.zig_lib.file != None:
            inputs.append(zigtoolchaininfo.zig_lib.file)
    else:
        args.add("-o", zig_out)
    args.add(hdr)

    args.add_all([
        "-undef",
        "-nobuiltininc",
        "-D__building_module(x)=0",
    ])

    if cc_toolchain:
        c_compile_variables = cc_common.create_compile_variables(
            feature_configuration = cc_feature_configuration,
            cc_toolchain = cc_toolchain,
            user_compile_flags = ctx.fragments.cpp.copts + ctx.fragments.cpp.conlyopts,
        )
        command_line = cc_common.get_memory_inefficient_command_line(
            feature_configuration = cc_feature_configuration,
            action_name = ACTION_NAMES.c_compile,
            variables = c_compile_variables,
        )

        transitive_inputs.append(cc_toolchain.all_files)
        args.add_all(_sanitize_commandline(command_line))
        args.add_all(cc_toolchain.built_in_include_directories, before_each = "-isystem")

        # If the toolchain specifies a sysroot, add the sysroot's /usr/include as an
        # include path since that's where the toolchain's builtin headers are expected to be.
        sysroot = _extract_sysroot(command_line)
        if sysroot != None and sysroot != "/dev/null":
            args.add("-isystem", paths.join(sysroot, "usr", "include"))

        # If using the local apple cc toolchain, also include the default toolchain's
        # builtin headers since the local apple cc toolchain doesn't include them by default.
        if is_local_apple_cc:
            args.add_all(
                _APPLE_DEFAULT_TOOLCHAIN_INCLUDE_DIRS,
                before_each = "-isystem",
                format_each = paths.join(
                    apple_support.path_placeholders.xcode(),
                    "Toolchains",
                    "XcodeDefault.xctoolchain",
                    "",
                ) + "%s",
            )

    args.add_all(compilation_context.defines, format_each = "-D%s")
    args.add("-I.")
    args.add_all(compilation_context.includes, format_each = "-I%s")

    # Note, Zig does not support `-iquote` as of Zig 0.12.0
    # args.add_all(compilation_context.quote_includes, format_each = "-iquote%s")
    args.add_all(compilation_context.quote_includes, format_each = "-I%s")
    args.add_all(compilation_context.system_includes, before_each = "-isystem")

    # Added in Bazel 7, see https://github.com/bazelbuild/bazel/commit/a6ef0b341a8ffe8ab27e5ace79d8eaae158c422b
    args.add_all(getattr(compilation_context, "external_includes", []), before_each = "-isystem")
    args.add_all(compilation_context.framework_includes, format_each = "-F%s")

    args.add("--emulate=clang")

    actions_run = ctx.actions.run
    actions_run_extra_kwargs = {}
    if is_local_apple_cc:
        actions_run = apple_support.run
        actions_run_extra_kwargs = dict(
            actions = ctx.actions,
            apple_fragment = ctx.fragments.apple,
            xcode_config = ctx.attr._xcode_config[apple_common.XcodeVersionConfig],
            xcode_path_resolve_level = apple_support.xcode_path_resolve_level.args,
        )
    actions_run_extra_kwargs.update(translate_c_exec_group_action_kwargs())

    actions_run(
        inputs = depset(
            direct = inputs,
            transitive = transitive_inputs,
        ),
        executable = translatectoolchaininfo.executable,
        outputs = [zig_out],
        arguments = [args],
        mnemonic = "ZigTranslateC",
        progress_message = "zig translate-c %{label}",
        execution_requirements = {tag: "" for tag in ctx.attr.tags},
        tools = [translatectoolchaininfo.files_to_run],
        **actions_run_extra_kwargs
    )

    return zig_out, translatectoolchaininfo.runtime_modules

def zig_translate_c(*, ctx, name, zigtoolchaininfo, global_args, cc_infos, output_prefix = "", canonical_name = None, translatectoolchaininfo = None):
    """Handle translate-c build action.

    Sets the appropriate command-line flags for the Zig compiler to expose
    provided headers and link against the provided libraries.

    Args:
      ctx: Context object.
      name: String, the name of the resulting Zig module.
      canonical_name: String or None, optional canonical name override for the resulting Zig module.
      zigtoolchaininfo: ZigToolchainInfo.
      global_args: Args; mutable, Append the global Zig command-line flags to this object.
      cc_infos: List of CcInfo, The CcInfo providers for the C dependencies.
      output_prefix: String, a prefix to be used for generated files. Used for zig_docs.
      translatectoolchaininfo: TranslateCToolchainInfo or None. If present, use the external translate-c executable.

    Returns:
        `ZigModuleInfo` surrounding the generated zig file.
    """
    cc_info = cc_common.merge_cc_infos(direct_cc_infos = cc_infos)
    compilation_context = cc_info.compilation_context
    linking_context = cc_info.linking_context

    if translatectoolchaininfo:
        zig_out, translate_c_deps = _external_translate_c(
            ctx = ctx,
            zigtoolchaininfo = zigtoolchaininfo,
            translatectoolchaininfo = translatectoolchaininfo,
            compilation_context = compilation_context,
            output_prefix = output_prefix,
        )
    else:
        zig_out, translate_c_deps = _builtin_translate_c(
            ctx = ctx,
            zigtoolchaininfo = zigtoolchaininfo,
            global_args = global_args,
            compilation_context = compilation_context,
            output_prefix = output_prefix,
        )

    return zig_module_info(
        name = name,
        # To avoid collisions, we need to escape both label and name,
        # joined using a separator that cannot appear in escapted text.
        # (here "__" is used as separator, since "_" is escaped as "_U").
        canonical_name = canonical_name if canonical_name else "{}__{}".format(escape_label(label = ctx.label), escape_label_str(name)),
        main = zig_out,
        cdeps = [CcInfo(linking_context = linking_context)],
        deps = translate_c_deps,
    )
