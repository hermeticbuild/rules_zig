# Experimental incremental compilation

Enable incremental compilation for existing compilation rules:

```sh
bazel build --@rules_zig//zig/settings:incremental //app:app
```

The default remains ordinary compilation. The setting applies to `zig_binary`,
`zig_test`, `zig_static_library`, and `zig_shared_library`. A compilation's imported
Zig modules participate in its retained compiler session; source-only `zig_library`
targets do not need a different rule. Documentation, `translate-c`, and execution
tools retain their existing paths.

## Supported configurations

Incremental execution is verified with Bazel 9.2.0. Bazel 8.4.1 crashes in its
worker-file hashing when using the SDK directory as a worker tool; this also
affects the earlier toolchain-built adapter. Ordinary compilation is unaffected.

The initial implementation supports hermetic Zig 0.17.0, POSIX execution tools,
x86_64 Linux targets, Zig linking, and one primary output. Native dependencies,
C sources, linker options/scripts, auxiliary outputs, path toolchains, and other
compiler versions or targets are rejected for incremental compilations. Static
libraries require `emit_bin = True`; C/C++ linking and test-object pipelines using
`use_cc_common_link` are unsupported. Unsupported configurations fail explicitly;
they do not silently use ordinary compilation. The Linux integration tests
cover both generated sources and directory inputs, source
file symlinks, external repositories, and the sibling repository layout.

Binaries, test executables, and static libraries support both the self-hosted and
LLVM backends. Shared libraries require explicit effective `-fllvm` and `-flld`:

```sh
bazel build --@rules_zig//zig/settings:incremental \
  --@rules_zig//zig/settings:zigopt=-fllvm \
  --@rules_zig//zig/settings:zigopt=-flld //lib:shared
```

The adapter checks those switches without rewriting arguments. Missing flags,
or a later `-fno-llvm` or `-fno-lld`, fail before starting the compiler.
Option operands are skipped when checking the backend, so an rpath named `-flld`
does not enable LLD. Versioned shared libraries (`--version`) and native compiler
flag groups remain unsupported and fail explicitly.

Zig 0.17's self-hosted incremental shared-library output failed execution in
qualification. LLVM still retains frontend state; LLD performs a full relink.

For `zig_test`, the worker compiles with `zig test --test-no-exec`. Bazel executes
the published test executable in its normal, separate test action. The worker
does not execute tests through Zig's compiler-server protocol.

The adapter is an ordinary `zig_binary`, built automatically for the Zig action's
execution platform using the registered SDK and target toolchains. A private
configuration transition disables incremental compilation for that binary; its
configured worker dependency then resolves to an empty target, breaking the
dependency cycle during analysis. The transition wrapper exposes the executable
through a symlink. Ordinary builds have no dependency on the adapter binary.
The adapter uses the normal execution-tool build settings and explicit baseline
CPU features. Custom hermetic SDK toolchains need no worker-specific attributes.

Adapter-owned controls are reserved: compiler server mode, incremental mode, SDK
and cache directories, compilation naming, build root, response files, and output
selection. For libraries, `-static` and `-dynamic` are also adapter-owned.
Conflicting `zigopts` fail with a diagnostic. Other compiler arguments
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

Each worker retains one Zig compiler session by default. Changing its compilation
options or building a different output replaces that session. Bazel's worker pool
can start several workers, so resource use and target scheduling affect how
often a warm compiler is available. `--worker_max_instances=ZigIncrementalCompile=1`
is useful when evaluating a single binary; it is not a universal performance
recommendation.

For builds that alternate between several targets, a worker can retain a bounded
number of sessions:

```sh
bazel build --@rules_zig//zig/settings:incremental \
  --worker_extra_flag=ZigIncrementalCompile=--max-sessions=2 //app:app
```

The limit counts active and idle compilers together. When full, the worker stops
the least recently used compiler and removes its staged inputs and local cache.
Its global cache remains private to the worker. Every reused session still checks
the current request's inputs before compiling. This trades additional memory and
disk space for reuse across outputs; the default stays at one. The bound applies
per worker, not to the entire build. Bazel can create several workers and does not
guarantee that a target returns to the same one. Changing startup flags can also
leave a different worker pool alive until Bazel evicts it or shuts down.

Direct and incremental compilations share action declaration and semantic argument
construction. Incremental actions use one automatic parameter file containing
metadata, the output path, ordered compiler arguments, and the declared input
paths. The private format has no version negotiation or legacy decoding; its
producer and adapter ship together. The same request is used for persistent and
one-shot execution. The adapter does not reconstruct commands by stripping compiler
options. Missing input digests conservatively cause a fresh copy; they never imply
unchanged contents.

Paths supplied as artifacts remain File-aware until the action expands its
arguments. This removes the separate argument/manifest write actions, but does
not advertise `supports-path-mapping`: location-expanded compiler options and
Bazel's worker input-path namespace still need complete qualification.

The adapter stages current declared inputs in a private `/tmp` directory. Changed
Bazel input digests cause atomic file replacement, including when timestamps and
file sizes match. Changes to the set of input files, including directory members,
replace the compiler session and its filesystem view. This also handles files
changing into directories or vice versa. Zig's reported inputs can include
historical dependencies, so retaining a session across membership changes is
deliberately deferred. Content edits with unchanged membership retain the session.
Compiler artifacts remain private; successful outputs are copied into Bazel's
declared locations so later compilations cannot mutate previously published
artifacts. Static libraries retain their normal `CcInfo` exports; shared libraries
retain their configured filename and matching SONAME.

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
Cold builds still construct semantic state, and several compilation targets can
evict each other's sessions. Compiler memory remains live between builds. The
development probe records representative costs for its synthetic workload;
application performance should be measured separately.

Unstripped debug information contains absolute compiler input paths. Ordinary
sandboxed Zig actions already contain transient sandbox paths; incremental
actions contain private staged paths instead. Debuggers may require source-path
substitution. This implementation does not promise byte-identical artifacts
across compilation histories, worker restarts, or execution strategies, and it
does not rewrite DWARF. General compiler-side debug-prefix mapping and broader
artifact reproducibility remain follow-up work.

The compiler protocol is internal to Zig and admitted only for the tested SDK
version. Additional compiler versions, native targets, remote-worker support,
additional output kinds, and auxiliary outputs require separate compatibility work.
