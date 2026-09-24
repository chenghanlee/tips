# Fable's plain-Mix proposal: code trace and root problems

2026-09-25. Branch: `experiment/plain-mix-compile`.

This records the investigation before implementation. The subsequent foreground
prototype and its test results are in [README.md](README.md).

**The performance benefit is credible. The proposed foreground compiler is worth
testing, but its claim of exact, race-free feedback from a roughly 40-line hook is
not established. New probes reproduce stale output even with sequential builds.**

This review revisits Fable's proposal, rather than treating the retained stack's
five-second contract as mandatory. The user has explicitly allowed changing that
budget. No product hook or navigation implementation changed. The Neovim savepoint
remains at `f878459` and `savepoint/neovim-elixirls-hook-2026-09-25`.

Inputs: [Fable's review](/private/tmp/tips-fable-release-review-9xb93ihp/REVIEW.md),
especially its proposal in section 4. Prior verification is
in [OPERATIONAL_FIXES.md](../codex-elixirls-v2/OPERATIONAL_FIXES.md). New results and
source hashes are in [analysis-evidence.json](analysis-evidence.json).

**What Fable gets right**

- Compiler feedback does not inherently need an LSP. A foreground compiler gives
  a direct exit status and compiler output, avoiding editor synchronization and
  diagnostic-cache collection on the feedback path.
- The ordinary CLI build can share `_build/test` with subsequent `mix test`
  invocations when environment, project, toolchain, options and build paths match.
  That reuses artifacts; it does not remove test execution or necessarily every
  later compilation.
- Measured warm Tips source edit/error/repair invocations took 0.653–0.742 seconds.
  Earlier ElixirLS hook source edits took 1.43–2.88 seconds. This is promising, but
  these are different runs, not a paired benchmark of two complete current hooks.
- Avoiding a compile wait after an ordinary test-only edit removes a measured
  no-op. That is useful if we accurately describe what has and has not been checked.

The 50.20-second cold Tips measurement compiled dependencies, including native
code, as its log shows. It is not representative of a warm one-file edit and does
not refute the fast foreground design. Cold preparation can be a separate step.
Conversely, 0.65 seconds cannot be promised for dependency/configuration changes,
large dependency fan-out, arbitrary compile-time work, or waiting for a build lock.

**Trace: what stock Mix actually does**

The downloaded v1.20.4 compiler source matches the prior investigation byte for
byte (SHA-256 `ae323e0d10b14fc55f0a415d53654d8c39e22723bde17138eb8dc78b34067c87`).
The new probes execute stock Homebrew Elixir 1.20.4 / OTP 29.1, with `MIX_ENV=test`.

```text
tool finishes
  -> proposed PostToolUse hook
     -> unbuffer mix compile --warnings-as-errors
        -> Mix.Tasks.Compile.run/1: loadpaths, then compile.all
        -> Mix.Tasks.Compile.All.run/1: acquire the build-directory lock
        -> configured compiler tasks (Tips also includes phoenix_live_view)
        -> Mix.Tasks.Compile.Elixir.run/1
        -> Mix.Compilers.Elixir.compile/7
           -> enumerate .ex files under elixirc_paths
           -> compare manifest metadata and dependencies
           -> select stale sources
           -> Kernel.ParallelCompiler -> elixir_compiler:file/2
              -> read and parse source; execute compile-time code
              -> file-completion callback
                 -> Mix reads disk again to fill a missing source digest
           -> record manifest and artifacts; return status
     -> hook must encode the status/output for agent delivery
```

Pinned source locations: `tasks/compile.ex:136–153`, `tasks/compile.all.ex:17–24`,
`tasks/compile.elixir.ex:125–175`, `compilers/elixir.ex:49–50, 438–457, 565–576,
1075–1076, 1271–1300`, `kernel/parallel_compiler.ex:655–658, 856–858`, and
`src/elixir_compiler.erl:10–34`. Copies are under
`tmp/plain-mix-analysis/upstream/lib/`; GitHub links below refer to the pinned tag.

**1. Root problem: completing a command does not establish input identity**

There are now two distinct stock-Mix counterexamples:

| Case | Disk | Manifest digest | Executable target and compile-time caller | Why another compile skips |
| --- | --- | --- | --- | --- |
| Earlier overlapping write | B | B | A | Digest wrongly certifies the old artifact |
| New sequential same-second edit | B | A | A | Equal size and equal whole-second mtime bypass the digest check |

The earlier case was a deliberately widened overlap, not an actual Codex hook.
Its fresh-VM ExUnit assertions failed after two successful incremental retries.
The compiler reads source at `elixir_compiler.erl:33`, while Mix may hash the file
later at `compilers/elixir.ex:1293`. The artifacts establish the mismatch; the
precise internal callback timing was not instrumented in that older reproduction.

The new case requires no overlap and no restored timestamps. The probe writes A,
waits for its successful compile (0.407 s), writes equal-length B in the same
wall-clock second, and runs a second successful compile (0.385 s). Nanosecond
mtimes differ, but both reduce to `1790269115` in Mix's metadata. The second
invocation does not compile the source. A fresh VM returns A from both modules;
the manifest digest differs from disk B. A later ordinary retry still returns A.
Advancing the file's mtime to a different second causes normal compilation to
produce B. This control repairs this metadata case; touching is not a general
repair for the older case whose digest already matches B.

Source trace: `Mix.Utils.last_modified_and_size/1` uses POSIX time metadata;
`compilers/elixir.ex:449–452` gates the content comparison behind an mtime change
when size and the other invalidation conditions do not change. Merely waiting
before the next compile does not change the file's stored mtime. The new probe is
synthetic and establishes possibility, not frequency in normal Tips agent work.

Ten whys:

1. Why can a successful hook still leave old code? Mix can select no source to rebuild.
2. Why can that selection be wrong? The source's freshness record does not reliably
   identify the bytes represented by its artifact in these boundary cases.
3. Why does overlap break that identity? Source parsing and later digest capture
   can observe different revisions.
4. Why can sequential builds also fail? Same-size edits in one metadata second can
   bypass content comparison entirely.
5. Why does a build lock not catch either? It serializes participating compiler
   operations, not file writes, and does not change the metadata predicate.
6. Why does placing compilation after a write help? It removes one source of
   overlap if that writer truly waits for the entire compile and no others write.
7. Why is that insufficient as a blanket promise? It neither repairs prior cache
   inconsistency nor fixes same-second invalidation or other active writers.
8. Why can one agent still have another writer? A previously started shell process
   may keep running; tool-call sequencing is not a filesystem lock.
9. Why not just retry or reread the manifest? Both counterexamples reuse the same
   invalidation decision and preserve the stale artifact.
10. Why not infer exactness from exit zero? It reports the result of Mix's selected
    work, not an independent proof that every saved input was revalidated.

The last two whys return to the same requirement: trustworthy invalidation and
stable inputs during the work being certified.

Mix's lock is still useful and should be reused. `Mix.Project.with_build_lock/2`
keys `Mix.Sync.Lock` by build directory (`project.ex:1000–1016`). `mix test` calls
compile at `test.ex:599`, then later starts the app and requires/runs tests at
632 and 694–698. It does not hold that compilation lock throughout ExUnit. A new
probe compiled successfully in 0.383 s while a test body was still sleeping.
This verifies lock scope; it does not demonstrate that overlapping tests were
corrupted. Fable's serialization claim is valid for their build phases, not for
the entire background test workflow or source writes.

**2. Root problem: cancellation discards the execution needed to make progress**

The two original results—4.982 and 5.055 seconds—are explained by the actual probe:
`plain_mix_feedback_probe.py:101–110` places `Process.sleep(8000)` inside the module
body, before the bad definition, then gives each compile 4.7 seconds before cleanup.
This is compile-time execution, not a slow ExUnit test or a diagnostic transport delay.

The new [cancellation trace](cancellation_trace.py) keeps the source byte-identical
through two cancellations and a third longer attempt. It records a marker before
and after the sleep, process IDs, cleanup phases, and remaining processes.

| Attempt | Marker sequence | Error delivered | Total wall time |
| --- | --- | --- | --- |
| Cancel at 4.7 s, first | Entered; never finished | No | 5.064 s |
| Cancel at 4.7 s, second | Entered again in a new VM; never finished | No | 5.000 s |
| Allow 20 s, unchanged source | Entered again; finished | Yes | 8.518 s |

Each cancelled attempt left `compile.elixir.update.cp` and no observed surviving
processes. That checkpoint tracks required recompilation (`elixir.ex:398–405,
470–473, 1010–1014`); it does not persist the Elixir process's execution position.
The third attempt reexecutes the module from its beginning. Completed dependency
work can remain cached, so this does not prove every large cold project makes no
progress under cancellation. It proves that this single long compilation unit
cannot finish through repeated shorter attempts.

Eight whys:

1. Why did neither cancelled attempt report the undefined function? The compiler
   was stopped before the preceding module-body operation finished.
2. Why was it stopped then? The wrapper's per-attempt allowance was 4.7 seconds.
3. Why did the next attempt not finish the remainder? The first VM was terminated.
4. Why does incremental compilation not resume its execution? Its cache and
   checkpoints describe completed artifacts and work to redo, not continuations.
5. Why does the same failure repeat with unchanged source? The same module-body
   operation needs eight uninterrupted seconds on every attempt.
6. Why did the longer attempt report the error? It crossed that minimum execution
   window and reached the failing compilation, without changing source.
7. Why doesn't optimizing shutdown fix missing feedback? Faster cleanup does not
   give the compiler enough execution time.
8. Why doesn't another fixed short retry solve it? Every attempt repeats the same
   interruption. Progress requires allowing completion or explicitly changing the
   promised outcome to unfinished validation.

The root is the retry/deadline policy, not a broken diagnostic queue. The third
attempt demonstrates that stock Mix can return the correct error here.

**The separate 5.055-second overrun**

New first-attempt monotonic timestamps, relative to process launch:

```text
4.700 s  nominal compile allowance
4.774 s  polling loop notices expiry
4.811 s  final descendant discovery completes
4.849 s  SIGTERM sent after another liveness scan
4.993 s  grace period and SIGKILL-stage scan complete; child reaped
5.064 s  final survivor checks complete
```

Five whys: why exceed five seconds → work continues after timeout detection;
why → cleanup and verification are included in reported wall time; why insufficient
reserve → polling/process-table scans plus a fixed 100 ms grace period consume it;
why can they overshoot → the deadline is checked after a process scan and later
cleanup is not governed by that same deadline; why isn't another retry a fix →
it repeats the same accounting. The final two questions identify the same missing
total-deadline accounting, separately from the eight-second progress problem.

The original helper runs `ps` for each discovery/liveness check; these scans took
up to about 43 ms in the new first attempt. This is measurement overhead and
cleanup design, not an extra five seconds spent in Mix. A production wrapper
needs owned-process cleanup, an absolute monotonic deadline and adequate host-hook
headroom. The observed PID checks are not proof against every daemonization pattern
an arbitrary custom compiler might spawn. Reuse the tested cleanup approach and
qualify its scope; do not assume killing `unbuffer` alone kills the compiler.

**3. Root problem: fast compilation and complete edit feedback are different scopes**

New boundary checks establish:

- An undefined function in `test/proposal_test.exs` produces exit zero from
  `mix compile` and exit one from `mix test`. The compiler hook cannot report an
  error in a file its task never evaluates.
- A `.txt` file declared as an external resource changes a module's compiled
  value. Extension-only change selection can skip real compiler inputs.
- Tips compiles `lib` and `test/support` under `MIX_ENV=test`, and includes a
  Phoenix compiler. Ordinary test `.exs` files are not compiled by that step;
  `mix.exs` and configuration scripts are nevertheless evaluated in the build
  workflow. Treating all `.exs` uniformly is incorrect. Fable's proposal does
  explicitly include configuration changes; that is better than its broad A2 wording.

Seven whys:

1. Why does skipping test edits make the hook faster? It omits a no-op compile.
2. Why was it a no-op? The file is outside that task's compiled inputs.
3. Why can there still be an error? Test files need their own parsing/compilation
   and execution path.
4. Why can't the hook call all edits validated? A successful selected task does
   not establish correctness of files the task never examined.
5. Why isn't a suffix list a complete trigger policy? Inputs include project
   configuration, lockfiles, custom compilers and declared external resources.
6. Why can't exact-path extraction from apply_patch alone settle coverage? Shell
   commands, deletes and renames can also change inputs; missing a change can mean
   the compiler is never invoked.
7. Why does raw compiler output not finish the integration? Agent receipt is a
   separate transport contract. Codex's PostToolUse ignores plain stdout text;
   the wrapper must provide supported structured feedback.

The final questions preserve the same boundary: explicitly select work and
accurately report what was executed. Do not create a second dependency graph or
claim a clean test suite from a compile result. Mix should own dependency selection;
a small conservative change detector can decide when to invoke it. Skipped test
validation must remain distinguishable from successful compilation.

The [official hook documentation](https://learn.chatgpt.com/docs/hooks#posttooluse)
supports `hookSpecificOutput.additionalContext`. It documents synchronous waiting
for the triggering operation and separate handling for long-running exec sessions;
it does not supply a worktree-wide source lock. For code-mode tool calls, blocking
feedback can also reject the nested promise. Reuse ordinary informational context
for compiler results, including compile failures, unless intentionally changing
tool control flow. A live plain-Mix hook has not yet been tested here.

**4. Root problem: separating feedback does not remove navigation's lifecycle**

Fable is right that the foreground hook need not wait for the language server.
However, replacing the feedback producer cannot automatically delete all code
that protects the remaining Neovim/ElixirLS navigation session.

The pinned vv-mcp Lua enables `sync_from_disk` for `fix_document`, not by default
for hover, definition, references or diagnostics. Our init adds those flags through
the internal operation table (`neovim_init.lua:63–69`). The helper itself only runs
`checktime` (`vv-mcp/lsp/context.lua:35–54`). It does not send a save. Prior verified
open-clean-file behavior can therefore persist even if a query reloads the buffer.
This is independent of the overlapping-write Mix defect.

Six whys:

1. Why can navigation remain stale after CLI compilation succeeds? ElixirLS owns
   another build and loaded semantic state.
2. Why doesn't reusing `_build/test` for CLI tests update it? The server uses its
   separate `.elixir_ls` build; shared input paths are not shared live state.
3. Why isn't the suggested disk-sync read sufficient? Reloading one buffer does
   not necessarily trigger the required save/build or refresh an unopened callee.
4. Why can stale state extend beyond that file? The existing executable fixture
   demonstrates a compile-time caller also retaining the old value. Navigation
   impact must be tested per operation, not assumed confined to one file.
5. Why retain process ownership even after moving feedback? The navigation
   session can still crash, silently replace its instance or orphan children.
6. Why can't a small compiler hook fix those failures? They belong to the
   independently retained navigation service, not its old feedback collector.

The last two whys reach the same ownership boundary. The existing four
operational fixes should not be undone merely because hook output comes from
another process. Similarly, removing `tmp/` exclusions trades background build
noise and CPU for less configuration; it does not make that work disappear.
The effect on foreground latency under contention is not measured.

**Smallest promising next candidate**

First principles: an invocation needs stable inputs, trustworthy invalidation,
enough uninterrupted time, and delivery of its actual outcome. LSP is optional
for that feedback path. A short wait is a UX preference, not compiler semantics.

Occam: start with one foreground `unbuffer mix compile --warnings-as-errors`
invocation, the ordinary test build directory, existing Mix locking and the
existing hook JSON format. Separate initial preparation from warm feedback.
Use a generous configurable safety timeout (60 seconds is a reasonable first
experiment, not a guarantee) rather than repeatedly cancelling useful work at
five seconds. At the safety limit, reap owned processes and report unfinished;
do not return clean or promise a later result that no process will produce.
This deliberately accepts occasional longer waits and unfinished validation at
the safety limit. It avoids introducing a persistent compiler manager first.

Pareto: measure that direct path before replacing navigation. It can remove the
editor's build/diagnostic wait from most warm edits while leaving its independently
needed synchronization and ownership intact. Test unchanged tools and test-only
edits too, so a 0.65-second compile is not accidentally added after every shell read.

Correctness remains a distinct gate. With strictly stock Mix, we must accept its
demonstrated cache limitations or correct them. Our already tested local
`--force-path` patch is a candidate for a small foreground variant: changed paths
enter Mix's existing dependency invalidation without the ElixirLS scheduler. It
would make the candidate locally patched Mix, not stock Mix. No claim is made that
the complete hook, its changed-path delivery or its cancellation behavior is
validated merely because the compiler primitive already passed earlier gates.

Do not add a full forced project rebuild on every edit, an extra dependency graph,
or a background job service before testing this smaller contract. A longer timeout
alone fixes neither the new metadata case nor the older overlapping-write case.

Next discriminating gates are: same-second/equal-size edits; edits arriving during
another compile; warm and cold execution; completion beyond five seconds; cleanup
at the safety limit; config/resource/create/delete triggers; test-only qualification;
and real hook receipt without diagnostic polling. Only then repeat paired Tips
workloads and compare complete workflows, including navigation and total CPU.

**Reproduction and verification**

```sh
python3 agent/lsp/experiments/plain-mix-compile/proposal_boundaries.py \
  --output tmp/plain-mix-analysis/boundaries-new
python3 agent/lsp/experiments/plain-mix-compile/cancellation_trace.py \
  --output tmp/plain-mix-analysis/cancellation-new
```

Both probes completed with their expected assertions. The scope probe's final
formatting, warnings-as-errors compilation and ExUnit test passed. Its deliberately
bad test failed as expected; Credo is unavailable in the dependency-free fixture.
The cancellation probe's restored source passed formatting and compilation.
Python syntax checks passed. No Tips application code changed and its suite was
not rerun. No LSP connector is exposed in this session; exact upstream source and
runtime probes were used instead. Raw logs remain under `tmp/plain-mix-analysis/`.
The small probes are qualification tools, not production hook implementations.

Official source references:

- [Mix compile pipeline](https://github.com/elixir-lang/elixir/blob/v1.20.4/lib/mix/lib/mix/tasks/compile.all.ex#L17)
- [Source selection and digest capture](https://github.com/elixir-lang/elixir/blob/v1.20.4/lib/mix/lib/mix/compilers/elixir.ex#L438)
- [Compiler input read](https://github.com/elixir-lang/elixir/blob/v1.20.4/lib/elixir/src/elixir_compiler.erl#L32)
- [Build lock](https://github.com/elixir-lang/elixir/blob/v1.20.4/lib/mix/lib/mix/project.ex#L1000)
- [Test task compilation and execution](https://github.com/elixir-lang/elixir/blob/v1.20.4/lib/mix/lib/mix/tasks/test.ex#L593)
