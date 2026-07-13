<!-- Generated with Stardoc: http://skydoc.bazel.build -->

Extension for importing Zig package dependencies.

<a id="zig_packages"></a>

## zig_packages

<pre>
zig_packages = use_extension("@rules_zig//zig:packages.bzl", "zig_packages")
zig_packages.from_file(<a href="#zig_packages.from_file-build_zig_zon">build_zig_zon</a>)
zig_packages.system_library(<a href="#zig_packages.system_library-name">name</a>, <a href="#zig_packages.system_library-lib">lib</a>)
zig_packages.system_integration(<a href="#zig_packages.system_integration-name">name</a>)
zig_packages.patch(<a href="#zig_packages.patch-name">name</a>, <a href="#zig_packages.patch-patch_strip">patch_strip</a>, <a href="#zig_packages.patch-patches">patches</a>, <a href="#zig_packages.patch-version">version</a>)
zig_packages.config(<a href="#zig_packages.config-name">name</a>, <a href="#zig_packages.config-optimize">optimize</a>, <a href="#zig_packages.config-select_on">select_on</a>, <a href="#zig_packages.config-target">target</a>, <a href="#zig_packages.config-zig_flags">zig_flags</a>)
zig_packages.configure(<a href="#zig_packages.configure-configs">configs</a>, <a href="#zig_packages.configure-fallback">fallback</a>, <a href="#zig_packages.configure-package">package</a>, <a href="#zig_packages.configure-version">version</a>)
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


**TAG CLASSES**

<a id="zig_packages.from_file"></a>

### from_file

Resolve the Zig package dependencies declared in a `build.zig.zon` manifest.

**Attributes**

| Name  | Description | Type | Mandatory | Default |
| :------------- | :------------- | :------------- | :------------- | :------------- |
| <a id="zig_packages.from_file-build_zig_zon"></a>build_zig_zon |  A `build.zig.zon` manifest to resolve Zig dependencies for.   | <a href="https://bazel.build/concepts/labels">Label</a> | required |  |

<a id="zig_packages.system_library"></a>

### system_library

Map a system library a Zig package links (`linkSystemLibrary`) to a `cc_library` or similar that provides it.

The root module's mapping of a library takes precedence; otherwise other
modules' mappings apply, and must agree.

**Attributes**

| Name  | Description | Type | Mandatory | Default |
| :------------- | :------------- | :------------- | :------------- | :------------- |
| <a id="zig_packages.system_library-name"></a>name |  The name of the system library as passed to `linkSystemLibrary` in a package's `build.zig`.   | <a href="https://bazel.build/concepts/labels#target-names">Name</a> | required |  |
| <a id="zig_packages.system_library-lib"></a>lib |  A `cc_library` or similar (any target providing `CcInfo`) that provides the named system library.   | <a href="https://bazel.build/concepts/labels">Label</a> | required |  |

<a id="zig_packages.system_integration"></a>

### system_integration

Enable an optional system integration (`systemIntegrationOption`) when configuring Zig packages. Only the root module's `system_integration` tags take effect.

**Attributes**

| Name  | Description | Type | Mandatory | Default |
| :------------- | :------------- | :------------- | :------------- | :------------- |
| <a id="zig_packages.system_integration-name"></a>name |  The name of an optional system integration (`systemIntegrationOption`) to enable.   | <a href="https://bazel.build/concepts/labels#target-names">Name</a> | required |  |

<a id="zig_packages.patch"></a>

### patch

Apply patches to a fetched Zig package before it is configured.

The root module's `patch` tags for a package take precedence; otherwise other
modules' apply, and must agree.

**Attributes**

| Name  | Description | Type | Mandatory | Default |
| :------------- | :------------- | :------------- | :------------- | :------------- |
| <a id="zig_packages.patch-name"></a>name |  The name of the Zig package to patch.   | <a href="https://bazel.build/concepts/labels#target-names">Name</a> | required |  |
| <a id="zig_packages.patch-patch_strip"></a>patch_strip |  Number of leading path components to strip when applying `patches` (as `patch -p<N>`).   | Integer | optional |  `1`  |
| <a id="zig_packages.patch-patches"></a>patches |  Patch files applied in order to the fetched package tree. An empty list in the root module disables other modules' patches of the package.   | <a href="https://bazel.build/concepts/labels">List of labels</a> | required |  |
| <a id="zig_packages.patch-version"></a>version |  Disambiguate `name` by version.   | String | optional |  `""`  |

<a id="zig_packages.config"></a>

### config

Declare a build-configuration matrix cell that a `configure` tag can apply to Zig packages.

**Attributes**

| Name  | Description | Type | Mandatory | Default |
| :------------- | :------------- | :------------- | :------------- | :------------- |
| <a id="zig_packages.config-name"></a>name |  Module-local name of this configuration cell.   | <a href="https://bazel.build/concepts/labels#target-names">Name</a> | required |  |
| <a id="zig_packages.config-optimize"></a>optimize |  Zig optimize mode: `debug`, `release_safe`, `release_small` or `release_fast`.   | String | optional |  `""`  |
| <a id="zig_packages.config-select_on"></a>select_on |  Extra Bazel condition labels ANDed into this cell's `select()` branch.   | List of strings | optional |  `[]`  |
| <a id="zig_packages.config-target"></a>target |  Zig target triple (e.g. `x86_64-linux-gnu`) to configure the package for, passed as `-Dtarget=<triple>`. The package's `build.zig` must accept it, typically via `b.standardTargetOptions`. A package that does not accept a target option fails to configure under a target-bearing matrix; exempt it with a per-package `configure` of a single target-less config.   | String | optional |  `""`  |
| <a id="zig_packages.config-zig_flags"></a>zig_flags |  Extra Zig build options as `NAME=VALUE`, each passed as `-DNAME=VALUE`.   | List of strings | optional |  `[]`  |

<a id="zig_packages.configure"></a>

### configure

Apply a build-configuration matrix to Zig packages, globally or per package.

Each package is configured once per listed `config` cell; its generated
targets select the cell whose conditions (`optimize` mode and `select_on`)
hold, or `fallback` otherwise. A per-package `configure` overrides a global
one for that package. Only the root module's `config` and `configure` tags
take effect.

**Attributes**

| Name  | Description | Type | Mandatory | Default |
| :------------- | :------------- | :------------- | :------------- | :------------- |
| <a id="zig_packages.configure-configs"></a>configs |  Ordered `config` cell names that apply.   | List of strings | required |  |
| <a id="zig_packages.configure-fallback"></a>fallback |  The config name used for the `//conditions:default` branch.   | String | required |  |
| <a id="zig_packages.configure-package"></a>package |  If set, apply only to the named package; otherwise apply globally.   | String | optional |  `""`  |
| <a id="zig_packages.configure-version"></a>version |  Disambiguate `package` by version.   | String | optional |  `""`  |


