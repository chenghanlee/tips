# Three Tips workloads after the four fixes

Date: 2026-09-24. Branch: `experiment/elixirls-codex-v2`.

**All three application workloads passed. The save, delivery and deadline fixes
passed their boundary tests. The adapter remains experimental because the
conservative uncertainty latch still disables useful semantic results after an
overlapping edit.** The media agent encountered that limitation in this rerun.

[Implementation and boundary tests](FOUR_FIXES.md).
[Machine-readable cohort evidence](dogfood-v2-evidence.json).
[Machine-readable boundary evidence](four-fixes-evidence.json).
The [first cohort](DOGFOOD.md), its worktrees and raw evidence remain intact.

## Actual rerun

Three concurrent `codex exec -m gpt-6-sol` sessions used fresh worktrees at
`81501387eb77b220c95693f58076f7f8255da1b0`, separate dependency copies, build/index
directories, database suffixes and ports. Each launched its own headless Neovim,
vv-mcp 0.3.4 and ElixirLS 0.31.1. The model prompts retained normal file edits and
prohibited manual save/refresh/restart workarounds. Initial warmup remained ten
seconds; the cold builds were not prewarmed away for the experiment.

| Workload | Targeted tests | Full suite | Agent session |
|---|---:|---:|---:|
| Provider API rename, callers, tests and docs | 26 passed, 1 excluded | 508 passed, 4 excluded | 208.4 s |
| Media bigint validator reuse and cast/dump/load boundaries | 30 passed | 508 passed, 4 excluded | 178.2 s |
| Seeded health private-function rename repair | 4 passed | 508 passed, 4 excluded | 152.7 s |

Baseline compilation and original targeted tests passed before launch. For
health, only the private definition was renamed before launch; the model then
reproduced the compile failure and repaired its caller. This is an injected
scenario, not a defect discovered on main.

Each agent passed formatting, warnings-as-errors compilation, strict Credo and
targeted tests. Provider demonstrated a failing acceptance test for the new API
before implementing it, then passed documentation checks and the full suite.
Media tested the existing behavior and expanded boundaries before its production
refactor. The parent independently ran the media and health full suites after
their sessions. All final diffs passed `git diff --check`; changes remain isolated
and unmerged. Browser and real-provider tests stayed excluded.

## What changed in the feedback experience

**Health's stale diagnostics are fixed in the real application.** The LSP log
records the repaired source in `didSave` at line 484, a build start at 488 and
successful completion at 504 (1.990 s). Its edit hook returned after 2.232 s with
generation 1 completed. Subsequent MCP diagnostics were empty, definition resolved
to `query_database/0`, and references included its real caller and definition.
This contrasts with the first cohort's reload without a subsequent build.

**Repeated edits receive feedback.** Media edited four source generations. All
four returned explicit uncertainty messages, instead of silently deduplicating
later edits with the same wording. Four random receipts were emitted; the agent
quoted the final one, `bc750aa2fb44`, and described repeated uncertainty in its
final response. This directly proves model receipt of that final message; the
audit records the other three outputs without claiming each receipt was quoted.

**Empty diagnostics no longer conceal known uncertainty.** Media's final
diagnostics response contained `error.code = elixirls_uncertain`, an empty
diagnostic cache and generation/completion 3/3. It did not return an ordinary
empty success. The agent correctly used normal checks instead of citing that
cache as verification. Provider and health received successful navigation and
ordinary diagnostic responses after their builds settled.

**No hook timeout occurred in this cohort.** All 78 hooks were under 2.4 seconds.
This cohort did not itself exercise a five-second compiler wait; the separate
real long-build and paused-RPC tests did, with measured full waits below five
seconds and successful Stop retry after expiry.

| Agent | Hook calls | Median | Maximum | Nonempty hook messages |
|---|---:|---:|---:|---:|
| Provider | 29 | 0.067 s | 2.366 s | 0 |
| Media | 27 | 0.066 s | 0.098 s | 4 |
| Health | 22 | 0.069 s | 2.232 s | 0 |

Provider and health's edited builds completed without new compiler errors.
Their hooks were intentionally quiet: no earlier error or pending message had
been delivered through the hook to clear. Their startup “pending” messages came
through MCP, not PostToolUse. The collector now keeps those observation and
delivery histories separate. A quiet first clean build is existing behavior,
not evidence of a suppressed pending edit.

All 23 MCP calls named files under their assigned worktrees: 11 ordinary results
and 12 explicit pending/uncertain responses. This is root-use evidence, not a
cross-root rejection claim. Cold ElixirLS builds took 63.5–64.1 s under concurrent
load. Runtime Lua/init copies matched the source hashes used in the boundary
tests. All three sessions exited with no observed owned processes remaining
before parent cleanup.

## Remaining limitation and next decision

The media agent changed its test file during the cold build and latched
uncertainty. Later builds finished, but the session never recovered semantic
readiness. Definition queries remained blocked; diagnostic reads explicitly
carried the uncertainty. The agent reported that this feedback did not help
verify its change. The cold-start boundary fixture also shows that actual
compiler errors are now retained under that warning rather than hidden.

That policy is still too broad for the desired editor-like experience. These
four fixes do not settle the separate choice between an ordinary editor
freshness contract and scoped automatic recovery for the demonstrated Mix
overlap bug. No mixClean loop, upstream protocol change or automatic clearing
was added. Provider test fixtures also still caused extra server builds
(32 total observed builds in its session). Those are documented remaining
issues, not reasons to discard the working save and delivery fixes.

## Artifacts and reproduction

Raw run directory:
`/private/tmp/tips-elixirls-codex-v2/tmp/elixirls-v2/sol-dogfood-v2/`.
Each worker directory contains model events, hook audit with phase timings,
startup state, LSP log, exact copied runtime, process results, final response,
application patch, baseline results and full-suite output.

Fresh worktrees retained for inspection:

- `/private/tmp/tips-lsp-sol-v2-provider` — `experiment/elixirls-sol-v2-provider`
- `/private/tmp/tips-lsp-sol-v2-media` — `experiment/elixirls-sol-v2-media`
- `/private/tmp/tips-lsp-sol-v2-health` — `experiment/elixirls-sol-v2-health`

The runner now accepts `--worktree-prefix`, `--run-name` and `--port-offset` so
new cohorts can preserve old ones. Prepare fresh worktrees/dependencies and use
a unique database suffix and port offset. Run `baseline` first, seed only the
health definition after it passes, then run `run`:

```sh
python3 agent/lsp/experiments/codex-elixirls-v2/neovim_dogfood.py baseline --vendor tmp/elixirls-v2/neovim-vendor --output tmp/elixirls-v2/sol-dogfood-v2 --worktree-prefix /private/tmp/tips-lsp-sol-v2- --run-name sol_v2 --port-offset 100
python3 agent/lsp/experiments/codex-elixirls-v2/neovim_dogfood.py run --vendor tmp/elixirls-v2/neovim-vendor --output tmp/elixirls-v2/sol-dogfood-v2 --worktree-prefix /private/tmp/tips-lsp-sol-v2- --run-name sol_v2 --port-offset 100
```

Do not replay into the retained output/worktrees. The `run` phase makes actual
model requests using Tips source. The existing main checkout, assigned checkout,
active client configuration and unrelated Claude integration were untouched.
