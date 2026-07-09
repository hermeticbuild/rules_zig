"""Implementation of the `zig_package` repository rule."""

load("@zig_host_toolchain//:toolchain.bzl", "zig_cache", "zig_path")

# Seconds to allow a `zig fetch`. Zig 0.17.0 runs `zig fetch` through
# `lib/compiler/Maker.zig`, which is compiled into the global cache on first
# use and can take several minutes.
ZIG_FETCH_TIMEOUT = 3600

DOC = """\
Fetch a Zig package with the Zig SDK.

The Zig SDK downloads, verifies, and prunes the package according to its
`build.zig.zon`, and supports `git+` URLs. Fetching fails if the resulting
package hash does not match the expected `zig_hash`. The package's `build.zig`
is then configured to extract its public module graph
(`module_manifest.json`), and a `zig_library` is generated for each module the
package owns. The package's files are public, individually and grouped as the
`files` filegroup.

With `zig_hash` the fetch is reproducible. Without it, the repository reports
the fetched hash so a fetch cycle surfaces the value to pin.
"""

ATTRS = {
    "url": attr.string(mandatory = True, doc = "The package URL, e.g. `https://...` or `git+https://...`."),
    "zig_hash": attr.string(doc = "The expected Zig package hash. May be omitted to obtain the hash to pin from a fetch cycle."),
    "deps": attr.string(
        default = "{\"root_deps\": [], \"packages\": {}}",
        doc = """\
JSON `{root_deps, packages}` describing the `@dependencies` closure used
to configure the package; each package carries its `deps` and a `path`
(its location as a sub-tree of this package, or null for a package in another
spoke). Each dependency edge is `[name, key, lazy]`.
""",
    ),
    "dep_build_files": attr.string_keyed_label_dict(
        doc = "Map from each URL dependency's hash to its `build.zig`, used to wire `@dependencies` (sub-tree dependencies are configured in-tree).",
    ),
    "system_libraries": attr.string_keyed_label_dict(
        doc = "Map from a system-library name (as passed to `linkSystemLibrary`) to a `cc_library` or similar providing it.",
    ),
    "system_integrations": attr.string_list(
        doc = "Names of optional system integrations (`systemIntegrationOption`) to enable when configuring the package.",
    ),
    "configs": attr.string(
        default = "[]",
        doc = "JSON list of build-configuration matrix cells `{name, zig_options, config_setting}` to configure the package under.",
    ),
    "config_settings": attr.string_keyed_label_dict(
        doc = "Map from a non-fallback cell name to the `config_setting_group` its `select()` branch keys on.",
    ),
}

_BUILD = """\
package(default_visibility = ["//visibility:public"])

filegroup(
    name = "files",
    srcs = glob(["**"], exclude = [
        "BUILD.bazel",
        "module_manifest.json",
    ]),
)
"""

_EXPORT_MANIFEST = """\

exports_files(["module_manifest.json"])
"""

_LIBRARY_LOAD = """\
load("@rules_zig//zig:defs.bzl", "zig_library")

"""

_ZIG_LIBRARY = """
zig_library(
    name = "{name}",
    main = "{main}",
    import_name = "{name}",
    srcs = glob(["**/*.zig"], exclude = ["{main}"]),
    deps = {deps},
    import_names = {import_names},
)
"""

# A module owned by an in-tree sub-tree path dependency: its target is
# namespaced by the sub-path so identically named modules in different sub-trees
# do not collide, while its `import_name` stays the module's own name.
_ZIG_LIBRARY_SUBTREE = """
zig_library(
    name = "{name}",
    main = "{main}",
    import_name = "{import_name}",
    srcs = glob(["{subpath}/**/*.zig"], exclude = ["{main}"]),
    deps = {deps},
    import_names = {import_names},
)
"""

_CC_LOAD = """\
load("@rules_cc//cc:defs.bzl", "cc_library")

"""

_HEADER_EXTENSIONS = ["h", "hh", "hpp", "hxx"]

# The module's headers and include directories, collected once. Zig's module
# model has no public/private header distinction — only include directories —
# so a single library carries them; its `hdrs` and `includes` reach every C
# group and the linking module through `deps`.
_CC_HEADERS = """
cc_library(
    name = "{name}",
    hdrs = glob({hdrs}, allow_empty = True),
    includes = {includes},
)
"""

# One `cc_library` per group of C sources sharing `copts`, aggregated by a
# dependency-only `cc_library` the owning module links against. Each `copts`
# entry is one literal compiler argument, so `no_copts_tokenization` disables
# their Bourne-shell tokenization. A C source may textually include any file of
# its package, such as a unity build including sibling `.c` files, so all of
# them are compile inputs.
_CC_LIBRARY = """
cc_library(
    name = "{name}",
    srcs = {srcs},
    copts = {copts},
    features = ["no_copts_tokenization"],
    additional_compiler_inputs = [":files"],
    deps = {deps},
)
"""

_CC_LIBRARY_GROUP = """
cc_library(
    name = "{name}",
    deps = {deps},
)
"""

def _is_subtree(packages, owner):
    return owner in packages and packages[owner]["path"] != None

def _target_name(packages, owner, module):
    # Root-package modules keep their bare name; an in-tree sub-tree module is
    # namespaced by its sub-path so identically named modules in different
    # sub-trees do not collide.
    if not owner:
        return module
    return packages[owner]["path"] + "/" + module

def _spoke_label(labels, key, target):
    # A package in another spoke is a URL dependency, keyed by its hash, or a
    # sub-tree of one, keyed `<hash>/<sub-path>`, whose targets that spoke
    # namespaces by the sub-path. `labels` maps each hash to a label in its spoke.
    spoke, _, sub_path = key.partition("/")
    return labels[spoke].same_package_label(sub_path + "/" + target if sub_path else target)

def _literal_copts(flags):
    # Rendered `copts` undergo Make-variable expansion, but the package's flags
    # are literal.
    return json.encode([flag.replace("$", "$$") for flag in flags])

def _render_c_library(url, module, packages, owner):
    """Render the `cc_library` targets for a module's vendored C sources.

    Returns:
      `(chunks, dep)`: the `cc_library` text chunks and the label the owning
      module links against, or `([], None)` when the module has no C sources.
    """
    prefix = (packages[owner]["path"] + "/") if owner else ""

    c_sources = []
    for csrc in module.get("csrcs", []):
        if csrc["language"] not in (None, "c", "cpp"):
            fail("The Zig package '{}' module '{}' declares the unsupported C source language '{}'.".format(
                url,
                module["name"],
                csrc["language"],
            ))
        c_sources.append((prefix + csrc["path"], csrc["flags"]))
    if not c_sources:
        return [], None

    includes = [prefix + inc["path"] for inc in module.get("include_dirs", [])]

    # Headers can live in an include directory or beside the C sources.
    header_dirs = {inc: None for inc in includes}
    for path, _flags in c_sources:
        header_dirs[path.rpartition("/")[0]] = None
    header_globs = [
        (directory + "/" if directory else "") + "**/*." + ext
        for directory in sorted(header_dirs)
        for ext in _HEADER_EXTENSIONS
    ]

    name = _target_name(packages, owner, module["name"]) + ".cinc"
    headers = name + ".hdrs"
    chunks = [_CC_HEADERS.format(
        name = headers,
        hdrs = json.encode(header_globs),
        includes = json.encode(includes),
    )]

    # `copts` apply to every source in a `cc_library`, so partition by flags.
    groups = []
    for path, flags in c_sources:
        if groups and groups[-1][0] == flags:
            groups[-1][1].append(path)
        else:
            groups.append((flags, [path]))

    group_labels = []
    for index in range(len(groups)):
        flags, paths = groups[index]
        group_name = "{}.{}".format(name, index)
        group_labels.append(":" + group_name)
        chunks.append(_CC_LIBRARY.format(
            name = group_name,
            srcs = json.encode(paths),
            copts = _literal_copts(flags),
            deps = json.encode([":" + headers]),
        ))
    chunks.append(_CC_LIBRARY_GROUP.format(name = name, deps = json.encode(group_labels)))
    return chunks, ":" + name

def _module_dep_label(repository_ctx, imported, packages):
    # A same-package or in-tree sub-tree import resolves to a sibling target
    # here; any other import resolves to the module's target in its spoke.
    key = imported["package"]
    if key == "":
        return ":" + imported["module"]
    if _is_subtree(packages, key):
        return ":" + _target_name(packages, key, imported["module"])
    return str(_spoke_label(repository_ctx.attr.dep_build_files, key, imported["module"]))

def _cells(repository_ctx, manifest):
    # The configurer names the cells it merged, fallback first; the `configs`
    # attr supplies each cell's `config_setting` (empty for the fallback).
    settings = {cell["name"]: cell["config_setting"] for cell in json.decode(repository_ctx.attr.configs)}
    return [
        struct(name = name, config_setting = settings.get(name, ""))
        for name in manifest["cells"]
    ]

def _field(module, field, default, cell):
    """The value of a merged module field in one cell.

    A field the configurer found to vary carries a per-cell value under
    `select`; an invariant field carries its single value directly.
    """
    select = module.get("select")
    if select != None and field in select:
        return select[field][cell]
    return module.get(field, default)

def _render_select(cells, config_settings, by_cell):
    """Render a per-cell attribute value as a literal or a `select()`.

    Args:
      cells: the ordered cells, the `//conditions:default` fallback first.
      config_settings: map from a non-fallback cell name to its
        `config_setting_group` label.
      by_cell: map from cell name to the attribute's value in that cell.

    Returns:
      the attribute's Starlark code.
    """
    fallback = by_cell[cells[0].name]
    if all([by_cell[cell.name] == fallback for cell in cells]):
        return json.encode(fallback)

    lines = ["select({"]
    for cell in cells:
        if cell.config_setting != "":
            lines.append("    {}: {},".format(json.encode(str(config_settings[cell.name])), json.encode(by_cell[cell.name])))
    lines.append("    \"//conditions:default\": {},".format(json.encode(fallback)))
    lines.append("})")
    return "\n".join(lines)

def _module_deps(repository_ctx, module, cell, cc_dep, packages):
    """The `deps` and `import_names` of a module's `zig_library` in one cell."""
    deps = []
    import_names = {}
    for imported in _field(module, "imports", [], cell):
        label = _module_dep_label(repository_ctx, imported, packages)
        deps.append(label)
        if imported["name"] != imported["module"]:
            import_names[label] = imported["name"]
    if _field(module, "link_libc", False, cell):
        deps.append("@rules_zig//zig/lib:libc")
    if _field(module, "link_libcpp", False, cell):
        deps.append("@rules_zig//zig/lib:libc++")

    for name in _field(module, "system_libs", [], cell):
        lib = repository_ctx.attr.system_libraries.get(name)
        if lib == None:
            fail(("The Zig package '{}' module '{}' requires the system library '{}', which is not " +
                  "provided. Map it to a cc_library with a " +
                  "`zig_packages.system_library(name = \"{}\", lib = ...)` annotation.").format(
                repository_ctx.attr.url,
                module["name"],
                name,
                name,
            ))
        deps.append(str(lib))

    if cc_dep:
        deps.append(cc_dep)
    return deps, import_names

# Fields that reshape the module's own targets, not its dependencies. Varying
# them across configurations — e.g. platform-specific C sources — requires
# pushing the differing source globs into each `select()` branch and selecting
# which `cc_library` siblings a branch includes, which this renderer does not
# do, so the importer requires these to agree across cells.
_INVARIANT_FIELDS = ["root_source", "csrcs", "include_dirs"]

def _render_libraries(repository_ctx, modules, cells, packages):
    """Render a `zig_library` for each module this package owns.

    A dependency is imported under its own name by default; an import under a
    different name is remapped through `import_names`. Vendored C sources become
    sibling `cc_library` targets the module links against. Root-package modules
    become top-level libraries; a module owned by an in-tree sub-tree path
    dependency becomes a library scoped to its sub-path; a module owned by a URL
    dependency lives in that dependency's own spoke and is skipped here.

    A module's dependencies, libc linkage and system libraries may vary across
    the configuration matrix, rendering as a `select()` on the cells'
    `config_setting_group`s. Its root source, C sources and include directories
    must agree across cells (see `_INVARIANT_FIELDS`).

    Returns:
      `(text, has_cc)`, the rendered targets and whether any `cc_library` was
      generated (so the caller loads the `cc_library` rule).
    """
    config_settings = repository_ctx.attr.config_settings
    cc_chunks = []
    library_chunks = []
    for module in modules:
        owner = module["package"]
        if owner != "" and not _is_subtree(packages, owner):
            continue

        for cell in cells:
            unsupported = _field(module, "unsupported", [], cell.name)
            if unsupported:
                fail("The Zig package '{}' module '{}' uses unsupported constructs: {}.".format(
                    repository_ctx.attr.url,
                    module["name"],
                    "; ".join(unsupported),
                ))

        select = module.get("select", {})
        for field in _INVARIANT_FIELDS:
            if field in select:
                fail("The Zig package '{}' module '{}' varies its '{}' across configurations, which the importer does not support.".format(
                    repository_ctx.attr.url,
                    module["name"],
                    field,
                ))

        chunks, cc_dep = _render_c_library(repository_ctx.attr.url, module, packages, owner)
        cc_chunks.extend(chunks)

        deps_by_cell = {}
        names_by_cell = {}
        for cell in cells:
            deps, import_names = _module_deps(repository_ctx, module, cell.name, cc_dep, packages)
            deps_by_cell[cell.name] = deps
            names_by_cell[cell.name] = import_names

        deps = _render_select(cells, config_settings, deps_by_cell)
        import_names = _render_select(cells, config_settings, names_by_cell)
        if owner == "":
            library_chunks.append(_ZIG_LIBRARY.format(
                name = module["name"],
                main = module["root_source"],
                deps = deps,
                import_names = import_names,
            ))
        else:
            subpath = packages[owner]["path"]
            library_chunks.append(_ZIG_LIBRARY_SUBTREE.format(
                name = _target_name(packages, owner, module["name"]),
                import_name = module["name"],
                main = subpath + "/" + module["root_source"],
                subpath = subpath,
                deps = deps,
                import_names = import_names,
            ))
    return "".join(cc_chunks + library_chunks), len(cc_chunks) > 0

# Directories the rule creates in the repository root for its own use.
_SCRATCH_DIRS = ["_fetch", "_configure"]

def _fetch(repository_ctx, zig, cache):
    """Fetch the package into the repository root.

    Returns:
      the fetched package's Zig hash.
    """

    # Only `zig fetch --save` lays the package tree out under `--pkg-dir`, and
    # it requires a build root to record the dependency in. The name is explicit
    # because a package without `build.zig.zon` has none to default to.
    build_root = repository_ctx.path("_fetch")
    repository_ctx.file("_fetch/build.zig", "")
    pkg_dir = build_root.get_child("pkg")
    fetch = repository_ctx.execute(
        [zig, "fetch", "--pkg-dir", str(pkg_dir), "--save=package", repository_ctx.attr.url],
        environment = {"ZIG_GLOBAL_CACHE_DIR": cache},
        working_directory = str(build_root),
        timeout = ZIG_FETCH_TIMEOUT,
    )
    if fetch.return_code != 0:
        fail("`zig fetch {}` failed:\n{}".format(repository_ctx.attr.url, fetch.stderr))

    trees = pkg_dir.readdir()
    if len(trees) != 1:
        fail("`zig fetch {}` produced {} package trees, expected exactly one.".format(repository_ctx.attr.url, len(trees)))
    tree = trees[0]
    for entry in tree.readdir():
        if entry.basename in _SCRATCH_DIRS:
            fail("The Zig package '{}' has a top-level '{}', a name `zig_package` reserves for its own use.".format(
                repository_ctx.attr.url,
                entry.basename,
            ))
        repository_ctx.rename(entry, entry.basename)
    repository_ctx.delete(build_root)
    return tree.basename

_EMPTY_DEPS = """\
pub const packages = struct {};
pub const root_deps: []const struct { []const u8, []const u8 } = &.{};
"""

def _zig_string(value):
    return "\"" + value.replace("\\", "\\\\").replace("\"", "\\\"") + "\""

def _edge_lines(edges, indent):
    return [
        "{}.{{ {}, {} }},".format(indent, _zig_string(name), _zig_string(key))
        for name, key, _lazy in edges
    ]

def _dep_build_zig(repository_ctx, key, package):
    if package["path"] != None:
        return repository_ctx.path(package["path"] + "/build.zig")
    return repository_ctx.path(_spoke_label(repository_ctx.attr.dep_build_files, key, "build.zig"))

def _available(deps, requested):
    """The packages reachable through eager or `requested` lazy dependency edges."""
    packages = deps["packages"]
    available = {}
    frontier = deps["root_deps"]
    for _ in range(len(packages)):
        reached = []
        for _name, key, lazy in frontier:
            if key not in available and (not lazy or key in requested):
                available[key] = True
                reached.extend(packages[key]["deps"])
        frontier = reached
    return available

def _dependencies_source(repository_ctx, deps, available):
    """Render the `@dependencies` module that `b.dependency` consumes.

    A package outside `available` is an unrequested lazy dependency; it is
    declared unavailable, so its spoke is not materialized.
    """
    packages = deps["packages"]
    if not packages:
        return _EMPTY_DEPS

    lines = ["pub const packages = struct {"]
    for key in sorted(packages):
        package = packages[key]
        lines.append("    pub const @\"{}\" = struct {{".format(key))
        if key not in available:
            lines.append("        pub const available = false;")
            lines.append("    };")
            continue
        build_zig = _dep_build_zig(repository_ctx, key, package)
        lines.append("        pub const build_root = {};".format(_zig_string(str(build_zig.dirname))))
        lines.append("        pub const build_zig = @import(\"{}\");".format(key))
        lines.append("        pub const deps: []const struct { []const u8, []const u8 } = &.{")
        lines.extend(_edge_lines(package["deps"], "            "))
        lines.append("        };")
        lines.append("    };")
    lines.append("};")
    lines.append("")
    lines.append("pub const root_deps: []const struct { []const u8, []const u8 } = &.{")
    lines.extend(_edge_lines(deps["root_deps"], "    "))
    lines.append("};")
    return "\n".join(lines) + "\n"

def _run_configurer(repository_ctx, zig, build_zig, cache, deps, available):
    """Compile the configurer against the package's `build.zig` and run it.

    Returns:
      the configurer's `exec_result`.
    """
    configurer = repository_ctx.path(Label("//zig/private/packages:configurer.zig"))

    # `configurer.zig` is watched by the `path` above, but the modules it
    # `@import`s are not: Bazel cannot see Zig's transitive imports, so a change
    # to the configurer's logic there would reuse a cached manifest. Watch them
    # so editing the configurer re-runs configuration.
    repository_ctx.watch(Label("//zig/private/packages:module_graph.zig"))

    repository_ctx.file("_configure/deps.zig", _dependencies_source(repository_ctx, deps, available))

    keys = sorted(available)

    args = [zig, "build-exe", "--dep", "pkg", "--dep", "deps", "-Mroot=" + str(configurer), "-Mpkg=" + str(build_zig)]
    for key in keys:
        args.extend(["--dep", key])
    args.append("-Mdeps=" + str(repository_ctx.path("_configure/deps.zig")))
    for key in keys:
        package = deps["packages"][key]
        dep_build_zig = _dep_build_zig(repository_ctx, key, package)

        # The configurer is compiled against each dependency's `build.zig`, so a
        # change to one in another spoke must re-run configuration. A sub-tree
        # `build.zig` of this package is inside this spoke already, and Bazel
        # forbids watching a path under the repository's own working directory.
        if package["path"] == None:
            repository_ctx.watch(dep_build_zig)
        args.append("-M{}={}".format(key, dep_build_zig))
    args.extend([
        "--cache-dir",
        cache,
        "--global-cache-dir",
        cache,
        "-femit-bin=" + str(repository_ctx.path("_configure/configurer")),
    ])

    compiled = repository_ctx.execute(args)
    if compiled.return_code != 0:
        fail("Failed to compile the Zig configurer for '{}':\n{}".format(repository_ctx.attr.url, compiled.stderr))

    configure_args = [
        str(repository_ctx.path("_configure/configurer")),
        "--zig",
        str(zig),
        "--build-root",
        str(repository_ctx.path(".")),
    ]
    for name in repository_ctx.attr.system_integrations:
        configure_args.extend(["--system-integration", name])
    for cell in json.decode(repository_ctx.attr.configs):
        configure_args.extend(["--config", cell["name"]])
        for option in cell["zig_options"]:
            configure_args.extend(["--zig-option", option])

    configured = repository_ctx.execute(configure_args)
    if configured.return_code != 0:
        fail("Failed to configure the Zig package '{}':\n{}".format(repository_ctx.attr.url, configured.stderr))
    return configured

def _configure(repository_ctx, zig, build_zig, cache):
    """Configure the package with only the lazy dependencies it requests, as `zig build` does.

    Returns:
      the package's module-graph JSON.
    """
    deps = json.decode(repository_ctx.attr.deps)
    edges = deps["root_deps"] + [edge for package in deps["packages"].values() for edge in package["deps"]]
    lazy = {key: None for _name, key, is_lazy in edges if is_lazy}
    requested = {}
    for _ in range(len(lazy) + 1):
        configured = _run_configurer(repository_ctx, zig, build_zig, cache, deps, _available(deps, requested))
        result = json.decode(configured.stdout, default = None)
        if result == None:
            fail("Failed to configure the Zig package '{}': its output is not JSON:\n{}".format(repository_ctx.attr.url, configured.stderr))
        if "needed_lazy_dependencies" not in result:
            return configured.stdout
        new = [key for key in result["needed_lazy_dependencies"] if key not in requested]
        if not new:
            break
        requested.update({key: None for key in new})
    fail("Failed to configure the Zig package '{}': with every requested lazy dependency available, it still requests lazy dependencies:\n{}".format(
        repository_ctx.attr.url,
        configured.stderr,
    ))

def _zig_package_impl(repository_ctx):
    zig = zig_path(repository_ctx)
    cache = zig_cache(repository_ctx)

    fetched_hash = _fetch(repository_ctx, zig, cache)
    if repository_ctx.attr.zig_hash and fetched_hash != repository_ctx.attr.zig_hash:
        fail("Zig package hash mismatch for '{}':\n  expected: {}\n  fetched:  {}".format(
            repository_ctx.attr.url,
            repository_ctx.attr.zig_hash,
            fetched_hash,
        ))

    build = _BUILD
    if repository_ctx.path("build.zig").exists:
        manifest = _configure(repository_ctx, zig, repository_ctx.path("build.zig"), cache)
        repository_ctx.delete("_configure")
        repository_ctx.file("module_manifest.json", manifest)

        decoded = json.decode(manifest)
        packages = json.decode(repository_ctx.attr.deps)["packages"]
        libraries, has_cc = _render_libraries(repository_ctx, decoded["modules"], _cells(repository_ctx, decoded), packages)
        loads = _LIBRARY_LOAD + (_CC_LOAD if has_cc else "")
        build = loads + build + libraries + _EXPORT_MANIFEST

    repository_ctx.file("BUILD.bazel", build)

    if not repository_ctx.attr.zig_hash:
        return repository_ctx.repo_metadata(attrs_for_reproducibility = {"zig_hash": fetched_hash})
    return repository_ctx.repo_metadata(reproducible = True)

zig_package = repository_rule(
    _zig_package_impl,
    attrs = ATTRS,
    doc = DOC,
)
