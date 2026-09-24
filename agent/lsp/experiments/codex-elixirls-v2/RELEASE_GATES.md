# Installed-stack release gates

Date: 2026-09-24. Branch: `experiment/elixirls-codex-v2`.

**Historical report.** The internal-rollout assessment below was withdrawn after
adversarial review found operational failures. See [OPERATIONAL_FIXES.md](OPERATIONAL_FIXES.md)
for the repairs, new gates, and current provisional status. Earlier successful
checks remain evidence for their tested paths, not for the missing failure paths.

The three outstanding gates passed for the pinned macOS arm64 stack. The matching
Mix, ElixirLS, Neovim, vv-mcp and adapter are packaged, startup symbols carry
feedback, and three actual `gpt-6-sol` Codex CLI agents completed real Tips work
against that installation. This supports an opt-in internal rollout on the tested
versions. It does not establish a long-term production failure rate.

The active user configuration was not changed. Application workload patches stay
in separate experiment worktrees; no GitHub issues were closed or application
changes merged. The main detached checkout remains clean.

## Gates and results

| Gate | Evidence |
| --- | --- |
| Package the matching stack | Clean build from checked upstream archives and locked dependencies; private Mix compiled with warnings as errors; installation manifest verified |
| Independent runtime | Relocated runtime-only copy works through MCP without its build sources or download cache |
| Reject a broken pairing | Replacing the private compiler with stock Mix, or changing synchronization Lua, fails the integrity check |
| Qualify empty startup symbols | Actual empty document-symbol and workspace-symbol responses carry pending feedback; useful symbols remain available; warm responses report current |
| Actual three-agent cohort | Three separate `codex exec -m gpt-6-sol` processes, private configurations, worktrees, databases and ports; all exit successfully |
| Cold-start edit | All first document-symbol responses show generation 1, building=true, completed=-1, and pending after the agents' first edits |
| Error and repair | All agents observe the seeded undefined-function error and recover after an ordinary disk edit; no save/index/restart workaround |
| Nonempty hook delivery | All agents repeat unpredictable receipts found in their hook audits; the repository agent receives the actual error through PostToolUse |
| Fixture exclusion | Zero watched-file notifications for each assigned worktree's `tmp/` in the recorded streams |
| Lifecycle | No observed descendants remain after any of the three Codex sessions exits |

Installed bundle: `agent/lsp/vendor/elixirls-neovim-v1/` (ignored output).
Build and launch instructions: [INSTALL.md](INSTALL.md).
The install pins Elixir 1.20.4 / OTP 29.1, Neovim 0.12.5, ElixirLS 0.31.1,
vv-mcp 0.3.4 at the recorded source commit, and Python 3.14.3.
Host Python and OTP remain explicit prerequisites; this is not an all-platform
standalone distribution.

## Real Tips workloads

All checkouts start at current `origin/main`,
`5fe1cda1bb16bea97df77c078ca0789ae641f909` (PR #251).
Project 15 supplied the context: provider configuration #49, media/schema #38,
and the open checkout-retry investigation #200. The first two are bounded
maintenance exercises in those implemented areas, not claims to complete the
broader project issues. The third directly investigates #200.

| Agent | Workload | Final checks | Agent elapsed |
| --- | --- | --- | --- |
| Provider | Rename ProviderConfig.mode/0 to provider_mode/0 across callers, tests and docs; preserve runtime `:mode` and stub/real behavior | 26 tests passed, one real-provider test excluded; format, warnings-as-errors, strict Credo and docs check passed | 195.17 s |
| Media | Reuse the existing bigint validator; cover maximum/overflow through cast/dump/load for all three ID-bearing targets | 30 tests passed; format, warnings-as-errors and strict Credo passed | 182.12 s |
| Repository | Reproduce retryable connection loss using the real Repo/Postgrex/DBConnection stack and an isolated one-connection pool | 3 tests passed; format, warnings-as-errors and strict Credo passed; independent final replay also passed | 464.89 s |

Each agent first inserted an explicitly authorized temporary undefined-function
probe in its task module while ElixirLS was compiling. All removed the probe.
This was fault injection, not an application defect discovered in main.
Provider demonstrated a failing renamed-API acceptance test before implementation.
Media's new boundary assertions passed before and after its behavior-preserving
refactor. Repository tried ordinary query timeout and orderly backend termination
before establishing the retryable transport-loss reproduction. Its intermediate
failed tests remain in the raw trace.

The repository result proves possible deadline extension under that controlled
transport fault. It does not choose a global production retry policy. Its evidence
note recommends deciding which request paths need an absolute deadline or zero
checkout retries; the agent left production configuration unchanged.

## Feedback and latency

| Agent | Hook calls | Median recorded hook time | Maximum | Repair feedback |
| --- | --- | --- | --- | --- |
| Provider | 23 | 0.063 s | 4.775 s | 2.022 s |
| Media | 24 | 0.069 s | 4.765 s | 2.061 s |
| Repository | 31 | 0.060 s | 4.759 s | 2.132 s |

These are the hook's own elapsed measurements, not end-to-end model response
latency. The cold edits exhausted the bounded wait and returned pending. Later
repair feedback arrived synchronously. The five-second default therefore stays.

Delivery details matter: provider and media saw the error through MCP diagnostics
and received pending/completed messages through hooks. Repository also received
the error itself through PostToolUse and then a cleared message. The result is
not a claim that every diagnostic was delivered through every channel.

One provider references request timed out while the seeded compilation was
failing. Its response retained explicit `errors.elixirls=timeout` and failed-state
qualification. The same references query succeeded after repair. No permanent
uncertainty state or forced restart was needed. The media agent explicitly noted
that an empty pending diagnostic response did not establish a clean build.

## Compiler and adapter boundaries

- 81 server tests passed against a copy of the freshly packaged source and its
  private compiler, including worker death, retained invalidation and batching.
- 12 Lua boundary checks passed, including the new symbol qualification check.
  That check failed before adding document/workspace symbols to the wrapper.
- Actual installed MCP/hook reconciliation passed: rejected first notification,
  unopened resource with preserved timestamp, deletion, recreation, and another
  edit during compilation. Fresh-VM assertions checked both the resource owner
  and its compile-time caller without compiling or repairing their artifacts.
- An eight-second build returned pending in 4.774 seconds; an unchanged hook took
  0.091 seconds; later feedback and executable assertions passed.
- The upstream full-server compile still reports its existing parser warning.
  The private Mix modules compiled with warnings as errors. ElixirLS has no
  Credo task; all three Tips workloads passed strict Credo.

Packaging found one real prerequisite problem: the older precompiled Hex archive
could not load Hex.State on OTP 29. The recipe now builds pinned Hex 2.5.1 source.
No global tool installation was modified.

The remaining boundaries are unchanged: unobserved transient filesystem history
cannot be reconstructed, late notifications may require another incremental
build, and editor compilation status does not replace normal application tests.
See [CORRECTNESS.md](CORRECTNESS.md) and [BATCHING.md](BATCHING.md).

## Evidence and replay

[release-gates-evidence.json](release-gates-evidence.json) records the bundle hash,
checks, MCP replies, receipts, timings and cleanup assertions. Raw command logs,
MCP transcripts, hook audits, read-only event snapshots, workload patches and
agent finals are in `tmp/elixirls-v2/release-gates/`.

Worktree branches:

- `experiment/elixirls-gate-provider`: `/private/tmp/tips-lsp-release-provider`
- `experiment/elixirls-gate-media`: `/private/tmp/tips-lsp-release-media`
- `experiment/elixirls-gate-repo`: `/private/tmp/tips-lsp-release-repo`

Replay entry points are `build_bundle.py`, `bundle_probe.py`,
`neovim_reconcile_probe.py --bundle ...`, `neovim_patch_boundaries.lua`, and
`release_dogfood.py`. Use fresh output/state directories and fresh workload
checkouts. The cohort runner requires passing baselines before launching agents.
