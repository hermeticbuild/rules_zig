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
| 3 | Done: `c79fe48`; validation policy superseded by item 13 | Distinguish compiler switches from operands when validating options. Item 13 removes this validation by agreement; ordinary cache/SDK flags still stay out of worker requests. |
| 4 | Deferred by agreement | Versioned shared-library cache filenames (`--version`). No demonstrated user need: rules_zig does not generate this option and already controls the published filename and SONAME. Retain the explicit unsupported diagnostic; reconsider when needed. |
| 5a | Deferred for the current Linux scope | Do not add archive indexing for gold or other GNU-linker compatibility. Qualify Linux C/C++ consumers with hermetic-llvm; direct Zig linking retains its qualified defaults. Revisit indexing only if an in-scope consumer requires it, including the Apple linker when macOS targets are qualified. |
| 5b | Closed by agreement: upstream compiler bug | No archive workaround, backend fallback or configuration-specific rejection. Document the affected 0.17.0 path and upstream fix. Allow compatible fixed toolchains by qualifying 0.17.x patch builds and relaxing both exact-version checks together. |
| 6 | Done: `89c9aa6` | Support assembly, LLVM IR and bitcode outputs, including `emit_bin=False`. Describe and publish each requested artifact; preserve output groups and backend choices. |
| 7 | Done: `f7c3442` | Allow generated C bindings and header-only dependencies. Translation remains ordinary; its generated Zig source becomes a worker input. No provider change is needed merely to enable this feature. |
| 8 | Done: 8a in `9dbe090`; 8b in `82d1444` | Support `use_cc_common_link`: incremental Zig source compilation followed by the existing ordinary C/C++ link. Binary/shared-library paths first; test-object compilation and ordinary archive packaging in a follow-up commit. Account for item 5 before enabling affected archive configurations. |
| 9a | Done: `87ae4ac` | Allow `linkopts` with `use_cc_common_link`. Preserve the existing ordinary link consumer, ordering, and static-library ignored-options behavior. No worker or location-expansion changes. |
| 9b | Done: `a530777` | Allow linker options consumed by Zig through the existing ordered argument path. Static libraries still ignore them. No worker or location-expansion changes; ownership of files referenced through raw options remains separate in item 12. |
| 10 | Done: `aaa424a` | Allow native dependencies already handled through CcInfo, warning during analysis when selected native linker files are present. Keep declaring/staging current files; leave refresh correctness to Zig. No restart machinery or provider changes. |
| 11 | Deferred by agreement | Keep rejecting nonempty `csrcs` or `copts` in incremental mode, including with `use_cc_common_link`. Use C/C++ library dependencies or ordinary compilation. Revisit only for a concrete need; no restart policy or provider changes are assumed. |
| 12 | Deferred by agreement to the general input-declaration issue | Revisit after the ruleset's compiler/linker file-input API is addressed separately. Existing misuse of `data` also affects ordinary compilation and does not block incremental support. Preserve declared-input semantics; no `_location_inputs` scanner or new input attributes in this effort. |
| 13 | Done: `c5084db` | Remove reserved-option policing and the option-arity table. Pass semantic arguments unchanged; retain a simple shared-library configuration check. Flag-shaped operands and conflicting raw overrides are outside the supported interface. |

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
- Linker scripts also remain unsupported with direct Zig linking. This extension
  is deferred; do not reintroduce it without discussion.
- Documentation and standalone translation remain ordinary actions. An ordinary
  non-incremental worker mode, wider SDK/platform support, full path mapping and
  remote execution/cache eligibility are outside this rewrite's agreed scope.
- Items 1 and 2 passed the focused checks. After item 2, all 16 focused test
  targets passed, a real persistent-worker build produced an x86-64 Linux ELF,
  and its action metadata contained only `command`, `name`, and `output_kind`.
- Item 3 was approved and implemented. Corentin's item 13 decision on 2026-10-31
  supersedes its validation policy: remove reserved-option policing and operand
  parsing. The evidence below records the earlier behavior, not a current promise.
- Item 3 evidence: the new unit regression failed before the fix, then all 16
  focused targets passed. A Linux comparison ran exactly the same selected test
  with direct Zig, the persistent worker and one-shot execution; the old worker
  rejected it. Actual reserved switches still failed without creating their
  requested destinations. The generated worker action's argv/environment stayed
  unchanged, with ordinary cache/SDK flags absent. Read-only review found no issues.
- **Agreed rewrite and final verification complete.** Item 8a and the
  emission-description cleanup are committed as `9dbe090`. Corentin declined the
  proposed `global_args` cleanup: keep the existing construction. Item 8b is
  committed as `82d1444`.
  Item 9a is committed as `87ae4ac`. Corentin explicitly approved allowing direct
  native dependencies with a warning, accepting Zig's refresh limitation without
  a restart workaround. Item 10 is committed as `aaa424a`.
  Direct Zig `linkopts` in item 9b is committed as `a530777`. Corentin deferred
  item 11 and requested documenting the `csrcs`/`copts` limitation. Item 12 is
  deferred until the general input-declaration issue is addressed separately; it is not a
  prerequisite for incremental support. Item 13's normal-use simplification and
  accepted-pitfall comments are committed as `c5084db`. Corentin authorized the
  final documentation reconciliation, integrated checks and branch review;
  their results are recorded below. No push was requested.
  The native-update investigation below establishes the reason for implementing
  `cc_common.link` before native inputs consumed by Zig. Items 4 and 5a are
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

### Item 6: combined implementation approved (2026-10-30)

1. **Auxiliary outputs alongside the binary.** Support `emit_asm`, `emit_llvm_ir`
   and `emit_llvm_bc` through explicit action-owned output descriptions. Publish
   every requested artifact and preserve existing output groups. Leave backend
   selection to Zig; fail if the compiler does not produce a requested artifact.
2. **Auxiliary outputs without a binary.** Extend static-library compilation to
   `emit_bin=False` when another output is requested, matching the ordinary rule.
   Do not request, require or publish an archive in that case.

Both paths share one output description/publication change, reviewed together
and approved for commit. Keep ordinary action construction and comments in
place. No provider changes,
module-argument refactoring, documentation-action support or native linking work
belong to this commit. Qualify retained edits and one-shot execution for each
output combination before declaring it supported. The previous capability audit
is a starting point for checks, not authority to restore the rejected patch.

The only moved code in `zig_build.bzl` declares auxiliary files and their output
groups beside the primary output. Ordinary emission flags stay at their original
position. Auxiliary output attributes are evaluated once when declaring files.
Each selected auxiliary emission is a struct carrying its kind, file and ordinary
flag. Action outputs, output groups and worker metadata are derived from those
records; ordinary emission iterates the same records without filtering primary
outputs or deriving flags from kind names.
The request lists output kinds in JSON followed by File-aware paths;
the adapter owns emission flags and cache filenames, never strips compiler argv,
and includes the full output description in session identity. Static libraries
without a binary explicitly request `-fno-emit-bin`. All requested cache artifacts
must exist before independent atomic copies publish them.

LLVM IR/bitcode requests select LLVM in Zig, so they also satisfy the existing
shared-library LLVM requirement; explicit LLD selection is still required.
Backend choices remain with the caller. Missing compiler output is a failure,
including assembly requested from a backend that does not emit it.

Verification on 2026-10-30:

- Baseline `bazel build --config=remote-cache --//zig/settings:incremental
  --platforms=//zig/tests/platforms:x86_64-linux
  //zig/tests/emit-attr:static_emit_asm_only` failed at the old auxiliary-output
  analysis guard. The corresponding incremental analysis case now passes and
  checks the sole assembly output, its output group, and its request path.
- `bazel test --config=remote-cache //zig/tests:incremental_test
  //zig/tests:incremental_worker_test //zig/tests:emit_attr_test`: all 23 targets
  pass, including the existing ordinary emission checks. Remote execution was
  already unavailable for the Darwin executor; this uses the established local
  execution/remote-cache fallback.
- After consolidating output selection, all 22 emission/incremental analysis
  tests pass. Before/after `aquery` snapshots matched by target, mnemonic and
  configuration checksum show identical keys, arguments, environments, execution
  requirements, inputs and outputs for all eight ordinary actions inspected.
- The new Linux integration case passed with Bazel 9.2.0 and Zig 0.17.0: binary,
  test, static auxiliary-only and shared-library outputs; retained compiler PIDs
  across edits; current IR contents, bitcode headers, saved output independence,
  executable/shared-library consumers, no unwanted archive, hardened worker and
  sandboxed one-shot execution. Shared IR selects LLVM without explicit `-fllvm`;
  explicit `-fno-llvm` still fails.
- A direct protocol qualification exercised all 15 nonempty subsets of binary,
  assembly, IR and bitcode for static compilation, each cold, retained and
  one-shot. Bitcode consumers executed the current value. Changing output kinds
  or destination paths changed the compiler PID. Self-hosted assembly absence
  failed before overwriting an existing published binary.
- Buildifier, Zig formatting, whitespace checks and a narrow read-only review
  passed. No provider, bootstrap or native-linking changes. Corentin approved
  the reviewed implementation for commit; changes remain unpushed.

The disposable Linux fixture and commands are under
`/home/corentin/.cache/rules-zig-outputs-20261030` on `9985wx-5090x4`:
`run.sh` runs the checked-in integration case; `outputs_protocol.py` runs the
output-selection qualification. Results are in `run.log`, `outputs_protocol.log`
and `protocol.log`. These checks used released 0.17.0 with LLVM; they do not
establish auxiliary output support on other target architectures or SDK series.

Commit rationale: incremental mode unnecessarily rejected existing
emission attributes because its private request described one mandatory binary.
Describe every requested output explicitly and publish the corresponding cache
artifacts, allowing the same legitimate output choices as ordinary compilation
within the already qualified backend/target scope.

### Item 7: header-only dependencies (2026-10-30)

The compilation gate now rejects linking payloads (libraries, user link flags,
additional linker inputs), rather than all CcInfo dependencies or empty linker
records. Automatic `c` translation and explicit `zig_c_library` bindings use the
existing ordinary translation actions and declared generated-source inputs.
No provider, worker, argument-construction or translation implementation changes.
Native linking remains a later item; this rejection is temporary.

- Both new binding analysis cases failed against the original guard. All 24
  targets now pass with `bazel test --config=remote-cache
  //zig/tests:incremental_test //zig/tests:translate_c_action_test`, including
  separate rejections for libraries, link flags and additional linker inputs.
- Linux Bazel 9.2.0 / Zig 0.17.0 qualification used the existing e2e standalone
  translate-c toolchain and a disposable fixture. Both automatic and explicit
  bindings consumed transitive/generated headers, defines and include paths
  through Zig modules. Hardened workers produced 42, then 44, then recovered from
  a translation error to 46, retaining the same compiler PID within each case.
  Sandboxed one-shot and ordinary compilation both produced the next value, 48.
- The action graph confirms ordinary translation owns the header inputs and
  define; generated bindings and translate-c runtime modules are declared inputs
  of the incremental action. Documentation translation remains ordinary too.
- Narrow read-only review found no issues. Production changes are confined to
  the guard and its diagnostics in `zig_build.bzl`. Corentin reviewed the diff
  and approved the commit; changes remain unpushed.

The disposable Linux fixture and rerunnable `probe.py` are under
`/home/corentin/.cache/rules-zig-headers-20261030` on `9985wx-5090x4`.
`probe-builds.log` records builds; `actions.json` records the action graph.
The fixture uses its own ordinary compiler cache because the host's default
`/tmp/zig-cache` belongs to another user. Worker state remains private as before.

Commit rationale: header translation already produces declared Zig sources that
the worker can update. Rejecting their CcInfo solely for headers or empty linker
records unnecessarily excludes this path. Check actual linking payloads instead,
preserving the unsupported native-linking boundary until its implementation.

### Items 8 and 10: native-input update investigation (2026-10-30)

Corentin asked to establish whether direct Zig linking actually requires extra
invalidation before choosing the implementation order. Retained compiler-server
experiments now demonstrate stale native inputs independently of Bazel and the
worker. All cases below target x86_64 Linux and link an executable against native
files produced separately from the Zig compilation.

| Compiler / linker | Native input | Observed retained-session behavior |
| --- | --- | --- |
| 0.17.0, self-hosted; also default backend/linker | Static archive | Replacing a function returning 41 with one returning 42 still produces 41. |
| 0.17.x `12d9399228`, self-hosted | Static archive | Same stale result, through both the worker and Zig directly. |
| Master `9da2875656`, self-hosted | Static archive | Same stale result through Zig directly. |
| 0.17.0, self-hosted | Object file | Same stale result through Zig directly. |
| 0.17.0, self-hosted | Shared library | A newly added symbol remains undefined; a fresh compiler links it successfully. |
| 0.17.0, LLVM + LLD | Static archive and shared library | Content/symbol additions work, but after an undefined-symbol link error, restoring the library and then editing Zig still leaves the session reporting the old error. Fresh sessions succeed. |

For archives, a later Zig edit adding 1 produces 42 instead of 43: Zig source
updates work while native code remains stale. Worker probes verified an unchanged
compiler PID and equality between each requested native-file digest and the bytes
actually staged under that compiler's working directory. Direct-server probes
reproduce the failure without the adapter. Fresh-session controls use the same
final files and produce the expected results. Shared-library content-only edits
are not evidence of linker refresh: the runtime loader reads the replaced DSO.

A real Bazel 9.2.0 hardened-worker reproduction used a disposable export of
`f7c3442`. The unmodified native-dependency guard rejected it first. Bypassing only
that guard in the disposable export allowed the existing direct-link path to run:
cold result 41, native edit still 41 (expected 42), subsequent Zig edit 42
(expected 43). Worker logs show `reused=true` and one copied input for each edit.
The action graph confirms separate `CppCompile`/`CppArchive` actions and their
archive as a declared `ZigIncrementalCompile` input. A fresh Bazel output base with
`--strategy=ZigIncrementalCompile=sandboxed` produces 43. Merely changing strategy
did not rerun the cached action, so that earlier attempt is not a cold control.
The disposable guard edit was restored; no production restriction was removed.

Source inspection explains the self-hosted behavior. At tested 0.17.x revision
`12d9399228a41e5c4369602bfc0b51907662066f`, `Compilation.zig:2576` queues
`.load_explicitly_provided` in `oneshot_prelink_tasks`; `:4444` consumes and clears
that list on the first update. `link.zig:1551` loads the native link inputs from
that task. LLD instead constructs a new link invocation in `link/Lld.zig:elfLink`.
The observed LLD recovery failure is consistent with `clearMiscFailures` clearing
diagnostic flags but retaining `link_diags.lld`; this latter cause was not proved
by a compiler patch and before/after run.

Limits: the source-built 0.17.x/master compilers have no LLVM extensions. Current
LLVM+LLD was not tested, and the current-0.17.x shared-library fixture could not
build its glibc dependencies for that reason. The release LLVM-backend/self-hosted
linker combination closed its protocol stream on its second update; the cause
and compiler exit status were not captured. Native fixtures use ordinary GCC/ar ELF
outputs; these are Zig-linker checks, not hermetic-llvm consumer qualification.
The checked remote branch tips matched the two tested source revisions.

Decision: item 8 first. Keep native libraries in the existing ordinary
`cc_common.link` action and retain only Zig source compilation in the worker.
Native-only changes should rerun linking without rebuilding the Zig archive;
Zig-only changes should retain the compiler and then relink. This avoids the
demonstrated native-input state problem without introducing a compiler workaround
or changing backend selection. Qualify the existing archive output against the
chosen C/C++ toolchain, using a fixed 0.17.x compiler for self-hosted archives as
discussed in item 5b. Start with binary/shared-library source stages; keep test-object
compilation and archive packaging in the agreed follow-up commit.

Direct Zig native linking remains planned. An upstream refresh fix is preferred;
a restart on changed native inputs would be a separately agreed correctness and
performance tradeoff. Do not add restart metadata, provider fields or a backend
allowlist merely from these experiments. A fix for item 5b's archive corruption
does not fix this distinct native-input refresh problem.

Rerunnable scripts, protocol responses, build logs and action graph are preserved
under `/tmp/rules-zig-native-update-evidence-20261030` locally and
`/home/corentin/.cache/rules-zig-native-update-20261030` on `9985wx-5090x4`.
`probe.py` exercises direct/worker sessions; `bazel-probe.py` and
`collect-evidence.py` record the Bazel reproduction and fresh-output-base control.

### Item 8a: separate C/C++ linking (2026-10-30)

Corentin authorized implementation for review. Production changes stay in
`zig_build.bzl`: declare the existing binary/shared-library intermediate archive
before constructing the worker request, describe it as `build-lib` / static
library, and pass the existing libc/compiler-rt defaults before explicit options.
The two defaults use a shared concrete list; their original comments remain in
place. The C/C++ link blocks, providers and worker protocol are unchanged.

Native libraries, dependency linker flags and additional linker inputs remain
owned by the existing C/C++ link action. Static-library dependencies inherit the
global setting and retain their archive path, forwarding native CcInfo to the
final link as before. Only `zig_test` remains gated for the deferred test-object
pipeline. Direct Zig native linking, C sources/compiler options and rule-level
linker options/scripts retain their restrictions.

- The three initial new analysis cases failed at the original guard. All 47
  focused tests now pass: incremental, ordinary C/C++ linking, output emission
  and translation action suites. Checks cover intermediate/final output ownership,
  auxiliary output groups, explicit compiler-rt overrides, native input ownership,
  and a binary -> Zig static library -> C library dependency chain.
- Linux Bazel 9.2.0, Zig 0.17.0 LLVM+LLD, hermetic-llvm 0.8.24: both a binary and a
  shared library with a C consumer passed hardened-worker compilation, retained
  Zig edits, native-only edits, native-link and Zig-error recovery, sandboxed
  one-shot execution and ordinary compilation. Assembly, LLVM IR and bitcode were
  published alongside the intermediate archives. Retaining both targets used
  `--worker_extra_flag=ZigIncrementalCompile=--max-sessions=4` with one worker.
- Native-only edits left worker logs and all Zig artifact hashes unchanged;
  source edits reused the same compiler processes. A saved earlier executable
  still returned its original result. The action graph confirms hermetic-llvm
  link actions consume native inputs that are absent from the worker action.
  The separate Zig-static-library dependency chain also executed correctly and
  relinked after native-only edits without invoking its workers.
- Fixed 0.17.x `12d9399228` self-hosted archive qualification found a distinct
  compiler failure: LLD rejects the Zig object's malformed `.eh_frame` with
  "FDE version 1 or 3 expected, but got 0". A direct Zig compiler-server probe
  reproduces it in the private archive, without Bazel or the adapter; ordinary
  compilation of the same source links successfully with the same C/C++ command.
  Item 5b's compiler-rt fix does not resolve it. No backend switch, unwind-option
  change, compiler patch or version-specific rejection was added. Public docs
  qualify LLVM+LLD and record this remaining self-hosted limitation.
- Narrow read-only review caught the inherited static-library setting case;
  its correction and dependency-chain regression were re-reviewed without findings.
  Formatting and whitespace checks pass. Item 8b remains unimplemented.

Evidence and scripts: `/tmp/rules-zig-cc-link-evidence-20261030` locally;
`/home/corentin/.cache/rules-zig-cc-link-20261030` on `9985wx-5090x4`.
`qualification.json`, `archive-dependency.json`, `actions-focused.json` and
`direct-eh-frame/results.json` preserve the outcomes and owning actions.

Review follow-up: primary compiler outputs now use the same emission records as
auxiliary outputs. Ordinary flags, worker destinations and declared compiler
outputs derive from those records. The ordinary test-object and archive stages
keep separate descriptions; final linked outputs remain unchanged. Added the
comment explaining why libc/compiler-rt defaults are retained for both argument
paths. All existing comments remain in place.

The 47 focused analysis tests pass. Before/after action-graph comparisons matched
all 53 captured actions across ordinary and worker compilation, with and without
`cc_common.link`, including ordered arguments, inputs and outputs. Narrow review
found no issues. Corentin approved this change, committed as `9dbe090`, then
declined the proposed `global_args` cleanup. Keep the existing construction and
resume discussion of the remaining feature items.

### Item 8b: incremental test-object compilation (2026-10-30)

Corentin authorized a small, local implementation for review. `zig_build.bzl`
selects `test-obj` / object output for the existing test-object emission when
`use_cc_common_link` is enabled. The worker accepts that command/output pair,
passes `--test-no-exec`, and publishes the `.o` alongside requested auxiliary
outputs. Existing session identity, input handling and publication remain shared.

The test branch still packages the object through ordinary Zig `build-lib`, now
explicitly selecting `worker = None`. When source compilation is incremental,
the packaging arguments include the ordinary SDK/cache paths omitted from the
worker request. Existing C/C++ linking and test execution are unchanged. No
providers, argument builders, callbacks or `global_args` refactoring were added;
existing comments remain in place.

- The new analysis case failed at the original unsupported-test guard and passes
  after the change. All 47 focused analysis targets and the worker unit-test
  target pass. Before/after comparisons matched all 12 captured ordinary actions,
  including arguments, inputs, outputs and execution settings.
- Linux Bazel 9.2.0, Zig 0.17.0 LLVM+LLD, hermetic-llvm 0.8.24: hardened-worker
  compilation produced the test object, assembly, LLVM IR and bitcode; ordinary
  packaging and linking produced a test executable that Bazel ran successfully.
- Native-only edits changed the test result without invoking the worker or
  changing the object/archive/auxiliary hashes. Zig edits and compiler-error
  recovery reused the same compiler PID. Native link-error recovery, no-op
  builds, sandboxed one-shot execution, ordinary compilation, and an independently
  saved earlier test executable also passed their expected outcomes.
- The actual action graph shows the object consumed by ordinary `ZigBuildLib`,
  its archive consumed by hermetic-llvm's `CppLink`, and native library inputs
  absent from the worker. Archive packaging has no worker execution requirements.
- Fixed 0.17.x `12d9399228` self-hosted `test-obj` produces the same malformed
  `.eh_frame` diagnostic observed for archives in 8a; ordinary compilation of
  that test passes. Documented the observation without a workaround or new gate.
- Narrow read-only review found no issues. Corentin reviewed and approved item
  8b, including ordinary SDK/cache setup for archive packaging; commit `82d1444`.

Evidence: `/tmp/rules-zig-8b-evidence-20261030` locally and
`/home/corentin/.cache/rules-zig-test-object-20261030` on `9985wx-5090x4`.
`qualification.json`, `selfhosted.json`, action graphs and per-phase logs retain
the compiler reuse, artifact hashes, test outcomes and toolchain evidence.

### Item 9a: linker options with separate C/C++ linking (2026-10-30)

Corentin approved narrowing the `linkopts` rejection to incremental compilations
without `use_cc_common_link`. Existing actions already route these options to the
ordinary link, preserving their order, and ignore them for static libraries.
Only the analysis guard changes; no worker, provider, argument construction or
location-expansion changes are needed. C sources/options and linker scripts
retain their existing rejection. Direct Zig `linkopts` remains unsupported.

- The new binary regression failed at the original blanket rejection. All 52
  focused analysis tests pass, including binary/test/shared-library routing,
  static-library ignored options, and the direct Zig rejection.
- Linux Bazel 9.2.0, Zig 0.17.0 LLVM+LLD, hermetic-llvm 0.8.24: binary, test,
  shared-library and static-library builds passed with hardened workers.
- Changing only `linkopts` from empty to `-Wl,-z,now`, `-Wl,-z,lazy`, then
  reversing that order, changed the three final link actions and ELF binding
  flags. All four worker actions and the ordinary test archive action retained
  identical keys, arguments, inputs, outputs, environment and execution settings.
  Their artifact hashes were unchanged and no worker request ran for either edit.
- Ordinary compilation also passed; direct Zig linking failed with the intended
  diagnostic. The qualification Bazel server was shut down afterward.
- Narrow read-only review found no issues. Corentin reviewed and approved this
  change for commit.

Evidence: `/tmp/rules-zig-9a-evidence-20261030` locally; remote qualification is
under `linkopts-evidence` in the existing item 8b fixture.

### Item 10: accept native linking with a compiler warning (2026-10-30)

Corentin explicitly chose to allow native dependencies with direct Zig
incremental linking, warn about stale results, and leave native-refresh
correctness to the selected compiler. This supersedes the earlier proposed
deferral or restart design; it does not fix the compiler bugs recorded above.

Removed the CcInfo linking-payload rejection. The existing linker-input helper
still selects the files, arguments and runtime dependencies. After that selection,
`zig_build.bzl` emits one analysis-time warning for incremental direct linking
with selected native files. It warns about stale inputs and retained link errors,
states that native changes do not restart Zig, and points to `use_cc_common_link`
or disabling incremental compilation. Bazel renders Starlark `print` messages
with a DEBUG prefix; the message itself identifies the target and says warning.

The warning does not run for ordinary compilation, separate C/C++ linking,
header-only dependencies, or dependency flags with no selected linker files.
It cannot discover files referenced only by raw compiler/linker options.
Inputs remain declared and their new bytes are staged normally; no worker,
provider, argument-routing, session, cache or backend behavior changed.

- The updated native-library analysis failed at the old guard, then passed.
  All 52 focused analysis tests pass, including acceptance of existing library,
  dependency-flag and additional-linker-input fixtures.
- Linux Bazel 9.2.0, Zig 0.17.0 self-hosted, native archive built by hermetic-llvm:
  initial build warned once and returned 41. After rebuilding the archive to
  return 42, the same compiler still produced 41; a Zig edit adding 1 produced
  42. The staged archive matched the current declared input. Ordinary compilation
  of the final sources returned the correct 43. This verifies the warning and
  preserved behavior, not a compiler fix.
- Ordinary, header-only and `cc_common.link` analysis emitted no warning. The
  qualification Bazel server was shut down afterward.

Evidence: `/tmp/rules-zig-native-warning-evidence-20261030` locally and
`native-warning-evidence` in the existing item 8b remote fixture. Narrow read-only
review found no issues. Corentin reviewed and approved this change for commit.

### Item 9b: linker options with direct Zig linking (2026-10-31)

Corentin approved removing the direct `linkopts` rejection while retaining the
existing argument construction, static-library behavior, worker validation and
file ownership. The production change deletes only that two-line gate.
`zig_binary`, `zig_test` and `zig_shared_library` now pass these options to the
worker in their existing order. Static libraries still ignore them, just as in
ordinary compilation. The session key already includes compiler arguments, so
changing options selects a different compiler session. No worker, provider,
flag-parser, location-expansion or input-declaration changes were needed.

- The new direct-link analysis regression failed at the original gate before
  its removal. All 55 focused incremental, separate-link, output and translation
  analysis tests then passed. Remote execution had no Darwin/arm64 executor;
  these tests ran locally with `--config=remote-cache`.
- Linux Bazel 9.2.0, Zig 0.17.0 LLVM+LLD, hardened sandboxed worker: a source edit
  changed the executable's result while retaining compiler PID 700374. Reversing
  `-z now -z lazy` to `-z lazy -z now` selected PID 702100 and enabled ELF NOW
  binding. Reversing back removed NOW binding in binaries, tests and shared
  libraries. Tests passed and the shared library's exported function returned
  the updated value.
- Action inspection confirmed ordered options in all three linking worker
  actions and no C/C++ link. The static-library action key and archive bytes
  stayed unchanged when only `linkopts` changed.
- At this checkpoint, a worker-owned `--cache-dir` passed through `linkopts`
  failed with the ownership diagnostic, subsequently removed by item 13.
  Ordinary compilation also passed with the same final options. The qualification
  Bazel server was shut down afterward.
- Narrow read-only review found no issues. Corentin approved the change, committed
  as `a530777`. Files referenced only through raw options remain item 12;
  this change does not add them to the native-input warning.

Evidence: `/tmp/rules-zig-9b-evidence-20261031` locally and
`direct-linkopts-evidence` in the existing item 8b remote fixture. The standalone
qualification script is preserved with its action graphs and artifact reports.

### Item 11: defer C source compilation inside Zig (2026-10-31)

Corentin chose to defer incremental support for `csrcs` and `copts`. Keep the
existing explicit rejection, including with `use_cc_common_link`: that setting
separates the final link but still leaves `csrcs` compilation to Zig. C/C++
libraries supplied through `deps` remain supported within the existing documented
limits; ordinary compilation remains available for targets using `csrcs`/`copts`.

No implementation or compiler qualification is included in this deferral. If a
concrete use case warrants revisiting it, first qualify C source edits, included
header edits and error recovery in retained Zig sessions, then agree on the
minimal argument handling and file ownership. The earlier instruction to extend
a restart policy is withdrawn; no restart machinery or provider change is
preselected. The user-facing incremental documentation records the limitation.

### Item 12: defer the general file-input API issue (2026-10-31)

Corentin chose to defer this item until the general ruleset issue is addressed.
A file consumed through an option but listed only in runtime `data` is already
incorrectly declared for ordinary compilation. Repairing that usage is not a
prerequisite for incremental compilation: the worker continues to stage the
action's declared inputs, without discovering undeclared files from arguments.

The separate issue draft is titled "Separate compiler and linker file inputs
from runtime data" on `hermeticbuild/rules_zig`. It was prepared in Chrome and
left unsubmitted for Corentin; publication has not been verified. The proposed
API direction reuses `extra_srcs` for compiler inputs and considers
`additional_linker_inputs` for final linking, with action ownership matching
direct Zig or separate C/C++ linking. Neither proposal is approved for
implementation in this incremental effort. Do not reintroduce the rejected
`_location_inputs` scanner or broaden providers as worker plumbing.

### Item 13: minimize compiler-option knowledge (2026-10-31)

Corentin explicitly chose normal compiler usage over exhaustive validation of
raw options. This supersedes item 3's reserved-option and operand-aware policy,
including the earlier acceptance evidence that describes those checks.

- Remove the reserved-option validator and the Zig option-arity table. Do not
  reject arbitrary cache, emission, protocol, or library-mode overrides.
- Pass semantic compiler arguments through unchanged and in order. The adapter
  still supplies its own controls from the existing request metadata.
- Keep the shared-library capability check: LLVM plus effective explicit LLD,
  with the last backend switch winning. Keep the deferred `--version` diagnostic.
  Use a simple token scan; flag-shaped operands are outside this check's contract.
- Remove the raw `-cflags`/`-rcflags` guard with the parser. This does not enable
  `csrcs` or `copts`: their existing Starlark restriction remains in item 11.
- Preserve request framing, declared-input checks, staging, session identity,
  compiler lifecycle, and output publication. No provider or public API change.

Acceptance: worker unit tests cover normal backend selections and overrides;
real Linux builds retain compiler reuse after source edits, publish current
artifacts, reject unsupported shared-library configurations, and use the same
request through one-shot execution. Remove tests for the discarded raw-option
policing; do not replace them with pathological argument cases.

Verification on 2026-10-31:

- `bazel test --config=remote-cache //zig/tests:incremental_worker_test` passed.
  The integration runner built with the same config; Zig 0.17 formatting checks
  passed for both modified Zig files.
- The disposable Linux fixture used Bazel 9.2.0, Zig 0.17.0, direct Zig linking,
  worker sandboxing and worker sandbox hardening. An executable returned `2`, then
  `3` after a source edit with compiler PID `756789` unchanged. One-shot sandboxed
  execution returned `4` after the next edit.
- Binary, test, shared-library and static-library builds passed. The shared
  library exported the current value `43`; archive members were present. The
  action graph retained the ordered linker arguments for binary/test/shared
  actions and omitted them for the static library, as before.
- Shared configurations ending in `-fno-llvm`, `-fno-lld`, or `--version 1.2.3`
  failed with the intended capability diagnostic. Restoring the supported shared
  configuration succeeded. This focused check preceded the full integration
  rerun recorded in the final verification section below.
- Narrow read-only review found two obsolete operand-aware integration cases and
  two stale plan passages; these were corrected. No production-code issue found.

The standalone qualification script is `/tmp/rules-zig-13-qualify.py`; its logs,
action graph and compiler-process records are in
`/tmp/rules-zig-13-evidence-20261031`. The Linux copy remains under
`/home/corentin/.cache/rules-zig-test-object-20261030/flag-simplification-evidence`.
The disposable fixture's sources were restored and its Bazel server shut down.
Corentin approved the change and the four comments documenting accepted pitfalls:
flag-shaped operands, user response files, conflicting adapter controls, and
trusted SDK/cache/build-root prefixes. Committed as `c5084db`; no push requested.

### Final verification and review (2026-10-31)

The agreed rewrite is complete within the accepted scope. The remaining feature
items are explicit deferrals, not unfinished implementation. No push was
authorized or performed during this closeout.

- On macOS, `bazel test --config=remote-cache
  --test_tag_filters=-requires-network //zig/tests/... //docs/...
  //util:buildifier.check --test_output=errors --test_summary=short` passed:
  all 224 tests and all 337 requested targets built successfully. Existing test
  results were reused where valid. The repaired native archive consumer also
  executed successfully. Zig formatting and Git whitespace checks passed.
- The first full regression exposed two small issues, fixed independently:
  `b093612` scopes a buildifier suppression to the intentionally emitted native
  compiler warning; `bcee626` makes the native archive consumer call the archive's
  exported Zig function, instead of incorrectly expecting C bindings to be
  reexported through the Zig module. The latter failed compilation before the
  fixture correction, then built and ran successfully. No provider change.
- Linux Bazel 9.2.0 and Zig 0.17.0 ran all four real integration cases in
  `//zig/tests/integration_tests:incremental_tests`, passing in 349.4 seconds.
  The suite covers unsandboxed, sandboxed, hardened and sibling-repository
  layouts; current source/generated/external/embed inputs; retained compilers;
  independent published artifacts; bounded sessions and eviction; tests and
  libraries; requested outputs; one-shot execution; and unsupported configurations.
  Hardened modes checked distinct mount namespaces and write restrictions.
- A separate hardened hermetic-llvm 0.8.24 / LLVM+LLD test-object qualification
  passed with `use_cc_common_link`. Native-only edits changed the test result
  without invoking Zig or changing object/archive/auxiliary-output hashes.
  Zig edits and compiler-error recovery retained PID 823647. Native link-error
  recovery, no-op builds, saved earlier executable, one-shot execution and
  ordinary compilation also passed their expected outcomes.
- Its action graph confirms `ZigIncrementalCompile` publishes the object and
  auxiliary outputs; ordinary `ZigBuildLib` packages the archive with SDK/cache
  arguments; hermetic-llvm `CppLink` alone consumes the native object. The first
  two actions contain no native input, and packaging advertises no worker support.
- Two narrow read-only reviews covered the full worker and Starlark branch diff
  from `d692048`, including bootstrap, ordinary compilation, input ownership,
  lifecycle and publication. No actionable findings. The two closeout fixes
  also received a narrow review without findings.

Linux used an archive of `c5084db`, containing all final production behavior;
the later commits above change only a lint comment and an unrelated regression
fixture. The existing AppArmor launcher was used without policy changes. Remote
cache authentication was unavailable, so the outer run disabled remote caching.
The host's shared `/tmp/zig-cache` belonged to another user: both outer and nested
Bazel used a task-owned `RULES_ZIG_CACHE_PREFIX`, with the nested value supplied
through the existing `.bazelrc.ic.user` test hook in the disposable source export.
Neither adjustment changes worker-private cache ownership or repository defaults.

Evidence on `9985wx-5090x4`: the integration log is under
`/home/corentin/.cache/rules-zig-closeout-20261031-output/execroot/_main/bazel-out/k8-fastbuild/testlogs/zig/tests/integration_tests/incremental_tests/`;
the separate-link script, `qualification.json`, `actions.json` and phase logs
are under `/home/corentin/.cache/rules-zig-closeout-cc-20261031/`.
Local copies of the separate-link records are
`/tmp/rules-zig-closeout-cc-20261031.json` and
`/tmp/rules-zig-closeout-cc-actions-20261031.json`.
The integration log is copied to
`/tmp/rules-zig-closeout-integration-20261031.log`.

## Contract

A successful action publishes independent artifacts for its current declared
inputs, compiler, environment, and options. Bazel owns action invalidation; Zig
owns semantic incremental work. With a compiler that correctly handles updates,
removing retained state changes only performance. The documented native-link
refresh bugs are accepted compiler limitations: rules_zig warns and stages current
inputs, but does not repair Zig's retained state.

## Accepted scope

- Existing `zig_binary`, `zig_test`, `zig_static_library`, and `zig_shared_library`,
  opt-in `//zig/settings:incremental`; default unchanged.
- Hermetic Zig 0.17.x from 0.17.0 onward, x86_64 Linux target, Zig linking or
  separate C/C++ linking through `use_cc_common_link`, binary and requested
  assembly/LLVM outputs. Static libraries may omit the binary.
  The known 0.17.0 archive corruption is an upstream limitation;
  select a compiler containing its fix.
- Binaries, test executables, and static libraries support self-hosted and LLVM
  compilation. Shared libraries linked by Zig require LLVM (explicitly or through
  LLVM output) and explicit effective LLD selection. Separate C/C++ linking is
  qualified with LLVM+LLD and hermetic-llvm; self-hosted `.eh_frame` failures remain
  upstream limitations, as documented above.
- Singleplex JSON worker, one compiler session by default, optional bounded LRU.
- The adapter supplies protocol, cache, SDK, naming, and output controls from
  explicit metadata. Conflicting raw options are outside the supported interface
  and are not policed. Semantic compiler arguments retain their original order.
- Native dependencies already handled through CcInfo are accepted in direct Zig
  linking, with the warning and compiler limitations above. Native changes do
  not trigger an adapter-controlled restart.
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
   actions, opt-out behavior, supported configurations, bootstrap, configuration
   replacement, source and embed edits, missing inputs, immutable publication,
   compiler restart, and one-shot execution. Inspect artifacts and source/debug
   paths; correct path mapping or bound supported configurations where needed.
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
and inspect actual sandbox processes. The adapter's session management must not
introduce stale successes; the accepted upstream compiler limitations remain
documented separately. Metadata-preserving tests explicitly provide
changed Bazel input digests; they cannot repair Bazel failing to detect an edit.

## Deferred, not prerequisites

Multiplexing, target-affinity scheduling, remote worker locality, macOS and
Windows targets, additional Zig protocol versions, and remote-cache eligibility.
The rewrite also defers C source compilation inside Zig, versioned shared-library
artifacts, linker scripts, and the general file-input API issue. Native
dependencies, auxiliary outputs and the separate C/C++ link pipeline are
implemented within the accepted scope above. Measure representative multiple
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
  The original reserved-control validation is removed by item 13; arguments
  continue to pass through unchanged.
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
  paths when unstripped. Native macOS/Windows targets and additional protocol
  versions remain excluded. Native dependencies and auxiliary outputs are now
  supported within the documented compiler limitations.

## Recorded checks

This section records earlier checkpoints. The rewrite decisions and final
verification above supersede their scope and option-validation policies.

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

The initial shared-library backend check used Zig 0.17's option arities to skip
operands, then checked the last LLVM and LLD switches. It rejected native flag
groups and versioned shared-library names. Item 13 supersedes that design: remove
the option-arity table and native flag-group guard, retaining a simple backend
scan and the versioned-name diagnostic. Automatically forcing LLVM/LLD would hide
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
