# Zig incremental compilation worker

[`worker.zig`](worker.zig) keeps a Zig compiler running across Bazel requests.
It starts Zig with `-fincremental` and `--listen=-`. Zig keeps fine-grained
compilation state in memory and uses it to decide what to recompile on each
`update`. Replacing the child loses that state.

## Routing and reuse

Bazel owns the worker pool. The rules pass the compiler and SDK paths at
startup. They also pass the first declared output path, which gives the
compilation action its own worker key. All outputs of the action share that
key.

Each adapter handles one request at a time and owns at most one Zig child.
Different compilations can stay warm independently. Each retained compiler
uses memory between requests. Bazel can start multiple adapters for the same
key, each with its own compiler state. [Bazel's worker key and instance limits][pool]

## Updating a compiler session

The action supplies the input paths, output metadata, and ordered Zig
arguments. Each session has a private execroot for staged inputs and an
in-memory map of their Bazel digests, keyed by path.

1. **Check for reuse.** Start a new session if the compiler arguments or
   output metadata changed. A change to the set of staged paths also starts a
   new session so Zig sees a clean input tree.
2. **Stage the inputs.** Keep a staged copy if its nonempty Bazel digest
   matches. If the digest changed or is missing, replace the file atomically.
   Zig sees a new inode even if the size and modification time match.
3. **Compile and publish.** Send `update` to Zig. Copy the resulting artifacts
   out of Zig's cache so later updates cannot mutate published outputs.

## Sandboxing and cleanup

The adapter keeps staged inputs and caches in a unique directory under
`/tmp`. This gives Zig stable paths across requests.

- **Without sandboxing**, Bazel runs the adapter in the shared execroot.
- **With `--worker_sandboxing`**, Bazel refreshes a private worker execroot
  between requests. It can remove undeclared scratch files there.
  [Bazel's worker directory contract][workers]
- **With Linux sandbox hardening**, `--experimental_worker_sandbox_hardening`
  gives each sandboxed worker its own `/tmp`. It survives requests. Bazel
  removes it when it destroys the sandbox. [Bazel's hardening option][hardening]

With ordinary sandboxing or no sandbox, the adapter owns cleanup of its tree
in the host `/tmp`. On normal exit it stops Zig and removes the tree. On POSIX,
`SIGTERM` wakes the shutdown coordinator through a self-pipe. The coordinator
cancels and joins request serving before cleanup, even if serving is waiting
for Bazel or Zig. A crash or `SIGKILL` can leave the tree behind outside the
hardened sandbox.

[pool]: https://bazel.build/remote/persistent#modifying-persistent-workers
[workers]: https://bazel.build/remote/creating#cancellation
[hardening]: https://bazel.build/reference/command-line-reference#flag--experimental_worker_sandbox_hardening
