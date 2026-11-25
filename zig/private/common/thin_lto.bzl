"""Prepare a Zig compilation unit for the C/C++ toolchain's ThinLTO link."""

load("@rules_cc//cc:action_names.bzl", "ACTION_NAMES")
load("@rules_cc//cc:find_cc_toolchain.bzl", "CC_TOOLCHAIN_TYPE")
load("@rules_cc//cc/common:cc_common.bzl", "cc_common")

_OPTIMIZATION = {
    "debug": "-O0",
    "release_safe": "-O3",
    "release_fast": "-O3",
    "release_small": "-Oz",
}

def zig_thin_lto_validate(ctx, *, zigtoolchaininfo, target, settings, root_module):
    """Check the Zig settings and output modes supported by the raw bitcode path.

    Args:
        ctx: Zig rule context.
        zigtoolchaininfo: Resolved Zig compiler toolchain.
        target: Resolved Zig target toolchain.
        settings: Active Zig build settings.
        root_module: Root Zig module and its transitive module specifications.
    """
    if zigtoolchaininfo.zig_version != "0.17.1":
        fail("ThinLTO currently requires Zig 0.17.1.")
    abi = (target.triple.abi or "").split(".")[0]
    if target.triple.arch != "x86_64" or target.triple.os != "linux" or abi not in ("gnu", "musl"):
        fail("ThinLTO currently supports x86_64 Linux with the GNU or musl ABI, got '{}'.".format(target.target))
    if ctx.attr.csrcs or ctx.attr.copts:
        fail("ThinLTO requires C sources in cc_library dependencies rather than csrcs/copts.")
    if ctx.file.linker_script or ctx.attr.emit_asm or ctx.attr.emit_llvm_ir or ctx.attr.emit_llvm_bc:
        fail("ThinLTO does not support linker_script or auxiliary assembly/LLVM outputs.")

    # These flags would change the raw output, optimization, or target that
    # the preparation action expects. The first settings arguments set -O.
    options = list(settings.args[2:])
    for module in [root_module.module_context] + root_module.transitive_module_contexts.to_list():
        options.extend(module.zigopts)
    for option in options:
        if option in ("-fno-llvm", "-flibllvm", "-flld", "-fno-PIC", "-target", "-mcpu") or option.startswith(("-ofmt=", "-flto", "-femit-", "-fno-emit-", "-mcpu=", "-O", "--verbose-llvm-bc")):
            fail("ThinLTO cannot be combined with Zig option '{}'.".format(option))

def zig_thin_lto_emit_args(*, args, output):
    """Emit the frontend module through the Zig 0.17 bitcode dump interface.

    Args:
        args: Zig compiler arguments to extend.
        output: Declared raw bitcode output.
    """
    args.add_all([
        "-fllvm",
        "-fno-libllvm",
        "-fno-lld",
        "-fno-emit-bin",
    ])
    args.add(output, format = "--verbose-llvm-bc=%s")

def _check_target(target, command_line):
    # Clang can retarget an LLVM module. Require an explicit compatible triple
    # before allowing equivalent spellings to override the module triple.
    cc_target = None
    next_target = False
    for arg in command_line:
        if next_target:
            cc_target = arg
            next_target = False
        elif arg in ("-target", "--target"):
            next_target = True
        elif arg.startswith(("--target=", "-target=")):
            cc_target = arg.split("=", 1)[1]
        elif arg in ("-m32", "-mx32", "-arch", "-triple") or arg.startswith("-mabi="):
            fail("ThinLTO does not support target override '{}'.".format(arg))

    if not cc_target or next_target:
        fail("ThinLTO requires an explicit -target/--target from the C/C++ toolchain.")
    parts = cc_target.split("-")
    expected = [target.triple.arch, target.triple.os, target.triple.abi.split(".")[0]]
    if len(parts) == 4:
        parts = parts[:1] + parts[2:]
    if parts != expected:
        fail("ThinLTO target mismatch: Zig '{}', Clang '{}'.".format(target.target, cc_target))

def zig_thin_lto_prepare(ctx, *, raw, cc_toolchain, feature_configuration, target, mode):
    """Prepare raw bitcode for rules_cc's indexing and backend actions.

    Args:
        ctx: Zig rule context.
        raw: Frontend bitcode emitted by Zig.
        cc_toolchain: Resolved C/C++ toolchain for the cpp_link execution group.
        feature_configuration: C/C++ features active for this target.
        target: Resolved Zig target toolchain.
        mode: Active Zig optimization mode.

    Returns:
        A pair of the full bitcode object and its LTO compilation context.
    """
    if "clang" not in cc_toolchain.compiler:
        fail("Zig ThinLTO requires a Clang C/C++ toolchain, got '{}'.".format(cc_toolchain.compiler))

    full = ctx.actions.declare_file(ctx.label.name + ".o")
    use_minimized_bitcode = not cc_common.is_enabled(
        feature_configuration = feature_configuration,
        feature_name = "no_use_lto_indexing_bitcode_file",
    )
    minimized = ctx.actions.declare_file(ctx.label.name + ".indexing.o") if use_minimized_bitcode else None
    backend_flags = ctx.fragments.cpp.copts + ctx.fragments.cpp.conlyopts + [_OPTIMIZATION[mode]]

    variables = cc_common.create_compile_variables(
        cc_toolchain = cc_toolchain,
        feature_configuration = feature_configuration,
        source_file = raw.path,
        output_file = full.path,
        use_pic = True,
        user_compile_flags = backend_flags + ["-x", "ir"],
        variables_extension = {"lto_indexing_bitcode_file": minimized.path} if minimized else {},
    )
    action = ACTION_NAMES.c_compile
    command_line = cc_common.get_memory_inefficient_command_line(
        feature_configuration = feature_configuration,
        action_name = action,
        variables = variables,
    )
    _check_target(target, command_line)
    lto_flags = [flag for flag in command_line if flag == "-fno-lto" or flag == "-flto" or flag.startswith("-flto=")]
    if not lto_flags or lto_flags[-1] != "-flto=thin":
        fail("The C/C++ toolchain's compile action must enable -flto=thin to prepare Zig bitcode.")

    args = ctx.actions.args()
    args.add_all(command_line)
    args.add("-Wno-override-module")

    # The C compile action can supply include paths that LLVM IR does not use.
    args.add("-Wno-unused-command-line-argument")
    ctx.actions.run(
        executable = cc_common.get_tool_for_action(
            feature_configuration = feature_configuration,
            action_name = action,
        ),
        arguments = [args],
        inputs = [raw],
        tools = cc_toolchain.all_files,
        outputs = [full, minimized] if minimized else [full],
        env = cc_common.get_environment_variables(
            feature_configuration = feature_configuration,
            action_name = action,
            variables = variables,
        ),
        execution_requirements = {
            requirement: ""
            for requirement in cc_common.get_execution_requirements(
                feature_configuration = feature_configuration,
                action_name = action,
            )
        } | {tag: "" for tag in ctx.attr.tags},
        exec_group = "cpp_link",
        toolchain = CC_TOOLCHAIN_TYPE,
        mnemonic = "ZigThinLTOPrepare",
        progress_message = "Preparing Zig ThinLTO bitcode %{label}",
    )
    return full, cc_common.create_lto_compilation_context(objects = {
        full: (minimized, backend_flags),
    })
