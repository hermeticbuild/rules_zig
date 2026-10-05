# Bazel build rules for Zig

Build [Zig code][zig] with the [Bazel build system][bazel].

[zig]: https://ziglang.org/
[bazel]: https://bazel.build/

## Status

Take a look at the [planned functionality][planned-functionality] tracking
issue to get a picture of which functionality is already implemented and what
is still missing.

[planned-functionality]: https://github.com/hermeticbuild/rules_zig/issues/1

## Motivation

Why would you use Bazel to build Zig code,
when Zig comes with its own perfectly fine [build system][zig-build]?

These Bazel rules are not meant as competition to the Zig build system.
If your project fits well within the scope of Zig's build system,
in particular, it only uses Zig code and perhaps C/C++ code,
then Zig's build system will probably work very well for your use-case.

Bazel is useful for polyglot, monorepo projects,
especially if they are very large.
If your project involves multiple programming languages
and if some of them are not supported by Zig's build system,
or if your project involves complex code-generation steps
or requires a lot of [custom build steps][zig-build-command-step],
then Bazel may be a good choice.
If your project is already a Bazel project
and you want to add Zig code to it
then this rule set is for you.

Bazel has builtin support for [cross-compilation][bazel-platforms]
and [build configuration][bazel-configurations],
meaning it can support Zig's cross-compilation
and build configuration features well.

[zig-build]: https://ziglang.org/documentation/master/#Zig-Build-System
[zig-build-command-step]: https://ikrima.dev/dev-notes/zig/zig-build/#run-commands-as-build-steps
[bazel-platforms]: https://bazel.build/extending/platforms
[bazel-configurations]: https://bazel.build/extending/config

## Installation

The instructions assume basic familiarity with the Bazel build system.
Take a look at [Bazel's documentation][bazel-intro] if you are unfamiliar.

Consider the [_Additional Setup_](#additional-setup) section as well.

[bazel-intro]: https://bazel.build/about/intro

Bazel dependencies are managed using Bzlmod, you can read more about it in the
[Bazel documentation][bzlmod-doc].
Note, the old WORKSPACE mechanmism is no longer supported by rules_zig.

[bzlmod-doc]: https://bazel.build/external/overview#bzlmod

To install a [release version of rules_zig][rules-zig-releases] follow the
installation instructions given in the corresponding release notes.

[rules-zig-releases]: https://github.com/hermeticbuild/rules_zig/releases

To install a development version add the following to your MODULE.bazel file:

```bzl
bazel_dep(name = "rules_zig")
archive_override(
    module_name = "rules_zig",
    integrity = "sha256-$SHA256",
    strip_prefix = "rules_zig-$COMMIT",
    urls = ["https://github.com/hermeticbuild/rules_zig/archive/$COMMIT.tar.gz"],
)
```

Note, `$SHA256` and `$COMMIT` are placeholders that you need to fill in. Take a
look at the [Bazel documentation][archive-override-doc] for further
information.

[archive-override-doc]: https://bazel.build/versions/7.0.0/rules/lib/globals/module#archive_override

<!-- TODO[AH] Write a user-guide
  https://github.com/hermeticbuild/rules_zig/issues/59

## User Guide Documentation

-->

### Additional Setup

#### Zig Cache

The Zig compiler caches intermediate outputs on disk. This cache is shared and
persisted between Bazel builds and build actions. You can configure the cache
directory using the following set of environment variables, you can configure
them through Bazel by using the `--repo_env` flag.

- `RULES_ZIG_CACHE_PREFIX_LINUX`: Cache directory on Linux, default `/tmp/zig-cache`.
- `RULES_ZIG_CACHE_PREFIX_MACOS`: Cache directory on MacOS, default `/var/tmp/zig-cache`.
- `RULES_ZIG_CACHE_PREFIX_WINDOWS`: Cache directory on Windows, default `C:\Temp\zig-cache`.
- `RULES_ZIG_CACHE_PREFIX`: Cache directory fall-back for all platforms, default `/tmp/zig-cache`.

> [!Note]
> On Bazel 7 and above you need to explicitly allow persistence in the sandbox.
> You can use the following `.bazelrc` snippet, adjust the paths depending on
> your cache configuration.
>
> ```
> common --enable_platform_specific_config
> # You can configure `/tmp/zig-cache`, or similar, specifically,
> # if you can ensure that the directory exists before the build.
> build:linux --sandbox_add_mount_pair=/tmp
> build:macos --sandbox_add_mount_pair=/var/tmp
> build:windows --sandbox_add_mount_pair=C:\Temp
> ```

## Usage Examples

<!-- TODO[AH] Create an instructive example.
  https://github.com/hermeticbuild/rules_zig/issues/58
-->

Examples can be found among the end-to-end tests under
[`./e2e/workspace`](./e2e/workspace).

## ZLS

ZLS toolchains are provided by a separate extension and selected by the active
Zig SDK version.

```starlark
zls = use_extension("@rules_zig//zig/zls:extensions.bzl", "zls")
zls.index(file = "@rules_zig//zig/zls/private:versions.json")
zls.toolchain(
    zig_version = "0.16.0",
    zls_version = "0.16.0",
)
use_repo(zls, "zls_toolchains")
register_toolchains("@zls_toolchains//:all")
```

Use `zig_version` as the selector and `zls_version` as the artifact version.
They do not need to match, which allows a dev ZLS build to be tied to a stable
Zig SDK.

Use the [`zls_completion`](./zig/zls/zls_completion.bzl) macro to define a ZLS
entry point for the Zig targets you want to expose to the language server.
For example, in `tools/BUILD.bazel`:

```starlark
load("@rules_zig//zig/zls:defs.bzl", "zls_completion")

zls_completion(
    name = "zls",
    deps = ["//src:app"],
)
```

Then point your editor's ZLS binary setting at a wrapper script that runs that
target.

```bash
#!/usr/bin/env bash
cd "$(dirname "${BASH_SOURCE[0]}")/.."
exec bazel run -- //tools:zls "${@}"
```

## Reference Documentation

Generated API documentation for the provided rules is available in
[`./docs/rules.md`](./docs/rules.md).

Generated API documentation for the module extensions is available in
[`./docs/extensions.md`](./docs/extensions.md).

Generated API documentation for the toolchain rules is available in
[`./docs/toolchains.md`](./docs/toolchains.md).

## Runfiles Library Documentation

Documentation for the Zig runfiles library can be found in
[`./zig/runfiles/guide.md`](./zig/runfiles/guide.md).
