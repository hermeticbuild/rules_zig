"""Expose the configured C/C++ toolchain's static C++ runtime as CcInfo."""

load("@rules_cc//cc:find_cc_toolchain.bzl", "use_cc_toolchain")
load("@rules_cc//cc/common:cc_common.bzl", "cc_common")
load("@rules_cc//cc/common:cc_info.bzl", "CcInfo")
load("//zig/private:cc_helper.bzl", "find_cc_toolchain")

def _cc_toolchain_runtime_impl(ctx):
    toolchain, features = find_cc_toolchain(ctx, mandatory = True)
    archives = toolchain.static_runtime_lib(feature_configuration = features).to_list()
    if not archives:
        fail("The configured C/C++ toolchain does not expose static C++ runtime archives. Use a toolchain that provides static_link_cpp_runtimes and enables it for this target.")

    libraries = []
    for archive in archives:
        libraries.append(cc_common.create_library_to_link(
            actions = ctx.actions,
            cc_toolchain = toolchain,
            feature_configuration = features,
            static_library = archive,
        ))

    linker_input = cc_common.create_linker_input(
        owner = ctx.label,
        libraries = depset(libraries),
    )
    return [CcInfo(linking_context = cc_common.create_linking_context(
        linker_inputs = depset([linker_input]),
    ))]

cc_toolchain_runtime = rule(
    implementation = _cc_toolchain_runtime_impl,
    toolchains = use_cc_toolchain(),
    fragments = ["cpp"],
)
