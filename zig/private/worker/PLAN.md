# Upstream incremental compilation plan

## Current rewrite plan (2026-10-29)

This section governs the remaining rewrite. The sections below it record the
earlier committed implementation and its evidence; they do not authorize further
extensions. The previous uncommitted extension patch was rejected for excessive
refactoring, unexplained provider changes, lost comments, and poor reviewability.
Its feature goals remain candidates, but its implementation is not the template.

### Checkpoint and preserved work

- Branch: `cerisier/zig-incremental-prototype`.
- Accepted starting point: `33c39ba` (`build the incremental worker with zig_binary`).
- The rejected patch is saved in stash commit
  `cc5e05cce6db85752b938c90d383f88f4ce529f4`, currently `stash@{0}`, named
  `incremental worker extensions before agreed small-commit reimplementation`.
  All 43 changed paths, including untracked fixtures and deletions, were verified
  against the saved snapshot. Stash indices can change; use the commit to identify
  it. Preserve this stash until the rewrite is finished or its removal is agreed.
- The `forward_executable` extraction was undone before stashing. Forwarding stays
  local to each rule, with the original implementation and comments.
- Reimplement from the committed branch. Consult the stash for findings and
  reproductions; do not apply the whole patch back onto the branch.

### Working agreement

1. Discuss each remaining item before implementing it. Corentin may decide that
   particular inputs or modes are not worth supporting. Record those decisions
   here instead of silently restoring the old patch's scope.
2. Before editing, explain the intended behavior, affected files, necessary code
   movement, and focused acceptance checks. Any provider or public API change
   requires its own explicit explanation and agreement.
3. Preserve comments verbatim when moving code. Explain any necessary comment
   change, especially compiler workarounds and their rationale. Keep mechanical
   moves separate from behavior changes so the diff remains easy to follow.
4. Follow surrounding formatting. Avoid incidental one-line compression,
   unnecessary small helpers, and callback-based argument builders. Duplication
   is acceptable when it makes straightforward code easier to understand.
5. Keep ordinary action behavior unchanged unless a separately agreed correctness
   fix requires otherwise. Preserve ordered compiler arguments; do not reconstruct
   them by stripping flags.
6. Present each focused diff and verification, obtain agreement, then commit it
   before starting the next item. Items 1 and 2 were explicitly authorized without
   intermediate approval. Do not accumulate another uncommitted feature stack.
   Push only when requested.
7. Update this checkpoint with decisions, commits, and any remaining uncertainty
   as work proceeds. Tests and feature documentation belong with each change;
   existing large fixtures are reference material, not mandatory imports.

### Ordered items

The order favors small independent changes first while respecting dependencies.
Pending items describe behavior to discuss, not an approved implementation.

| Item | Status | Behavior and commit boundary |
| --- | --- | --- |
| 1 | Done: `eecd8d1` | Rename the private wrapper to `non_incremental_binary`. Rename only; implementation and comments preserved. |
| 2 | Done: `0ba2f99` | Remove the private request schema field and version check. Update producer, decoder, existing fixtures and docs together. Retain required-field and structural validation; no compatibility decoder. |
| 3 | Done: `c79fe48` | Distinguish compiler switches from operands when validating options. Reuse the existing option-arity table without changing argv. Actual worker-owned flags remain rejected; their ordinary action equivalents must stay out of worker requests. |
| 4 | Deferred by agreement | Versioned shared-library cache filenames (`--version`). No demonstrated user need: rules_zig does not generate this option and already controls the published filename and SONAME. Retain the explicit unsupported diagnostic; reconsider when needed. |
| 5a | Deferred for the current Linux scope | Do not add archive indexing for gold or other GNU-linker compatibility. Qualify Linux C/C++ consumers with hermetic-llvm; direct Zig linking retains its qualified defaults. Revisit indexing only if an in-scope consumer requires it, including the Apple linker when macOS targets are qualified. |
| 5b | Closed by agreement: upstream compiler bug | No archive workaround, backend fallback or configuration-specific rejection. Document the affected 0.17.0 path and upstream fix. Allow compatible fixed toolchains by qualifying 0.17.x patch builds and relaxing both exact-version checks together. |
| 6 | Pending | Support assembly, LLVM IR and bitcode outputs, including `emit_bin=False`. Describe and publish each requested artifact; preserve output groups and backend choices. |
| 7 | Pending | Allow generated C bindings and header-only dependencies. Translation remains ordinary; its generated Zig source becomes a worker input. No provider change is needed merely to enable this feature. |
| 8 | Pending | Support `use_cc_common_link`: incremental Zig source compilation followed by the existing ordinary C/C++ link. Binary/shared-library paths first; test-object compilation and ordinary archive packaging in a follow-up commit. Account for item 5 before enabling affected archive configurations. |
| 9 | Pending | Allow ordinary scalar linker options. Preserve their consumer, ordering, and existing static-library behavior. Do not bundle location-expansion changes. |
| 10 | Design discussion required | Invalidate retained state when Zig consumes native libraries or objects. Native changes restart the compiler; Zig-only changes retain it. Agree on the supported inputs and their representation first. |
| 11 | Design discussion required | Support `csrcs`, their options and relevant included files. Extend the restart policy only after agreeing on transitive headers and `extra_srcs` handling. |
| 12 | Separate scope decision | Correct action ownership of files referenced by compiler/linker options. This affects ordinary rules too and needs its own reproduction and design. The rejected `_location_inputs` scanner is not an accepted implementation. |
| 13 | Agreed final phase | Simplify the completed implementation and minimize the worker's knowledge of Zig flags. Revisit option-arity tables and capability checks; prefer explicit action-owned metadata or compiler-provided information where appropriate. Preserve compiler argv and supported-configuration correctness; do not grow a general Zig command-line parser. |

Item 8 intentionally contains smaller commit boundaries. Do not combine
them into a large patch merely because they share a numbered item. If dependencies
require a different order, explain and agree on the adjustment before proceeding.

### Implementation choices to reconsider

- `extra_srcs` already exists. The rejected patch added `extra_inputs` to the
  module context carried by `ZigModuleInfo`, to identify transitive restart inputs.
  That provider-content change is not approved for reintroduction. Establish what
  existing data can express and discuss any required extension or conservative
  tradeoff explicitly.
- `library_files` / `library=` described selected dynamic/interface libraries for
  the new library-search validation. They are not inherently required by the
  restart mechanism. Decide whether that validation and extra representation are
  needed for the supported scope before adding them.
- `_location_inputs` attempted to turn option references into declared Files.
  The underlying ownership issue and the proposed custom scanner are separate
  questions. Do not silently change ordinary compilation or documentation actions
  as worker plumbing.
- Drop the callback design using `build_args`, `source_args`, and `archive_args`.
  The direction to discuss for item 8 is to identify the actual Zig source-stage
  command/output before constructing arguments, keep construction visible in
  `zig_build_impl`, and pass concrete arguments and inputs to the existing action
  helper. Keep test archive packaging local to its branch.
- Do not automatically restore `_global_compile_args` or other small extractions.
  Preserve the original libc/compiler-rt and StackProtector explanations. Any
  necessary movement must be visible and justified.

### Deferred scope and resume point

- Native C/C++ consumer qualification is limited to hermetic-llvm, plus the
  default Apple linker on macOS when hermetic-llvm is not used. GNU gold and
  compatibility work for other GNU linkers are outside this effort's scope.
  Consumer tests must use those selected toolchains and verify the actual link
  action instead of accidentally using a system GNU linker.
- That toolchain scope concerns C/C++ linking, including `use_cc_common_link`.
  With `use_cc_common_link=False`, Zig owns linking and its qualified Linux
  defaults remain supported. Selecting a C/C++ toolchain does not select Zig's
  internal backend. Existing per-output capability restrictions still apply.
- This toolchain scope does not qualify macOS incremental targets. The current
  x86_64 Linux target restriction remains; Apple archive/link behavior needs
  qualification when macOS target support is undertaken. Item 5a is deferred
  for the current Linux scope, not evidence that Apple needs no archive index.
- `linker_script` with `use_cc_common_link` stays unsupported; Corentin explicitly
  does not need it. Retain the corresponding restriction when enabling item 8.
- The rejected patch also implemented linker scripts for Zig linking. Deferring
  that extension is proposed; do not reintroduce it without discussion.
- Documentation and standalone translation remain ordinary actions. An ordinary
  non-incremental worker mode, wider SDK/platform support, full path mapping and
  remote execution/cache eligibility are outside this rewrite's agreed scope.
- Items 1 and 2 passed the focused checks. After item 2, all 16 focused test
  targets passed, a real persistent-worker build produced an x86-64 Linux ELF,
  and its action metadata contained only `command`, `name`, and `output_kind`.
- Item 3 remains approved and implemented. The request to minimize flag knowledge
  adds a final simplification phase; it does not withdraw this fix. Reserved
  switches remain rejected, while their use as option values is allowed.
- Item 3 evidence: the new unit regression failed before the fix, then all 16
  focused targets passed. A Linux comparison ran exactly the same selected test
  with direct Zig, the persistent worker and one-shot execution; the old worker
  rejected it. Actual reserved switches still failed without creating their
  requested destinations. The generated worker action's argv/environment stayed
  unchanged, with ordinary cache/SDK flags absent. Read-only review found no issues.
- **Resume at item 6's scope and implementation agreement.** Items 4 and 5a are
  deferred; item 5b needs no compiler workaround. There is no separate item 5c.
  Later feature extensions remain unapproved. Keeping an edge case unsupported
  is a valid outcome if explicitly agreed and recorded here.

### Item 5b: original evidence

The earlier probes recorded in the preserved patch's `CAPABILITIES.md` used Zig
0.17.0 (`7647adab80dd088f4de3610fd245915a912eb6ad`) on x86_64 Linux. These are
previous observations, not a fresh reproduction during the rewrite discussion.

- A self-hosted incremental static archive contained a 396,504-byte
  `compiler_rt.o` member filled entirely with zeros. The same bytes were present
  in Zig's private cache artifact before copying or indexing the published file.
- A direct compiler-server probe reproduced this without Bazel or the adapter:
  successive `build-lib --listen=- -fincremental -static -lc -fcompiler-rt`
  sessions, each with its own local cache and a shared global cache, compiled
  `pub export fn answer() u32 { return 41; }`. With `-fno-llvm -fno-lld`, one run
  produced one healthy runtime member followed by four zero-filled members.
  Five `-fllvm -flld` sessions produced valid ELF runtime members. Another
  self-hosted run stayed healthy, so successful retries do not resolve the issue.
- The suspected cause is deferred archive-member writes being skipped by the
  pending-input bookkeeping in Zig's `Elf2` linker. The exact cause has not been
  proved by instrumenting the compiler; the corrupt member itself was observed.
- The concrete reproduction concerns compiler-rt. Extending a restriction to
  other external members is a separate conservative choice when those inputs
  are enabled. Item 5b is not approval to disable all self-hosted compilation.

### Item 5b: upstream investigation (2026-10-30)

The requested Sol 6.1 high investigation reproduced the corruption independently
of Bazel and the adapter, then built current Zig sources and repeated the probe
on x86_64 Linux. Each compiler-server session received one update, used a unique
local cache and a shared global cache, and produced a static library containing
compiler-rt. The probe inspected the private archive before publication and
verified that its bytes stayed unchanged after the compiler exited.

| Compiler and configuration | Sessions | Zero-filled `compiler_rt.o` |
| --- | --- | --- |
| Pinned 0.17.0, incremental self-hosted | 20 | 17 |
| Pinned 0.17.0, incremental LLVM/LLD | 20 | 0 |
| Pinned 0.17.0, ordinary self-hosted | 5 | 0 |
| 0.17.x at `12d9399228a41e5c4369602bfc0b51907662066f`, incremental self-hosted | 30 | 0 |
| Master at `9da28756563d966484e79154c6ee56ca3065bfe6`, incremental self-hosted | 30 | 0 |

All compiler sessions exited successfully, including the corrupt cases. In a
separate five-session pinned-compiler run, four archives were corrupt and failed
direct Zig consumer linking with "not an ELF file"; the healthy archive linked
and ran. Five fixed-0.17.x consumers and all 30 master consumers linked and ran.
These consumer checks use Zig's self-hosted linker, not a native C/C++ toolchain.

The matching upstream bug is [Zig issue 37327](https://codeberg.org/ziglang/zig/issues/37327),
fixed by [PR 37326](https://codeberg.org/ziglang/zig/pulls/37326):

- Master fix: `f7626b95269bc3baad2c46e4d3b7acc16221c424`.
- 0.17.x backport: `ea475556756d5afbaf88d472e9b223ab2a1ca1f4`.
- `Elf2.prelinkInner` inserted a synthetic Zig input and advanced the pending
  input index even for archives, which already contain the actual Zig object.
  Depending on scheduling, this skipped writing a pending member. The fix limits
  the synthetic input and index increment to nonarchive outputs.
- The backport applies cleanly to the pinned source. No new compiler patch was
  needed. Attribution combines upstream diagnosis, source inspection and fresh
  reproduction; no instrumented or fix-only before/after compiler was built.

Local source toolchains are feasible through the file-based interface introduced
by merged [rules_zig PR 651](https://github.com/hermeticbuild/rules_zig/pull/651):
expose the executable, matching `lib` directory and `zig.h` as labels, register a
`zig_toolchain` for the bootstrap-enabled configuration, and enable the
`bootstrapped` setting. Both source-built compilers successfully built an ordinary
`zig_static_library` in a Linux Bazel sandbox; action inspection confirmed the
compiler and SDK files were declared inputs. Compilers were built outside Bazel
and exposed through a local repository. Building Zig itself inside the Bazel graph
was not tested.

Agreed follow-up: qualify a fixed 0.17.x source compiler, then update the
exact-version boundaries in `zig_build.bzl` and `worker.zig` together. Accept the
0.17 series from 0.17.0 onward, including later patch development builds; reject
pre-release 0.17.0 and other minor versions. Versions are not disguised, and the
adapter does not encode a particular local build's revision in an allowlist.
`Client.zig` and `Server.zig` are unchanged between
the pinned release and tested 0.17.x revision, making that a smaller compatibility
step than master. No fixed 0.17.1 SDK was published in the download index checked
during this investigation. The existing 0.17.0 corruption remains until a fixed
compiler is selected. Corentin chose to document that limitation, leaving the
compiler fix upstream rather than adding a configuration-specific rejection.

The initial one-update-per-session probe did not exercise the actual rules_zig
worker or retained source edits; the follow-up below covers those. A Zig compiler built by
`zig_binary` inside Bazel also needs an ordinary-compilation boundary: the current
toolchain transition resets `bootstrapped`, but not `incremental`. LLVM-enabled
source builds, hermetic-llvm consumers and macOS targets remain unqualified here.
Item 5a stays deferred; no production compiler, backend gate or provider changed.

Reproduction scripts and full report are committed in the local Zig audit branch
`cerisier/zig-archive-audit`, commits `4bfca1bf953b8078fe91abf78d1b44bd44f75c58`
and `29095e841bc9627371f48f0eb8e89133529d3495`. The report is
`tools/incremental_archive_audit.txt`; worktree:
`/Users/corentinkerisit/code/codeberg.org/ziglang/zig-archive-audit`.
Raw evidence is copied to `/tmp/zig-archive-audit-evidence-20261030` locally;
the builds and complete matrix remain under `/tmp/zig-archive-audit-9da2875656`
on `9985wx-5090x4`. Nothing was pushed or submitted upstream.

### Item 5b: fixed compiler qualification and closure (2026-10-30)

Both the Starlark action gate and worker protocol check now accept the 0.17
compiler line from 0.17.0 onward, including patch-development builds. Ordinary
compilation, compiler arguments, providers and backend selection are unchanged.
The public documentation records the compiler bug and fixing revision, with no
configuration-specific workaround or rejection.

- Before the change, the real `0.17.1-dev.12d9399228` toolchain failed analysis;
  separately, the unmodified adapter failed its first real request with
  `UnsupportedZigVersion`. Both cases pass after the change.
- `bazel test --config=remote-cache //zig/tests:incremental_test
  //zig/tests:incremental_worker_test`: all 16 focused targets pass. Full remote
  execution was unavailable for Darwin, so tests ran locally with remote caching.
- On x86_64 Linux with Bazel 9.2.0, the actual hardened persistent worker built
  binaries and static archives containing compiler-rt with the fixed compiler's
  self-hosted backend. Same-session edits changed results from 41 to 42, compile
  errors recovered to 43, and saved earlier outputs still produced 41. Archive
  consumers linked and executed with the expected results.
- No-op builds left worker logs unchanged. One-shot execution produced the edited
  result, and a real `zig_test` compiled through the worker and passed Bazel's
  separate test action. Action inspection confirmed the declared source SDK,
  `-fcompiler-rt`, and existing worker/local-execution requirements.
- The existing full protocol probe passed with the Bazel-built adapter and fixed
  SDK: metadata-preserving edits, independent published outputs, error recovery,
  input removal, compiler crash/restart, embedded/directory inputs, and one-shot
  execution. The updated adapter still rejected the real 0.18 master compiler.
- The narrowly scoped read-only review found no issues. Formatting and diff
  checks passed. No changes were pushed.

The disposable fixture, commands and logs are under
`/home/corentin/.cache/rules-zig-fixed-qualification-20261030` on `9985wx-5090x4`;
`python3 qualify.py` reruns the positive checks. Selected logs and the driver are
copied to `/tmp/rules-zig-fixed-qualification-evidence-20261030` locally. Early
fixture attempts under `/tmp` encountered sandbox path visibility/mount failures;
moving the fixture and declared SDK outside `/tmp` resolved them without changing
the worker or sandbox policy.

### Item 6: proposed commit boundaries, pending agreement

1. **Auxiliary outputs alongside the binary.** Support `emit_asm`, `emit_llvm_ir`
   and `emit_llvm_bc` through explicit action-owned output descriptions. Publish
   every requested artifact and preserve existing output groups. Leave backend
   selection to Zig; fail if the compiler does not produce a requested artifact.
2. **Auxiliary outputs without a binary.** Extend static-library compilation to
   `emit_bin=False` when another output is requested, matching the ordinary rule.
   Do not request, require or publish an archive in that case.

Keep ordinary action construction and comments in place. No provider changes,
module-argument refactoring, documentation-action support or native linking work
belong to either commit. Qualify retained edits and one-shot execution for each
output combination before declaring it supported. The previous capability audit
is a starting point for checks, not authority to restore the rejected patch.

## Contract

A successful action publishes an independent artifact for its current declared
inputs, compiler, environment, and options. Removing retained state changes only
performance. Bazel owns action invalidation; Zig owns semantic incremental work.

## Accepted scope

- Existing `zig_binary`, `zig_test`, `zig_static_library`, and `zig_shared_library`,
  opt-in `//zig/settings:incremental`; default unchanged.
- Hermetic Zig 0.17.x from 0.17.0 onward, x86_64 Linux target, Zig linking, one
  primary output. The known 0.17.0 archive corruption is an upstream limitation;
  select a compiler containing its fix.
- Binaries, test executables, and static libraries support self-hosted and LLVM
  compilation. Shared libraries require explicit effective LLVM and LLD options.
- Singleplex JSON worker, one compiler session by default, optional bounded LRU.
- Adapter-owned protocol, cache, SDK, naming, and output controls are reserved.
  Conflicting `zigopts` fail clearly; arbitrary invalid compiler usage is outside
  the contract. Semantic compiler arguments retain their original order.
- Local execution; remote caching disabled pending artifact equivalence work.
- Ordinary, sandboxed, and hardened Linux worker execution; one-shot fallback
  consumes the same compilation request and uses the same compiler settings.
- Documentation, `translate-c`, and execution tools keep their ordinary paths.
  Unsupported compilation configurations fail when incremental mode is requested.
  There is no ordinary-compilation worker mode or silent backend fallback.

## Implementation sequence

1. **Request and bootstrap boundary.** An ordinary `zig_binary` builds the adapter
   with its SDK, without recursively invoking an incremental Zig rule. Starlark
   emits output metadata separately from ordered compiler arguments.
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

Multiplexing, target-affinity scheduling, remote worker locality, macOS and
Windows, native dependencies, object pipelines/auxiliary outputs, additional Zig
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

- **No request reconstruction or flag stripping.** The action owner emits explicit
  metadata, the output File, ordered compiler arguments, and prefixed input File
  records in one automatic parameter file. The final `--` frames the input list;
  prefixed paths cannot collide with the delimiter, and empty operands survive.
  The adapter rejects reserved controls instead of interpreting or deleting them.
  Singleplex JSON and one-shot execution consume this same contract.
- **Portable bootstrap.** The adapter is an ordinary `zig_binary` dependency in
  `config.exec("zig")`. A private transition disables incremental compilation;
  the configured tool alias then selects an empty target, cutting the dependency
  cycle. Registered target toolchains supply the execution-platform triple, and
  the worker declares baseline CPU features. SDK toolchains only describe SDKs.
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
- **Bounded retention and publication.** One compiler per worker by default;
  `--worker_extra_flag=ZigIncrementalCompile=--max-sessions=N` enables a bounded
  LRU collection including the active compiler. Options and output identity select
  a session; changed input membership replaces it. Eviction stops the compiler
  and removes its private session tree. Broken transport retries once;
  ordinary compile errors can recover in place. Publication copies the private
  artifact rather than hard-linking it. Normal EOF/one-shot cleanup removes
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
Add opt-in incremental compilation to binary, test, and library rules for hermetic
Zig 0.17.0 and x86_64 Linux, preserving declared-input isolation and independent
published outputs through a singleplex worker. Reject unsupported configurations,
including self-hosted shared libraries, instead of silently compiling ordinarily.
Support sandboxed and hardened workers and document the artifact limitations.

## Compilation-kind extension

### Acceptance criteria and ownership

- With incremental enabled, all four compilation rules emit `ZigIncrementalCompile`
  or a supported-configuration error. Without it, existing actions stay unchanged.
- Tests compile with `test --test-no-exec`; Bazel retains test execution ownership.
- Pure Zig archives and LLVM+LLD shared libraries retain compiler state on content
  edits and publish independently usable outputs. Existing CcInfo, configured
  shared filenames, and SONAME behavior stay with the rule that already owns them.
- C sources/dependencies, cc_common linking (including test objects), auxiliary
  outputs, non-emitting archives, other targets, and unqualified SDKs fail.
- Documentation and translate-c are intentionally outside the incremental setting.

The shared action helper belongs in `zig_build_impl`: that layer already owns
the command, output type, SDK, and ordered module graph. It writes explicit
command/output-kind metadata rather than inferring the kind from compiler flags.
The adapter maps that metadata to server arguments and known Linux artifact names.
No semantic arguments are stripped or rebuilt.

The shared-library backend check is read-only and uses Zig 0.17's option arities
to skip operands, then checks the last LLVM and LLD switches. Native flag groups
and versioned shared-library names are explicitly rejected. The option-arity table
is a compatibility obligation when admitting another SDK protocol version; it is
not a general Zig command-line parser. Automatically forcing LLVM/LLD would hide
unsupported user choices, while accepting the self-hosted path produced an unusable
library in qualification. Supporting versioned names cleanly should use explicit
compiler artifact metadata; silently guessing another cache file is excluded.

The option-arity check was compared with Zig tag `0.17.0`, commit
`7647adab80dd088f4de3610fd245915a912eb6ad`, `src/main.zig`'s compile-command
argument loop. Artifact naming follows that SDK's `lib/std/zig.zig:binNameAlloc`.

### Baseline evidence

Before this extension, `bazel aquery --config=remote-cache --//zig/settings:incremental`
on binary-only commit `681f61d` still reported `ZigBuildTest`, `ZigBuildStaticLib`,
and `ZigBuildSharedLib` for the existing simple test and library fixtures. The
setting was silently ineffective for those rules. Action analysis now checks
their incremental command/output-kind metadata and declared request-file inputs.

Direct Zig 0.17 compiler-server probes produced updated, executable test outputs
and linkable archives with both backends. LLVM+LLD shared libraries loaded updated
exports. Self-hosted incremental shared output crashed when loaded, while ordinary
compilation of the same source/backend loaded successfully. This is a qualified
implementation boundary, not a claim about every Zig release or shared-library
configuration.

### Extension verification

The ordinary macOS regression command above passed all 206 tests, including 15
incremental action/settings checks, the compiler parser/backend checks, generated
documentation, and buildifier. The minimal consumer integration passed on Bazel
8.4.1 and 9.2.0. A final `aquery` inspected all four incremental action kinds,
their command/output-kind metadata, SDK adapter, and worker/local-only properties.

The final Linux integration passed both native tests in 326.1 seconds with Bazel
9.2.0 and Zig 0.17.0. The binary checks cover four sandbox/layout modes; test and
library checks cover ordinary, sandboxed, and hardened workers. They execute
updated passing/failing tests, assert compiler PID reuse, link and execute archive
and shared-library consumers after edits, exercise one-shot library compilation,
and verify the custom shared filename/SONAME through loading. Negative cases check
missing/overridden backends, backend-looking rpath operands, versioned shared
artifacts, and ARM targets; a final real `bazel test` verifies test execution.
Read-only review found the versioned-name and operand-scanning boundaries; both
were fixed and rechecked against the pinned source before this final execution.

The consumer fixture declares its own ARM platform and direct `platforms`
dependency. Referencing the ruleset's test platforms from a consumer reproduced
an unavailable development-only `bazel_features` dependency; declaring a consumer
platform without a direct `platforms` dependency reproduced another repository
mapping error. Both were fixture issues, distinct from the production target gate.
Keep consumer-platform fixtures self-contained rather than relying on root-module
development repositories.

## Shared-action cleanup and bounded retention (2026-10-28)

### Contract and implementation

One compilation helper now owns action registration for both execution paths.
Ordinary compilation keeps its executable, arguments, and environment. Incremental
compilation selects the adapter and supplies one automatic parameter file containing
metadata, a File-valued output, ordered compiler arguments, and File-valued
input records. The adapter uses the same request parser and execution logic for
persistent and one-shot operation; it neither reconstructs nor strips compiler
arguments. Module roots remain Files until argument expansion, including the ZLS
consumer's explicit conversion to paths.

Action-owned input records define membership; worker-protocol digests only optimize
copying those inputs. A missing digest forces copying. This separates authority
from the optional optimization and avoids depending on Bazel's current mismatch
between mapped arguments and unmapped worker input paths. Full path-mapping support
is still not advertised: location-expanded string options remain unqualified.

Session retention defaults to one compiler. The startup option `--max-sessions=N`
opts into a bounded LRU per worker; eviction terminates the compiler and removes
its private session directory. Private global cache ownership, staged inputs,
independent published outputs, and sandbox boundaries remain unchanged. A larger
default or an unbounded worker key per output would impose an unmeasured memory
cost. Bazel does not guarantee target affinity across worker processes.

### Qualification

- Compared ordinary action graphs before and after: all 207 compilation commands
  and environments were identical. Inspected the incremental action graph for
  request metadata, declared inputs, and execution requirements.
- Broad macOS regression: 206 tests passed. After the final helper simplification,
  all 17 focused checks passed and ordinary action equivalence was rechecked.
- Minimal consumer integration passed on Bazel 8.4.1 and 9.2.0.
- Native Linux integration: all three tests passed in 311.6 seconds, covering
  existing compilation kinds/sandbox modes, empty one-shot arguments, and bounded
  A/B/A/C/B retention with compiler reuse and eviction. Hardened execution used
  the host's existing `linux-sandbox` AppArmor profile.
- The standalone protocol probe passed metadata-preserving edits, independent
  outputs, error recovery, removed inputs, configuration changes, compiler crash
  recovery, embed edits, directory topology changes, empty/quoted arguments, SDK
  aliases, sibling repositories, and the one-shot contract.
- A forced path-mapping consumer with generated Zig sources built successfully
  using `--experimental_output_paths=strip` and an explicit
  `+supports-path-mapping` execution-info override. This was a macOS-to-Linux
  cross-compilation check, not full path-mapping qualification.
- Buildifier, Zig formatting, and whitespace checks passed. A narrow read-only
  review found a probe telemetry attribution issue; per-log deltas and worker-key
  filtering fixed it, and the follow-up review found no remaining issue.

The final synthetic retention probe alternated two outputs with 2,000 exported
functions and three rounds of edits. With one session, every switch restarted
Zig: warm median Bazel elapsed time was 312 ms, with one compiler using 123,796 KiB
RSS at the final sample. With two sessions, both compiler generations were reused:
warm median was 125 ms, compiler updates took 7 ms, and two compilers used a combined
385,856 KiB RSS at the final sample. The unmodified baseline's warm median was
319.5 ms. These short synthetic runs demonstrate reuse and its memory tradeoff;
they do not predict application-wide performance. The probe excludes old worker
pools created with different session limits from its process measurements.

### Cleanup PR description

Share direct and incremental Zig compilation action construction and carry worker
requests in one automatic parameter file, preserving ordinary command lines and
sandboxed input isolation. Add opt-in bounded compiler-session retention so
alternating targets can reuse Zig state without an unbounded worker per output.

## Ordinary worker binary (2026-10-28)

### Ownership and acceptance criteria

The worker must use the existing `zig_binary` implementation, target the Zig
execution platform, and have no recursive worker dependency. Disabling
incremental compilation must remove the worker binary from the dependency graph.
SDK toolchains must not compile the adapter or require worker-specific attributes.
Ordinary compilation commands and existing incremental execution behavior must
remain unchanged.

The old `ZigWorkerBootstrap` action was already in Bazel's graph, but belonged to
the SDK toolchain and duplicated command construction. An ordinary binary inside
that toolchain would create a toolchain-to-binary-to-toolchain cycle. Moving the
worker dependency to compilation rules makes it possible to cut the remaining
binary-to-worker cycle through configuration instead.

The execution-tool edge follows Bazel's documented
[`config.exec` association with named execution groups](https://bazel.build/extending/exec-groups#defining-execution-groups).

Compilation rules now depend on `//zig/private/worker:tool` through
`config.exec("zig")`. Its alias selects an empty filegroup when incremental mode
is off. Otherwise it selects a private wrapper whose incoming transition sets
`//zig/settings:incremental` to false before analyzing the ordinary worker
`zig_binary`. That binary's own tool alias therefore resolves to the empty target.
This removes the dependency edge; merely skipping a worker action at execution
time would not break an analysis cycle.

The wrapper creates an executable symlink and forwards the binary's runfiles.
Bazel requires an executable forwarding rule to own its executable artifact;
returning the dependency's `DefaultInfo` directly failed analysis. Compilation
still belongs entirely to `zig_binary`, and `ctx.actions.run` receives the
wrapper's `FilesToRunProvider` so sandboxed execution includes its runfiles.
The SDK toolchain loses `exec_target`, `_worker_sources`, the worker provider
field, and the bespoke compilation action.

Only incremental mode is overridden. The worker otherwise follows ordinary
host-tool build settings and toolchain resolution, with baseline CPU features
declared on the binary. Standard registrations retain the shared SDK version
selection. Custom target-sensitive registrations may select a different SDK to
build the adapter; the application action still passes its own selected SDK
explicitly for the adapter to drive. This is normal tool dependency behavior,
not a promise that both compilation steps use the identical SDK instance.

### Evidence

- A baseline ownership assertion failed on commit `1ae7285`: the adapter artifact
  belonged to the SDK toolchain. The updated graph checks pass for binary, test,
  static-library, and shared-library actions. They assert one ordinary
  `zig_binary` worker compilation, disabled incremental mode in that compilation,
  the execution-platform triple, baseline CPU features, and no worker compilation
  when the feature is disabled.
- Compared ordinary action graphs: all 207 commands and environments are unchanged.
- Broad regression: 205 functional/documentation checks passed; the formatter
  identified two style issues. Both were fixed, and the subsequent focused run
  passed all 15 analysis checks, buildifier, and minimal consumers on Bazel 8.4.1
  and 9.2.0 (18 checks total).
- Native Linux integration on Bazel 9.2.0 passed all three suites in 474.2 seconds,
  including ordinary/sandboxed/hardened workers, sibling repositories, one-shot
  fallback, libraries/tests, and retained-session eviction. No worker protocol or
  state-storage code changed.
- A sandboxed worker built on aarch64 macOS successfully cross-compiled an x86_64
  Linux ELF. The action graph shows `ZigBuildExe` for the worker with
  `-target aarch64-macos-none -mcpu=baseline`, and `ZigIncrementalCompile` for the
  application with `-target x86_64-linux-gnu.2.17`. No `ZigWorkerBootstrap` remains.
- An additional Bazel 8.4.1 incremental consumer crashed in
  `WorkerFilesHash.getCombinedHash`. The identical consumer and invocation also
  crashed against an archived `1ae7285` snapshot. Bazel 8's worker hashing accepts
  a null digest for the SDK source-directory tool and then attempts to hash it;
  this is a pre-existing incremental limitation, distinct from ordinary consumer
  compatibility. The feature documentation now states the verified Bazel version.
  See [Bazel 8.4.1's worker-file hashing](https://github.com/bazelbuild/bazel/blob/8.4.1/src/main/java/com/google/devtools/build/lib/worker/WorkerFilesHash.java).
- A narrow read-only review found no actionable defect in cycle breaking,
  execution-group selection, or executable/runfiles forwarding.

### PR description

Build the incremental adapter with the existing `zig_binary` rule instead of a
special compilation action inside `zig_toolchain`. A private configuration
transition removes the worker's own worker dependency, while the named execution
group selects its target platform. Ordinary builds retain their existing commands
and acquire no worker binary dependency; custom SDKs no longer need `exec_target`.
