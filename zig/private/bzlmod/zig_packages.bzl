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
        edges = []
        for dep_name, dep_key in package["deps"].items():
            if graph["packages"][dep_key]["url"] == None:
                fail("Zig package '{}' has a path dependency '{}', which is not supported inside fetched packages.".format(
                    key,
                    dep_name,
                ))
            edges.append([dep_name, dep_key])
            reached[dep_key] = True
            for dep in reachable[dep_key]:
                reached[dep] = True
        reachable[key] = reached

        hub_graph[key] = {
            "name": name,
            "version": version,
            "deps": {dep_name: dep_key for dep_name, dep_key in package["deps"].items()},
        }
        zig_package(
            name = key,
            url = package["url"],
            zig_hash = key,
            deps = json.encode({
                "root_deps": edges,
                "packages": {
                    dep: {"deps": [[n, k] for n, k in graph["packages"][dep]["deps"].items()]}
                    for dep in reached
                },
            }),
            dep_build_files = {dep: "@{}//:build.zig".format(dep) for dep in reached},
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
  provides functions that address the spokes: `zig_package_target` names the
  `zig_library` generated for a module of a package, `zig_package_files` and
  `zig_package_file` name its files, and `zig_package_deps` lists its
  dependencies. Each takes a package `name` and an optional `version`. Without
  `version`, `name` is a dependency declared by the `from_file` manifest of
  the calling Bazel package or its nearest ancestor. With `version`, `name` is
  a package name, and the lookup fails if several packages share that name and
  version.

```starlark
zig_packages = use_extension("@rules_zig//zig:packages.bzl", "zig_packages")
zig_packages.from_file(build_zig_zon = "//:build.zig.zon")
use_repo(zig_packages, "zig_deps")
```
""",
    tag_classes = {
        "from_file": from_file,
    },
)
