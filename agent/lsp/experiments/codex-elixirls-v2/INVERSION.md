# Inversion of the watcher proposal

Date: 2026-09-24. ElixirLS 0.31.1, Elixir 1.20.4, OTP 29.1.

**Decision: automatic file notifications are necessary, but a watcher alone is
not a complete freshness solution. A generic wait-for-build fix is also insufficient.**

The attack objective was to obtain a plausible old answer or misleading empty
answer after a saved edit, even if every filesystem notification is delivered.
`inversion_probe.py` talks directly to unmodified ElixirLS over LSP. It injects
the notifications that the proposed watcher would send. This deliberately gives
the proposal perfect event delivery; it is not a test of an implemented watcher
or a patched MCP bridge. No active integration or application code was changed.

## Live observations

| Attack/control | Result | Consequence |
|---|---|---|
| Edit unopened callee, send notification, immediately hover caller | Old BASELINE docs returned in 3.29–5.01 ms in the three retained runs, while the deliberately slowed build took about 1.53 seconds | Notification delivery does not establish query freshness |
| Query after that one build | Fresh SLOW_A docs | Standard watched-file notification fixes the missing update in this single-edit case |
| Introduce a syntax error, wait for failed-build telemetry and error diagnostic, hover caller | Null hover | Empty semantic result does not prove symbol absence; compiler failure must remain visible |
| Save A; after its compilation starts, save B with equal byte length; notify both changes | First build succeeds; queued second build reports mix_compile_noop; hover still returns A despite B on disk | Even two completed builds do not prove that the current source was compiled |
| Repeat equal-size overlap with 1.1 seconds between writes | Same stale A result; filesystem mtimes cross a whole-second boundary | This reproduction is not explained solely by same-second timestamps |
| Repeat overlap with B having a different byte length | Second build compiles and hover returns B | Control narrows the problem to incremental compilation bookkeeping |
| Repeat equal-size overlap in plain Mix, with no language server or bridge | Both compile commands exit zero; second prints no compilation; Code.fetch_docs returns A while source contains B | The overlapping-edit failure also exists below ElixirLS |
| Open target; edit disk; send only watched-file notification | Old docs, no build observed in the measured 500 ms window | Open documents require content synchronization too |
| Then send didChange and didSave for open target | Fresh OPEN_UPDATED docs | Confirms the proposed separate open-document path |
| Advertise standard work-done progress support throughout | Zero progress-create or progress notifications in these runs | Existing generic progress tracking cannot establish readiness for these builds |

The 1.5-second module-body sleep is deliberate fault injection. It makes an edit
during compilation reproducible. These tests establish possible failures, not
their frequency in ordinary Tips work. One agent can still make another edit
while its language server compiles asynchronously.

An initial exploratory run also exposed a probe shutdown error: `exit` incorrectly
contained object params. The probe now sends null, and all three retained runs
completed with server exit code zero. The initial run is excluded from the retained
evidence and is not classified as an ElixirLS lifecycle defect.

## Compiler isolation and likely mechanism

`mix_overlap_probe.py` reproduces the overlap in a separate dependency-free Mix
project, with no ElixirLS process. It waits for module A to start compiling, writes
equal-length B after 1.1 seconds while A is sleeping, finishes the first compile,
then invokes `mix compile --warnings-as-errors` again. Both commands succeed, but
`Code.fetch_docs(V2Target)` returns A. This independently establishes that the
failure can occur in plain Mix on this toolchain.

The fetched Elixir 1.20.4 compiler source compares file size and mtime, and checks a
digest when relevant. Its `each_file` callback reads the file from disk to record
the digest after compiling that file. An edit during compilation can therefore
make the recorded digest describe newer disk contents than the code just compiled.
The equal-size failure and different-size control fit that mechanism. The plain
Mix reproduction isolates the affected layer; the exact digest bookkeeping
mechanism remains a source-supported explanation rather than an instrumented
proof. No upstream issue has been filed.

Source: [Mix compiler at v1.20.4](https://github.com/elixir-lang/elixir/blob/v1.20.4/lib/mix/lib/mix/compilers/elixir.ex).
The retrieved source is preserved with the ignored raw output.

## Other counterexamples established by design analysis only

- **Query beats event delivery:** disk write finishes, immediate query arrives,
  watcher callback has not arrived. An empty event queue cannot prove clean state.
- **Watcher registration/startup gap:** files change before watching is ready.
  Watcher startup must participate in initialization, with reconciliation for a gap.
- **Rename or atomic replacement:** watching a file's old inode or dropping its
  replacement loses future changes. Use a tested directory watcher and exercise
  create/change/delete behavior; renames have two paths.
- **Watcher failure or exclusions:** missed events, unreadable paths, or an ignored
  local path dependency leave stale state. A known watcher failure must invalidate
  freshness; broad polling is not automatically the right recovery.
- **Build output feedback:** watching `.elixir_ls` or `_build` can generate repeated
  self-triggered work. Exclusions and burst handling need measured tests.
- **Debounce starvation:** resetting a timer on every event can postpone work
  indefinitely. Batching needs a maximum delay if introduced.

These are unrun attack cases, not additional observed defects in the proposed
library. No hard cross-worktree confinement requirement has been reintroduced.

## Revised minimum and stopping rule

1. Preserve the standard watcher and separate open-document synchronization paths.
2. Require evidence that a build covers the latest saved changes before labeling
   dependent semantic results current. A local change counter helps detect an
   overtaken build, but neither the counter nor a build-completion count repairs
   the observed compiler no-op case.
3. Keep compiler errors available immediately. Semantic results during failed or
   unfinished builds need explicit incomplete status rather than an authoritative
   absence claim. Internal bounded waiting should cover normal operation without
   asking the agent to refresh, pre-open files, or restart servers.
4. Resolve the compiler overlap case and validate the server's readiness contract before
   implementing a production integration. Do not compensate with arbitrary sleeps,
   source timestamp mutations, or a restart on every edit. Measure existing rebuild
   mechanisms before accepting or rejecting them; the follow-up below does that.

The smallest next investigation is an upstream-compatible correction for the
isolated compiler case and a reliable way to identify which changes a completed
build covers. The watcher remains useful, but this experiment rejects claiming
it is a sufficient fix.

## Follow-up: existing recovery mechanism and measured cost

ElixirLS already advertises `mixClean:<server-instance-id>` through
`workspace/executeCommand`. Calling it with `[false]` cleans the application
without cleaning dependencies. Sending a watched-file notification afterward
triggered a rebuild in the same server. In `inversion-clean-recovery`, this
restored OVERLAP_B documentation in 1.552 seconds, including the fixture's deliberate
1.5-second compile delay. No server restart was needed.

In `inversion-clean-overlap`, we edited B to equal-size C during that recovery
build and notified both changes. The rebuild compiled B; the queued compile was
again a no-op. Hover still returned B with C on disk. A second clean-and-rebuild
with no intervening edit returned C. Both follow-up runs completed and the servers
exited with code zero. This rejects a claim that one unconditional clean rebuild
solves concurrent edits. It does not test an automatic bounded retry implementation.

One warm CLI sample on the isolated Tips checkout measured:

| Command | Elapsed | Result |
|---|---:|---|
| `unbuffer mix compile --warnings-as-errors` | 0.648 s | Unchanged, success |
| `unbuffer mix compile --force --warnings-as-errors` | 1.357 s | 49 application files compiled, success |

Dependencies were already warm. These are whole CLI invocation timings, not
ElixirLS rebuild timings or a general performance guarantee. The result corrects
the earlier unmeasured assumption that application-wide recompilation is necessarily
too expensive. It does not justify recompiling on every query.

A warm content-scan microbenchmark over 113 selected source/configuration files
(579,164 bytes) had a median of 5.923 ms over seven samples. Its extension/path
selection does not cover every external resource or path dependency, so it is not
a complete workspace snapshot or an implemented synchronization solution.

Before extending the bridge, compare existing complete clients and MCP adapters.
[Reuse analysis](REUSE.md) records the standard, Neovim/VS Code references and
candidate tools. The compiler reproduction should accompany that comparison.

## Reproduce

From the experiment worktree, with the installed ElixirLS executable available:

```sh
python3 agent/lsp/experiments/codex-elixirls-v2/inversion_probe.py --output tmp/elixirls-v2/inversion-replay
python3 agent/lsp/experiments/codex-elixirls-v2/inversion_probe.py --output tmp/elixirls-v2/inversion-size-replay --overlap-b-marker OVERLAP_B_LONGER
python3 agent/lsp/experiments/codex-elixirls-v2/inversion_probe.py --output tmp/elixirls-v2/inversion-time-replay --overlap-gap-seconds 1.1
python3 agent/lsp/experiments/codex-elixirls-v2/mix_overlap_probe.py --output tmp/elixirls-v2/plain-mix-replay
python3 agent/lsp/experiments/codex-elixirls-v2/inversion_probe.py --output tmp/elixirls-v2/clean-replay --recover-with-clean
python3 agent/lsp/experiments/codex-elixirls-v2/inversion_probe.py --output tmp/elixirls-v2/clean-overlap-replay --recover-with-clean --edit-during-recovery
```

Each output path must be new. The probe asserts the initial baseline and the
positive refresh controls; it records adversarial outcomes for interpretation.
Exit zero does not mean the proposed integration passed a freshness acceptance gate.

Retained observations: `inversion-evidence.json`. Full local protocol transcripts:
`tmp/elixirls-v2/inversion-2`, `inversion-size-control`, `inversion-time-control`.
Plain Mix evidence is under `tmp/elixirls-v2/plain-mix-overlap`.

## Validation

The direct LSP runs and plain Mix isolation completed. Python syntax checks,
documentation links, diff whitespace checks, and formatting/compilation of the
repaired synthetic fixture passed. Credo is unavailable in this dependency-free
fixture (`The task "credo" could not be found`). The Tips application suite was
not run because application code was not changed. Watcher-library behavior,
actual MCP readiness handling, and real-workload failure frequency remain untested.
