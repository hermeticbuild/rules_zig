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

The implementation accepts hermetic Zig 0.17.x from 0.17.0 onward, including
development builds of later patches in that series. Other minor versions and
pre-release builds of 0.17.0 remain unsupported. It supports POSIX execution tools,
x86_64 Linux targets and Zig linking, or separate C/C++ linking for `zig_binary`,
`zig_test` and `zig_shared_library`. C sources, linker scripts, path toolchains,
and other compiler versions or targets are rejected for incremental compilations.
The `linkopts` attribute requires `use_cc_common_link`. With that setting, static
libraries retain their archive-compilation path. Unsupported configurations
fail explicitly; they do not silently use ordinary compilation. The Linux
integration tests cover both generated sources and directory inputs, source
file symlinks, external repositories, and the sibling repository layout.

Header-only C dependencies are supported, including automatic `c` bindings and
explicit `zig_c_library` modules. Use a registered standalone translate-c toolchain
with `--@rules_zig//zig/settings:use_standalone_translate_c` for Zig 0.17.
Translation remains an ordinary action; the worker consumes its generated Zig
sources. Header edits rerun translation and update those sources in the retained
compiler session. Native dependencies can use direct Zig linking with the
compiler limitations below, or separate C/C++ linking.

Binaries, test executables, and static libraries support both the self-hosted and
LLVM backends. Shared libraries linked by Zig require LLVM and explicit effective
`-flld`. Select LLVM with `-fllvm` or by requesting LLVM IR/bitcode output:

```sh
bazel build --@rules_zig//zig/settings:incremental \
  --@rules_zig//zig/settings:zigopt=-fllvm \
  --@rules_zig//zig/settings:zigopt=-flld //lib:shared
```

The adapter checks that selection without rewriting arguments. An unsupported
backend selection, including a later `-fno-llvm` or `-fno-lld`, fails before
starting the compiler.
Option operands are skipped when checking the backend, so an rpath named `-flld`
does not enable LLD. Versioned shared libraries (`--version`) and native compiler
flag groups remain unsupported and fail explicitly.

Zig 0.17's self-hosted incremental shared-library output failed execution in
qualification. LLVM still retains frontend state; LLD performs a full relink.

### Separate C/C++ linking

For binaries, tests and shared libraries, combine the existing settings. The
qualified LLVM path uses:

```sh
bazel build --@rules_zig//zig/settings:incremental \
  --@rules_zig//zig/settings:use_cc_common_link \
  --@rules_zig//zig/settings:zigopt=-fllvm \
  --@rules_zig//zig/settings:zigopt=-flld //app:app
```

For binaries and shared libraries, the worker incrementally compiles Zig into an
intermediate static archive. The existing ordinary `cc_common.link` action
consumes that archive and the native dependencies using the selected C/C++
toolchain. Native libraries, dependency linker flags and additional linker inputs
belong to that link action, not the worker. A native-only edit can relink without
recompiling Zig; an edit to generated bindings still updates the Zig compilation.
The final executable/shared library
and its runfiles retain their existing providers and paths.

The `linkopts` attribute is passed to the ordinary C/C++ link in its existing
order. These options do not reach the worker or test archive packaging; changing
them can relink without recompiling Zig. As in ordinary compilation,
`zig_static_library` ignores `linkopts`. Location expansion and ownership of
files referenced by options retain their existing behavior.

For `zig_test`, the worker runs `test-obj` and publishes an object plus any
requested auxiliary outputs. An ordinary Zig `build-lib` action packages that
object into an archive, then the existing `cc_common.link` action produces the
test executable. Archive packaging uses the ordinary SDK/cache configuration;
only source compilation retains compiler state. Bazel runs the tests separately.

The intermediate archive uses the selected Zig backend, including when the final
output is a shared library. The direct shared-library backend restriction above
does not apply to this archive. As with ordinary separate linking, the compilation
receives `-lc` and `-fcompiler-rt` before explicit user options. Linux execution is
qualified with LLVM+LLD and hermetic-llvm; self-hosted objects and archives have
the additional compiler limitation described below. macOS incremental targets
remain unsupported.

### Requested outputs

The existing `emit_asm`, `emit_llvm_ir`, and `emit_llvm_bc` attributes also work in
incremental mode. Their files retain the `asm`, `llvm_ir`, and `llvm_bc` output
groups. Request those groups as usual, for example:

```sh
bazel build --@rules_zig//zig/settings:incremental \
  --output_groups=+asm,+llvm_ir,+llvm_bc //lib:library
```

Static libraries may set `emit_bin = False` when another output is enabled. Such
targets expose no default archive or `CcInfo`; request the desired output group.
Binaries, tests, and shared libraries still require their primary output.

Zig selects LLVM when IR or bitcode is requested. Assembly without those outputs
requires `-fllvm` on the supported target. The adapter does not choose a backend
on the user's behalf; incompatible options fail, and a compiler that reports
success without producing a requested file causes an explicit missing-output
failure. Every requested artifact is checked before publication and copied
independently into its declared location. Changing requested output kinds or
destinations selects a different compiler session; source edits retain the session.

### Known compiler limitations

Direct Zig linking accepts native dependencies from `CcInfo`. When their selected
libraries or additional linker inputs are present, rules_zig emits an
analysis-time warning: Zig may reuse stale native inputs or retain previous link
errors. These files remain declared action inputs and the worker stages their
current contents, but it does not restart Zig when they change. Refreshing native
link state remains the selected compiler's responsibility.

On x86_64 Linux, the self-hosted linker in 0.17.0, tested 0.17.x revision
`12d9399228` and tested master revision `9da2875656` reused old archive contents
after native-only edits, even while reporting success. A subsequent Zig edit
still used the old native code. Fresh compiler sessions produced the correct
result. With 0.17.0 LLVM+LLD, native edits worked, but a retained session continued
reporting an undefined-symbol error after the library was repaired. Newer
LLVM-enabled compilers were not qualified for this recovery case.

These upstream limitations are accepted in experimental direct native linking;
rules_zig does not add restart metadata, backend fallback or a compiler-version
gate. Use `use_cc_common_link` or disable incremental compilation to avoid
retained native-link state. The warning occurs during target analysis, not on
each build request. Arbitrary files referenced only through raw options are not
discovered by this warning.

Zig 0.17.0 can produce a zero-filled `compiler_rt.o` member in incremental static
archives using its self-hosted linker, while reporting successful compilation.
The corruption occurs inside Zig before the worker publishes the archive; an
external C/C++ linker cannot repair it. See
[Zig issue 37327](https://codeberg.org/ziglang/zig/issues/37327).

Use a compiler containing the fix, backported to the `0.17.x` branch as
[`ea47555675`](https://codeberg.org/ziglang/zig/commit/ea475556756d5afbaf88d472e9b223ab2a1ca1f4).
rules_zig does not work around this bug or reject its affected configurations.
Accepting a compiler version establishes the adapter's compatibility boundary;
it does not establish that every accepted development build contains this fix.

The fixed source revision `12d9399228a41e5c4369602bfc0b51907662066f`, reporting
`0.17.1-dev.12d9399228`, was verified with the self-hosted backend through the
hardened Linux worker, retained edits, error recovery, and one-shot execution.
LLVM/shared-library qualification remains based on the released 0.17.0 SDK.

Separate C/C++ linking exposed another limitation in that fixed source compiler:
an incremental self-hosted archive for a binary contained malformed `.eh_frame`
data, rejected by hermetic-llvm's LLD with "FDE version 1 or 3 expected, but got 0".
Ordinary compilation of the same target linked successfully. The compiler-rt fix
above does not resolve this failure. A direct Zig compiler-server probe reproduces
it before the worker is involved. Incremental `test-obj` with the same fixed
self-hosted compiler also produced an object rejected with this diagnostic;
ordinary compilation of that test passed. LLVM+LLD archives and test objects
passed separate linking; rules_zig does not switch backends, disable unwind
information or introduce a compiler-version rejection to work around this problem.

## Compiler invocation

For `zig_test`, the worker compiles with `zig test --test-no-exec`, or
`zig test-obj --test-no-exec` when `use_cc_common_link` is enabled. Bazel executes
the resulting test executable in its normal, separate test action. The worker
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
selection. For libraries and test objects, `-static` and `-dynamic` are also
adapter-owned.
Conflicting `zigopts` fail with a diagnostic. These checks distinguish switches
from their values: `--test-filter --cache-dir` uses `--cache-dir` as filter text,
while an actual `--cache-dir` switch remains rejected. Other compiler arguments
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
metadata listing output kinds, their corresponding output paths, ordered compiler
arguments, and the declared input paths. The private format has no version
negotiation or legacy decoding; its
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
additional output kinds beyond binary, assembly, LLVM IR, and bitcode require
separate compatibility work.
