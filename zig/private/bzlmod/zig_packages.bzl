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

system_integration = tag_class(
    doc = "Enable an optional system integration (`systemIntegrationOption`) when configuring Zig packages. Only the root module's `system_integration` tags take effect.",
    attrs = {
        "name": attr.string(
            doc = "The name of an optional system integration (`systemIntegrationOption`) to enable.",
            mandatory = True,
        ),
    },
)

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
    tags = []
    root_tags = {}
    for mod in module_ctx.modules:
        for tag in mod.tags.from_file:
            manifest = module_ctx.path(tag.build_zig_zon)

            # The manifest is read by the resolver, which is opaque to Bazel.
            module_ctx.watch(manifest)
            manifests.append(manifest)
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

    graph = _resolve_graph(module_ctx, zig, resolver, cache, pkg_dir, manifests)

    for index, root in enumerate(graph["roots"]):
        tag = tags[index]
        for name, key in root["deps"].items():
            if graph["packages"][key]["url"] == None:
                fail("Zig dependency '{}' is a path dependency, which is not supported; declared by".format(name), tag)

    # `graph["packages"]` is topologically ordered, so each dependency's
    # reachable set is already known by the time we reach a package: accumulate
    # in one pass. A package is configured against its full closure, since its
    # `build.zig` runs those of its dependencies.
    reachable = {}
    hub_graph = {}
    for key, package in graph["packages"].items():
        if package["url"] == None:
            continue
        name, version = package_name_version(key)

        reached = {}
        for dep_name, dep_key in package["deps"].items():
            if graph["packages"][dep_key]["url"] == None:
                fail("Zig package '{}' has a path dependency '{}', which is not supported inside fetched packages.".format(
                    key,
                    dep_name,
                ))
            reached[dep_key] = True
            for dep in reachable[dep_key]:
                reached[dep] = True
        reachable[key] = reached

        hub_graph[key] = {"name": name, "version": version}
        zig_package(
            name = key,
            url = package["url"],
            zig_hash = key,
            deps = json.encode({
                "root_deps": _dep_edges(package),
                "packages": {
                    dep: {"deps": _dep_edges(graph["packages"][dep])}
                    for dep in reached
                },
            }),
            dep_build_files = {dep: "@{}//:build.zig".format(dep) for dep in reached},
            system_libraries = system_libraries,
            system_integrations = system_integrations,
        )

    manifests = [
        {
            "repo": tags[index].build_zig_zon.repo_name,
            "package": tags[index].build_zig_zon.package,
            "deps": {name: {"key": key} for name, key in root["deps"].items()},
        }
        for index, root in enumerate(graph["roots"])
    ]

    zig_deps_hub(
        name = "zig_deps",
        package_files = {key: "@{}//:files".format(key) for key in hub_graph},
        graph = json.encode(hub_graph),
        manifests = json.encode(manifests),
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
  nearest ancestor, `zig_deps` resolves all of them, and `zig_import_names`
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
    },
)
