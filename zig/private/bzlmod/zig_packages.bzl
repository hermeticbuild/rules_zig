"""Implementation of the `zig_packages` module extension."""

load("@zig_host_toolchain//:toolchain.bzl", "zig_cache", "zig_path")
load("//zig/private/repo:zig_deps_hub.bzl", "zig_deps_hub")
load("//zig/private/repo:zig_package.bzl", "ZIG_FETCH_TIMEOUT", "zig_package")

# Length of the base64url digest that ends a Zig package hash key.
_HASH_DIGEST_LEN = 44

def package_name_version(key):
    """Split a URL package's hash key into its name and version.

    Args:
      key: a URL package's Zig hash key, `<name>-<version>-<digest>`. Both
        `version` and `digest` may contain `-` (e.g. `0.5.0-dev`).

    Returns:
      (name, version).
    """
    name, _, rest = key.partition("-")
    return name, rest[:-(_HASH_DIGEST_LEN + 1)]

def _dep_edges(package):
    """A resolved package's dependency edges as `[name, key, lazy]` lists."""
    return [[name, key, name in package["lazy"]] for name, key in package["deps"].items()]

def select_by_precedence(entries, keys):
    """Select the module-extension tag entry that applies, the root module deciding.

    The root module's entry under the first of `keys` it declares applies and
    overrides every dependency module's entry. Otherwise the dependency
    modules' entries under the first such key apply; they must agree, and
    equal ones collapse.

    Args:
      entries: map from a key to its entries in module order, each
        `struct(module, is_root, key, value, tag)`, where `value` compares with
        `==` and the root module's entries under one key agree.
      keys: the candidate keys, most specific first.

    Returns:
      `(conflict, selected, overridden)`: `conflict` is a pair of disagreeing
      dependency-module entries, or None; `selected` is the entry that applies,
      or None if there is none under `keys`; `overridden` lists the
      dependency-module entries the root module's overrides.
    """
    candidates = [entry for key in keys for entry in entries.get(key, [])]
    for entry in candidates:
        if entry.is_root:
            return (None, entry, [other for other in candidates if not other.is_root])
    if not candidates:
        return (None, None, [])
    selected = candidates[0]
    for entry in candidates[1:]:
        if entry.key == selected.key and entry.value != selected.value:
            return ((selected, entry), None, [])
    return (None, selected, [])

def _tag_entry(mod, key, value, tag):
    return struct(module = mod.name, is_root = mod.is_root, key = key, value = value, tag = tag)

def _apply_precedence(entries, keys, tag_class_name, subject, warnings):
    """`select_by_precedence`, failing on a conflict.

    Args:
      entries: as for `select_by_precedence`.
      keys: as for `select_by_precedence`.
      tag_class_name: the tag class of the entries, for messages.
      subject: function from a key to a description of what it configures.
      warnings: map from warning message to tag, extended in place.

    Returns:
      the entry that applies, or None.
    """
    conflict, selected, overridden = select_by_precedence(entries, keys)
    if conflict != None:
        first, second = conflict
        fail("Conflicting `{}` tags for {} from non-root modules '{}' and '{}'; declare a `{}` tag for it in the root module.".format(
            tag_class_name,
            subject(second.key),
            first.module,
            second.module,
            tag_class_name,
        ), second.tag)
    for entry in overridden:
        warnings["Ignoring the `{}` tag for {} from non-root module '{}'; the root module's takes precedence.".format(
            tag_class_name,
            subject(entry.key),
            entry.module,
        )] = entry.tag
    if selected != None and not selected.is_root:
        warnings["Using the `{}` tag for {} from non-root module '{}'.".format(
            tag_class_name,
            subject(selected.key),
            selected.module,
        )] = selected.tag
    return selected

def _system_library_subject(name):
    return "system library '{}'".format(name)

def _package_subject(pkg_key):
    name, version = pkg_key
    return "Zig package '{}'{}".format(name, " version '{}'".format(version) if version else "")

from_file = tag_class(
    doc = "Resolve the Zig package dependencies declared in a `build.zig.zon` manifest.",
    attrs = {
        "build_zig_zon": attr.label(
            doc = "A `build.zig.zon` manifest to resolve Zig dependencies for.",
            mandatory = True,
            allow_single_file = True,
        ),
    },
)

system_library = tag_class(
    doc = """\
Map a system library a Zig package links (`linkSystemLibrary`) to a `cc_library` or similar that provides it.

The root module's mapping of a library takes precedence; otherwise other
modules' mappings apply, and must agree.
""",
    attrs = {
        "name": attr.string(
            doc = "The name of the system library as passed to `linkSystemLibrary` in a package's `build.zig`.",
            mandatory = True,
        ),
        "lib": attr.label(
            doc = "A `cc_library` or similar (any target providing `CcInfo`) that provides the named system library.",
            mandatory = True,
        ),
    },
)

patch = tag_class(
    doc = """\
Apply patches to a fetched Zig package before it is configured.

The root module's `patch` tags for a package take precedence; otherwise other
modules' apply, and must agree.
""",
    attrs = {
        "name": attr.string(
            doc = "The name of the Zig package to patch.",
            mandatory = True,
        ),
        "version": attr.string(
            doc = "Disambiguate `name` by version.",
        ),
        "patches": attr.label_list(
            doc = "Patch files applied in order to the fetched package tree. An empty list in the root module disables other modules' patches of the package.",
            allow_files = True,
            mandatory = True,
        ),
        "patch_strip": attr.int(
            default = 1,
            doc = "Number of leading path components to strip when applying `patches` (as `patch -p<N>`).",
        ),
    },
)

system_integration = tag_class(
    doc = "Enable an optional system integration (`systemIntegrationOption`) when configuring Zig packages. Only the root module's `system_integration` tags take effect.",
    attrs = {
        "name": attr.string(
            doc = "The name of an optional system integration (`systemIntegrationOption`) to enable.",
            mandatory = True,
        ),
    },
)

config = tag_class(
    doc = "Declare a build-configuration matrix cell that a `configure` tag can apply to Zig packages.",
    attrs = {
        "name": attr.string(
            doc = "Module-local name of this configuration cell.",
            mandatory = True,
        ),
        "optimize": attr.string(
            doc = "Zig optimize mode: `debug`, `release_safe`, `release_small` or `release_fast`.",
        ),
        "target": attr.string(
            doc = """\
Zig target triple (e.g. `x86_64-linux-gnu`) to configure the package for,
passed as `-Dtarget=<triple>`. The package's `build.zig` must accept it,
typically via `b.standardTargetOptions`. A package that does not accept a
target option fails to configure under a target-bearing matrix; exempt it
with a per-package `configure` of a single target-less config.
""",
        ),
        "select_on": attr.string_list(
            doc = "Extra Bazel condition labels ANDed into this cell's `select()` branch.",
        ),
        "zig_flags": attr.string_list(
            doc = "Extra Zig build options as `NAME=VALUE`, each passed as `-DNAME=VALUE`.",
        ),
    },
)

configure = tag_class(
    doc = """\
Apply a build-configuration matrix to Zig packages, globally or per package.

Each package is configured once per listed `config` cell; its generated
targets select the cell whose conditions (`optimize` mode and `select_on`)
hold, or `fallback` otherwise. A per-package `configure` overrides a global
one for that package. Only the root module's `config` and `configure` tags
take effect.
""",
    attrs = {
        "configs": attr.string_list(
            doc = "Ordered `config` cell names that apply.",
            mandatory = True,
        ),
        "fallback": attr.string(
            doc = "The config name used for the `//conditions:default` branch.",
            mandatory = True,
        ),
        "package": attr.string(
            doc = "If set, apply only to the named package; otherwise apply globally.",
        ),
        "version": attr.string(
            doc = "Disambiguate `package` by version.",
        ),
    },
)

_OPTIMIZE_MODES = {
    "debug": "debug",
    "release_safe": "safe",
    "release_small": "small",
    "release_fast": "fast",
}

def _config_error(message, tag):
    """A configuration error carrying the `config`/`configure` tag that caused it.

    The tag is forwarded to `fail()` so the reported error points at the
    offending declaration in the consumer's `MODULE.bazel`.
    """
    return struct(message = message, tag = tag)

def resolve_cell(tag):
    """Resolve a `config` tag into a build-configuration matrix cell.

    `optimize` expands to `//zig/config/mode:mode` and `-Doptimize=Mode`;
    `target` expands to `-Dtarget=<triple>`; `select_on` is appended verbatim
    and `zig_flags` become `-DNAME=VALUE`.

    Args:
      tag: a `config` tag.

    Returns:
      `(error, cell)`, `cell`: `struct(name, select_on, zig_options, tag)`, where
      `zig_options` is a list of `-DNAME=VALUE` Zig build option flags and `tag`
      is the originating `config` tag, retained for error reporting.
    """
    select_on = []
    zig_options = []

    if tag.optimize:
        mode = _OPTIMIZE_MODES.get(tag.optimize)
        if mode == None:
            return (_config_error("config '{}' has unknown optimize mode '{}'".format(tag.name, tag.optimize), tag), None)
        select_on.append("@rules_zig//zig/config/mode:" + tag.optimize)
        zig_options.append("-Doptimize=" + mode)

    if tag.target:
        zig_options.append("-Dtarget=" + tag.target)

    select_on.extend(tag.select_on)

    for flag in tag.zig_flags:
        if "=" not in flag:
            return (_config_error("config '{}' flag '{}' is not NAME=VALUE".format(tag.name, flag), tag), None)
        zig_options.append("-D" + flag)

    return (None, struct(name = tag.name, select_on = select_on, zig_options = zig_options, tag = tag))

def check_cells(package_name, cells):
    """Validate and deduplicate a package's matrix cells.

    Args:
      package_name: the package the cells belong to, for error messages.
      cells: the package's cells, each a
        `struct(name, select_on, zig_options, config_setting, tag)`.

    Returns:
      (error, cells), the fallback cells followed by the deduplicated
        non-fallback cells.
    """
    fallbacks = [cell for cell in cells if cell.config_setting == ""]
    nonfallback = [cell for cell in cells if cell.config_setting != ""]

    deduped = []
    by_conditions = {}
    for cell in nonfallback:
        if not cell.select_on:
            return (_config_error("package '{}' config '{}' has no select conditions".format(package_name, cell.name), cell.tag), None)

        conditions = tuple(sorted(cell.select_on))
        existing = by_conditions.get(conditions)
        if existing != None:
            if existing.zig_options != cell.zig_options:
                return (_config_error("package '{}' configs '{}' and '{}' share conditions but differ in build options".format(
                    package_name,
                    existing.name,
                    cell.name,
                ), cell.tag), None)
            continue
        by_conditions[conditions] = cell
        deduped.append(cell)

    for outer in deduped:
        for inner in deduped:
            if outer.name == inner.name:
                continue
            if len(outer.select_on) < len(inner.select_on) and all([c in inner.select_on for c in outer.select_on]):
                return (_config_error("package '{}' config '{}' conditions are a subset of '{}'; they would match ambiguously".format(
                    package_name,
                    outer.name,
                    inner.name,
                ), outer.tag), None)

    return (None, fallbacks + deduped)

def package_cells(key, cells_by_name, global_configure, per_package_configure):
    """Resolve the matrix cells a URL package is configured under.

    Args:
      key: the package's Zig hash key.
      cells_by_name: map from config name to its `struct(name, select_on, zig_options, tag)`.
      global_configure: the global `configure` tag (with `configs`/`fallback`), or None.
      per_package_configure: map from `(name, version)` to a `configure` tag.

    Returns:
      (error, cells): cells is the ordered list of `struct(name, select_on,
        zig_options, config_setting, tag)`, or None if the package is configured
        once at the host default.
    """
    name, version = package_name_version(key)

    selected = per_package_configure.get((name, version))
    if selected == None:
        selected = per_package_configure.get((name, ""))
    if selected == None:
        selected = global_configure
    if selected == None:
        return (None, None)

    if selected.fallback not in selected.configs:
        return (_config_error("package '{}' configure fallback '{}' is not among its configs".format(name, selected.fallback), selected), None)

    cells = []
    seen = {}
    for config_name in selected.configs:
        if config_name in seen:
            return (_config_error("package '{}' configure lists config '{}' more than once".format(name, config_name), selected), None)
        seen[config_name] = True
        cell = cells_by_name.get(config_name)
        if cell == None:
            return (_config_error("package '{}' configure references unknown config '{}'".format(name, config_name), selected), None)
        cells.append(struct(
            name = cell.name,
            select_on = cell.select_on,
            zig_options = cell.zig_options,
            config_setting = "" if config_name == selected.fallback else cell.name,
            tag = cell.tag,
        ))

    return check_cells(name, cells)

def collect_configs(modules):
    """Collect the build-configuration matrix from the root module's tags.

    Configurations from non-root modules are ignored (each returned as
    `struct(module, tag)` so the caller can warn, pointing at the tag).

    Args:
      modules: sequence of bazel_module, the extension's modules with
        `tags.config` and `tags.configure`.

    Returns:
      (error, result), where result is `struct(cells_by_name, global_configure,
        per_package_configure, ignored)`.
    """
    ignored = []
    cells_by_name = {}
    global_configure = None
    per_package_configure = {}

    for mod in modules:
        if not mod.is_root:
            for tag in mod.tags.config:
                ignored.append(struct(module = mod.name, tag = tag))
            for tag in mod.tags.configure:
                ignored.append(struct(module = mod.name, tag = tag))
            continue

        for tag in mod.tags.config:
            error, cell = resolve_cell(tag)
            if error != None:
                return (error, None)
            existing = cells_by_name.get(tag.name)
            if existing != None and (existing.select_on != cell.select_on or existing.zig_options != cell.zig_options):
                return (_config_error("conflicting config tags named '{}'".format(tag.name), tag), None)
            cells_by_name[tag.name] = cell

        for tag in mod.tags.configure:
            if tag.package:
                pkg_key = (tag.package, tag.version)
                if pkg_key in per_package_configure:
                    return (_config_error("multiple configure tags for package '{}'".format(tag.package), tag), None)
                per_package_configure[pkg_key] = tag
            elif global_configure != None:
                return (_config_error("at most one global configure tag is allowed", tag), None)
            else:
                global_configure = tag

    return (None, struct(
        cells_by_name = cells_by_name,
        global_configure = global_configure,
        per_package_configure = per_package_configure,
        ignored = ignored,
    ))

def _portable_key(key, pkg_dir, manifest_labels):
    """Map a path dependency's absolute directory to a portable key.

    Absolute paths are local to a single resolution and must not be persisted.
    A path inside the resolver's package directory is a sub-tree dependency of a
    fetched package and becomes a package-relative key; a path in module source
    is a consumer path dependency and becomes the label of its provided manifest.

    Args:
      key: the path dependency's absolute directory.
      pkg_dir: the resolver's package directory (holds fetched manifests).
      manifest_labels: map from a provided manifest's absolute path to its label.

    Returns:
      the portable key.
    """
    if key.startswith(pkg_dir + "/"):
        return key[len(pkg_dir) + 1:]

    manifest = key + "/build.zig.zon"
    if manifest in manifest_labels:
        return manifest_labels[manifest]

    fail("Zig path dependency at '{}' has no provided manifest; add its `build.zig.zon` as a `from_file` tag.".format(key))

def _localize_paths(graph, pkg_dir, manifest_labels):
    """Rewrite the graph's absolute path-dependency keys to portable keys."""
    remap = {
        key: _portable_key(key, pkg_dir, manifest_labels)
        for key, package in graph["packages"].items()
        if package["path"] != None
    }

    packages = {}
    for key, package in graph["packages"].items():
        package["deps"] = {name: remap.get(child, child) for name, child in package["deps"].items()}
        if package["path"] != None:
            package["path"] = remap[key]
        packages[remap.get(key, key)] = package
    graph["packages"] = packages

    for root in graph["roots"]:
        root["deps"] = {name: remap.get(child, child) for name, child in root["deps"].items()}

    return graph

def _deps_data(graph, key, reached):
    """The `deps` closure to configure the URL package `key` against.

    Every reachable package must be configurable: a sub-tree path dependency of
    `key` is configured in-tree, its `path` being its location relative to
    `key`; a URL dependency, or a sub-tree of one, resolves through that
    dependency's sibling spoke (`path` is None).
    """
    packages = {}
    for dep in reached:
        package = graph["packages"][dep]
        if dep.startswith(key + "/"):
            path = dep[len(key) + 1:]
        elif package["url"] != None or dep.partition("/")[0] in reached:
            path = None
        else:
            fail("Zig package '{}' depends on out-of-tree path dependency '{}', which is unsupported.".format(key, dep))
        packages[dep] = {
            "deps": _dep_edges(package),
            "path": path,
            "naked": package.get("naked", False),
        }
    return {
        "root_deps": _dep_edges(graph["packages"][key]),
        "packages": packages,
    }

def _resolve_graph(module_ctx, zig, resolver, cache, pkg_dir, manifests):
    result = module_ctx.execute(
        [zig, "run", "--cache-dir", cache, "--global-cache-dir", cache, resolver, "--", zig, cache, str(pkg_dir)] +
        [str(manifest) for manifest in manifests],
        timeout = ZIG_FETCH_TIMEOUT,
    )
    if result.return_code != 0:
        fail("Failed to resolve the Zig dependency graph:\n{}".format(result.stderr))
    return json.decode(result.stdout)

def _zig_packages_impl(module_ctx):
    zig = zig_path(module_ctx)
    resolver = module_ctx.path(Label("//zig/private/packages:resolver.zig"))
    cache = zig_cache(module_ctx)
    pkg_dir = module_ctx.path("pkg")

    manifests = []
    manifest_labels = {}
    tags = []
    root_tags = {}
    for mod in module_ctx.modules:
        for tag in mod.tags.from_file:
            manifest = module_ctx.path(tag.build_zig_zon)

            # The manifest is read by the resolver, which is opaque to Bazel.
            module_ctx.watch(manifest)
            manifests.append(manifest)
            manifest_labels[str(manifest)] = str(tag.build_zig_zon)
            tags.append(tag)
            if mod.is_root:
                root_tags[len(tags) - 1] = module_ctx.is_dev_dependency(tag)

    warnings = {}

    system_library_entries = {}
    for mod in module_ctx.modules:
        for tag in mod.tags.system_library:
            entries = system_library_entries.setdefault(tag.name, [])
            for other in entries:
                if other.module == mod.name and other.value != tag.lib:
                    fail("Conflicting `system_library` annotations for '{}': {} and {}.".format(tag.name, other.value, tag.lib), tag)
            entries.append(_tag_entry(mod, tag.name, tag.lib, tag))
    system_libraries = {}
    for name in system_library_entries:
        system_libraries[name] = _apply_precedence(system_library_entries, [name], "system_library", _system_library_subject, warnings).value

    system_integrations = {}
    for mod in module_ctx.modules:
        for tag in mod.tags.system_integration:
            if not mod.is_root:
                warnings["Ignoring a `system_integration` tag from non-root module '{}'.".format(mod.name)] = tag
                continue
            system_integrations[tag.name] = True
    system_integrations = system_integrations.keys()

    patch_entries = {}
    for mod in module_ctx.modules:
        for tag in mod.tags.patch:
            pkg_key = (tag.name, tag.version)
            entries = patch_entries.setdefault(pkg_key, [])
            if [entry for entry in entries if entry.module == mod.name]:
                fail("Multiple `patch` tags for {}.".format(_package_subject(pkg_key)), tag)
            entries.append(_tag_entry(mod, pkg_key, struct(patches = tag.patches, patch_strip = tag.patch_strip), tag))
    used_patches = {}

    error, matrix = collect_configs(module_ctx.modules)
    if error != None:
        fail("Invalid Zig package configuration: {}.".format(error.message), error.tag)
    for ignored in matrix.ignored:
        # buildifier: disable=print
        print("Ignoring a `config`/`configure` tag from non-root module '{}'.".format(ignored.module), ignored.tag)

    graph = _resolve_graph(module_ctx, zig, resolver, cache, pkg_dir, manifests)
    graph = _localize_paths(graph, str(pkg_dir), manifest_labels)

    # `graph["packages"]` is topologically ordered, so each dependency's
    # reachable set is already known by the time we reach a package: accumulate
    # in one pass. A package is configured against its full closure, since its
    # `build.zig` runs those of its dependencies. Reachability follows every
    # edge (URL and sub-tree path), so a URL spoke reached only through a
    # sub-tree dependency is configured too.
    reachable = {}
    hub_graph = {}
    config_groups = {}
    for key, package in graph["packages"].items():
        reached = {}
        for _dep_name, dep_key in package["deps"].items():
            reached[dep_key] = True
            for dep in reachable[dep_key]:
                reached[dep] = True
        reachable[key] = reached
        if package["url"] == None:
            continue
        name, version = package_name_version(key)

        hub_graph[key] = {"name": name, "version": version}

        url_deps = [dep for dep in reached if graph["packages"][dep]["url"] != None]
        dep_files = {dep: "@{}//:files".format(dep) for dep in url_deps}

        # A naked (manifest-less) package exposes only its files; it is not
        # configured.
        if package.get("naked", False):
            zig_package(
                name = key,
                url = package["url"],
                zig_hash = key,
            )
            continue

        error, cells = package_cells(key, matrix.cells_by_name, matrix.global_configure, matrix.per_package_configure)
        if error != None:
            fail("Invalid Zig package configuration: {}.".format(error.message), error.tag)
        configs = []
        config_settings = {}
        if cells != None:
            for cell in cells:
                configs.append({
                    "name": cell.name,
                    "zig_options": cell.zig_options,
                    "config_setting": cell.config_setting,
                })
                if cell.config_setting != "":
                    config_settings[cell.name] = "@zig_deps//config:cfg_" + cell.name
                    config_groups[cell.name] = {"name": cell.name, "select_on": cell.select_on}

        patch_keys = [(name, version), (name, "")]
        patch = _apply_precedence(patch_entries, patch_keys, "patch", _package_subject, warnings)
        for pkg_key in patch_keys:
            if pkg_key in patch_entries:
                used_patches[pkg_key] = True

        build_deps = [dep for dep in url_deps if not graph["packages"][dep].get("naked", False)]
        zig_package(
            name = key,
            url = package["url"],
            zig_hash = key,
            package_name = name,
            deps = json.encode(_deps_data(graph, key, reached)),
            dep_build_files = {dep: "@{}//:build.zig".format(dep) for dep in build_deps},
            dep_files = dep_files,
            system_libraries = system_libraries,
            system_integrations = system_integrations,
            configs = json.encode(configs),
            config_settings = config_settings,
            patches = patch.value.patches if patch else [],
            patch_strip = patch.value.patch_strip if patch else 1,
        )

    for pkg_key, entries in patch_entries.items():
        if pkg_key not in used_patches:
            fail("`patch` tag targets {}, which is not a URL package in the resolved dependency graph.".format(_package_subject(pkg_key)), entries[0].tag)

    # Resolve each provided manifest's declared dependencies to the target that
    # satisfies them: a URL dependency to its spoke (by hash key), a consumer
    # path dependency to a target of the same name in its own provided
    # manifest's package, which the user defines.
    tag_by_label = {str(tag.build_zig_zon): tag for tag in tags}
    manifests = []
    for index, root in enumerate(graph["roots"]):
        deps = {}
        for name, key in root["deps"].items():
            package = graph["packages"][key]
            if package["url"] != None:
                deps[name] = {"key": key}
            else:
                deps[name] = {"target": str(tag_by_label[key].build_zig_zon.same_package_label(name))}
        manifests.append({
            "repo": tags[index].build_zig_zon.repo_name,
            "package": tags[index].build_zig_zon.package,
            "deps": deps,
        })

    zig_deps_hub(
        name = "zig_deps",
        package_files = {key: "@{}//:files".format(key) for key in hub_graph},
        graph = json.encode(hub_graph),
        manifests = json.encode(manifests),
        config_groups = json.encode([config_groups[name] for name in sorted(config_groups)]),
    )

    for message, tag in warnings.items():
        # buildifier: disable=print
        print(message, tag)

    root_nondev = False
    root_dev = False
    for is_dev in root_tags.values():
        if is_dev:
            root_dev = True
        else:
            root_nondev = True

    direct = ["zig_deps"] if root_nondev else []
    dev = ["zig_deps"] if root_dev and not root_nondev else []
    return module_ctx.extension_metadata(
        root_module_direct_deps = direct,
        root_module_direct_dev_deps = dev,
    )

zig_packages = module_extension(
    implementation = _zig_packages_impl,
    doc = """\
Import Zig package dependencies.

**Experimental:** this extension, its tags, and the repositories it generates
may change without notice.

Resolves the dependency graph across the `build.zig.zon` manifests provided
via `from_file` tags and generates two kinds of repositories:

- A *spoke* per URL package in the graph, named by the package's Zig hash so
  that several versions of a package coexist. Spokes are internal; their names
  are not part of the API.
- The `@zig_deps` *hub*, the only repository consumers use. Its `defs.bzl`
  provides functions that address the spokes. `zig_dep` resolves a dependency
  declared by the `from_file` manifest of the calling Bazel package or its
  nearest ancestor, `zig_deps` resolves all of them that have Zig modules
  (packages without a `build.zig.zon` have none), and `zig_import_names`
  imports each under its declared name. `zig_package_target` names the
  `zig_library` generated for a module of a package, `zig_package_files` and
  `zig_package_file` name its files. Each takes a package `name` and an
  optional `version`. Without `version`, `name` is a dependency declared by
  the manifest, as for `zig_dep`. With `version`, `name` is a package name,
  and the lookup fails if several packages share that name and version.

In `MODULE.bazel`:

```starlark
zig_packages = use_extension("@rules_zig//zig:packages.bzl", "zig_packages")
zig_packages.from_file(build_zig_zon = "//:build.zig.zon")
use_repo(zig_packages, "zig_deps")
```

In `BUILD.bazel`, next to `build.zig.zon`:

```starlark
load("@rules_zig//zig:defs.bzl", "zig_binary")
load("@zig_deps//:defs.bzl", "zig_deps", "zig_import_names")

zig_binary(
    name = "main",
    main = "main.zig",
    import_names = zig_import_names(),
    deps = zig_deps(),
)
```
""",
    tag_classes = {
        "from_file": from_file,
        "system_library": system_library,
        "system_integration": system_integration,
        "patch": patch,
        "config": config,
        "configure": configure,
    },
)
