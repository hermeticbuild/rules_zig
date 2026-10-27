"""Prepare raw Zig bitcode for the resolved C/C++ toolchain's ThinLTO pipeline."""

load("@rules_cc//cc:action_names.bzl", "ACTION_NAMES")
load("@rules_cc//cc:find_cc_toolchain.bzl", "CC_TOOLCHAIN_TYPE")
load("@rules_cc//cc/common:cc_common.bzl", "cc_common")
load(":semver.bzl", "semver")

_MIN_ZIG_VERSION = "0.18.0-dev.624+b7f2c6d8f"
_OPTIMIZATION = {
    "debug": "-O0",
    "release_safe": "-O3",
    "release_fast": "-O3",
    "release_small": "-Oz",
}

def thin_lto_validate(ctx, *, kind, zigtoolchaininfo, settings, root_module):
    """Reject combinations which cannot preserve the raw-bitcode contract."""
    if not semver.gte(zigtoolchaininfo.zig_version, _MIN_ZIG_VERSION):
        fail("ThinLTO requires Zig {} or newer with -ofmt=llvmbc support.".format(_MIN_ZIG_VERSION))
    if kind != "zig_static_library" and not settings.use_cc_common_link:
        fail("ThinLTO requires --@rules_zig//zig/settings:use_cc_common_link=true.")
    if ctx.attr.csrcs or ctx.attr.copts:
        fail("ThinLTO requires C sources in cc_library dependencies rather than csrcs/copts.")
    if ctx.file.linker_script or ctx.attr.emit_asm or ctx.attr.emit_llvm_ir or ctx.attr.emit_llvm_bc:
        fail("ThinLTO does not yet support linker_script or auxiliary assembly/LLVM outputs.")
    if kind == "zig_static_library" and not ctx.attr.emit_bin:
        fail("ThinLTO requires emit_bin=True.")

    # The settings provider starts with its authoritative '-O <mode>' pair.
    options = list(settings.args[2:])
    for module in [root_module.module_context] + root_module.transitive_module_contexts.to_list():
        options.extend(module.zigopts)
    for option in options:
        if option in ["-fno-llvm", "-flibllvm", "-flld", "-fno-PIC", "-target", "-mcpu"] or option.startswith(("-ofmt=", "-flto", "-femit-", "-fno-emit-", "-mcpu=", "-O")):
            fail("ThinLTO cannot be combined with Zig option '{}'.".format(option))

def _version(value):
    parts = value.split(".")
    if not value or len(parts) > 3 or not all([part.isdigit() for part in parts]):
        fail("ThinLTO requires an explicit numeric macOS deployment version, got '{}'".format(value))
    return [int(part) for part in parts] + [0] * (3 - len(parts))

def _check_target(target, command_line):
    # Validate the supported spellings rather than translating arbitrary flags
    # into Zig configuration. Clang otherwise silently overwrites the IR triple.
    cc_target = None
    macos_version = None
    next_target = False
    for arg in command_line:
        if next_target:
            cc_target = arg
            next_target = False
        elif arg in ["-target", "--target"]:
            next_target = True
        elif arg.startswith(("--target=", "-target=")):
            cc_target = arg.split("=", 1)[1]
        elif arg.startswith("-mmacosx-version-min="):
            macos_version = arg.split("=", 1)[1]
        elif arg in ["-arch", "-m32", "-m64", "-triple", "-darwin-target-variant-triple"] or arg.startswith(("-mtargetos=", "-target-variant", "-miphoneos-version-min=", "-mios-simulator-version-min=", "-mtvos-version-min=", "-mwatchos-version-min=")):
            fail("ThinLTO target validation does not support '{}'; configure an explicit C/C++ target triple.".format(arg))
    if not cc_target or next_target:
        fail("ThinLTO requires an explicit -target/--target from the C/C++ toolchain.")
    cc_parts = cc_target.split("-")
    zig_parts = target.target.split("-")
    if len(cc_parts) not in [3, 4] or len(zig_parts) != 3:
        fail("Unsupported ThinLTO target pair: Zig '{}', Clang '{}'.".format(target.target, cc_target))
    cc_arch = "aarch64" if cc_parts[0] == "arm64" else cc_parts[0]
    zig_arch, zig_os, zig_abi = zig_parts
    if cc_arch != zig_arch or zig_arch not in ["aarch64", "x86_64"]:
        fail("ThinLTO target architecture mismatch: Zig '{}', Clang '{}'.".format(target.target, cc_target))
    cc_os = cc_parts[2]
    cc_abi = cc_parts[3] if len(cc_parts) == 4 else "unknown"
    if zig_os.startswith("macos.") and cc_parts[1] == "apple" and cc_abi == "unknown" and zig_abi == "none":
        if cc_os.startswith("macosx"):
            triple_version = cc_os.removeprefix("macosx")
            if macos_version and _version(macos_version) != _version(triple_version):
                fail("Conflicting ThinLTO deployment targets: Clang triple '{}', -mmacosx-version-min={}.".format(cc_target, macos_version))
            macos_version = triple_version
        elif cc_os != "darwin":
            fail("Unsupported ThinLTO macOS triple '{}'".format(cc_target))
        if _version(zig_os.removeprefix("macos.")) != _version(macos_version or ""):
            fail("ThinLTO deployment target mismatch: Zig '{}', Clang macOS '{}'. Align the target toolchains.".format(target.target, macos_version))
    elif zig_os == "linux" and cc_os == "linux" and cc_abi in ["gnu", "musl"] and zig_abi.split(".")[0] == cc_abi:
        pass
    else:
        fail("Unsupported ThinLTO target pair: Zig '{}', Clang '{}'. macOS requires an explicit Zig deployment version.".format(target.target, cc_target))

def thin_lto_compile(ctx, *, raw, cc_toolchain, feature_configuration, zigtargetinfo, settings):
    """Optimize once and emit paired full/indexing bitcode using resolved Clang."""
    if "clang" not in cc_toolchain.compiler:
        fail("Zig ThinLTO requires a Clang C/C++ toolchain, got '{}'".format(cc_toolchain.compiler))
    full = ctx.actions.declare_file(ctx.label.name + ".o")
    use_mini = not cc_common.is_enabled(feature_configuration = feature_configuration, feature_name = "no_use_lto_indexing_bitcode_file")
    mini = ctx.actions.declare_file(ctx.label.name + ".indexing.o") if use_mini else None
    backend_flags = ctx.fragments.cpp.copts + ctx.fragments.cpp.conlyopts + [_OPTIMIZATION[settings.mode]]
    variables = cc_common.create_compile_variables(
        cc_toolchain = cc_toolchain,
        feature_configuration = feature_configuration,
        source_file = raw.path,
        output_file = full.path,
        use_pic = True,
        user_compile_flags = backend_flags + ["-x", "ir"],
        variables_extension = {"lto_indexing_bitcode_file": mini.path} if mini else {},
    )
    action = ACTION_NAMES.c_compile
    command_line = cc_common.get_memory_inefficient_command_line(feature_configuration = feature_configuration, action_name = action, variables = variables)
    _check_target(zigtargetinfo, command_line)
    args = ctx.actions.args()
    args.add_all(command_line)

    # After checking semantic equality, permit spelling differences such as
    # aarch64 vs arm64 and Zig's explicit trailing -unknown ABI on Darwin.
    args.add("-Wno-override-module")
    ctx.actions.run(
        executable = cc_common.get_tool_for_action(feature_configuration = feature_configuration, action_name = action),
        arguments = [args],
        inputs = [raw],
        tools = cc_toolchain.all_files,
        outputs = [full, mini] if mini else [full],
        env = cc_common.get_environment_variables(feature_configuration = feature_configuration, action_name = action, variables = variables),
        execution_requirements = {key: "" for key in cc_common.get_execution_requirements(feature_configuration = feature_configuration, action_name = action)},
        toolchain = CC_TOOLCHAIN_TYPE,
        mnemonic = "ZigThinLTOPrepare",
        progress_message = "Preparing Zig ThinLTO bitcode %{label}",
    )
    lto = cc_common.create_lto_compilation_context(objects = {full: (mini, backend_flags)})

    # Zig and Clang both receive PIC flags. The same PIC object is valid for
    # static executables and shared libraries, including mixed C/C++ consumers.
    return cc_common.create_compilation_outputs(
        objects = depset([full]),
        pic_objects = depset([full]),
        lto_compilation_context = lto,
    )
