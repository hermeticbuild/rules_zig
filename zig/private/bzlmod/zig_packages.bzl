"""Implementation of the `zig_packages` module extension."""

load("@zig_host_toolchain//:toolchain.bzl", "zig_cache", "zig_path")
load("//zig/private/repo:zig_package.bzl", "ZIG_FETCH_TIMEOUT", "zig_package")

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

    packages = {}
    package_tags = {}
    direct = {}
    dev = {}
    for index, root in enumerate(graph["roots"]):
        tag = tags[index]
        for name, key in root["deps"].items():
            package = graph["packages"][key]
            if package["url"] == None:
                fail("Zig dependency '{}' is a path dependency, which is not supported; declared by".format(name), tag)

            existing = packages.get(name)
            if existing != None and existing != key:
                fail(
                    "Conflicting declarations for the Zig dependency '{}': {} and {}; declared by".format(name, existing, key),
                    package_tags[name],
                    "and",
                    tag,
                )
            packages[name] = key
            package_tags[name] = tag

            if index in root_tags:
                if root_tags[index]:
                    dev[name] = True
                else:
                    direct[name] = True

    for name, key in packages.items():
        zig_package(
            name = name,
            url = graph["packages"][key]["url"],
            zig_hash = key,
        )

    return module_ctx.extension_metadata(
        root_module_direct_deps = sorted([name for name in direct]),
        root_module_direct_dev_deps = sorted([name for name in dev if name not in direct]),
    )

zig_packages = module_extension(
    implementation = _zig_packages_impl,
    doc = """\
Import Zig package dependencies.

**Experimental:** this extension, its tags, and the repositories it generates
may change without notice.

Resolves the dependencies declared in the `build.zig.zon` manifests provided
via `from_file` tags and declares a repository per URL dependency, named
after the dependency.
""",
    tag_classes = {
        "from_file": from_file,
    },
)
