"""Implementation of the `zig_packages` module extension."""

load("@zig_host_toolchain//:toolchain.bzl", "zig_cache", "zig_path")
load("//zig/private/repo:zig_package.bzl", "zig_package")

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

def _parse_manifests(module_ctx, zig, resolver, cache, manifests):
    result = module_ctx.execute(
        [zig, "run", "--cache-dir", cache, "--global-cache-dir", cache, resolver, "--"] +
        [str(manifest) for manifest in manifests],
    )
    if result.return_code != 0:
        fail("Failed to parse the Zig package manifests:\n{}".format(result.stderr))
    return json.decode(result.stdout)

def _zig_packages_impl(module_ctx):
    zig = zig_path(module_ctx)
    resolver = module_ctx.path(Label("//zig/private/packages:resolver.zig"))
    cache = zig_cache(module_ctx)

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

    parsed = _parse_manifests(module_ctx, zig, resolver, cache, manifests)

    packages = {}
    package_tags = {}
    direct = {}
    dev = {}
    for index, manifest in enumerate(parsed):
        tag = tags[index]
        for name, dep in manifest["deps"].items():
            if dep["url"] == None:
                fail("Zig dependency '{}' is a path dependency, which is not supported; declared by".format(name), tag)
            if dep["hash"] == None:
                fail("Zig dependency '{}' is missing a hash; declared by".format(name), tag)

            package = (dep["url"], dep["hash"])
            existing = packages.get(name)
            if existing != None and existing != package:
                fail(
                    "Conflicting declarations for the Zig dependency '{}': {} and {}; declared by".format(name, existing, package),
                    package_tags[name],
                    "and",
                    tag,
                )
            packages[name] = package
            package_tags[name] = tag

            if index in root_tags:
                if root_tags[index]:
                    dev[name] = True
                else:
                    direct[name] = True

    for name, (url, zig_hash) in packages.items():
        zig_package(
            name = name,
            url = url,
            zig_hash = zig_hash,
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
