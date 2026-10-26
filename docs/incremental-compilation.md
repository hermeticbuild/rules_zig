# Experimental incremental compilation

Enable incremental compilation for existing `zig_binary` targets:

```sh
bazel build --@rules_zig//zig/settings:incremental //app:app
```

The default remains ordinary compilation. Libraries, tests, documentation actions,
and execution tools retain their existing compilation paths. A binary's imported
Zig modules participate in its retained compiler session; they do not need a
different library rule.

## Supported configurations

The initial implementation supports hermetic Zig 0.17.0, POSIX execution tools,
x86_64 Linux targets, Zig linking, and one executable output. Native dependencies,
C sources, linker options/scripts, auxiliary outputs, path toolchains, and other
compiler versions or targets are rejected for incremental binaries. The Linux
integration tests cover both generated sources and directory inputs, source
file symlinks, external repositories, and the sibling repository layout.

Downloaded SDK toolchains provide the adapter automatically. Manually declared
hermetic toolchains must supply `exec_target`, a portable SDK execution triple
such as `x86_64-linux-musl`, to enable adapter bootstrapping. The adapter is built
for baseline CPU features rather than those of the machine compiling it.

Adapter-owned controls are reserved: compiler server mode, incremental mode, SDK
and cache directories, compilation naming, build root, response files, and output
selection. Conflicting `zigopts` fail with a diagnostic. Other compiler arguments
retain their original order. Invalid options or options that undermine Bazel's
declared input/output model are not a supported interface.

The adapter uses a single compiler response file to preserve argument ordering.
Zig 0.17 cannot represent apostrophes in that format; compilations containing them
use direct arguments and are subject to the operating system's argv size limit.

## Execution and retained state

Bazel workers are normally selected automatically. They can also be selected
explicitly:

```sh
bazel build --@rules_zig//zig/settings:incremental \
  --strategy=ZigIncrementalCompile=worker //app:app
```

Each worker retains one Zig compiler session. Changing its compilation options
or building a different executable replaces that session. Bazel's worker pool
can start several workers, so resource use and target scheduling affect how
often a warm compiler is available. `--worker_max_instances=ZigIncrementalCompile=1`
is useful when evaluating a single binary; it is not a universal performance
recommendation.

The adapter stages current declared inputs in a private `/tmp` directory. Changed
Bazel input digests cause atomic file replacement, including when timestamps and
file sizes match. Changes to the set of input files, including directory members,
replace the compiler session and its filesystem view. This also handles files
changing into directories or vice versa. Zig's reported inputs can include
historical dependencies, so retaining a session across membership changes is
deliberately deferred. Content edits with unchanged membership retain the session.
Compiler artifacts remain private; successful outputs are copied into Bazel's
declared locations so later compilations cannot mutate previously published
executables.

Ordinary compiler errors keep the session available for recovery. A broken
compiler connection is retried once with fresh state. Normal adapter EOF and
one-shot completion remove private state. Forced termination can leave temporary
directories in ordinary execution. Hardened workers have their own `/tmp`, which
Bazel removes when destroying the worker. No state is shared between worker
processes or required to survive worker destruction.

A non-worker execution strategy uses the same request contract and compiler
settings for one fresh compilation. The action currently disables remote
execution and remote caching; local action caching still applies. No-op builds
remain Bazel cache hits rather than compiler updates.

## Sandboxing

Ordinary worker sandboxing is supported. On Linux, consumers may also enable
Bazel's experimental hardened singleplex worker sandbox:

```sh
bazel build --@rules_zig//zig/settings:incremental \
  --worker_sandboxing --experimental_worker_sandbox_hardening //app:app
```

Hardening requires a host that permits Bazel's Linux sandbox namespaces and mount
operations. The integration does not require extra writable-path exceptions.
Multiplex workers are not advertised.

## Current limitations

The largest measured savings are warm edits to an existing compiler session.
Cold builds still construct semantic state, and several executable targets can
evict each other's sessions. Compiler memory remains live between builds. The
development probe records representative costs for its synthetic workload;
application performance should be measured separately.

Unstripped debug information contains absolute compiler input paths. Ordinary
sandboxed Zig actions already contain transient sandbox paths; incremental
actions contain private staged paths instead. Debuggers may require source-path
substitution. This implementation does not promise byte-identical executables
across compilation histories, worker restarts, or execution strategies, and it
does not rewrite DWARF. General compiler-side debug-prefix mapping and broader
artifact reproducibility remain follow-up work.

The compiler protocol is internal to Zig and admitted only for the tested SDK
version. Additional compiler versions, native targets, remote-worker support,
other rule kinds, and auxiliary outputs require separate compatibility work.
