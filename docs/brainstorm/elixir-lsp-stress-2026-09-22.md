# Patched Expert stress test — 2026-09-22

> Historical exploration report, preserved from `task/lsp-startup-mvp`.
> Commands, paths, installed versions and timeout choices below describe those experiments,
> not current settings. See the [maintained LSP guide](../../agent/lsp/README.md)
> for the integrated fixes and current acceptance limits. Local evidence paths are
> recorded as text; their artifacts are not bundled or guaranteed to remain available.
> Original source SHA-256: `cb7b21d75d11f66b058a1f6c892013ce1fc6a26cb726f254496415d65802873d`.

## Verdict

The readiness fix passed normal cold-start, warm-query, edit, and recovery scenarios.
The stress test found a separate correctness bug: two projects with the same folder
basename in one Expert session can return references from the wrong project.
This reproduced in two independent runs. The failing assertion remains in the harness.

Three workload runs made 621 MCP requests, including initialization, across fresh
bridge/Expert sessions. The final run passed 93 of 94 checks. A separate real-process
freeze test passed timeout and recovery checks, but also exposed queue latency outside
the handler deadline. This is not an all-green stress result.

No Expert or bridge source/binary changes were made during this stress task. No
upstream submission was made. Two Codex Sol agents independently reviewed the
harness/source and exercised process faults.

## Setup and workload

- Actual Tips Phoenix project archived at `ec365824ab49ad8a89608ef22e60252649c949b1`.
- Installed Expert `0.1.10-tips.ff842bb88e5229ee` through the installed MCP bridge.
- Bridge SHA-256: `cd12f59e4c724b4dc11d5cbe1f8b465b907abc20ec20b0b815ddd61e96641735`.
- Three disposable project copies with private dependency copies; three concurrent
  fresh MCP sessions. Calls within each workload session were sequential, matching
  ordinary agent use. A separate fault test queued three calls in one session.
- Immediate cold query at `test/tips/content/schema_test.exs:165:13`, checking all
  14 expected `tip_fixture` reference paths and lines.
- Repeated exact reference sets, unused-function empties, definition, hover, and
  diagnostics; unresolved-symbol errors in the final run.
- Concurrent edits adding/removing a seventeenth caller; syntax error and repair;
  cross-project navigation, return to the original project, and a session restart.

Final layout: `team-a`, `team-a/.worktrees/team-b`, and
`team-a/.worktrees/nested/team-a`. Separate sessions initially query their own roots;
the first session then navigates into both nested projects.

| Run | Requests | Checks passed | Result |
| --- | ---: | ---: | --- |
| A | 248 | 215/217 | Two invalid outside-workspace success expectations; corrected in B. |
| B | 248 | 216/217 | Same-basename project returned outer-project references. |
| C, final harness | 125 | 93/94 | Same failure reproduced; all other checks passed. |

Run A used sibling projects outside the initialized workspace. Those calls returned
explicit readiness timeouts at about 100 seconds. Expert limits project discovery to
its workspace, so these are negative boundary observations, not supported-navigation
regressions. B and C use nested projects and check exact paths, not just result counts.

## Final-run timings

Client-observed timings; small samples, not production performance estimates.

| Operation | Samples | Median | Maximum |
| --- | ---: | ---: | ---: |
| Cold imported-function references | 3 | 75.790 s | 78.095 s |
| Warm references | 15 | 1.913 ms | 6.288 ms |
| Warm true empty | 15 | 1.483 ms | 2.196 ms |
| Definition | 15 | 1.703 ms | 5.323 ms |
| Hover | 15 | 1.830 ms | 7.582 ms |
| Clean diagnostics | 3 | 1.041 s | 1.041 s |
| Unresolved symbol | 3 | 2.076 ms | 2.110 ms |

Different-name nested navigation passed in 10.118 seconds; returning to the original
project took 4.484 ms. Restarted-session references passed in 8.045 seconds.
Edits became visible after several seconds. This expected batching delay is separate
from readiness. Syntax-error repair validates document diagnostics, not failed index
initialization; the latter remains covered by the earlier deterministic Expert tests.

## Findings

### High: successful references from the wrong project

In B and C, the first session queried
`team-a/.worktrees/nested/team-a/lib/tips/lsp_stress/caller_0.ex`.
Expert returned 16 successful locations, all in outer `team-a/lib/tips/lsp_stress/`.
Both projects had distinct engine nodes; routing to an engine was not the failure.

Source evidence in the patched Expert checkout:

- `apps/engine/lib/engine/search/store/backends/ets.ex:113-123` follows an existing
  global search leader.
- `ets.ex:175-184` names that leader `{:ets_search, Project.name(project)}` and
  routes backend calls through it.
- `apps/forge/lib/forge/project.ex:55-73` makes `Project.name/1` the basename,
  while `Project.unique_name/1` includes root-path identity.
- Related WAL names also use the basename at
  `apps/engine/lib/engine/search/store/backends/ets/wal.ex:225,367-368`.

Why chain:

1. Why did the exact-location assertion fail? Returned paths belonged to the outer project.
2. Why were those paths returned successfully? The query read the outer project's index.
3. Why did the nested project read that index? Its backend followed the existing global leader.
4. Why did that leader appear to belong to it? Both leaders were named using `team-a`.
5. Why does `team-a` identify both? The backend uses a display basename as project identity.
6. Why can correct engine routing not prevent this? The backend independently collapses the two identities.
7. Why can typed readiness errors not prevent this? A query against the wrong ready store succeeds.

The last two questions leave the root unchanged: search-store identity is not unique
per project root. From first principles, index ownership must match project ownership.
The smallest candidate correction is to reuse the existing root-qualified identity
for the leader and related WAL names, then rerun the retained isolation test. Retrying
or changing readiness notices cannot fix this. This correction was not implemented.

### Medium: concurrent engine-cache preparation can fail transiently

Run A exposed shared-cache failures in two sessions, including `File.stat!` on a
vanished consolidated `Elixir.Collectable.beam`. Supervisors recovered; all three cold
queries returned the correct 14 references after 64.873–73.843 seconds. Readiness
remained an explicit retryable outcome during startup.

`apps/expert/priv/build_engine.exs:17-59` shares a version/runtime cache and performs
namespacing after `Mix.install` finishes. The Mix install lock therefore does not
protect the entire pipeline. `apps/forge/lib/mix/tasks/namespace.ex:69-94` reads and
updates shared build trees; `apps/forge/lib/forge/namespace/file_sync.ex:53-57` contains
an existence-check/stat race. These paths predate the references patch.

Prewarming or staggering the first engine launch is a plausible operational mitigation,
not a proven complete fix. A source fix needs serialization of the full shared pipeline.

### Medium: queued MCP calls can exceed the advertised handler deadline

With only the test-owned Expert process stopped, the first call returned a timeout at
60.001 seconds. After resuming it, two queued calls returned correct locations at
60.013 and 60.015 seconds from submission; a fresh query succeeded in 2 ms.

In a separate continued-freeze probe, the second queued call timed out after
120.003 seconds. The third was still outstanding when that probe stopped; no third
completed timeout is claimed.

`mcp-go@v0.25.0/server/stdio.go:128-151,225-249` handles messages synchronously.
The bridge starts tool/LSP deadlines after dequeue, excluding prior queue time.
Thus the 100-second tool bound is not an end-to-end client latency bound under
same-session concurrency. This behavior predates the readiness fix. Tests resumed
the stopped process before terminating their own process groups.

## Reproduction and evidence

Run from the implementation worktree, with a new output directory each time:

```sh
python3 scripts/stress_elixir_lsp.py \
  --repo /absolute/path/to/main/tips \
  --tools-dir /absolute/path/to/main/tips/.elixir-tools \
  --output /private/tmp/tips-lsp-stress-new \
  --rounds 15

python3 scripts/test_elixir_lsp_faults.py \
  --tools-dir /absolute/path/to/main/tips/.elixir-tools
```

The workload harness currently exits nonzero for the same-basename bug. It does not
hide that failure. Expert requires access to its normal macOS engine cache; the live
runs used sandbox escalation for that access. Disposable copies and evidence remain;
owned test processes were cleaned up.

- Run A summary (`/private/tmp/tips-lsp-stress-20260922-a/summary.json`)
- Run B summary (`/private/tmp/tips-lsp-stress-20260922-b/summary.json`)
- Run C summary (`/private/tmp/tips-lsp-stress-20260922-c/summary.json`)
- Run C exact requests and replies (`/private/tmp/tips-lsp-stress-20260922-c/requests.json`)
- Freeze/recovery report (`/var/folders/26/15tlmtc55wggjp8xt79bh5n40000gn/T/tips-expert-faults-cwe4i23i/report.json`)
- Continued-freeze queue observation (`/var/folders/26/15tlmtc55wggjp8xt79bh5n40000gn/T/tips-expert-faults-f5szwbpj/queue-probe-notes.md`)
- Independent source/harness review (`/private/tmp/tips-lsp-stress-review.md`)

Each workload directory also contains bridge logs and project `.expert/expert.log`
files. Final workload fixtures passed `mix format --check-formatted` and
`mix credo --strict` (18 files, no issues). The fault fixture passed formatting and
warning-free compilation; Credo is unavailable in that minimal project. Both Python
harnesses passed compilation checks. Installed binaries were unchanged.
