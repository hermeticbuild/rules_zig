<!-- Generated with Stardoc: http://skydoc.bazel.build -->

Extension for importing Zig package dependencies.

<a id="zig_packages"></a>

## zig_packages

<pre>
zig_packages = use_extension("@rules_zig//zig:packages.bzl", "zig_packages")
zig_packages.from_file(<a href="#zig_packages.from_file-build_zig_zon">build_zig_zon</a>)
</pre>

Import Zig package dependencies.

**Experimental:** this extension, its tags, and the repositories it generates
may change without notice.

Resolves the dependency graph across the `build.zig.zon` manifests provided
via `from_file` tags and generates two kinds of repositories:

- A *spoke* per URL package in the graph, named by the package's Zig hash so
  that several versions of a package coexist. Spokes are internal; their names
  are not part of the API.
- The `@zig_deps` *hub*, the only repository consumers use. Its `defs.bzl`
  provides functions that address the spokes: `zig_package_files` and
  `zig_package_file` name a package's files, `zig_package_deps` lists its
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


**TAG CLASSES**

<a id="zig_packages.from_file"></a>

### from_file

Resolve the Zig package dependencies declared in a `build.zig.zon` manifest.

**Attributes**

| Name  | Description | Type | Mandatory | Default |
| :------------- | :------------- | :------------- | :------------- | :------------- |
| <a id="zig_packages.from_file-build_zig_zon"></a>build_zig_zon |  A `build.zig.zon` manifest to resolve Zig dependencies for.   | <a href="https://bazel.build/concepts/labels">Label</a> | required |  |


