# Three Tips workloads with the minimal patch

Date: 2026-09-24. Implementation branch: `experiment/elixirls-codex-v2`.

**All three actual Codex Sol agents completed their application tasks. Normal
edits synchronized, the hooks stayed below five seconds, and fixture noise was
filtered. Cold-start references still timed out, with explicit qualifications.**
The implementation remained frozen throughout this cohort.

[Implementation and boundary tests](MINIMAL_PATCH.md).
[Machine-readable evidence](dogfood-v3-evidence.json).
[Previous cohort](DOGFOOD_V2.md).

## Workloads and checks

Three concurrent `codex exec -m gpt-6-sol` sessions used fresh Tips worktrees at
`81501387eb77b220c95693f58076f7f8255da1b0`. Each had separate dependency copies,
build/index directories, database suffixes and ports. Each used its own Neovim
0.12.5, patched vv-mcp 0.3.4 and ElixirLS 0.31.1. Codex CLI was 0.156.1.
The prompts required ordinary file edits and prohibited manual saves, refreshes,
indexing, server restarts and inspecting the hook logs.

| Workload | Targeted tests | Full suite | Agent session |
|---|---:|---:|---:|
| Provider API rename, application callers, tests and docs | 26 passed, 1 excluded | 508 passed, 4 excluded | 196.1 s |
| Media bigint validator reuse and cast/dump/load boundaries | 30 passed | 508 passed, 4 excluded | 171.3 s |
| Seeded health private-function rename repair | 4 passed | 508 passed, 4 excluded | 121.4 s |

Baseline compilation and original targeted tests passed before launch. The
health definition was then intentionally renamed, leaving its caller broken.
The agent reproduced the undefined-function failure and repaired that caller.
This is a seeded scenario, not a defect discovered on main.

Provider updated acceptance tests first and demonstrated two failures for the
new API, then implemented the rename without a compatibility alias. Media ran
its original and expanded tests before changing production code, then added
negative-ID and trailing-junk cases. Review of the final diffs found only the
requested changes; health preserved its deadline, Task and repository behavior.

All agents passed formatting, warnings-as-errors compilation, targeted tests
and strict Credo. Provider also ran documentation checks and the full suite.
The parent independently ran the media and health full suites. All final diffs
passed `git diff --check`. Browser and real-provider tests stayed excluded.

## Synchronization and feedback

All six edit hooks observed their generation complete within 1.078–2.312 s.
No manual synchronization was used. No hook timed out or reported a sync error,
conflict or permanent uncertainty.

| Agent | Hook calls | Median | Maximum | Nonempty hook messages |
|---|---:|---:|---:|---:|
| Provider | 29 | 0.067 s | 2.312 s | 0 |
| Media | 26 | 0.0665 s | 1.162 s | 0 |
| Health | 20 | 0.068 s | 2.179 s | 0 |

**Health's queried-file repair triggered a real build.** Its LSP log records
`didSave` at line 494, then successful build telemetry at line 514, with a build
duration of 1.931 s. Its edit hook returned after 2.179 s with generation and
completion both 1. Later MCP diagnostics were empty with `current` feedback,
and definition resolved the repaired call to `query_database/0`. This addresses
the first cohort's reload-without-compilation failure.

Media's previously queried production file and test file also received save
notifications (log lines 500 and 531). Their subsequent build telemetry appears
at lines 521 and 549. Provider's queried application caller received `didSave`
at line 507; the other changed files were covered by native watcher events.

**Qualified results remained useful.** Media received the actual definition of
`positive_integer/1` while its first build was still running, accompanied by
the pending/staleness qualification. Health received explicit failed-build
feedback with the undefined-function diagnostic, then current feedback after
repair. Provider retried references after indexing and received the declaration
and application call site. All 25 MCP calls named files in their assigned roots;
22 responses carried feedback metadata. This is routing evidence, not a test
of cross-root rejection.

**Fixture noise was absent at the notification boundary.** Provider ran its
fixture-writing targeted suite twice and its full suite while ElixirLS lived.
There were zero watched-file notification batches under its worktree's `tmp/`.
The same was true for media and health. Real edited files still produced watcher
events. Total observed builds were 5, 5 and 3 respectively, versus provider's 32
in the previous cohort. This is not a controlled performance ratio: task timing
also differed. Each root had one dependency-template watcher event during the
cold dependency build; the patch intentionally filters only the demonstrated
fixture directory.

## Remaining observations and their causes

**Each first references request timed out.** Cold ElixirLS builds took
61.909–64.556 s. The LSP logs show references requests cancelled three seconds
after dispatch: provider lines 403/416, media 384/393 and health 434/489. The
existing vv-mcp request default is 3000 ms (`lua/vv-mcp/lsp/context.lua:101`).
Each response retained `errors.elixirls = timeout` and pending/failed feedback.
Provider's later retry succeeded. Health's build failed, so its references
timeout should not be described as evidence that waiting longer would succeed.

Why chain: an agent cannot use the first reference result → the server did not
answer before cancellation → the request had the existing three-second limit
→ it ran while the initial build was unfinished → dependencies were being
compiled into a fresh ElixirLS build directory → launcher warmup ends before
that long build finishes → readiness qualification deliberately permits useful
requests during compilation. The five-second edit-hook limit is a separate
deadline. This cohort supports preserving the qualification and retry behavior;
it does not justify increasing every timeout or restoring global blocking.

**No hook feedback receipt was emitted.** All 75 audits have empty output.
This was the collector's existing quiet-clean policy, not hidden delivery
failure: edited builds completed cleanly, and the hook had not previously
reported pending/error feedback to clear. The health error was seeded before
startup and observed through explicit MCP diagnostics. The agents' accounts of
"automatic feedback" therefore refer to explicit MCP responses in this run.
No claim of `additionalContext` receipt can be made from this cohort.

Why chain: there is no receipt → the Python hook adds receipts only to messages
→ Lua returned an empty message → each edited build was clean → there was no
earlier hook-delivered diagnostic or pending message → MCP observations do not
consume/update hook delivery history → clean first results are intentionally
quiet (`neovim_sync.lua:180–192`). This does not reproduce the old deduplication
bug that suppressed pending feedback after an edit.

**Startup document symbols remain outside the qualification wrapper.** Provider
received `clients: []` and empty symbols without feedback before its references
queries. The wrapper covers hover, definition, references and diagnostics, not
`document_symbols`. Media and health later obtained nonempty document symbols.
An unqualified empty result is still possible through this operation; it must
not be advertised as having the same readiness contract as the wrapped tools.

Provider reported approximately 17 seconds for a diagnostics call. The retained
Codex event stream has no per-call elapsed timestamps, so this is an agent
observation, not a measured adapter latency or a five-second hook violation.
If that delay is investigated next, record timing at MCP dispatch/return first.

## Coverage limits

All first edits occurred after the initial build finished. This cohort does not
reproduce the previous media edit-during-cold-build scenario. The removal of the
permanent restriction and synchronization retry behavior have their separate
boundary evidence in [MINIMAL_PATCH.md](MINIMAL_PATCH.md).

No reload/save failure, conflicting unsaved buffer, five-second compiler wait
or message-delivery event was induced here. Earlier retained boundary probes
cover those scenarios. Passing normal workloads does not replace those tests.

The known Mix overlapping-write invalidation defect is unchanged. `current`
means the last observed compilation completed under the ordinary editor
contract; it does not prove the exact source bytes consumed by Mix. Normal
compilation and tests remain required. No force build, clean/restart loop or
upstream patch was introduced.

## Isolation, lifecycle and artifacts

Runtime Lua copies, Python source and patched vv-mcp binary matched their
pre-run hashes. Every agent exited with code 0. All observed descendants
(150 provider, 84 media, 55 health, including transient test processes) had
exited before parent cleanup. The harness did not need to terminate survivors.

Raw directory:
`/private/tmp/tips-elixirls-codex-v2/tmp/elixirls-v2/sol-dogfood-v3/`.
`setup.json` pins application commit, model, source hashes and binary hash.
Each worker contains exact prompt/command, event stream, hook audit, LSP log,
runtime copies, baseline checks, final response, application patch and process
results. Independent full-suite logs are under media and health; provider's
full-suite output is in its event stream at `item_40`.

Retained worktrees:

- `/private/tmp/tips-lsp-sol-v3-provider` — `experiment/elixirls-sol-v3-provider`
- `/private/tmp/tips-lsp-sol-v3-media` — `experiment/elixirls-sol-v3-media`
- `/private/tmp/tips-lsp-sol-v3-health` — `experiment/elixirls-sol-v3-health`

Use fresh output/worktrees for another run. After dependency setup, run the
existing harness's `baseline` phase, seed only the health definition, then run:

```sh
python3 agent/lsp/experiments/codex-elixirls-v2/neovim_dogfood.py run --vendor tmp/elixirls-v2/minimal-patch/vendor --output tmp/elixirls-v2/sol-dogfood-v3 --worktree-prefix /private/tmp/tips-lsp-sol-v3- --run-name sol_v3 --port-offset 200
```

Application changes remain isolated and unmerged. This test changed no runtime
implementation, active client configuration, assigned checkout or unrelated
Claude integration work.
