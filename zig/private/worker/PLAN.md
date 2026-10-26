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
   parent traversal. Stage digest changes with atomic replacement; remove missing
   inputs. Handle external repositories, generated files, directory inputs, and
   ordinary source symlinks. Capture compiler stderr per action, retain normal
   compile-error recovery, and reset unknown or broken compiler state.
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
- [ ] Replace request/bootstrap boundary and expose the public opt-in.
- [ ] Replace storage and complete lifecycle/input behavior.
- [ ] Add and run contract tests and sandbox matrix.
- [ ] Review changes and record upstream readiness accurately.
