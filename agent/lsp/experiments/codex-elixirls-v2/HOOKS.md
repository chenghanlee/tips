# Automatic feedback after normal file edits

Date: 2026-09-24. Branch: `experiment/elixirls-codex-v2`.

Latest: [save/readiness/delivery/deadline fixes](FOUR_FIXES.md) and
[the second three-agent Tips cohort](DOGFOOD_V2.md). The timing tables below
describe the earlier implementation.

**Follow-up: [three Sol agents on real Tips workloads](DOGFOOD.md) exposed a
reload path that misses compilation, suppressed pending messages and unqualified
diagnostics. The fixture results below remain valid for their tested cases;
the adapter is not ready for rollout.**

**Working prototype: normal Codex `apply_patch` edits automatically reach
Neovim/ElixirLS, and compiler feedback reaches the agent through a PostToolUse
hook. No model-issued save, refresh, diagnostics query or restart is needed for
the ordinary edit/repair cases tested.** This follows the earlier
[Neovim experiments](NEOVIM.md); it does not use the discarded bridge patch.

The actual Codex test introduced an undefined function, quoted the automatic
compiler error before making another tool call, repaired the file, and quoted
the automatic cleared message. Unpredictable receipt identifiers added by the
test hook proved that those messages reached the model. The fixture was restored
exactly, and all observed owned processes exited.

This is an isolated experiment, not a rollout. Active client configurations,
application source and the main checkout's Claude integration were not changed.

## Five-second synchronous budget

The selected design keeps feedback synchronous with a **five-second maximum
feedback budget**, returning early as soon as the current build settles. This
replaces the initial 1.2-second budget. A completed ordinary edit still returns
in a fraction of a second. Five seconds is a starting policy, not a promise that
every project can compile within that time.

The Python deadline includes connection and RPC time; the compiler wait uses the
remaining budget with room for the final snapshot and response. Python start-up
and output are outside it, so there is no hard total cutoff; process startup and
OS scheduling add small overhead to measured tool latency. The host's
six-second timeout is a cleanup guard, not an extra second of compilation wait.
Calls with no new relevant source changes read current state without another
compilation wait. A multi-file tool invocation has one shared budget.

If an edited source is still compiling at the deadline, the hook reports pending
and arms one bounded `Stop` check. That check can wait up to five seconds more
when the agent tries to finish. It returns a synchronous continuation reason
with the final diagnostics, completion, or explicit remaining uncertainty. The
same pending edit cannot repeatedly re-arm Stop through unchanged tool calls.
A later edit can arm a new final check, including during a Stop continuation.

The design deliberately has no asynchronous diagnostic delivery. Receiving a
result at an edit or final-check boundary avoids adding a delayed diagnostic
message to a later source revision. The existing source-generation and overlap
checks remain necessary; the longer budget does not fix the compiler overlap
bug. If both waits expire, the result remains unverified rather than blocking
the agent indefinitely or silently claiming success.

The new [budget acceptance probe](neovim_hook_budget_probe.py) covers three-,
eight- and fifteen-second compilations, early repair feedback, unchanged tools,
final-edit delivery, stalled RPC and prevention of repeated Stop continuations. Its initial
run failed against the old 1.2-second behavior, as expected.

| Final local test | Observed hook wall time | Result |
|---|---:|---|
| Three-second compile error | 3.335 s | Error returned synchronously |
| Fast repair | 0.318 s | Cleared feedback; no fixed five-second delay |
| Eight-second compile | 5.034 s | Pending |
| Stop immediately after that edit | 3.230 s | Compiler error returned through continuation |
| Unchanged tool during pending build | 0.101 s | No extra compile wait or duplicate context |
| Fifteen-second compile, after the edit budget | 5.041 s at Stop | Still pending; repeated Stop did not loop |
| Neovim deliberately paused | 5.067 s | Unavailable; hook did not hang |

The fixture's process startup/scheduling overhead is included in this table.
Current evidence and exact tested source hashes are in
[hook-budget-evidence.json](hook-budget-evidence.json).
The existing worktree-isolation, atomic edit, failure and lifecycle suites passed
again. They caught a transient pending-message regression on unchanged tools;
the corrected collector retains previous feedback while late publications settle.

The final actual Codex test used an eight-second compile. The edit hook returned
pending in 4.969 seconds. Codex finished its response without another tool call;
Stop delivered the compiler error, which Codex quoted before repairing the file.
Repair feedback took 0.381 seconds; the next Stop was quiet. All receipts were
verified, the source was restored exactly, and all observed owned processes
exited. Fixture formatting, warnings-as-errors compilation, ExUnit, Python syntax
and documentation checks passed. Credo remains unavailable in the dependency-free
fixture. Actual Claude model delivery remains untested.

## Root problem: nine whys

1. Why did normal edits need a manual save or refresh? They changed disk outside
   the editor that owns the LSP documents.
2. Why did a filesystem notification not always fix this? It notified the
   compiler, but a loaded Neovim buffer could still contain old text.
3. Why did headless Neovim need help? It had no interactive focus cycle to trigger
   the usual external-file checks. Its existing `checktime` mechanism still works.
4. Why not ask the agent to run that check? It would have to remember hidden
   editor bookkeeping after every possible writing tool.
5. Why did automatic refresh alone not deliver editor-like feedback? Diagnostic
   notifications updated Neovim's cache, not the agent's conversation.
6. Why use PostToolUse? It is the host's existing extension point after ordinary
   tools finish, including writes made outside Neovim.
7. Why return `additionalContext`? It is the documented field for supplying that
   feedback to the model; ordinary hook stdout is not an equivalent contract.
8. Why would another save instruction fix the root cause? It would not move
   synchronization and delivery into the integration that owns them.
9. Why would another refresh tool fix it? It would leave the same bookkeeping
   with the agent. The last two whys leave the root answer unchanged.

First principles: the integration has two responsibilities: keep editor state
aligned with saved files, and deliver observed compiler feedback to the agent.
Neither responsibility requires a new language server or a new editing workflow.

Occam: reuse Neovim's LSP client, watchers, reload and diagnostics APIs; use the
published MCP adapter for requests and the hosts' documented hook output for
feedback. Pareto: prioritize normal edits, useful errors, repair, bounded waits
and process cleanup. Avoid patch parsing, a second filesystem watcher, a daemon
registry of our own, or a new agent tool catalog.

## What runs

```text
Agent's normal writing tool -> saved source files
                                 |
Neovim's existing watcher -> automatic buffer reload -> ElixirLS compile
                                 |
PostToolUse -> shared Python hook -> Neovim diagnostic cache
           <- additionalContext: errors / cleared / pending / uncertain

MCP queries -> published vv-mcp -> same Neovim -> same ElixirLS
```

- [neovim_launcher.py](neovim_launcher.py) eagerly starts one private headless
  Neovim per client/worktree, then starts the published `vv-mcp`. This lets hooks
  work before the agent calls an LSP tool. Neovim uses its documented `--embed`
  stdin lifetime. The launcher forwards raw MCP input bytes, without implementing
  MCP, and gives the bridge a private pipe so a killed launcher also causes EOF.
- [neovim_sync.lua](neovim_sync.lua) observes existing watcher/build events,
  checks relevant saved source content, reloads only unmodified loaded buffers,
  and collects compiler errors/warnings. It detects creation, deletion and atomic
  replacement. Unsaved editor changes are preserved and reported as a conflict.
- [neovim_hook.py](neovim_hook.py) runs the bundled `nvim --server --remote-expr`
  client under a subprocess timeout, observes the five-second feedback budget, and
  emits informational PostToolUse JSON or a pending-edit Stop continuation. The
  timeout kills a stalled client near the deadline; it is not a hard total cutoff
  (Python start-up and output are outside it). Identical ordinary feedback is
  deduplicated.
- [neovim_init.lua](neovim_init.lua) keeps the standard ElixirLS configuration and
  the earlier adapter read-refresh and startup-message adaptations. Published
  Neovim, vv-mcp and ElixirLS binaries remain unchanged.

The collector hashes Git-listed, nonignored `.ex`, `.exs` and `.heex` regular
files. This observes the actual saved result of any writing tool instead of
trying to interpret every tool's patch or shell command. It is a bounded source
scan on watcher/hook events, not a new background filesystem watcher.

The launcher waits up to ten seconds for initial compiler feedback before
serving MCP. Larger projects may remain pending. A completed build plus a short
diagnostic quiet period is an observed status hint, not a correctness guarantee.

## Codex and Claude share the feedback contract

The successful Codex test used CLI 0.156.1 and its documented command-hook output:

```json
{
  "hookSpecificOutput": {
    "hookEventName": "PostToolUse",
    "additionalContext": "ElixirLS: lib/caller.ex:2:19: error: undefined function missing_local/0"
  }
}
```

The same script accepts Claude's `PostToolUse` and `PostToolUseFailure` input and
returns the matching event name. Its `Stop` handler uses the shared top-level
`decision`/`reason` contract. No compiler or editor logic is host-specific.

| Host | Hook matching needed | Validation here |
|---|---|---|
| Codex | `apply_patch` and `Bash` (`exec_command` follows the shell hook contract) | Actual model-driven edit/repair with quoted receipts |
| Claude Code | `Edit`, `Write`, `Bash`; also `PostToolUseFailure` for shell commands that write and then fail | Local hook-contract tests with real Neovim/ElixirLS, including atomic repair and failed-shell input |

Actual Claude Code model delivery is **not yet tested**. This establishes a
shared implementation and tested event/output contracts, not completed host
parity. Claude's future launcher configuration should use the same MCP launcher
and shared hook, with its own documented settings syntax. Both hosts support
`additionalContext`; neither requires an invented context-delivery protocol.
See the official [Codex hooks documentation](https://learn.chatgpt.com/docs/hooks)
and [Claude Code hooks documentation](https://code.claude.com/docs/en/hooks).

The prototype uses synchronous bounded hooks. If compilation exceeds the budget,
the agent receives an explicit pending message. A later matching tool can read
completed feedback without waiting, and Stop checks an edit left pending even
when no further tool runs. It does **not** push completion into an idle agent.
The final check is also bounded; a still-running compiler remains unverified.

## Inversion: try to make the feedback wrong

| Attempt | Result |
|---|---|
| Edit a loaded caller without any LSP query | Buffer reloaded automatically; compiler error surfaced |
| Repeat the hook without changing source | No repeated error context |
| Edit ALPHA while BETA has the same module names | BETA stayed unaffected |
| Replace the file atomically to repair it | Previous errors cleared after compilation |
| Create an untracked erroneous file, then delete it | Error appeared, then cleared |
| Simulate a shell tool that wrote and then failed | Claude failure-event output still carried the compiler error |
| Give Neovim unsaved changes before a disk edit | Reload refused; unsaved buffer preserved; explicit conflict |
| Compile for three seconds with a 500 ms hook budget | Prompt pending response, then completion on a later hook |
| Save a second version during a controlled slow build | Explicit uncertain feedback; no clean certificate |
| Stop ElixirLS while Neovim remains alive | Explicit unavailable feedback |
| Remove the whole session | Explicit unavailable feedback |
| Close MCP stdin after initialization | Launcher, bridge, Neovim and observed LSP descendants exited |
| Kill the launcher while the host keeps stdin open | Observed descendants exited through private-pipe EOF |

Stress tests found and corrected two implementation issues. The initial eager
launcher leaked Neovim after Codex exited; using embedded stdin ownership fixed
that. A separate hard-kill test exposed the bridge's inherited input pipe; a
private pipe fixed it. A stopped-server test initially reported pending; the
collector now distinguishes unavailability. Its first fix returned too early
during initialization; preserving the bounded startup wait fixed that regression.
Raw failed and successful runs are retained, rather than discarded.

## Remaining limits

The previously reproduced equal-size edit during a slow build can still leave
Mix/ElixirLS results stale. The collector conservatively latches an uncertain
state when it observes saved changes during compilation. It does not repair the
compiler, automatically restart ElixirLS, or claim a later no-op build proves
freshness. Normal compilation and tests remain required. The overlap detector
is observational; it is not proof that every possible overlap was detected.

Build logs/telemetry are specific to ElixirLS 0.31.1, not a stable LSP readiness
protocol. The earlier vv-mcp operation-table adaptations also use internal APIs.
An upstream-supported refresh/status interface is preferable before rollout.
Dialyzer is disabled. Full Tips model-driven editing is now covered by the
[dogfood follow-up](DOGFOOD.md), with negative reliability findings. HEEx, umbrellas, dependency
or `mix.lock` changes, symlinked sources, Linux/Windows, parallel hook calls and
large-repository scan overhead are not validated by this fixture.

Performance figures are warm, tiny-fixture observations, not a one-second Tips
guarantee. The initial 1.2-second prototype's final Codex run measured 0.277 seconds for the error hook
and 0.253 seconds for repair feedback. These are hook execution times, not model
response or UI latency. An earlier successful run measured 0.257/0.260 seconds.

## Reproduce

Use the pinned dependencies in [neovim-versions.json](neovim-versions.json),
Python with the listed packages in the vendor's `python/` directory, the installed
ElixirLS/Elixir/OTP versions, `unbuffer`, Git and process-table access. This host's
vendor directory is `tmp/elixirls-v2/neovim-vendor`. No system install is required.
Every output directory must be new.

```sh
experiment=agent/lsp/experiments/codex-elixirls-v2
vendor="$PWD/tmp/elixirls-v2/neovim-vendor"
python3 "$experiment/neovim_hook_probe.py" --vendor "$vendor" --output tmp/elixirls-v2/hook-replay
python3 "$experiment/neovim_hook_inversion_probe.py" --vendor "$vendor" --output tmp/elixirls-v2/hook-inversion-replay
python3 "$experiment/neovim_hook_budget_probe.py" --vendor "$vendor" --output tmp/elixirls-v2/hook-budget-replay
python3 "$experiment/neovim_hook_codex_probe.py" --vendor "$vendor" --output tmp/elixirls-v2/hook-codex-replay
python3 "$experiment/neovim_hook_codex_probe.py" --vendor "$vendor" --output tmp/elixirls-v2/hook-codex-budget-replay --slow-final-edit
```

The first three commands use local synthetic Git fixtures and real compiler/MCP
processes. The last two use the authenticated Codex CLI and send only generated
synthetic source to the model. It supplies temporary MCP/hook configuration via
CLI options, uses the normal workspace-write sandbox, and bypasses hook trust
review for this invocation to run the reviewed experiment hook. Inspect its
generated `command.json` and hook script before replaying. Do not treat this
test invocation as a recommended permanent trust setting.

Unlike the earlier exploratory probes, these acceptance scripts assert
their expected outcomes and exit nonzero on failure. The actual Codex probe also
checks that exactly two ordinary file edits occurred, the model quoted each
receipt at the right point, the source was restored, and no observed owned
process remained. It does not count an exit code alone as success.

Initial prototype results are in [hook-evidence.json](hook-evidence.json). Raw results,
transcripts, audit receipts and logs remain under this worktree's
`tmp/elixirls-v2/hook-*` directories. Those fixture checks did not change
application source. The later dogfood report includes application changes and
full-suite results in separate worktrees.

Baseline checks passed: the original three hook acceptance scripts, Python syntax, local
documentation links, fixture formatting, compilation with warnings as errors,
and the fixture's ExUnit test. `unbuffer mix credo --strict` could not run because
the dependency-free fixture has no Credo task. This is recorded as unavailable,
not a passing check.
