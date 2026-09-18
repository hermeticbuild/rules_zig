"""Defines providers for the zig_library rule."""

load("@rules_cc//cc/common:cc_common.bzl", "cc_common")
load("//zig/private:cc_helper.bzl", "need_translate_c")
load("//zig/private/common:cdeps.bzl", "zig_cdeps_copts")

DOC = """\
Information about a Zig module.

A Zig module is a collection of Zig sources
with a main file that serves as an entry point.

Zig modules are not pre-compiled,
instead the Zig compiler performs whole program compilation.
"""

FIELDS = {
    "name": "string, The import name of the module.",
    "canonical_name": "string, The canonical name may differ from the import name via remapping.",
    "module_context": "struct, per module compilation context required when depending on the module.",
    "cc_info": "CcInfo or None, Merged CcInfo from all transitive dependencies.",
    "transitive_module_contexts": "depset of struct, All compilation context required by direct and transitive dependencies.",
    "transitive_inputs": "depset of File, All dependencies required when depending on the module, including transitive dependencies.",
}

ZigModuleInfo = provider(
    fields = FIELDS,
    doc = DOC,
)

def _zig_module_context(name, canonical_name, main, deps, cdeps, compilation_context, zigopts, import_names):
    mappings = [
        struct(name = import_names.get(dep.canonical_name, dep.name), canonical_name = dep.canonical_name)
        for dep in deps
    ]
    if any([need_translate_c(dep) for dep in cdeps]):
        # Global C module has a predefined name and canonical name since it is not defined yet here.
        mappings.append(struct(name = "c", canonical_name = "c"))
    return struct(
        name = name,
        canonical_name = canonical_name,
        main = main.path,
        compilation_context = compilation_context,
        zigopts = tuple(zigopts),
        dependency_mappings = tuple(mappings),
    )

def zig_module_info(*, name, canonical_name, main, srcs = [], extra_srcs = [], deps = [], cdeps = [], zigopts = [], import_names = {}):
    """Create `ZigModuleInfo` for a new Zig module.

    Args:
      name: string, The import name of the module.
      canonical_name: string, The canonical name may differ from the import name via remapping.
      main: File, The main source file of the module.
      srcs: list of File, Other Zig source files that belong to the module.
      extra_srcs: list of File, Other files that belong to the module.
      deps: list of ZigModuleInfo, Import dependencies of this module.
      cdeps: list of CcInfo, C dependencies of this module.
      zigopts: list of string, Additional list of flags passed to the zig compiler.
      import_names: dict of string to string, Override the import name of a
        dependency, keyed by the dependency's canonical name. A dependency not
        listed is imported under its own `name`.

    Returns:
      `ZigModuleInfo`
    """
    cc_infos = cdeps + [dep.cc_info for dep in deps if dep.cc_info]
    cc_info = cc_common.merge_cc_infos(direct_cc_infos = cc_infos)

    direct_compilation_context = cc_common.merge_cc_infos(direct_cc_infos = cdeps).compilation_context
    cc_headers = [direct_compilation_context.headers]

    module_context = _zig_module_context(name, canonical_name, main, deps, cdeps, direct_compilation_context, zigopts, import_names)

    module = ZigModuleInfo(
        name = name,
        canonical_name = canonical_name,
        module_context = module_context,
        cc_info = cc_info,
        transitive_module_contexts = depset(direct = [dep.module_context for dep in deps], transitive = [dep.transitive_module_contexts for dep in deps], order = "postorder"),
        transitive_inputs = depset(direct = [main] + srcs + extra_srcs, transitive = [dep.transitive_inputs for dep in deps] + cc_headers, order = "preorder"),
    )

    return module

def _render_per_module_args(module):
    args = []
    for mapping in module.dependency_mappings:
        args.extend(["--dep", "{}={}".format(mapping.name, mapping.canonical_name)])

    args.extend(zig_cdeps_copts(module.compilation_context))
    args.extend(module.zigopts)

    args.append("-M{name}={src}".format(name = module.canonical_name, src = module.main))

    return args

def zig_module_specifications(*, root_module, args, c_module = None):
    """Collect inputs and flags to build Zig modules.

    Args:
        root_module: ZigModuleInfo; The root module for which to render args.
        args: Args; mutable, Append the needed Zig compiler flags to this object.
        c_module: ZigModuleInfo or None; If not None, the global C translation module to depend on.
    """

    # The first module is the main module.
    args.add_all([root_module.module_context], map_each = _render_per_module_args)
    args.add_all(root_module.transitive_module_contexts, map_each = _render_per_module_args)

    if c_module:
        args.add_all([c_module.module_context], map_each = _render_per_module_args)
        args.add_all(c_module.transitive_module_contexts, map_each = _render_per_module_args)
