# Neovim + ElixirLS beta implementation and workload results

2026-09-25. Branch: `experiment/elixirls-codex-v2`, based on `fd4e2da`.
Implementation and research remain on the experiment branch; nothing was merged
to main. The current installed artifact is `elixirls-neovim-beta-r7`.

## Disposition

The opt-in stack completed three actual Codex Sol workloads on Tips, using normal
project tools and operator-reviewed hooks. A separate controlled late-error task
delivered compiler feedback to an agent without a diagnostics-polling instruction.
This supports continued internal beta use on the tested host. It does not establish
production readiness, general platform support, or a measured productivity gain.

The approved [plan](BETA_PLAN.md) is implemented through the runtime, launch and
gate work below. Cold-cache reuse is still an experiment, with a new cross-worktree
source-path failure documented in [the cold-start review](COLD_START_REVIEW.md).

## What changed

- One opt-in launcher generates the MCP configuration and supplies the two feedback
  hooks through normal Codex session configuration. The separate compiler hook is
  disabled; Credo remains enabled. Application commands keep the normal toolchain.
- Root and session `flock` locks reject duplicate ownership. Separate inheritable
  server locks remain held by the compiler if it outlives Neovim. Owner records
  identify the hook connection; stale PID records do not determine ownership.
- Starting and exited are distinct states. ElixirLS death requires reconnection,
  closes the existing session, and reports disconnected feedback once. Repeated
  termination signals no longer interrupt cleanup. macOS zombie-only `killpg`
  EPERM is handled; cleanup removes the owner record and socket on normal exit.
- Verbose logs and unbounded event recording are opt-in. Scans are coalesced;
  compiler errors sort ahead of warnings. BOM comparisons use disk representation.
  Synchronization failures retain retry work, including unopened files.
- The MCP schema and parser expose only the seven approved read operations. Useful
  results retain freshness qualifications. Normal file edits, incremental builds,
  targeted invalidation, pending/in-flight retention, the fixed 250 ms collection
  window and five-second feedback budget remain.

Maintained Python follows the team harness's Ruff and strict Pyright profile.
[CHECKS.md](../../CHECKS.md) records the selected files and exact check commands.

## Actual Codex launch discoveries

Codex 0.156.1 requires a valid transport even for a disabled MCP entry. The generated
disabled Expert entry now includes `command = "/usr/bin/false"`; it is not launched.

Linked worktrees load repository hooks from the main checkout, not their own
`.codex/hooks.json`. This is explicitly tested in the pinned Codex source:
`hooks_list_uses_root_repo_hooks_for_linked_worktrees`. The supported command is
`bundle.py codex --workspace ...`, which supplies normal session hook configuration.
Bare `codex` in a generated worktree is insufficient for beta feedback.

The operator reviewed both hooks. A read-only `hooks/list` query then reported both
enabled and trusted. No hook-trust bypass was used for this cohort. The same command
definition uses the session cwd in each worktree, avoiding conflicting trust hashes.

The `/mcp` display showed connected with zero tools during inspection, while actual
model calls succeeded. The inspected Codex status path opens a separate MCP snapshot
connection; the ownership guard rejects that second connection. This explains the
observed inspection discrepancy without weakening single-session ownership. Treat
actual tool calls separately from that status display.

## Three actual Sol workloads

All three used `gpt-6-sol`, separate Git worktrees, independent databases and build
directories, and `/opt/homebrew/bin/elixir` and `/opt/homebrew/bin/mix` (Elixir 1.20.4,
OTP 29). No private compiler was put on the agent PATH. The prompts did not ask for
diagnostics polling or feedback receipts. They did explain the beta tool, and the
provider task required references under AGENTS.md: navigation use was not unprompted.

| Workload | Result | Validation captured from the run |
| --- | --- | --- |
| Provider API rename | `mode/0` became `provider_mode/0`; caller, test helper, tests and docs updated; configuration key unchanged | Expected failing acceptance test, then 26 passed / 1 excluded; full suite 508 passed / 4 excluded; format, compile, strict Credo and docs checks passed |
| Media ID parsing | Reused the positive-integer check while retaining canonical decimal parsing; max/overflow coverage across cast/dump/load | 30 focused tests before and after; format, compile and strict Credo passed |
| Repo timeout investigation, issue 200 | Isolated one-connection regression demonstrated elapsed time beyond a query timeout after a retryable disconnect; no production policy changed | Three focused tests passed; format, compile and strict Credo passed; failed exploratory approaches and repaired Credo finding retained in transcript |

Useful LSP evidence includes provider hover documentation and exact function
definitions/references before and after the rename; media symbols and private-helper
navigation; and Repo symbols, hover and a local-variable definition. Final diagnostics
were empty with observed-current feedback. There were 29 MCP calls, including one
initial provider references timeout followed by a successful retry. Early qualified
results and empty responses are preserved, not counted as universal success.

These application changes remain in their workload worktrees. They were not merged
into the integration or main branch. Issue 200 was not closed.

## Automatic late-error delivery

After the media task completed, a separate ordinary documentation prompt was sent
while a tester-created module slept for 12 seconds before producing an undefined
function error. The prompt did not mention the error, diagnostics, receipts or polling.

| Event | Seconds after seed creation |
| --- | ---: |
| Hook compiler error entered developer context | 13.633 |
| Agent explicitly acknowledged the unrelated compiler error | 23.778 |
| Final answer mentioned the error | 38.448 |

No MCP call occurred in this follow-up. The seed was removed afterward; independent
RPC observation showed generation 4 completed, no pending build and no diagnostics.
This proves controlled delivery and awareness before completion, not natural error
frequency, reduced task time, or a replacement for compile/tests.

Long builds continue after the bounded hook returns pending. Later eligible tools
or Stop collect feedback. If Stop remains pending, validation is unfinished; there
is no background message delivered after the agent has already stopped.

## Lifecycle and performance

The operator closed all three panes. No matching compiler process or socket remained,
and all root/session/server locks were free. Abrupt pane closure left stale owner
records. A subsequent protocol-client reconnect in each *same state directory*
replaced the record, reached readiness in 2.62–2.92 seconds and exited with code 0,
empty stderr, removed owner/socket and no observed survivors. These were protocol
reconnect checks, not additional model workloads or a graceful CLI-exit claim.

| Measurement | Result and scope |
| --- | --- |
| Three concurrent cold worktrees | MCP connection 0.417–0.432 s; readiness 68.65–69.96 s |
| Three concurrent warm restarts | Connection 0.412–0.420 s; readiness about 3.24 s |
| Separate 20-edit Tips probe | Median 1.482 s, p95 1.570 s, maximum 1.571 s; 20 completed builds |
| Ten unchanged hooks in that probe | Median 0.153 s, maximum 0.158 s |

Cold preparation was completed before the three model prompts. These measurements
must not be presented as time from first prompt or as a paired comparison with
the archived plain-Mix candidate. Readiness is an observed build condition, not
proof of exact source bytes. The stalled-RPC gate measured 5.002 s at the outer
boundary: five seconds is the implementation budget, not a hard realtime guarantee.

## Checks and boundaries

- Ruff lint/format and strict Pyright passed on maintained integration and team
  code. Live Pyright diagnostics were empty on the four maintained Python files;
  hover, definition and references worked. The final launch changes passed 41
  worktree-helper tests; the earlier full team suite passed 79 tests.
- Luacheck: zero warnings/errors. Seventeen Lua boundary cases passed. A Lua
  language server was unavailable; no Lua LSP pass is claimed.
- vv-mcp: 59 Rust tests, Clippy with warnings denied and Rustfmt passed. Installed
  protocol tests verified the seven-operation surface and excluded write operations.
- Ownership, duplicate launch, crash/reconnect, repeated termination, orphan
  compiler, stalled RPC, retry without another edit, resources, overlapping edits,
  same-second/preserved-time invalidation, BOM repair, diagnostics ordering and
  late-feedback gates passed in the saved runs.
- The saved older rollback bundle still navigated successfully, but its EOF path
  hit the previously known EPERM cleanup defect. A return to the new bundle passed.
  The old artifact was preserved; that strict rollback cleanup gate is not passed.
- CI configuration is updated; CI has not been run or pushed by this pass.

## Evidence and limits

Evidence root: `tmp/elixirls-v2/beta-implementation/`. Important entries:
`runtime-r2/`, `runtime-r3/`, `lua-r3/`, `budget-r3/`, `reconciliation-r4/`,
`feedback-r4-retry/`, `performance-r2/`, `cohort/`, and `seed-review/`.
The cohort retains prompts, complete raw transcripts, diffs, MCP messages,
hook trust inspection, late-feedback messages and teardown/reconnect records.
Earlier failed probes remain alongside successful reruns.

Runtime boundary results before r7 apply to unchanged runtime/compiler/Lua artifacts;
r7's actual Codex cohort separately validates its changed launch configuration.
The r7 manifest SHA-256 is
`ef51b585907951f8e585a799ec266488f228481db8f1c4a6ef56dca7d565f55a`.

Host/toolchain pins, the start-log/quiet-window readiness heuristic, late duplicate
incremental builds, finite hook delivery opportunities and unobserved filesystem
histories remain limits. Cross-client parity and larger-team capacity are untested.
The new dependency-cache path finding prevents enabling cross-worktree compiled
dependency seeds as an unconditional optimization.
