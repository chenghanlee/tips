# Operational fixes and plain-Mix comparison

2026-09-25. Branch: `experiment/elixirls-codex-v2`.

**The four reviewed operational failures are fixed and their boundary tests pass.
Keep the current stack provisionally. Plain Mix provides fast warm feedback, but
the tested alternatives do not preserve our long-build behavior.** Active Codex
and Claude configuration remains unchanged.

[Contract](LONG_BUILDS.md), [structured evidence](operational-fixes-evidence.json),
[runtime delta against Fable's review snapshot](operational-fixes.patch), and
[installation instructions](INSTALL.md).

## What changed

| Failure | Small correction | End-to-end result |
| --- | --- | --- |
| Compiler warmup delays MCP startup | Wait for the owned Neovim registry entry, not compilation. Keep results qualified during startup, including an early `no_lsp` error. | Cold Tips MCP initializes in 0.417 s; compilation remains pending. |
| Neovim death silently starts/adopts another instance | Make vv-mcp's existing `--instance-id` bind the MCP session as well as CLI operations; remove the redundant managed fallback. Hooks verify the same instance ID, PID, and socket. Launcher monitors its child. | Racing an MCP request against Neovim death yields an explicit failure; launcher exits; no managed replacement. A hook rejects a different instance at the same root. |
| Failed scan discards build completion | Record build state independently of a fallible scan. Preserve a retryable scan error and retry through the existing collection path. | One injected end-of-build scan failure reports `sync_error`, with `building=false`. The next hook returns the actual compiler error in 0.162 s, without another edit. |
| Stalled RPC prevents shutdown | Remove RPC from cleanup. Use Neovim's supported `detached=false` setting so ElixirLS shares the private process group; terminate that group, including remaining compiler processes. | Paused Neovim exits through EOF or SIGTERM in about 2.03 s; no observed survivors. A compiler already inside a slow module is also terminated. |

The instance-binding change is a small additional patch to the already patched
vv-mcp dependency. No protocol bridge, new build queue, retry service, or watcher
framework was introduced. Existing incremental compilation, 250 ms batching,
pending/in-flight retention, fixture exclusions, and qualified results remain.

The first candidate's shutdown test exposed a detached ElixirLS orphan. That led
to the supported `detached=false` configuration and process-group cleanup. The
earlier failed test's verified orphan was explicitly cleaned up; the final tests
observe no survivors. The initial test harness also now always cleans up after
assertion failure.

## Defined long-build behavior

Five seconds bounds feedback collection, not the compiler's lifetime. When the
budget expires, the hook reports pending and ElixirLS continues. Subsequent edits
remain eligible for another incremental build. An unchanged eligible tool checks
new feedback without waiting another five seconds. Stop can make one further
bounded check; if it still reports pending, validation remains unfinished.

There is no unsolicited asynchronous message. If the session ends before a result
can be collected, shutdown terminates the outstanding compiler; this is not a
successful validation. A repeated Stop does not trap the agent in an endless loop.

The installed-stack budget probe passed an eight-second compile followed by Stop
delivery, and a fifteen-second compile that outlasted both budgets and was later
collected by an ordinary hook. It also verified a stalled hook RPC reports
unavailable near the five-second deadline. Detailed results are in
`tmp/elixirls-v2/operational-fixes/long-builds/results.json`.

## Actual agent delivery without diagnostic polling

Two new `gpt-6-sol` Codex sessions used the installed bundle and Codex's normal
MCP startup timeout. These were controlled tests on generated Elixir fixtures,
not another three-workload Tips cohort. Prompts explicitly injected a slow compiler
error and requested exact feedback receipts; they did not request diagnostic
polling. Neither agent called an MCP tool or manually ran a compiler.

| Delivery path | Observed sequence |
| --- | --- |
| Final edit, then Stop | Normal `apply_patch` → pending in 4.743 s → Stop delivers undefined-function error → agent quotes the unpredictable receipt before repair → repair feedback in 0.491 s |
| Later ordinary tool | Normal `apply_patch` → pending in 4.738 s → one shell `sleep 5` representing other work → that tool's hook delivers the error → agent quotes its receipt before repair → repair feedback in 0.513 s |

Both source files were restored exactly. Both sessions exited with no observed
descendants remaining. The full prompts, events, hook audits, commands, and results
are in `tmp/elixirls-v2/operational-fixes/late-agents/{stop,tool}/`.

This establishes delivery and model receipt through both channels without a
diagnostic request. It does not measure how often an unprompted production agent
will notice or act on feedback. The original three Tips workloads remain separate
evidence in [RELEASE_GATES.md](RELEASE_GATES.md).

## Plain Mix: verified benefits and boundaries

The comparison uses stock Elixir 1.20.4 / OTP 29.1 with `MIX_ENV=test` and
`unbuffer mix compile --warnings-as-errors`. It runs in an isolated Tips worktree
at `5fe1cda1bb16bea97df77c078ca0789ae641f909`, matching the prior release cohort.
The application source was restored after each fault experiment.

| Plain-Mix case | Measured wall time | Outcome |
| --- | --- | --- |
| Cold Tips preparation, including dependencies | 50.20 s | Succeeded; not within a five-second hook |
| Warm Tips no-op, three runs | 0.657–0.689 s | Succeeded |
| Warm Tips source edit | 0.742 s | Succeeded |
| Warm Tips undefined-function error | 0.653 s | Correct compiler error |
| Warm Tips repair | 0.742 s | Succeeded |
| Cancel an eight-second module, attempt one | 4.982 s including cleanup | Compiler terminated before reporting the error |
| Cancel the same source again | 5.055 s including cleanup | Again no completed compilation or error result |
| Wait for that same source to finish | 8.501 s | Actual undefined-function error delivered |
| Incremental repair after cancellation | 0.554 s | Fresh-VM ExUnit acceptance passed |

These independently support Fable's warm-feedback performance claim. They are
not a paired latency benchmark against the final Neovim implementation. The cold
measurement was made before warming the worktree; the later warm measurements
are explicitly separate.

The cancellation probe records and reaps its full owned process tree before
allowing another edit. Both attempts left no observed survivors. It is an
experimental compiler invocation, not an installed Codex hook. The 5.055 s sample
also shows that cleanup needs headroom if this candidate ever promises a hard
five-second total deadline.

The three timeout policies remain materially different:

1. **Return while stock Mix continues:** preserves progress but allows another
   write to overlap compilation. Our preceding independent counterexample produced
   B on disk and in the manifest while both the target and compile-time caller
   returned A after two later successful incremental builds. See
   `/private/tmp/tips-fable-release-review-9xb93ihp/codex-verification/long-compile/`.
   This is a tested continuation-policy counterexample, not a claim that every
   synchronous compile-hook implementation fails.
2. **Cancel and retry:** can remove that continuing writer/compiler overlap when
   all compiler processes are reaped first. The new probe also demonstrates its
   progress problem: a module that always takes longer than the budget never
   produces its error through repeated bounded attempts. A later unlimited shell
   compile could finish, but that changes automatic late-feedback behavior.
3. **Wait to completion:** produces the compiler result in the slow fixture,
   while exceeding the current bounded-feedback rule. This is a legitimate
   alternative if we deliberately change the latency contract and establish
   exclusive writes; starting a hook alone does not lock source files or repair
   an already inconsistent manifest.

A larger finite budget changes the frequency of this boundary. It does not
remove it. Stock ElixirLS navigation would also retain its independently observed
staleness risk if we removed the targeted invalidation/retention patches.

The proposed complete CLI hook still needs change selection, hook integration,
and a chosen deadline policy. No three-agent plain-Mix cohort was run: the policy
tests already distinguish its contract from the retained stack. There is no basis
here to delete the existing compiler recovery or session lifecycle work.

## Why the retained solution is small

First principles separate three responsibilities: compiler correctness for observed
edits, bounded feedback latency, and ownership of the processes providing it.
Changing the feedback producer does not automatically satisfy the other two.

Occam's razor favors the existing instance-ID router, Neovim's documented process
setting, OS process groups, and retrying the existing scan. Pareto's rule favors
fixing the four demonstrated failures before replacing a stack whose observed-edit
recovery is already tested. The seven root-cause questions in [LONG_BUILDS.md](LONG_BUILDS.md)
lead to these boundaries without adding another coordination mechanism.

## Verification and artifacts

- Five baseline failure checks reproduced against the old bundle.
- Seven installed-stack operational checks passed, plus a controlled check that
  shutdown kills a compiler after it enters a slow module.
- Actual cold Tips startup/shutdown passed: 0.417 s initialization, 0.118 s shutdown
  during a started project build, no observed survivors.
- 58 vv-mcp Rust tests passed. The initial two missing-executable failures were
  resolved by adding the bundled Neovim to the test PATH.
- 13 Neovim Lua boundary tests passed, including qualification of an early
  symbol-request error.
- Compiler reconciliation passed preserved-timestamp edits, dropped notification
  retry for an unopened file, resource deletion/recreation, another edit during
  compilation, and a build continuing past the hook deadline. Fresh-VM behavioral
  assertions passed for each state.
- Both controlled Sol delivery sessions passed; neither polled diagnostics.
- Python syntax checks passed. Restored Tips source passed formatting, compilation
  and strict Credo. The dependency-free Mix fixture passed formatting and fresh-VM
  ExUnit; its Credo task is unavailable, recorded as an expected missing-task result.

Raw evidence lives under `tmp/elixirls-v2/operational-fixes/`. Early runs retained
their logs: a wrong Credo flag and a fixture expectation were corrected before the
successful checks. The structured evidence separates the completed Tips measurements
from the subsequently completed deadline fixture.

Installed bundle: `agent/lsp/vendor/elixirls-neovim-v2/`.
Manifest SHA-256:
`80f20594670350ae2f1a3355a7c3b196adf82891ad1de9935e2aa76811e13f16`.
The fresh source build used the existing pinned download cache. After the first
boundary run, three adapter files were reinstalled using the recipe's adapter-copy
stage and their tracked hashes updated; that exact change is recorded in
`adapter-install-update.json`. The final runtime files match the experiment source
and `doctor` verifies all 1,312 tracked files. No installed compiler/server patch
was changed by these operational repairs.

Replay entry points: `operational_probe.py`, `tips_startup_probe.py`,
`late_feedback_probe.py`, `neovim_hook_budget_probe.py --bundle ...`,
`neovim_reconcile_probe.py --vendor ... --bundle ... --slow-budget`, and
`plain_mix_feedback_probe.py` (or `--deadlines-only` for the isolated policy tests).

This remains a provisional, pinned macOS stack. These tests close the four reviewed
failures; they do not establish a production failure rate, cross-platform support,
an upgrade/rollback drill, or freshness for source histories neither watchers nor
reconciliation observed. Normal project compilation and tests remain necessary.
