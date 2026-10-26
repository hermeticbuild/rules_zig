# Incremental worker investigation

The experiment below established whether Bazel can retain Zig compiler state
across source edits while preserving Bazel's action boundary. Its original
private rule, option stripping, and storage layout have since been replaced.
See [PLAN.md](PLAN.md) for the upstream implementation plan and
[the feature documentation](../../../docs/incremental-compilation.md) for the
current interface and supported configurations. Measurements below describe the
original prototype, not additional application performance guarantees.

## Contract and ownership

A successful request must publish an executable for the current declared inputs
and compilation settings. Previous requests must not supply undeclared sources,
and future requests must not mutate an already published executable. Discarding
the worker must affect performance rather than the program's behavior.

Bazel still owns dependency scheduling, action invalidation, outputs, and tests.
Zig owns semantic dependency tracking and incremental code generation/linking.
The adapter connects these two boundaries; splitting source modules into object
actions would change Zig's compilation model rather than preserve it.

Current rules_zig starts `zig build-exe` afresh. Its shared disk cache preserves
lowered source files and compiler support artifacts, but does not retain the
semantic dependency graph or linker state. The prototype keeps
`zig build-exe -fincremental --listen=-` alive and sends compiler `update`
messages for Bazel worker requests. It does not start a filesystem watcher or
invoke `zig build`.

Sources: Zig 0.17.0, commit `7647adab80dd088f4de3610fd245915a912eb6ad`,
[`src/main.zig`](https://codeberg.org/ziglang/zig/src/tag/0.17.0/src/main.zig),
[`lib/std/zig/Client.zig`](https://codeberg.org/ziglang/zig/src/tag/0.17.0/lib/std/zig/Client.zig),
[`lib/std/zig/Server.zig`](https://codeberg.org/ziglang/zig/src/tag/0.17.0/lib/std/zig/Server.zig),
and [`lib/compiler/Maker/Step.zig`](https://codeberg.org/ziglang/zig/src/tag/0.17.0/lib/compiler/Maker/Step.zig).
This is the internal **compiler** protocol, not the newer build-system protocol.

## Prototype boundary

- Hermetic Zig 0.17.0, x86_64 Linux targets, one executable output.
- Private `zig_incremental_binary`; public rules and settings retain their defaults.
- Source modules and embedded files; native dependencies and auxiliary outputs
  are rejected by the rule. Arbitrary advanced `zigopts` combinations are not
  a supported interface.
- Singleplex JSON Bazel protocol, one active compilation session per worker.
  Changing the output path or compiler arguments replaces that session.
- SDK executable and library directory are declared worker tools. The SDK remains
  read-only; source inputs are copied into the session's stable directory.
- Changed digests cause atomic file replacement, even if size and mtime match.
  Missing inputs are removed. Successful compiler updates are checked for
  undeclared cwd inputs before publication.
- Zig rejects explicit output paths in compiler-server mode. The adapter copies
  the completed cache artifact atomically into the declared Bazel output. It
  never hard-links a mutable compiler artifact into Bazel's output tree.
- Compiler error bundles become failed requests while retaining the compiler.
  A broken compiler connection gets one retry with a fresh session.
- A normal, non-worker invocation executes a fresh compiler. Remote execution
  and remote caching are disabled for the experimental compile action.

Local compiler state is per session. A separate worker-owned global cache allows
SDK/runtime work to survive session replacement. State lives above the input
directory traversal performed by Bazel 9.2's `WorkerExecRoot`; this relies on
Bazel's current worker directory layout and requires a better explicit contract
before upstreaming. Normal worker exit cleans up; forced termination may leave
state for `bazel clean` to reclaim.

Native macOS is deliberately excluded. On the tested 0.17.0 SDK, the new Mach-O
linker panicked while loading an archive. Selecting the legacy linker allowed an
initial build but failed on a subsequent update with an invalid cstring section.
Neither workaround establishes working incremental macOS support.

## Reproduction

On x86_64 Linux, from the checkout:

```sh
python3 zig/private/worker/probe.py --iterations=5 --report=/tmp/zig-worker-self-hosted.json
python3 zig/private/worker/probe.py --iterations=5 --backend=llvm --report=/tmp/zig-worker-llvm.json
```

Python is only the development probe driver, using its standard library. The
Bazel action uses the compiled Zig adapter and adds no runtime dependency.
The driver generates a temporary package without editing tracked source files.
Its Bazel commands use the repository's remote cache configuration with local
execution; the experimental action itself bypasses that remote cache.

The direct protocol probe executes real generated programs and checks:

- Same-size, metadata-preserving source edits with changed input digests.
- Published output independence after subsequent compilation.
- Compile errors and recovery, input removal despite the file still existing in
  the caller's directory, configuration changes, compiler crashes and restart.
- Metadata-preserving `@embedFile` changes.

The Bazel probe compares ordinary and incremental binary rules sharing a source
module, executes each edited result, checks failure/recovery and no-op builds,
exercises the ordinary sandboxed fallback, and inspects the generated action.
The benchmark has 2,000 exported functions, Debug mode, the repository's default
strip setting, four compiler threads, and five measured edits after warming.
It reports both subprocess wall time and Bazel's own elapsed time; the former
also includes client startup and command completion overhead.

Bazel must first notice an edit and supply a changed digest. Preserving file
metadata can defeat Bazel's own source change detection even for ordinary
actions; that is outside the adapter's contract. Thus the protocol probe sends
changed digests explicitly, while the Bazel probe uses ordinary file edits.

Measurements on `9985wx-5090x4`, 2026-10-26, Bazel 9.2.0 and Zig 0.17.0:

| Backend | Ordinary Bazel elapsed | Worker Bazel elapsed | Ordinary command wall | Worker command wall | Compiler peak RSS |
| --- | ---: | ---: | ---: | ---: | ---: |
| Self-hosted x86_64 | 1,001 ms | 98 ms | 2,257 ms | 1,871 ms | 294 MiB |
| LLVM + LLD | 1,473 ms | 536 ms | 2,674 ms | 1,895 ms | 326 MiB |

These are medians of five edits, not a representative application benchmark.
Worker telemetry places self-hosted warm updates around 8–9 ms, including input
preparation and output copying; those two parts individually rounded below
1 ms in the log. Client startup/completion overhead substantially reduces the
speedup visible in a complete shell command. Initial state construction and
session replacement remain cold work. No byte-for-byte equivalence claim follows
from these execution checks.

## Preferred upstream shape

Keep the current public binary, test, and library rules. Introduce an opt-in
experimental compilation setting only after the supported compiler combinations
and fallback behavior are defined; users should not need a second family of
rules to benefit from incremental compilation.

Centralize compilation action construction and make the execution toolchain own
the adapter and compatible compiler. Bootstrap the adapter through a deliberate
one-shot compilation path so that enabling workers cannot make the adapter
depend recursively on itself.

Pass explicit adapter metadata for compiler identity, compilation kind, and
output mappings alongside the existing ordered compiler arguments. Preserve those
arguments rather than reconstructing Zig's module graph or duplicating its option
parser. Reserve adapter-owned protocol, incremental-mode, SDK, cache, and output
controls; conflicting `zigopts` are unsupported and should produce a clear error,
not be silently stripped. Do not accommodate combinations that violate the rule's
declared action contract. Persistent and one-shot execution must consume the same
request contract. Keep Bazel's ordinary action identity separate from the identity
of a mutable incremental session.

Build bounded session management behind that adapter, independently of the
public rules. Measure a per-target session pool before choosing multiplexing;
one active session proves the mechanism but performs poorly if many final
targets repeatedly evict one another. Preserve the immutable output-publication
boundary in every execution mode.

## Worker sandbox compatibility

Include three execution modes in the initial Linux compatibility plan:
unsandboxed singleplex workers, ordinary worker sandboxing, and hardened worker
sandboxing with `--worker_sandboxing --experimental_worker_sandbox_hardening`.
Hardening is selected by Bazel, not a new rules_zig worker protocol capability.
Keep enabling it under the consuming workspace's control.

Bazel 9.2 has an explicit hardened-worker integration test that also compiles and
runs Java code through rules_java. This establishes a concrete precedent beyond
the synthetic example worker. The inspected Swift, Kotlin, and Scala rulesets did
not provide explicit hardening test configurations; ordinary worker sandboxing
alone does not establish hardened compatibility.

Sources: [Bazel integration test variants](https://github.com/bazelbuild/bazel/blob/9.2.0/src/test/shell/integration/BUILD#L592),
[Java worker integration scenarios](https://github.com/bazelbuild/bazel/blob/9.2.0/src/test/shell/integration/bazel_worker_test.sh#L91),
and [worker construction](https://github.com/bazelbuild/bazel/blob/9.2.0/src/main/java/com/google/devtools/build/lib/worker/WorkerFactory.java#L96).

Replace the prototype's parent-directory traversal with a deliberate temporary
storage policy. In hardened singleplex mode Bazel provides a private `/tmp` that
persists for the worker lifetime and is removed when Bazel destroys the worker.
A unique directory in that namespace is a candidate for retained state; verify
temporary-directory selection rather than assuming an inherited `TMPDIR` points
there. Ordinary workers still need explicit cleanup and crash-debris handling.
Do not require broad writable-path exceptions to make the integration work.
See [Bazel's hardened worker lifecycle](https://github.com/bazelbuild/bazel/blob/9.2.0/src/main/java/com/google/devtools/build/lib/worker/SandboxedWorker.java).

Acceptance checks must establish that hardening actually ran, that the compiler
subprocess remains inside it, and that changed inputs, failure recovery, session
replacement, and immutable output publication still work. Warm edits must retain
the same compiler and useful state across request cleanup. Check the expected
write restrictions and worker teardown as well as successful compilation.
These checks are planned, not demonstrated by the existing prototype.

## Upstream design questions

The integration is feasible. An upstream implementation needs more than enabling
the worker strategy:

1. **Execution state and paths.** Establish a supported worker-owned state
   directory and a declared-input view compatible with sandboxing, tree inputs,
   symlinks, generated sources, external repositories, and sibling layouts.
   Preserve useful source paths in diagnostics and debug information.
2. **Compilation identity and resource policy.** Keep bounded sessions per
   compatible configured action, with toolchain identity, relevant environment,
   module topology, and options included. Source contents may change without
   changing session identity. Decide eviction, target affinity, multiplexing,
   CPU allocation, cancellation, and compiler subprocess lifetime together.
3. **Artifacts and cache policy.** Support all declared outputs, debug sidecars,
   tests, libraries, and the C++ link path. Validate executable behavior, symbols,
   debug information, and byte reproducibility across edit histories and fresh
   builds before choosing action-cache/remote-cache policy. The current probe
   proves selected observable results, not general binary equivalence.
4. **Compiler compatibility.** Version and test the internal protocol adapter
   against each admitted compiler/backend/linker combination. Do not silently
   enable compiler configurations which Zig itself does not support correctly.
   Keep a reliable fresh-compilation fallback.
5. **Native inputs and remote execution.** Establish correct invalidation for
   archives, objects, headers, linker scripts, and native compilation options
   before admitting them. Remote worker support requires executor support and
   session locality; it does not follow automatically from local worker support.

The next useful evaluation is a representative application with several final
targets, realistic comptime work, debug information, generated inputs, and edits
to shared modules. The single-session prototype cannot establish the resource
or scheduling tradeoffs of that workload. No-op builds and cold builds are
separate cases: Bazel already skips unchanged actions, and a cold worker must
first construct Zig's in-memory state.

Related existing discussion: [rules_zig #254](https://github.com/hermeticbuild/rules_zig/issues/254).
