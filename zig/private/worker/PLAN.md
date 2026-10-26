# Upstream incremental compilation plan

## Contract

A successful action publishes an independent executable for its current declared
inputs, compiler, environment, and options. Removing retained state changes only
performance. Bazel owns action invalidation; Zig owns semantic incremental work.

## Accepted scope

- Existing `zig_binary`, opt-in `//zig/settings:incremental`; default unchanged.
- Hermetic Zig 0.17.0, x86_64 Linux target, Zig linking, one executable output.
- Singleplex JSON worker with one bounded active compiler session.
- Adapter-owned protocol, cache, SDK, naming, and output controls are reserved.
  Conflicting `zigopts` fail clearly; arbitrary invalid compiler usage is outside
  the contract. Semantic compiler arguments retain their original order.
- Local execution; remote caching disabled pending artifact equivalence work.
- Ordinary, sandboxed, and hardened Linux worker execution; one-shot fallback
  consumes the same compilation request and uses the same compiler settings.
- Other rule kinds continue using their ordinary compilation paths. Unsupported
  binary configurations fail explicitly when incremental mode is requested.

## Implementation sequence

1. **Request and bootstrap boundary.** Toolchain builds the native adapter directly
   with its SDK, without recursively invoking an incremental Zig rule. Starlark
   emits versioned output metadata separately from ordered compiler arguments.
   Remove compiler-option stripping and the private parallel binary rule.
2. **State and compiler lifecycle.** Unique worker temporary directory, no Bazel
   parent traversal. Stage digest changes with atomic replacement; restart when
   input membership changes. Handle external repositories, generated files,
   directory inputs, and ordinary source file symlinks. Capture compiler stderr
   per action, retain normal compile-error recovery, and reset unknown or broken
   compiler state.
3. **Integration and observable behavior.** Test the real public rule and generated
   actions, opt-out behavior, reserved flags, bootstrap, configuration replacement,
   source and embed edits, missing inputs, immutable publication, compiler restart,
   and one-shot execution. Inspect artifacts and source/debug paths; correct path
   mapping or bound supported configurations where needed.
4. **Sandbox matrix.** On Linux, test unsandboxed workers, `--worker_sandboxing`,
   and `--worker_sandboxing --experimental_worker_sandbox_hardening`. Establish
   actual hardening, compiler inheritance, warm reuse through cleanup, write
   restrictions, and worker teardown. Do not require broad writable exceptions.
5. **Closeout.** Run relevant analysis, formatting, ordinary regression, and Linux
   integration checks. Review only the implemented change. Record exact evidence,
   unsupported cases, and remaining performance questions. Update feature docs;
   ask before changing README files as required by repository instructions.

## Acceptance evidence

Regression cases must demonstrate the old boundary's failure where practical and
the new observable result. Passing builds alone are insufficient: execute edited
programs, inspect emitted actions, verify session reuse, compare saved outputs,
and inspect actual sandbox processes. Retained-state loss and configuration changes
must never yield stale successes. Metadata-preserving tests explicitly provide
changed Bazel input digests; they cannot repair Bazel failing to detect an edit.

## Deferred, not prerequisites

Multiplexing, target-affinity/LRU optimization, remote worker locality, macOS and
Windows, native dependencies, libraries/tests/auxiliary outputs, additional Zig
protocol versions, and remote-cache eligibility. Measure representative multiple
target workloads before expanding session policy; synthetic results already
justify implementing the narrow supported mode.

## Progress

- [x] Prototype mechanism and benchmark; investigate established workers.
- [x] Decide request ownership and hardened-worker compatibility requirements.
- [x] Replace request/bootstrap boundary and expose the public opt-in.
- [x] Replace storage and complete lifecycle/input behavior.
- [x] Add and run contract tests and sandbox matrix.
- [x] Review changes and record upstream readiness accurately.

## Final implementation decisions

- **No request reconstruction or flag stripping.** The action owner writes schema-1
  metadata, separate ordered global/module argument files, and an input manifest.
  The adapter rejects reserved controls instead of interpreting or deleting them.
  Singleplex JSON and one-shot execution consume this same contract.
- **Portable bootstrap.** The selected SDK compiles the adapter directly, using
  an explicit execution target and baseline CPU features. This avoids recursive
  toolchain resolution and machine-specific worker binaries in shared caches.
  Downloaded toolchains provide the execution triple; custom hermetic toolchains
  can supply the optional `exec_target` attribute.
- **Argument representation.** Zig 0.17 consumes direct argv before response
  contents and retains only the last response iterator. Use one response file
  for the whole semantic vector. Its parser cannot represent apostrophes, so
  those compilations use the whole direct vector, preserving order but accepting
  OS argv limits. Encoding is tested against Zig's actual parser, including
  empty tokens, quotes, and backslashes.
- **Private state.** An exclusive mode-0700 directory under `/tmp` holds staged
  sources, compiler state, and stderr. No dependency on Bazel's worker directory
  naming or parent traversal. Logical SDK tool paths remain available; separately
  declared source file aliases into the SDK are copied as ordinary inputs.
- **Input membership tradeoff.** Content edits use Bazel digests and atomic copies.
  Added/removed leaves or file/directory transitions replace the session before
  mutation. A real compiler probe showed historical dependency paths surviving
  an update after membership changed; restarting avoids stale filesystem entries
  and false undeclared-input failures. This sacrifices reuse on membership edits
  while preserving the common content-edit case.
- **Bounded retention and publication.** One active compiler per worker; options,
  output identity, or input membership replace it. Broken transport retries once;
  ordinary compile errors can recover in place. Publication copies the private
  executable rather than hard-linking it. Normal EOF/one-shot cleanup removes
  private state; forced termination may leave ordinary `/tmp` debris. Hardened
  worker temporary storage belongs to Bazel's sandbox lifecycle.
- **Artifact limits remain explicit.** No remote execution/cache admission, no
  byte-equivalence claim across histories, and no DWARF rewriting. Both ordinary
  sandboxed Zig and incremental actions were observed embedding temporary source
  paths when unstripped. Native macOS/Windows targets, native dependencies, extra
  outputs, and additional protocol versions remain excluded.

## Recorded checks

Linux verification used Bazel 9.2.0 and hermetic Zig 0.17.0. The Linux checkout
was a file snapshot of this branch; the original prototype snapshot was retained
separately for the hardened-storage reproduction.

```sh
bazel test --config=remote-cache --test_tag_filters=-requires-network \
  //zig/tests/... //docs/... //util:buildifier.check
bazel test --config=remote-cache --test_output=errors \
  //zig/tests/integration_tests:incremental_tests
python3 zig/private/worker/probe.py --iterations=2
```

The native integration passed all four modes in 142.3 seconds: ordinary workers,
sandboxed workers, hardened singleplex workers, and hardened workers with sibling
repositories. It executes edited programs; checks retained compiler identity,
source/embed/generated/tree/external/file-symlink edits, file/directory transitions,
error recovery, independent saved outputs, no-op cache hits, one-shot execution,
empty arguments, reserved-option diagnostics, SDK source aliases, and compiler
termination after Bazel shutdown. Hardened checks inspect actual mount namespaces,
compiler-parent inheritance, and blocked writes outside the worker area.

The macOS regression invocation passed all 195 tests, including four action/settings
analysis tests and the compiler-parser round-trip regression. Generated toolchain
documentation, buildifier, Zig formatting, and whitespace checks passed. The
expanded Linux protocol probe passed metadata-preserving source/embed edits,
missing inputs, directory topology changes, compiler kill/restart, SDK aliases,
quoted/backslash paths, sibling repositories, and one-shot/EOF cleanup.
The existing minimal-workspace integration also passed with Bazel 8.4.1 and 9.2.0
after extending its fixture; the worker parser regression passed natively on Linux.

Final self-hosted probe (2,000 exported functions, two warm edits) measured median
Bazel elapsed time of 958.5 ms ordinary versus 99.5 ms incremental; whole-command
medians were 2162.9 versus 1802.6 ms. Retained compiler RSS was 283,588 KiB, with
308,912 KiB high-water usage. The LLVM+LLD comparison measured 1449.5 versus
557.0 ms Bazel elapsed, 2668.2 versus 2063.7 ms whole-command time, and 378,712 KiB
retained RSS. Both backend comparisons passed real output, failure/recovery,
no-op, fallback, and action-graph checks. These are synthetic mechanism checks,
not broad application or multi-target performance claims.

The original prototype failed a hardened build with `ReadOnlyFileSystem` before
compilation; the replacement passes without extra writable-path exceptions. The
test host's existing `linux-sandbox` AppArmor profile was applied when starting
the Bazel server (`aa-exec -p linux-sandbox -- bazel ...`); no host policy changed.

A sandboxed worker running on aarch64 macOS also built an x86_64 Linux ELF.
`aquery` confirmed SDK bootstrap uses `-target aarch64-macos -mcpu=baseline`;
the Linux bootstrap uses `x86_64-linux-musl`. This is a cross-compilation check,
not evidence for native macOS incremental linking.

A narrow read-only review identified and then rechecked fixes for portable CPU
selection, empty arguments, SDK aliases, and file/directory transitions. A further
review found no actionable defect in response serialization or reported-path
normalization. Execution evidence remains the checks above, not the review.

## Proposed PR description

Warm Zig edits currently discard semantic and linker state between Bazel actions.
Add opt-in incremental compilation to existing `zig_binary` targets for hermetic
Zig 0.17.0 and x86_64 Linux, preserving declared-input isolation and independent
published outputs through a singleplex worker. Support sandboxed and hardened
workers, reserve adapter-owned options explicitly, and document the initial
configuration and artifact limitations.
