# Parallel-worktree exploration

> Historical exploration report, preserved from `task/lsp-startup-mvp`.
> Commands, paths, installed versions and timeout choices below describe those experiments,
> not current settings. See the [maintained LSP guide](../../agent/lsp/README.md)
> for the integrated fixes and current acceptance limits. Local evidence paths are
> recorded as text; their artifacts are not bundled or guaranteed to remain available.
> Original source SHA-256: `71bfe4bbc4ab848fbcef91b65059f1a8420c0a4d437358f4e805d25b45a2333e`.

The final local release is installed in the main checkout's `.elixir-tools`.
The evidence below retains the isolated experiments and their failures as well
as the final actual-agent validation. The standard `scripts/build_expert.sh`
includes both approved patches and hashes both into its release version.
The parallel-worktree patch layers two changes on
the locally patched Expert 0.1.10 references build:

1. Name the shared ETS search leader with `Project.root_path(project)` instead of
   `Project.name(project)`. WAL names and other registrations are unchanged.
2. Hold one cross-process `Mix.Sync.Lock` around shared tooling preparation,
   `Mix.install` (including forced deletion), and namespacing. The lock key is the
   cache/version/runtime tooling path plus `engine-preparation`, distinct from
   Mix's nested build locks. It serializes builders using the same tooling cache.

The candidate lives in `scripts/expert-parallel-exploration.patch`. It does not
change the references error contract or add request scheduling, immutable cache
publication, broad identity changes, or an automatic repair system.

## Isolation and reproduction

`scripts/build_expert_parallel_exploration.py` copies the installed release and
bridge into a new directory. It patches bundled engine source and the preparation
script. The manager BEAM files remain unchanged; Expert compiles the modified
engine source when it starts. This is sufficient for these two changes, both of
which execute outside the manager's compiled code.

The staged build has one harness-only modification, excluded from the candidate
patch: `build_engine.exs` requires `TIPS_EXPERT_TEST_CACHE`. Its launcher also sets
`HEX_HOME` beneath that cache. This prevents the experiment from rebuilding or
deleting the installed engine cache. The staging command refuses an existing
output directory and does not replace installed binaries. The wrapper accepts
only `--stdio`: cache-management commands such as `expert engine clean` are not
isolated by the builder shim and must not be used through the copied release.

```sh
python3 scripts/build_expert_parallel_exploration.py \
  --installed-tools /absolute/path/to/tips/.elixir-tools \
  --output /private/tmp/expert-parallel-new

python3 scripts/test_expert_parallel_exploration.py \
  --tools-dir /private/tmp/expert-parallel-new/tools \
  --output /private/tmp/expert-parallel-live-new

python3 scripts/test_expert_cache_inversion.py \
  --tools-dir /private/tmp/expert-parallel-new/tools \
  --output /private/tmp/expert-cache-inversion-new
```

Each harness creates a separate cache automatically. The inversion harness sends
signals only to the standalone builder process group it created. Project copies,
requests, responses, timings, and logs remain in the output directory for review.

## Source checks

The new ExUnit regression first failed on the original code: a foreign basename
registration caused `Ets.prepare/1` to return `{:error, :not_leader}`. With the
root-path change, that store prepares successfully and reads back its own entry.
The test runs synchronously because this backend has a node-local singleton and
the fixture uses the real global registry.

These source tests were run separately in the scratch source checkout. The staging
script includes the test in `patch-source` but does not run tests or copy them into
the release; its success alone is not a validation result.

After the change, 55 affected engine tests passed, including references outcomes,
store state, the new integration regression, and adjacent ETS state tests.
Incremental compilation with `--warnings-as-errors`, formatting, and strict Credo
passed for the changed source and test files. This is not a fresh whole-upstream
warnings-as-errors build. The existing editor LSP returned startup-unconfirmed
diagnostics for the scratch source; that result did not validate the change.

## Live results

The clean five-session run passed all 15 checks (24 MCP requests):

- Five simultaneous starts against an empty disposable engine cache returned the
  exact expected references in 38–44 seconds.
- Five simultaneous warm restarts returned the exact references in 7–13 seconds.
- A nested project with the same basename returned its own nine reference paths;
  the parent queried afterwards returned its own two paths. Both checks passed
  again after restart.
- No `File.Error` or build-script exit was found in the Expert logs. A separate
  inspection also found no failed-node, Hex registry, or permission errors.

The first inversion attempt hit Hex registry permissions because Hex was not yet
isolated. That run is retained as a failed setup attempt and is not evidence for
the candidate's forced-rebuild behavior. The clean rerun uses a private Hex home.

## Full-project and fault results

Three simultaneous real Tips project copies passed 58/58 checks across 89 MCP
requests. Cold imported-reference lookups took 84–96 seconds. Warm references,
true empty results, edits, diagnostics, definition, hover, same-basename
navigation, returning to the original project, and restart all passed.

Five simultaneous real Tips copies under overlapping fault-test load passed
64/74 checks across 125 MCP requests. All five first lookups returned explicit
errors at the 100-second deadline. Five follow-up lookups returned the correct
16 paths but failed the harness's under-two-second assertion (16–40 seconds).
That assertion assumes the first cold call succeeded; these are dependent
latency failures, not five additional wrong-result failures. All remaining
checks passed. Project compilation took 99–114 seconds; engine preparation
finished earlier. The fault run used a separate cache but shared the machine.
This result does not isolate ordinary five-agent startup performance.

The final inversion run passed 8/8 checks. It served 381 exact reference responses
while another process forced engine preparation. The harness observed `dev_ns`
disappear; a first definition call and diagnostics still succeeded. It then
killed a builder after its namespacing log, successfully rebuilt, and confirmed
correct references from a fresh Expert. These observations do not prove that
all code was loaded lazily or that the kill occurred during a file copy.

The generated minimal fault fixture passed formatting and compilation. Its
Credo task was unavailable. Source-level Credo results above apply to the edited
Expert files, not to that dependency-free fixture.

## Fault-free five-project control

The control uses five fresh Tips archives with private dependency copies and the
same already-prepared engine cache as the preceding full-project tests. No fault
builder was running. It is a cold **project** test, not an empty engine-cache test.

It passed 65/74 checks across 125 MCP requests in 175.706 seconds. All five first
imported-reference lookups failed: four reached the 100-second deadline; one
returned `query_failed` at 98.807 seconds. All five synthetic-reference followups
returned the correct 16 paths. Four took 4.9–17.8 seconds and failed the dependent
latency assertion; the fifth passed at 0.637 seconds. The remaining checks passed.

Initial preparation-to-engine-available intervals were 2.1–9.5 seconds. Project
compilation took 83.3–97.9 seconds, with index loading afterward. Therefore fault
injection is not required to reproduce five-project startup failure, and engine
preparation serialization does not account for most of the delay. No CPU profile
was captured; this does not establish which host resource is limiting compilation.

The `query_failed` attempt took 5,078 ms inside Expert immediately after repeated
loading responses. `Store.call_or_default/2` uses the default `GenServer.call/2`
timeout, so an internal store timeout is a plausible explanation. The handler
catches multiple error types, and the captured MCP output omits `data.detail`.
That recording alone did not establish the cause. The later actual-Codex run
below captured the missing detail. Do not retry all `query_failed` outcomes as
if they meant not-ready.

All five original imported-symbol queries were repeated after restarting against
the now-built projects. Each returned exactly the expected 14 paths in 11.7–18.4
seconds. This confirms recovery for the original target, not only the separate
synthetic fixture. No shared-cache File.Error, build-script exit, failed-node, or
Hex permission error matched the control log audit. Existing alias-expansion
warnings/errors are present; this is not a claim of universally clean logs.

### Root analysis

1. Why do first calls fail? Their deadline expires, or an explicit query fails.
2. Why is readiness so late? Each fresh worktree compiles and then loads an index.
3. Why does the engine cache not remove that cost? It caches the engine, not each
   worktree's application build and search index.
4. Why does starting five agents expose this? Five independent cold projects are
   initialized together; observed compilation plus indexing exceeds the budget.
5. Why does the lock not solve it? It protects shared preparation writes, not
   project readiness or the amount of compilation work.
6. Why is a scheduler not the demonstrated fix? Calls already use separate bridge
   sessions; the long interval is inside independent project initialization.
7. Why not conclude a bigger lock or broader retry fixes it? Neither reduces that
   initialization work. The unresolved requirement remains making each project
   ready before expecting a successful bounded lookup.

The last two questions leave the answer unchanged. Keep the root-path and outer
lock fixes, but do not claim they make five cold projects ready within 100 seconds.
Warming only the shared engine cache is insufficient. The real-agent timing
audit below now supports using the existing worktree-rooted launcher before
adding any startup scheduling. No new readiness gate or scheduler was added.

## Limits to test before promotion

The outer lock coordinates builders. Running engines do not hold it while reading
their prepared files. A forced install still replaces the same cache directory;
the earlier real-Mix marker experiment demonstrated that files disappear even
when builders correctly take turns. Successful warm queries cannot prove that
every lazily loaded module remains available.

The namespacing log is emitted before transformation and copying. Killing at that
log exercises interruption at that boundary, not a proven mid-copy failure.
No claim is made that arbitrary corrupt caches repair themselves. Symlink aliases,
concurrent manual cache cleaning, old binaries that bypass the new lock, and
within-session queue deadlines remain outside the candidate's guarantees. The
Mix lock also requires builders sharing a cache to run as the same user with
the same `TMPDIR`; its lock files live below that temporary directory.

`Mix.Sync.Lock` is internal API. This experiment targets the installed Elixir
1.20.4 / OTP 29 environment; other versions have not been validated. The original
installed tools were preserved during exploration and are retained for rollback
after the final local installation. No upstream submission was made.

## Reproducible release and Claude compatibility

Both standard build scripts completed against the pinned upstream sources. The
initial staged release was Expert `0.1.10-tips.b845754f94e9132c`; the bridge SHA-256 is
`dff2030907269d326a5d27e917b9a3e411a13d5ccf6b0f76e5a4ed97f9277456`.
The Expert build passed 55 engine and 24 server tests, formatting, and strict
Credo for the changed files. Upstream dependencies emit existing compiler
warnings. The bridge build passed vet and its four selected test packages.
The packaged engine source contains the root identity fix and outer lock,
without the experiment's cache redirection. It was kept separate until the
actual-agent tests below found and verified the additional Store timeout fix.

Fable independently tested her native Claude LSP integration. The plugin
`elixir-lsp@elixir-agent-tools` 2.1.1 launches its Python wrapper, which resolves
`expert` to Homebrew Expert 0.1.10. Warm definition, references, and hover worked.
That transport has no diagnostics operation. Its cold lookups still produce
upstream's ambiguous empty results; this work does not repair Claude's transport.

Codex's local release and Claude's Homebrew release have separate binaries and
versioned engine caches. Keep each concurrent agent in its own worktree: two
Expert processes on the same root still share that worktree's build files and
index WAL. Binary separation alone does not prove that shared-root use is safe.
No fixed two-minute delay proves Claude's index is ready. Compilation and index
loading depend on the project and machine load.

Evidence: final build provenance (`/private/tmp/tips-expert-parallel-5nzib40t/final-tools-provenance.json`),
Expert build log (`/private/tmp/tips-expert-parallel-5nzib40t/final-expert-build.log`),
bridge build log (`/private/tmp/tips-expert-parallel-5nzib40t/final-bridge-build-retry.log`),
Fable's independent review (`/private/tmp/tips-elixir-lsp-fable-review-round10.md`).

### Actual Codex agents and the Store timeout

Five actual Codex Sol CLI sessions ran on separate Git branches/worktrees, each
with its own bridge and Expert. Raw Codex MCP events, rather than the agents'
final claims, checked 14 exact reference locations, the fixture definition at
line 9, and zero diagnostics for `lib/tips/health.ex`.

The initial harness configuration used noninteractive read-only approval policy
and refused every MCP call before dispatch. That failed setup is retained; it
is not LSP validation. The corrected run used Codex's normal automatic approval
review. It started cold project builds against the engine cache prepared during
the first attempt. No artificial planning delay was inserted.

Three of five initial references calls succeeded. One reached the 100-second
deadline; another returned `query_failed`. All five definition and diagnostics
checks passed. First MCP dispatch arrived 16.9–32.3 seconds after bridge startup;
project compilation took 84.8–100.7 seconds. No matching cache/startup errors
were logged. These developer-style first calls arrive much sooner than the
historical review-lead sample; background startup helps but cannot guarantee a
successful first cold call within the fixed budget.

The newly visible `data.detail` identified the other failure exactly:
`GenServer.call(XPEngine.Search.Store, {:prefix, ...}, 5000)` timed out.
Index installation runs inside the Store process, preventing it from answering
the usual loading response during that interval. References now catches only
that Store-call timeout, before the remote-call exception wrapper, and returns
`index_not_ready`. The bridge uses its existing bounded retry. Other failures
retain their outcomes. No shared Store default, helper layer, scheduler, or
deadline was changed.

The new integration regression holds the real Store during index installation.
It failed with the real five-second timeout before the change, then passed:
not-ready while blocked, a genuine empty result after installation finishes.
All 56 affected engine tests passed, including the existing terminal failure
cases. Formatting and strict Credo passed. Editor LSP diagnostics for the two
scratch files remained startup-unconfirmed and were not counted as validation.
Fable accepted the exact catch after independent review.

During the five-project compile/query overlap, Fable's unchanged native Expert
returned the same definition, 11 references across six files, and hover docs.
Expert-side times were 5, 6, and 8 ms at 06:00:26–29; her reported client round
trip stayed about 1.3 seconds. The user confirmed that Claude and Codex always
use separate worktrees; shared-root operation is outside this deployment.

Evidence: actual-agent events and summary (`/private/tmp/tips-expert-parallel-5nzib40t/codex-five-agent-e2e/runs/20260921T215924Z/summary.json`),
startup and compile timings (`/private/tmp/tips-expert-parallel-5nzib40t/codex-five-agent-e2e/runs/20260921T215924Z/timings.json`),
failing regression (`/private/tmp/tips-expert-parallel-5nzib40t/store-timeout-red.log`),
56 passing tests (`/private/tmp/tips-expert-parallel-5nzib40t/store-timeout-green.log`),
Fable's timeout review (`/private/tmp/tips-elixir-lsp-fable-review-round11.md`).

### Final release validation and installation

Expert `0.1.10-tips.d037e57ca101608c` adds the narrow Store timeout catch to the
same references contract, root identity, and preparation lock. Its reproducible
build passed 56 engine and 24 server tests, formatting, and strict Credo. The
bridge binary is unchanged from the successful Go test/race/vet build above.

Five actual Codex agents then passed all 15 MCP checks with this release: each
returned its own exact 14 references, the correct definition, and zero
diagnostics. These were warm **projects** with a cold engine cache for the new
release version. Total agent durations, including startup, model calls, and
approval review, were 57.3–64.9 seconds. They are not individual LSP latencies.
No cache File.Error, build-script exit, or failed-node message matched the log
audit. The earlier cold-capacity failure remains a documented limitation.
The archived Expert logs are cumulative across the cold and final runs. The
original preflight's `cold_build_state` field referred to the unused `_build`
directory; `cold_expert_state: false` correctly identifies warm projects. The
runner now drops that misleading field, and the original evidence has a note
rather than rewritten measurements.

The tested release and bridge were copied into the main checkout's
`.elixir-tools` and selected by atomic replacement. The old Expert release and
a copy of the old bridge are retained under `releases/`. Homebrew Expert,
Claude's plugin, PATH, and existing running processes were not changed. Existing
Codex MCP processes need a restart to load the new pair; launch new sessions in
their own worktree as required by the team workflow.

The installed pair also passed the disposable-project smoke test: first cold
references in 34.118 seconds, a genuine empty result in 4 ms, explicit unresolved
symbol error in 2 ms, correct definition in 11 ms, and an empty unversioned
diagnostic publication in 1.043 seconds.

Evidence: final five-agent summary and raw events (`/private/tmp/tips-expert-parallel-5nzib40t/codex-five-agent-e2e/runs/20260921T221042Z/summary.json`),
final Expert build (`/private/tmp/tips-expert-parallel-5nzib40t/final-expert-timeout-build.log`),
installed versions and rollback locations (`/private/tmp/tips-expert-parallel-5nzib40t/installed-promotion.json`),
installed smoke test (`/private/tmp/tips-expert-parallel-5nzib40t/installed-final-smoke.log`).

### Five cold projects with immediate retry

On September 22, 2026, five fresh detached Tips worktrees at `ec365824` started
the installed `d037e57ca101608c` Expert and bridge simultaneously. Each had its
own dependency copy, no `.expert` directory, and no project build. The existing
shared engine cache was retained. A direct MCP client sent the same references
query at `schema_test.exs:165:13` about 1.56 seconds after each bridge launched,
without model planning delay or artificial host load.

| Session | First call | Immediate second call | Warm third call |
| --- | --- | --- | --- |
| 1 | Timeout at 100.001 s | Correct in 8.152 s | Correct in 58 ms |
| 2 | Timeout at 100.001 s | Correct in 9.115 s | Correct in 22 ms |
| 3 | Correct in 95.090 s | Correct in 30 ms | Correct in 24 ms |
| 4 | Correct in 91.628 s | Correct in 59 ms | Correct in 26 ms |
| 5 | Timeout at 100.001 s | Correct in 10.740 s | Correct in 41 ms |

All 12 successful responses returned the exact 14 expected reference locations
from their own worktree. The three failures explicitly reported
`references index not ready before deadline: context deadline exceeded`; none
reported a successful empty result. All three recovered on the very next call,
with unchanged arguments, no sleep, and no bridge or Expert restart. Each
Expert log contains one preparation and one project compilation.

Compilation took 76.7–90.8 seconds; preparation and the subsequent index load
used the rest of the initial request budget. Thus the limit concerns total
startup readiness, not necessarily compilation exceeding 100 seconds by itself.
No `query_failed`, cache `File.Error`, build-script exit, or failed-node message
occurred. The existing alias-expansion errors also seen in earlier runs remain
in the logs; the exact-path oracle passed despite them.

This reproduces the capacity limit and verifies same-session recovery in this
run. It does not guarantee that one retry suffices under arbitrary load. The
test created no additional background load, changed no product code or timeout,
and stopped its own sessions and removed its five disposable worktrees afterward.

Reproduction harness: `scripts/test_elixir_lsp_cold_retry.py`; Python syntax
check and the live scenario passed. Its `passed` flag means the bounded-error
and recovery contract passed; first-call success was only 2/5.

Evidence: results and complete replies (`/private/tmp/tips-expert-parallel-5nzib40t/cold-immediate-retry/summary.json`),
cold-state and installed-binary checks (`/private/tmp/tips-expert-parallel-5nzib40t/cold-immediate-retry/preflight.json`),
log audit (`/private/tmp/tips-expert-parallel-5nzib40t/cold-immediate-retry/log-audit.json`).
Per-session bridge logs, Expert logs, and all MCP request/response records are
retained in the same evidence directory.

### Both deadlines increased to 180 seconds

The user selected 180 seconds for both the bridge's overall tool deadline and
Codex's `tool_timeout_sec`. The bridge was rebuilt and installed; the main
checkout configuration and both launcher templates now use 180 seconds.
`codex mcp get elixir-lsp --json` confirms the installed client setting.
Existing MCP sessions need restarting to load these changes. Equal limits mean
the client can time out before the bridge's error arrives at the boundary.

Five more fresh detached Tips worktrees repeated the immediate-call scenario,
with private dependency copies, no project build/index, and the existing shared
engine cache. Every first references call returned all 14 exact own-project
locations without an external retry:

| Session | First cold call | Result |
| --- | --- | --- |
| 1 | 97.737 s | Correct |
| 2 | 110.460 s | Correct |
| 3 | 95.442 s | Correct |
| 4 | 112.639 s | Correct |
| 5 | 111.458 s | Correct |

All ten subsequent warm calls also passed, taking 21–57 ms. Three first calls
continued beyond the former 100-second limit and succeeded. No cache startup
failure matched the audit. This demonstrates the larger budget covers this
observed workload; it does not guarantee readiness under arbitrary load.

The bridge build passed vet and affected-package tests. The reviewer-launcher
integration test verifies the generated 180-second configuration; shell and
Python syntax checks passed. Test clients allow 190 seconds to observe a bridge
timeout response; the deployed Codex timeout remains exactly 180 seconds.
No Expert code or release changed. The five test worktrees were removed after
their logs were archived.

Evidence: 15 successful calls (`/private/tmp/tips-lsp-timeout-180/cold-five/summary.json`),
cold-state preflight (`/private/tmp/tips-lsp-timeout-180/cold-five/preflight.json`),
installed binary and settings (`/private/tmp/tips-lsp-timeout-180/installed.json`),
Codex configuration (`/private/tmp/tips-lsp-timeout-180/codex-mcp-config.json`),
bridge build and checks (`/private/tmp/tips-lsp-timeout-180/build.log`).
Full MCP replies, bridge logs, and Expert logs are in the `cold-five` directory.

## Evidence

- Staged build metadata (`/private/tmp/tips-expert-parallel-5nzib40t/staged/exploration.json`)
- Failing integration test before the change (`/private/tmp/tips-expert-parallel-5nzib40t/red.log`)
- 55 passing engine tests (`/private/tmp/tips-expert-parallel-5nzib40t/engine-regressions.log`)
- Clean five-session summary (`/private/tmp/tips-expert-parallel-5nzib40t/live-parallel-b/summary.json`)
- Exact live requests and responses (`/private/tmp/tips-expert-parallel-5nzib40t/live-parallel-b/requests.json`)

- Three full projects (`/private/tmp/tips-expert-parallel-5nzib40t/tips-workload/summary.json`)
- Five full projects with fault-test load (`/private/tmp/tips-expert-parallel-5nzib40t/tips-five/summary.json`)
- Forced preparation and interruption (`/private/tmp/tips-expert-parallel-5nzib40t/live-inversion-c/report.json`)
- Startup timeline excerpts (`/private/tmp/tips-expert-parallel-5nzib40t/startup-timelines.json`)
- Independent-review evidence index (`/private/tmp/tips-elixir-lsp-fable-round9-evidence.json`)

- Five-project control (`/private/tmp/tips-expert-parallel-5nzib40t/tips-five-control/summary.json`)
- Control request/response records (`/private/tmp/tips-expert-parallel-5nzib40t/tips-five-control/requests.json`)

- Original-target recovery after five warm restarts (`/private/tmp/tips-expert-parallel-5nzib40t/tips-five-recovery/report.json`)

## Approved follow-up implementation

The bridge already preserved typed error data for retry decisions. Its error
text and error log now include compact JSON `data`, making `data.detail` visible
when a query fails. Only `index_not_ready` is retried, as before. A real framed
fake-server regression failed before this change and passed afterward for
`query_failed`, `index_failed`, unresolved symbols, and unknown errors.

The first valid MCP `tools/call` dispatch is logged once per bridge process at
INFO level, with PID, workspace, tool name, and elapsed milliseconds since
process startup. Arguments and file contents are not logged by this timing hook.
This measures dispatch, not client-side queueing or wire arrival. Existing
historical logs cannot acquire that field retroactively.

The stress harness now reports error-contract checks separately from first-call
success. An explicit failure can pass the no-silent-empty check while still
failing usability. Exact reference paths remain mandatory on successful calls;
`cold-followup` no longer has a warm two-second limit. Explicitly warm checks
retain it. Initial project compilation times are recorded as measurements.
Historical reports above remain unchanged.

The corrected interruption test ran as `live-inversion-d`: 7/7 checks passed,
including 328 exact reference responses during forced preparation. After killing
the builder following its namespacing log, a normal Expert startup attempted the
interrupted cache before any forced repair. It logged `Namespacing 1788 files`
and returned exact references in 14.192 seconds. No forced repair was needed.
This proves normal recovery for the observed interruption, not every possible
partial file write. The former “lazy” probe is now named a first-method probe;
its limitations remain explicit.

Three real review-lead sessions were correlated between Codex call records and
Expert instance logs. Their Expert-start-to-first-explicit-LSP-call intervals were
46m15s, 30m46s, and 35m19s. Expert startup is the available proxy for bridge startup,
not an exact timestamp from the bridge executable. These main-rooted sessions
first discovered their review worktrees at that late call. The existing
worktree-rooted launcher could have used the intervening time to initialize the
correct project. Three sessions are not a guarantee for all future agent roles;
no additional prewarm scheduling is justified by these samples alone.

Validation: affected bridge packages pass ordinary and race tests; `go vet`
passes. The regenerated bridge patch applies to pristine v0.1.1 source and
matches the tested files. Both Expert patches apply to the pinned source and
match the previously tested 55-test engine source. Python syntax and shell syntax
checks pass. The new error-detail and timing behavior also has a live MCP smoke
test against the isolated patched Expert.

- Corrected ordinary recovery (`/private/tmp/tips-expert-parallel-5nzib40t/live-inversion-d/report.json`)
- Real agent timing evidence (`/private/tmp/tips-expert-parallel-5nzib40t/real-agent-timing.json`)
- Error-detail regression before fix (`/private/tmp/tips-expert-parallel-5nzib40t/error-detail-red.log`)
- Bridge race-test results (`/private/tmp/tips-expert-parallel-5nzib40t/revised-bridge-race.log`)
- Live revised bridge smoke test (`/private/tmp/tips-expert-parallel-5nzib40t/revised-bridge-live/summary.json`)
