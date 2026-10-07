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
package hash does not match the expected `zig_hash`. Any `patches` are then
applied to the verified tree. The package's `build.zig` is configured to
extract its public module graph (`module_manifest.json`), and a `zig_library`
is generated for each module the package owns. The package's files are public,
individually and grouped as the `files` filegroup.

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
to configure the package; each package carries its `deps`, a `path` (its
location as a sub-tree of this package, or null for a package in another
spoke), and whether it is `naked` (has no `build.zig.zon`). Each dependency
edge is `[name, key, lazy]`.
""",
    ),
    "dep_build_files": attr.string_keyed_label_dict(
        doc = "Map from each URL dependency's hash to its `build.zig`, used to wire `@dependencies` (sub-tree dependencies are configured in-tree).",
    ),
    "dep_files": attr.string_keyed_label_dict(
        doc = """\
Map from each URL dependency's hash to its `files` filegroup, used to
reference the dependency's files across repositories for out-of-package
(`dep.path`) C sources and include directories.
""",
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
    "patches": attr.label_list(
        allow_files = True,
        doc = "Patches applied to the fetched package tree after hash verification and before configuration.",
    ),
    "patch_strip": attr.int(
        default = 1,
        doc = "Number of leading path components to strip when applying `patches` (as `patch -p<N>`).",
    ),
    "package_name": attr.string(
        doc = "The package's name, under which its sole module is aliased when the module has a different name.",
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

# Every package publishes its files so another package's spoke can reference
# them across repositories for out-of-package C.
_EXPORTS = """
exports_files(glob(["**"], exclude = ["BUILD.bazel", "module_manifest.json"]))
"""

_ALIAS = """
alias(
    name = "{name}",
    actual = "{actual}",
)
"""

_ZIG_LIBRARY = """
zig_library(
    name = "{name}",
    main = {main},
    import_name = "{name}",
    srcs = {srcs},
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
    main = {main},
    import_name = "{import_name}",
    srcs = {srcs},
    deps = {deps},
    import_names = {import_names},
)
"""

_CC_LOAD = """\
load("@rules_cc//cc:defs.bzl", "cc_library")
load("@rules_zig//zig/private:package_headers.bzl", "package_headers")

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

# An out-of-package include directory, searched in place within the
# dependency's spoke; its search path and the spoke's files reach this compile
# and forward to consumers' `@cImport`.
_CC_CROSS_INCLUDE = """
package_headers(
    name = "{name}",
    files = "{files}",
    directory = "{directory}",
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
    additional_compiler_inputs = {compile_inputs},
    deps = {deps},
)
"""

_CC_LIBRARY_GROUP = """
cc_library(
    name = "{name}",
    deps = {deps},
)
"""

# The header a translated-C module translates, exposed as a `cc_library` the
# `zig_c_library` translates. Only this header is public, so it alone is
# translated; its own `#include`s resolve to the headers and include
# directories provided by `deps` (see `_CC_HEADERS` and `_CC_CROSS_INCLUDE`).
# The header is valid only under the translate step's C flags, which this
# library does not carry, so it opts out of `parse_headers`.
_CC_TRANSLATE_HEADERS = """
cc_library(
    name = "{name}",
    hdrs = {hdrs},
    features = ["-parse_headers"],
    deps = {deps},
)
"""

# A translated-C module: `zig_c_library` runs `translate-c` on the header library
# under the build toolchain, exposing the result under the module's import name.
# The translate step's C flags (`addCFlags`, `defineCMacro`) reach it as `copts`.
# The importing module binds it to `@import("c")` through `import_names`, taking
# precedence over `rules_zig`'s automatic `c` module.
_ZIG_C_LIBRARY = """
zig_c_library(
    name = "{name}",
    import_name = "{import_name}",
    cdeps = {cdeps},
    copts = {copts},
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

def _local_include(prefix, sub_path):
    # A sub-tree module's include directory, prefixed by its sub-path. The
    # configurer renders the package root as the empty string, so a root include
    # leaves a bare prefix whose trailing slash would make an invalid glob.
    path = prefix + sub_path
    return path[:-1] if path.endswith("/") else path

def _local_prefix(packages, owner, package):
    # The directory of this spoke a C source or include directory of `package`
    # lies under, or None when another spoke owns it (`dep.path`, referenced
    # across repositories). A file reports its owning package: the root package
    # as the empty string, a sub-tree by its key, which is the module's owner for
    # a sub-tree module's own files and another key for a `dep.path` into a
    # sub-tree dependency of this spoke.
    key = package or owner
    if not key:
        return ""
    return packages[key]["path"] + "/" if _is_subtree(packages, key) else None

def _cross_repo_label(repository_ctx, package, target):
    # A file/target in a dependency's spoke, reached through the `files`
    # filegroup label the extension provides for that dependency.
    return str(_spoke_label(repository_ctx.attr.dep_files, package, target))

def _spoke_files(repository_ctx, package):
    # The `files` of a dependency's whole spoke, including any sub-tree package.
    return str(repository_ctx.attr.dep_files[package.partition("/")[0]])

def _render_cross_include(repository_ctx, name, inc):
    # The directory is relative to the spoke root, under which a sub-tree
    # package (`<hash>/<sub-path>`) lies at its sub-path.
    spoke_sub_path = inc["package"].partition("/")[2]
    return _CC_CROSS_INCLUDE.format(
        name = name,
        files = _spoke_files(repository_ctx, inc["package"]),
        directory = "/".join([path for path in (spoke_sub_path, inc["path"]) if path]) or ".",
    )

def _literal_copts(flags):
    # Rendered `copts` undergo Make-variable expansion, but the package's flags
    # are literal.
    return json.encode([flag.replace("$", "$$") for flag in flags])

def _render_c_shape(repository_ctx, module, packages, owner, csrcs, include_dirs, name):
    """Render the `cc_library` targets for a module's vendored C sources.

    Returns:
      `(chunks, dep)`: the target text chunks and the label the owning module
      links against, or `([], None)` when the module has no C sources.
    """
    url = repository_ctx.attr.url

    c_sources = []
    for csrc in csrcs:
        if csrc["language"] not in (None, "c", "cpp"):
            fail("The Zig package '{}' module '{}' declares the unsupported C source language '{}'.".format(
                url,
                module["name"],
                csrc["language"],
            ))
        prefix = _local_prefix(packages, owner, csrc.get("package"))
        if prefix == None:
            src = _cross_repo_label(repository_ctx, csrc["package"], csrc["path"])
            files = _spoke_files(repository_ctx, csrc["package"])
        else:
            src = prefix + csrc["path"]
            files = ":files"
        c_sources.append((src, csrc["flags"], files))
    if not c_sources:
        return [], None

    local_includes = []
    cross_include_labels = []
    cross_include_chunks = []
    for index, inc in enumerate(include_dirs):
        prefix = _local_prefix(packages, owner, inc.get("package"))
        if prefix == None:
            inc_name = "{}.inc.{}".format(name, index)
            cross_include_labels.append(":" + inc_name)
            cross_include_chunks.append(_render_cross_include(repository_ctx, inc_name, inc))
        else:
            local_includes.append(_local_include(prefix, inc["path"]))

    # Local headers live in an include directory or beside a local C source.
    header_dirs = {inc: None for inc in local_includes}
    for src, _flags, _files in c_sources:
        if not src.startswith("@"):
            header_dirs[src.rpartition("/")[0]] = None
    header_globs = [
        (directory + "/" if directory else "") + "**/*." + ext
        for directory in sorted(header_dirs)
        for ext in _HEADER_EXTENSIONS
    ]

    headers = name + ".hdrs"
    chunks = cross_include_chunks + [_CC_HEADERS.format(
        name = headers,
        hdrs = json.encode(header_globs),
        includes = json.encode(local_includes),
    )]

    # `copts` apply to every source in a `cc_library`, so partition by flags.
    groups = []
    for path, flags, files in c_sources:
        if not groups or groups[-1][0] != flags:
            groups.append((flags, [], {}))
        groups[-1][1].append(path)
        groups[-1][2][files] = None

    group_deps = [":" + headers] + cross_include_labels
    group_labels = []
    for index in range(len(groups)):
        flags, paths, compile_inputs = groups[index]
        group_name = "{}.{}".format(name, index)
        group_labels.append(":" + group_name)
        chunks.append(_CC_LIBRARY.format(
            name = group_name,
            srcs = json.encode(paths),
            copts = _literal_copts(flags),
            compile_inputs = json.encode(list(compile_inputs)),
            deps = json.encode(group_deps),
        ))
    chunks.append(_CC_LIBRARY_GROUP.format(name = name, deps = json.encode(group_labels)))
    return chunks, ":" + name

def _render_c_library(repository_ctx, module, packages, owner, cells):
    """Render each distinct C shape the module presents across the cells.

    A module's C sources and include directories may differ across the
    configuration matrix; cells sharing a shape share one rendered `cc_library`
    tree. The fallback cell's shape keeps the bare `<module>.cinc` name so a
    package with a single C shape renders identically to an unconfigured one;
    each additional distinct shape is namespaced by a representative cell.

    Returns:
      `(chunks, cc_dep_by_cell)`: the target text chunks and, per cell, the label
      the owning module links against (or `None` when that cell has no C).
    """
    base = _target_name(packages, owner, module["name"])
    chunks = []
    shapes = {}
    cc_dep_by_cell = {}
    for cell in cells:
        csrcs = _field(module, "csrcs", [], cell.name)
        include_dirs = _field(module, "include_dirs", [], cell.name)
        key = json.encode([csrcs, include_dirs])
        if key not in shapes:
            name = base + ".cinc" if len(shapes) == 0 else "{}.{}.cinc".format(base, cell.name)
            shape_chunks, cc_dep = _render_c_shape(repository_ctx, module, packages, owner, csrcs, include_dirs, name)
            chunks.extend(shape_chunks)
            shapes[key] = cc_dep
        cc_dep_by_cell[cell.name] = shapes[key]
    return chunks, cc_dep_by_cell

def _render_translate_c_library(repository_ctx, module, packages, owner, cells):
    """Render the `zig_c_library` (and its header `cc_library`) for a translated-C module.

    A translated-C module (`b.addTranslateC` or a translate-c package
    `Translator`) has its root generated at build time from its header, so it
    becomes a `zig_c_library` that translates the header under the build
    toolchain. The header and each include directory are resolved like vendored
    C sources: an in-package path is referenced locally, an out-of-package one
    (`package` set) across repositories. A header written at configure time is
    materialized into the spoke. The C libraries the module links
    (`linkLibrary`) are rendered like vendored C; they and the module's other
    linked libraries are linked through the header `cc_library`.

    Returns:
      the target text chunks: any cross-repo include directory, the linked C
      libraries, the header `cc_library`, and the `zig_c_library`.
    """
    translate = module["translate_c"]
    name = _target_name(packages, owner, module["name"])
    headers = name + ".chdr"

    prefix = _local_prefix(packages, owner, translate.get("package"))
    generated_header = translate.get("generated_header")
    if generated_header != None:
        header = prefix + "_zig_generated/" + module["name"] + "/" + translate["header"]
        repository_ctx.file(header, generated_header)
    elif prefix == None:
        header = _cross_repo_label(repository_ctx, translate["package"], translate["header"])
    else:
        header = prefix + translate["header"]

    local_includes = []
    header_deps = []
    dep_chunks = []
    for index, inc in enumerate(module.get("include_dirs", [])):
        prefix = _local_prefix(packages, owner, inc.get("package"))
        if prefix == None:
            inc_name = "{}.inc.{}".format(headers, index)
            header_deps.append(":" + inc_name)
            dep_chunks.append(_render_cross_include(repository_ctx, inc_name, inc))
        else:
            local_includes.append(_local_include(prefix, inc["path"]))

    # The headers reachable from the translated header's own `#include`s: those
    # in its include directories, provided (with their search path) so the
    # translation finds them. Only the translated header itself is public.
    if local_includes:
        include_headers = headers + ".hdrs"
        header_deps.append(":" + include_headers)
        header_globs = [
            (directory + "/" if directory else "") + "**/*." + ext
            for directory in sorted(local_includes)
            for ext in _HEADER_EXTENSIONS
        ]
        dep_chunks.append(_CC_HEADERS.format(
            name = include_headers,
            hdrs = json.encode(header_globs),
            includes = json.encode(local_includes),
        ))

    c_chunks, cc_dep = _render_c_shape(
        repository_ctx,
        module,
        packages,
        owner,
        module.get("csrcs", []),
        module.get("include_dirs", []),
        name + ".cinc",
    )
    if cc_dep:
        header_deps.append(cc_dep)

    return dep_chunks + c_chunks + [
        _CC_TRANSLATE_HEADERS.format(
            name = headers,
            hdrs = json.encode([header]),
            deps = _render_select(cells, repository_ctx.attr.config_settings, {
                cell.name: header_deps + _link_deps(repository_ctx, module, cell.name)
                for cell in cells
            }),
        ),
        _ZIG_C_LIBRARY.format(
            name = name,
            import_name = module["name"],
            cdeps = json.encode([":" + headers]),
            copts = _select_expr(cells, repository_ctx.attr.config_settings, {
                cell.name: _literal_copts(_field(module, "translate_c_flags", [], cell.name))
                for cell in cells
            }),
        ),
    ]

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

def _select_expr(cells, config_settings, expr_by_cell):
    """Render a per-cell attribute as a literal or a `select()`.

    Each cell's value is given as an already-rendered Starlark expression string.

    Args:
      cells: the ordered cells, the `//conditions:default` fallback (`cells[0]`) first.
      config_settings: map from a non-fallback cell name to its
        `config_setting_group` label.
      expr_by_cell: map from cell name to that cell's rendered Starlark expression.

    Returns:
      the attribute's Starlark code.
    """
    fallback = expr_by_cell[cells[0].name]
    if all([expr_by_cell[cell.name] == fallback for cell in cells]):
        return fallback

    lines = ["select({"]
    for cell in cells:
        if cell.config_setting != "":
            lines.append("    {}: {},".format(json.encode(str(config_settings[cell.name])), expr_by_cell[cell.name]))
    lines.append("    \"//conditions:default\": {},".format(fallback))
    lines.append("})")
    return "\n".join(lines)

def _render_select(cells, config_settings, by_cell):
    """Render a per-cell attribute value (a JSON-encodable value per cell)."""
    return _select_expr(cells, config_settings, {cell.name: json.encode(by_cell[cell.name]) for cell in cells})

def _glob_srcs(pattern, exclude_main):
    # A module's non-root Zig sources: every `.zig` under `pattern` except the
    # cell's root source (supplied as `main`). Rendered per cell so a varying
    # root source becomes a `select()` of globs.
    return "glob([{}], exclude = {})".format(json.encode(pattern), json.encode([exclude_main]))

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
    deps.extend(_link_deps(repository_ctx, module, cell))
    if cc_dep:
        deps.append(cc_dep)
    return deps, import_names

def _link_deps(repository_ctx, module, cell):
    """The labels of the libraries a module links in one cell: its system libraries' `cc_library` annotations."""
    deps = []
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
    return deps

# Fields that reshape the module's own root and that the importer renders once
# for every configuration, so they must agree across cells: a
# `generated_source` is materialized to a single file shared by every cell, and
# a `translate_c` module becomes one `zig_c_library`. The root source, C
# sources, include directories and translate-c flags may vary: they render as a
# `select()` over the cells' `config_setting_group`s. Translated-C modules keep
# their C sources and include directories invariant (see
# `_check_module_supported`).
_INVARIANT_FIELDS = ["generated_source", "translate_c"]

def _check_module_supported(repository_ctx, module, cells):
    """Fail if a module cannot be rendered.

    A module cannot be rendered if it uses constructs the importer cannot
    represent, or varies a field the importer renders invariantly across the
    configuration matrix.
    """
    for cell in cells:
        unsupported = _field(module, "unsupported", [], cell.name)
        if unsupported:
            fail("The Zig package '{}' module '{}' uses unsupported constructs: {}.".format(
                repository_ctx.attr.url,
                module["name"],
                "; ".join(unsupported),
            ))

    select = module.get("select", {})
    invariant = _INVARIANT_FIELDS
    if module.get("translate_c") != None:
        # A translated-C module renders one `zig_c_library` and header
        # `cc_library` from the fallback cell's header and include directories,
        # neither of which it selects per cell.
        invariant = invariant + ["csrcs", "include_dirs"]
    for field in invariant:
        if field in select:
            fail("The Zig package '{}' module '{}' varies its '{}' across configurations, which the importer does not support.".format(
                repository_ctx.attr.url,
                module["name"],
                field,
            ))

def _render_libraries(repository_ctx, modules, cells, packages):
    """Render a `zig_library` for each module this package owns.

    A dependency is imported under its own name by default; an import under a
    different name is remapped through `import_names`. Vendored C sources become
    sibling `cc_library` targets the module links against. A translated-C module
    becomes a `zig_c_library` importers reach by name. Root-package modules
    become top-level libraries; a module owned by an in-tree sub-tree path
    dependency becomes a library scoped to its sub-path; a module owned by a URL
    dependency lives in that dependency's own spoke and is skipped here.

    A module's root source, C sources, include directories, translate-c flags,
    dependencies, libc linkage and system libraries may vary across the
    configuration matrix, rendering as a `select()` on the cells'
    `config_setting_group`s (see `_INVARIANT_FIELDS` for the fields that may
    not).

    Returns:
      `(text, has_cc, has_translate_c)`: the rendered targets, whether any
      `cc_library` was generated (so the caller loads the `cc_library` rule), and
      whether any `zig_c_library` was generated (so the caller loads it too).
    """
    config_settings = repository_ctx.attr.config_settings
    cc_chunks = []
    library_chunks = []
    has_translate_c = False
    for module in modules:
        owner = module["package"]
        if owner != "" and not _is_subtree(packages, owner):
            continue
        _check_module_supported(repository_ctx, module, cells)

        if module.get("translate_c") != None:
            cc_chunks.extend(_render_translate_c_library(repository_ctx, module, packages, owner, cells))
            has_translate_c = True
            continue

        # A `b.addOptions()` module has no file in the package tree; materialize
        # its source into the spoke and treat it as the module's root.
        generated = module.get("generated_source")
        if generated != None:
            root_source = "_zig_generated/" + module["name"] + ".zig"
            repository_ctx.file((packages[owner]["path"] + "/" if owner else "") + root_source, generated)
            root_by_cell = {cell.name: root_source for cell in cells}
        else:
            root_by_cell = {cell.name: _field(module, "root_source", None, cell.name) for cell in cells}

        chunks, cc_dep_by_cell = _render_c_library(repository_ctx, module, packages, owner, cells)
        cc_chunks.extend(chunks)

        deps_by_cell = {}
        names_by_cell = {}
        for cell in cells:
            deps, import_names = _module_deps(repository_ctx, module, cell.name, cc_dep_by_cell[cell.name], packages)
            deps_by_cell[cell.name] = deps
            names_by_cell[cell.name] = import_names

        deps = _render_select(cells, config_settings, deps_by_cell)
        import_names = _render_select(cells, config_settings, names_by_cell)

        if owner == "":
            main = _select_expr(cells, config_settings, {cell.name: json.encode(root_by_cell[cell.name]) for cell in cells})
            srcs = _select_expr(cells, config_settings, {cell.name: _glob_srcs("**/*.zig", root_by_cell[cell.name]) for cell in cells})
            library_chunks.append(_ZIG_LIBRARY.format(
                name = module["name"],
                main = main,
                srcs = srcs,
                deps = deps,
                import_names = import_names,
            ))
        else:
            subpath = packages[owner]["path"]
            mains = {cell.name: subpath + "/" + root_by_cell[cell.name] for cell in cells}
            main = _select_expr(cells, config_settings, {cell.name: json.encode(mains[cell.name]) for cell in cells})
            srcs = _select_expr(cells, config_settings, {cell.name: _glob_srcs(subpath + "/**/*.zig", mains[cell.name]) for cell in cells})
            library_chunks.append(_ZIG_LIBRARY_SUBTREE.format(
                name = _target_name(packages, owner, module["name"]),
                import_name = module["name"],
                main = main,
                srcs = srcs,
                deps = deps,
                import_names = import_names,
            ))
    return "".join(cc_chunks + library_chunks), len(cc_chunks) > 0, has_translate_c

# Directories the rule creates in the repository root for its own use.
_SCRATCH_DIRS = ["_fetch", "_configure", "_zig_generated"]

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
        if package.get("naked"):
            # A files-only dependency has no `build.zig`; `b.dependency` still
            # opens its build root, so provide an empty placeholder directory.
            # `dep.path(...)` records a sub-path without reading the file.
            naked_root = repository_ctx.path("_configure/naked/" + key)
            repository_ctx.file(str(naked_root) + "/.keep", "")
            lines.append("        pub const build_root = {};".format(_zig_string(str(naked_root))))
        else:
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

def _build_zig_dep_args(edges, keys):
    # A `build.zig` may `@import` a direct dependency's `build.zig` by the
    # dependency's name, as under `zig build`.
    return [arg for name, key, _lazy in edges if key in keys for arg in ("--dep", name + "=" + key)]

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

    for key in sorted(deps["packages"]):
        package = deps["packages"][key]
        if package["path"] != None and not repository_ctx.path(package["path"] + "/build.zig").exists:
            fail(("The Zig package '{}' has a source-only dependency at '{}' (a `build.zig.zon` " +
                  "with no `build.zig`); source-only dependencies are not supported.").format(
                repository_ctx.attr.url,
                package["path"],
            ))

    repository_ctx.file("_configure/deps.zig", _dependencies_source(repository_ctx, deps, available))

    # A naked dependency contributes no `build.zig` module to compile against;
    # its `@dependencies` entry is files-only.
    keys = [key for key in sorted(available) if not deps["packages"][key].get("naked")]

    args = [zig, "build-exe", "--dep", "pkg", "--dep", "deps", "-Mroot=" + str(configurer)]
    args.extend(_build_zig_dep_args(deps["root_deps"], keys))
    args.append("-Mpkg=" + str(build_zig))
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
        args.extend(_build_zig_dep_args(package["deps"], keys))
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

def _main_module_alias(package_name, modules):
    """An `alias` from the package name to its sole owned module, when they differ.

    `zig_dep`/`zig_deps` address a package's default module by the package name;
    a package that owns exactly one module under a different name is reachable
    through that default only via this alias. Anonymous modules are internal and
    do not count.
    """
    owned = [
        module["name"]
        for module in modules
        if module["package"] == "" and not module["name"].startswith("__anon_")
    ]
    if not package_name or len(owned) != 1 or owned[0] == package_name:
        return ""
    return _ALIAS.format(name = package_name, actual = ":" + owned[0])

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

    for patch in repository_ctx.attr.patches:
        repository_ctx.patch(patch, strip = repository_ctx.attr.patch_strip)

    loads = ""
    body = _BUILD
    if repository_ctx.path("build.zig").exists:
        manifest = _configure(repository_ctx, zig, repository_ctx.path("build.zig"), cache)
        repository_ctx.delete("_configure")
        repository_ctx.file("module_manifest.json", manifest)

        decoded = json.decode(manifest)
        packages = json.decode(repository_ctx.attr.deps)["packages"]
        libraries, has_cc, has_translate_c = _render_libraries(repository_ctx, decoded["modules"], _cells(repository_ctx, decoded), packages)
        zig_rules = ["zig_library"] + (["zig_c_library"] if has_translate_c else [])
        loads += "load(\"@rules_zig//zig:defs.bzl\", {})\n\n".format(", ".join([_zig_string(rule) for rule in zig_rules]))
        loads += _CC_LOAD if has_cc else ""
        body += libraries + _main_module_alias(repository_ctx.attr.package_name, decoded["modules"]) + _EXPORT_MANIFEST

    build = loads + body + _EXPORTS
    repository_ctx.file("BUILD.bazel", build)

    if not repository_ctx.attr.zig_hash:
        return repository_ctx.repo_metadata(attrs_for_reproducibility = {"zig_hash": fetched_hash})
    return repository_ctx.repo_metadata(reproducible = True)

zig_package = repository_rule(
    _zig_package_impl,
    attrs = ATTRS,
    doc = DOC,
)
