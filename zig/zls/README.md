# How the ZLS integration works

ZLS needs the module roots and imports selected by `zls_completion(deps = [...])`.
Bazel produces that information. For ZLS 0.17, the completion launcher also acts
as ZLS's Zig executable and translates the Bazel module graph into Zig's binary
build protocol.

## From the editor to Bazel

```text
Editor -> launcher -> ZLS
  The launcher starts ZLS with zig_exe_path pointing back to itself.

ZLS -> launcher build --listen=-
  This invocation enters compiler-proxy mode and calls zls_bsp.serve().

BSP -> bazel run --@zig_toolchains//:version=<SDK> -- //app:zls.print_build_config
  Bazel writes the graph JSON, prepares generated sources, and runs the printer.

Printer -> BSP
  The printer reads the JSON, resolves its paths, and writes JSON to stdout.

BSP -> ZLS
  BSP reads that stdout, serializes the graph to a temporary binary file,
  and sends the file path over Zig's build protocol.

ZLS -> Editor
  ZLS reads the file and uses the graph to answer go-to-definition over LSP.
```

ZLS starts a new instance of the launcher for each Zig command. The original
launcher supervises ZLS for the editor session. The Zig 0.16 and 0.17 launchers
share runfiles lookup and preparation of ZLS's temporary configuration,
arguments, and environment. [Shared launcher setup](zls_runner_common.zig)

## Which targets are included?

`zls_completion(name = "zls", deps = [":app"])` creates the `:zls` launcher,
the `:zls.build_config` exporter, and the `:zls.print_build_config` executable.
The exporter records the roots listed in `deps` and their transitive imports.
The raw JSON uses placeholders for workspace and output paths. The printer
resolves them to local paths.
[Completion macro](zls_completion.bzl) · [Graph exporter](zls_write_build_config.bzl)

This abbreviated example shows the printer's stdout. Here, `main.zig` is a
selected root and `@import("dep")` resolves to `dep.zig`.

```json
{
  "compilations": [{ "root_module": "/work/project/main.zig" }],
  "modules": {
    "/work/project/main.zig": {
      "import_table": { "dep": "/work/project/dep.zig" }
    },
    "/work/project/dep.zig": { "import_table": {} }
  }
}
```

Both versions use the same printer and JSON format. The 0.16 custom build
runner passes the printer's stdout to ZLS. The 0.17 adapter converts that
JSON to Zig's binary configuration. [Zig 0.16 build runner](zls_build_runner.zig)

## When does ZLS query Bazel?

When ZLS first finds a `build.zig` while resolving a document's imports, ZLS
starts the proxy with `build --listen=-`. Saving that `build.zig` in the editor
also makes ZLS reload the graph. To pick up changes to `BUILD.bazel` or
`MODULE.bazel`, save `build.zig` or restart ZLS. Each load runs the Bazel printer
again. ZLS uses `build.zig` to find the project, and the proxy loads the build
graph from Bazel.

## Which Zig commands does the proxy handle?

- `zig env` queries the real SDK and returns the proxy's path in `zig_exe` so
  ZLS sends later commands through the proxy.
- `zig build --listen=-` queries Bazel and serves the module configuration.
- Other non-build commands, such as compiler queries, run the real SDK and
  preserve its output and exit status.

The proxy accepts exactly `zig build --listen=-` for metadata requests. ZLS
can append `build_on_save_args` when build-on-save is enabled. The proxy rejects
those extra arguments because the graph comes from the selected Bazel targets.
Ignoring them could return a graph different from the one requested. Forwarding
the command to Zig would run the workspace's `build.zig`.
[Zig 0.17 launcher](zls_runner_017.zig)

## How does the printer locate generated and external files?

Bazel gives the printer the config's path relative to the execution root, such
as `bazel-out/.../zls.build_config.json`. The printer resolves the config's
runfiles path and removes that suffix. For a config under
`/cache/output-base/execroot/_main/bazel-out/...`, this gives
`/cache/output-base/execroot/_main`. Generated and external sources are resolved
against the output tree that contains the config. A separate
`bazel info execution_root` could select a different output base if its startup
options differ. The printer also canonicalizes paths so imports and documents
opened by the editor can refer to the same file.
[Workspace printer](workspace_printer.zig)

## What does the binary protocol service do?

The BSP library builds a `std.Build` graph from the printer's JSON and uses the
selected SDK to write a temporary binary configuration. Synthetic object steps
make the selected roots visible to the serializer. The service sends the
protocol handshake and the configuration path, then acknowledges ZLS's empty
build round. The file stays available until ZLS sends an exit request or closes
the connection.

The service rejects requests to execute build steps or watch files. Run
application builds through Bazel. A failed Bazel command or invalid module
graph is reported to ZLS as a configuration failure. [BSP library](zls_bsp.zig)

## Cancellation and cleanup: the process owner

[`owned_process.zig`](owned_process.zig) supervises the child processes used
by the outer runner, compiler proxy and metadata service. Each child starts in
a dedicated process group. Cleanup also reaches helpers remaining in that
group after the child exits.

While a Bazel query is running, the service still observes cancellation,
connection closure and ZLS's exit request. The process owner stops the owned
group, escalates termination if needed, and waits for the child to be reaped.
The surrounding runner/service then removes its temporary configuration files.
The outer runner gives inner helpers time to perform this cleanup when the
whole ZLS session ends. Shared Bazel daemons are outside this ownership.

## Platform and configuration support

The 0.17 integration supports Linux and macOS and one selected Bazel
configuration. Existing ZLS limitations around external-document association
and conflicting module contexts still apply. See the
[setup instructions](../../README.md#zls) for editor configuration.
