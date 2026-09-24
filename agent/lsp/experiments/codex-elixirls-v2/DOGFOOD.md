# Three Sol agents on Tips

Date: 2026-09-24. Experiment branch: `experiment/elixirls-codex-v2`.

Follow-up: [four fixes and a fresh three-agent rerun](DOGFOOD_V2.md). This file
preserves the first cohort's results.

**Three actual Codex Sol agents completed their Tips application tasks. The
automatic-feedback adapter failed the reliability check and is not ready for
rollout.** Real work exposed stale diagnostics after a repair and a suppressed
pending message that the earlier fixture tests missed.

[Root-cause analysis](ROOT_CAUSES.md) traces each of the four summarized findings
through the logs and code, with separate why chains and explicit confidence limits.

## Workloads and validation

Each agent ran `codex exec -m gpt-6-sol` concurrently, with workspace-write
sandboxing and automatic approval review. Each had its own Git worktree,
dependency copy, builds, test database, ports, Neovim, vv-mcp and ElixirLS.
The application revision was `81501387eb77b220c95693f58076f7f8255da1b0`, matching
the main checkout's current application source. Uncommitted Claude integration
edits in the main checkout were preserved.

| Agent | Actual application work | Targeted tests | Full suite | Session duration |
|---|---|---:|---:|---:|
| Provider | Rename `ProviderConfig.mode/0` to `provider_mode/0` across callers, tests and docs | 26 passed, 1 excluded | 508 passed, 4 excluded | 237.2 s |
| Media | Reuse bigint ID validation and extend cast/dump/load boundary tests | 31 passed | 509 passed, 4 excluded | 224.9 s |
| Health | Finish an intentionally seeded incomplete private function rename | 4 passed | 508 passed, 4 excluded | 179.3 s |

The health scenario renamed the private definition to `query_database/0` before
launch, leaving its `probe()` caller broken. The agent reproduced the compiler
failure and repaired the caller. This was an injected fault, not a defect found
in the main checkout. The other tasks were small maintenance exercises on real
application code, not feature changes selected from the issue backlog.

All three agents passed formatting, warnings-as-errors compilation, strict Credo
and diff checks. The provider agent also passed documentation checks and its
full suite. The parent independently ran the media and health full suites after
the agents finished. Browser and real-provider tests remained excluded; no
external provider request was part of this run. Baseline compilation and the
original targeted tests passed before launching the agents.

The provider agent demonstrated a failing acceptance test before implementing
the new name. Its first targeted run after the rename exposed a missed reference
in an excluded test; it fixed that reference and reran the checks successfully.
The media agent tested the original behavior and expanded boundaries before
refactoring production code. The changes were reviewed and remain isolated in:

- `/private/tmp/tips-lsp-sol-provider`, branch `experiment/elixirls-sol-provider`
- `/private/tmp/tips-lsp-sol-media`, branch `experiment/elixirls-sol-media`
- `/private/tmp/tips-lsp-sol-health`, branch `experiment/elixirls-sol-health`

## What worked

- Normal `apply_patch` edits and shell tools invoked the synchronous hook.
  Agents did not manually save, refresh, index or restart Neovim/ElixirLS.
- All 38 MCP calls used the assigned worktree. Semantic requests returned useful
  definitions/references/documentation once available, or explicit startup/build
  errors. This count includes unsuccessful and diagnostics requests.
- All five nonempty hook messages carried random audit receipts that the agents
  quoted without reading the audit logs. Model delivery was directly observed.
- The three cold ElixirLS builds took 72.2–73.2 seconds under concurrent load.
  Navigation requests during compilation received the custom not-ready response.
- All observed owned processes exited after each session. Health exited first;
  the other two agents continued working. Parent cleanup did not have to kill
  leftover processes in the successful cohort.

| Agent | Hook calls | Median hook time | Longest hook | Edit feedback |
|---|---:|---:|---:|---|
| Provider | 26 | 0.067 s | 0.134 s | Uncertain, then deduplicated |
| Media | 21 | 0.069 s | 5.003 s | Completed at 1.178 s, then pending |
| Health | 21 | 0.072 s | 4.986 s | Pending internally, but no edit context delivered |

These are hook execution times. They exclude model latency and include neither a
promise of fresh results nor a one-second compile guarantee. The media Stop
deadline returned an explicit unavailable message at 5.003 seconds; the small
overhead is consistent with the five-second internal budget and process costs.

## Failures and limits

### 1. A normal reload can miss the build trigger

After the health repair, ordinary Mix compilation and all health tests passed.
ElixirLS nevertheless kept reporting undefined `probe/0` and unused
`query_database/0`, including after the Stop continuation and two more queries.

The LSP trace at 16:30:04 local time shows this order:

1. `textDocument/didClose` for `lib/tips/health.ex`.
2. `textDocument/didOpen` containing the repaired `query_database()` caller.
3. `workspace/didChangeWatchedFiles` with the changed health file.
4. No `textDocument/didSave` or subsequent build telemetry before shutdown.

The installed ElixirLS 0.31.1 source explains the missed trigger. Its watched-file
handler builds for a changed file when it is not open or is dirty; reopening
creates a clean source file. Its `didOpen` handler parses the document, while
`didSave` explicitly triggers a build. Neovim's correct disk contents therefore
did not imply an updated compiler result. The media production edit also remained
pending without a completed build for that generation, although its diagnostic
cache was empty.

This is a blocker for automatic edit/repair feedback. Increasing the wait budget
cannot make a missing build start.

### 2. Pending text was deduplicated before the agent ever received it

The launcher's private warmup called the collector and recorded pending state.
On the health agent's first edit, the hook waited 4.986 seconds and returned
`{}`: the message matched that private startup result. A pending message reached
the model only through Stop (receipt `a2ecc6e92107`). Media's later changed
generation also spent 4.993 seconds waiting without new context because its
pending text matched the previous generation.

Delivery deduplication must track agent-visible feedback and source generation,
not just the text of a result collected privately during startup.

### 3. Raw diagnostics do not explain whether the current build completed

The first health diagnostics request returned an empty object during the cold
build. Later media diagnostics were empty while the automatic collector still
had no completed build for the latest edit. The readiness wrapper currently
covers hover/definition/references, leaving diagnostics unqualified. The model
correctly distinguished the explicit timeout from a clean result, but the raw
diagnostics response did not provide the missing freshness information.

### 4. Conservative overlap handling limits ordinary cold-start work

The provider agent updated an acceptance test during the initial build. That
latched `uncertain` for the entire session, including later successful semantic
queries and application checks. This is existing conservative behavior, not a
new false clean result. It makes the automatic channel substantially less useful
when an agent starts editing before indexing finishes. Do not simply clear the
latch: the earlier overlapping-build experiment demonstrated a real stale-build
risk.

The media Stop check also timed out its Neovim RPC. It returned unavailable and
did not loop; the agent explicitly acknowledged the receipt and queried
diagnostics. The timeout's exact scheduling cause was not established by this
run. Concurrent shell checks occurred in that workflow, so it needs a focused
regression case rather than an assumed explanation.

## Root cause and smallest next change

1. Why did health diagnostics stay old? ElixirLS did not build the repaired file.
2. Why did changing the file not start a build? The watcher event described an
   already-open, clean document.
3. Why was the document clean? Neovim reloaded it through close/open with the
   repaired contents.
4. Why did that leave compiler state stale? Opening parses a document; saving is
   a separate build trigger in ElixirLS.
5. Why did the prototype omit that trigger? It relied on disk reload plus watcher
   delivery being sufficient. That assumption depends on event ordering/state.
6. Why would waiting longer repair it? It would not create the missing event.
7. Why would a more careful agent repair it? Only by taking over the editor's
   synchronization duties, which is the manual workaround this integration must
   remove. The last two questions leave the root answer unchanged.

First principles: synchronizing saved text and triggering compilation are two
separate obligations. Feedback delivery must also distinguish private reads,
agent-visible messages and source generations.

Occam/Pareto: keep the existing Neovim LSP client, published MCP adapter and
five-second hook. The next focused patch should complete automatic save
notification for externally reloaded saved documents using Neovim/LSP's existing
save mechanism, fix delivery deduplication, and add pending/stale status to
diagnostics. Avoid agent instructions, automatic blanket restarts, a second
watcher or a larger wait budget. Cold-build overlap recovery remains a separate
correctness question and must not be "fixed" by claiming unverified results are
current.

Inversion acceptance for that patch: query a file first, repair it with a normal
edit, force reload-before-watcher ordering, and require fresh automatic error
clearance without another query. Also test startup pending followed by an edit,
two edits that both time out, parallel shell checks and a final pending edit.
Keep the existing overlap and process-cleanup tests.

## Evidence and reproduction

[dogfood-evidence.json](dogfood-evidence.json) records source hashes, timing,
checks, receipts and outcomes. [neovim_dogfood.py](neovim_dogfood.py) contains the
exact workload prompts and concurrent Codex launcher. The runtime adapter was
unchanged during this cohort. This report records the failures; it does not
claim that the proposed repairs have been implemented or validated.

Raw evidence is in `tmp/elixirls-v2/sol-dogfood-run/{provider,media,health}/`:
`events.jsonl`, `hook-audit.jsonl`, `environment.startup.json`, Neovim LSP logs,
`command.json`, `process-results.json`, `application.patch`, baseline logs and
agent final messages. Parent full-suite logs are present for media and health;
the provider full suite is in its event transcript. Read the full event stream
for all agent responses: a Stop continuation can make `final.md` contain only
the final follow-up rather than the earlier task summary.

To replay, create three fresh worktrees at the recorded application commit using
the paths above, copy dependency sources and the relevant `.agents/skills` into
each checkout, then run the script's `baseline` phase with a fresh `--output` and
the pinned Neovim `--vendor`. After the baseline passes, seed only the health
private-definition rename described above and run the `run` phase with the same
output. The script uses the documented shared PostgreSQL service on port 5433
and unique `_lsp_sol_*` database suffixes, ports 4511–4513 / 4611–4613, and four
BEAM schedulers per process. Existing worktree contents must be preserved before
reusing these paths. Baseline dependencies and source skills are preparation
requirements, not supplied by the runner.

The runner asserts process exit/cleanup, not adapter correctness. The observed
negative reliability verdict is explicit in the evidence; a zero CLI exit code
does not count as a passed adapter acceptance test.

The first launch attempt failed before any model session because the CLI rejects
combining `--approve-for-me` and `--sandbox`. The redundant sandbox argument was
removed; `--approve-for-me` itself selects workspace-write. That failed attempt
is preserved in `tmp/elixirls-v2/sol-dogfood/`. Hook trust bypass was confined to
the reviewed test invocation. Active client configuration was not changed.

The user's explicit request to run three Sol agents on the current Tips codebase
provided authorization for this real-source model test. The earlier synthetic-
only limitation is now superseded by this dogfood evidence.
