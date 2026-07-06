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

Resolves the dependencies declared in the `build.zig.zon` manifests provided
via `from_file` tags and declares a repository per URL dependency, named
after the dependency.


**TAG CLASSES**

<a id="zig_packages.from_file"></a>

### from_file

Resolve the Zig package dependencies declared in a `build.zig.zon` manifest.

**Attributes**

| Name  | Description | Type | Mandatory | Default |
| :------------- | :------------- | :------------- | :------------- | :------------- |
| <a id="zig_packages.from_file-build_zig_zon"></a>build_zig_zon |  A `build.zig.zon` manifest to resolve Zig dependencies for.   | <a href="https://bazel.build/concepts/labels">Label</a> | required |  |


