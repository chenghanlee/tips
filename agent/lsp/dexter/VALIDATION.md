# Prototype validation

The original record below describes the stock-backend prototype. The local
patch (argument counts, then the 2026-09-30 reference-discovery and local-type
extension) has a separate [patch validation record](patches/README.md) with its
final binary, tests, measured cost and remaining limits. The extension's
fixture results are in [references and local
types](#references-and-local-types-2026-09-30).


2026-09-29. Branch `experiment/dexter-agent-prototype`.

This is a working **prototype of the transport and workflows**, not a release
claim that stock Dexter satisfies strict freshness and mutation correctness.

## Incoming call ownership (2026-09-30)

Expanded live verification on eight additional examples passed its declared contracts:
25 supported reference lines had the correct owners; one line with calls in two
different functions was explicitly `multiple_owners` (expected partial result).
Stock incoming calls on the same 25 supported lines produced 5 correct owners,
13 wrong owners and 7 omissions. Every expected reference line was present in the
index. Coverage added setup/context combinations, cross-module attribution, inline
and multiline keyword syntax, nested/absolute modules, nested control flow, same-line
deduplication/ambiguity, pipelines and duplicate test labels with multi-clause helpers.
The executable fixture passed 18 ExUnit tests with warnings as errors. Source/client
hashes were unchanged and the fixture daemon stopped. Full source-derived expectations,
raw receipts and limitations: `/private/tmp/dx-incoming-expanded-5008ri/RESULTS.md`.
This was a verification-only run; the implementation was not changed. The two
ambiguous same-line owners remain unsupported, and lexical clause arity does not
prove runtime/default-argument arity resolution.

The prototype, integrated live run and eight-example source/receipts are also
archived in the main checkout's ignored `tmp/dx-fix-checkpoints/2026-09-30/`, with
SHA-256 checksums in `artifacts.json`. Runtime databases, build caches and nested
Git directories are excluded. The regression tests and fixtures below are versioned.

`incoming-calls` now uses stock references and Elixir's public parser for lexical
ownership. It runs inside the existing DX session and worktree lock. There is one
batched parser subprocess, no outer adapter CLI, new service, cache, index or upstream
patch. Implementation: `dexter_client/incoming.py`, `owners.exs`, and the existing
workflow dispatch. The JSON result is source-call sites plus explicit unsupported
lines, not fabricated LSP call-hierarchy items. See [the contract](README.md#incoming-calls).

The independently owned live fixture contained seven indexed references. Stock Dexter
returned one correct owner, misattributed two sites to a closed helper, and omitted
four. The integrated command returned all six supported sites with the exact source
owners, including aliased and imported calls. The seventh, a capture, appeared in
`unavailable` with `not_direct_call`; exit 1 retained the result. Results were identical
in one cold and three warm requests. Removing the capture file for a separate request
produced six correct sites, no unavailable entries, and exit 0. The file was restored
byte-for-byte and the fixture daemon stopped.

Same-fixture wall times: stock **114–119 ms**, integrated seven-site answers
**474–492 ms**, separate clean six-site answer **534 ms**. Integrated `elapsed_ms`
was 413–432 ms and 467 ms respectively. These are a small feasibility sample, not a
capacity benchmark. Keeping a single stateless parser process per request trades VM
startup cost for fewer moving parts.

Acceptance covers ExUnit blocks before/after helpers, ordinary and keyword-do clauses,
inline ends, nested control forms, nested/absolute module names, defaults, aliases and
imports, repeated references on a line, captures/quotes/typespecs, malformed sources,
dynamic identity, unreadable/out-of-root sources and observed caller-source changes.
The deliberate source fixtures are stored as `.txt` data so Dexter does not index them.
CI sets up the existing Elixir toolchain before the Python workflow tests and runs the
standalone ExUnit acceptance script in the same job.

Nine ExUnit acceptance tests and six Python workflow tests passed. Two existing
real-server hierarchy/capability regressions passed; nine existing protocol/edit tests
also passed. The other 14 stock-server tests were not run for this change. Helper
compilation with warnings as errors, formatting, strict Credo, Ruff, strict Pyright,
documentation links and whitespace checks passed. This checkout has no Mix dependencies,
so its direct Credo hook failed; scoped Credo used byte-identical scratch copies and
the main checkout's existing compiled dependencies, with no installation. No application
code changed and no application-wide Mix suite was run.

The index still determines target identity and which reference lines exist. The helper
does not independently resolve aliases/imports, execute macros or prove index freshness.
Its ranges are source navigation lines, and test/setup names identify syntax, not
expanded runtime functions. Captures and other unsupported cases cause explicit partial
failure; block graph follow-ups remain unsupported. The original 13-site trial corpus
was not replayed in this integration run. No full semantic parity claim follows.

Local raw evidence: `/private/tmp/tips-dx-integrated-live/evidence/`, runs
`live-20260930-024942-stock-baseline`, `live-20260930-025145-integrated`, and
`live-20260930-025159-clean-phase`. An earlier mid-edit run is labelled invalid and is
not evidence of the completed implementation. After these live runs, output cleanup
removed the obsolete `followup_sent` field for incoming calls and added the unsupported
line count to the error detail; ownership behavior was unchanged.

## Team launcher integration

Challenge-review follow-up: **85 team tests and 24 adapter tests passed**. The
team run enabled real Dexter fixtures and the installed Codex check. A later
correction to that Codex check also passed individually: it parses the generated
plugin values explicitly and checks that a legacy MCP definition in the fixture
main checkout is absent from the worktree's server list. It does **not** prove
project settings auto-load or real-model instruction uptake; a CLI trust override
was insufficient to establish project-file loading.

The launcher now preserves unrelated coding-Claude MCP servers, omits the invalid
transport-less Codex MCP table, and defaults source discovery to the main checkout's
versioned Elixir sources. Team retirement relocates snapshots before deleting
resources and refuses if that move fails. Ordinary `write` snapshots retain only
the target pre-image. Test daemons use a short explicit idle timeout and register
cleanup before startup; team daemons still default to a persistent watcher.

The default report omits repeated metadata and renders simple navigation lists
with relative paths and 1-based ranges. No matches are truncated, diagnostics and
warning/error notifications remain, and `--json` preserves the full protocol report.
On the prototype tree without deps, a paired smoke measured hover output at
1,821 → 909 bytes, definition at 1,892 → 832, references at 3,441 → 972; all six
calls succeeded in 128–135 ms. This is not a distribution or a full Tips-with-deps
benchmark. Evidence: main `tmp/dexter-architecture-review/review-fixes-output.json`.

Ruff, formatting, strict Pyright, documentation links and whitespace checks pass.
Real client sandbox/trust behavior and a mixed-harness assignment remain pilot
checks. Reviewers measured a local-socket denial with Codex network access disabled;
the setup guide records the prerequisite without changing user sandbox settings.

The prototype branch now provisions Dexter during worktree setup, exports a
worktree-bound command for both harnesses, supports explicit same-team `--share`,
and stops one daemon per retiring worktree. Native language plugins and the old
Expert bridge are disabled in generated sessions. The old patch/build scripts
were removed from this branch; user-wide installations and live teams were not
changed. Main remains merge-only, with agents operating in leaf worktrees.

Validation: **82 team tests passed**, including an opt-in test using real stock
Dexter daemons with fake Herdr/model clients representing two mixed teams. Four
simulated agents share two worktrees; an atomic edit changes the first tree's
hover while the second retains the original. The generated command stays bound
even when invoked from main with a competing `--root` argument. An additional
retirement snapshot-preservation test passed after that full run. Ruff lint and
format checks, strict Pyright, documentation links, and `git diff --check` pass.
Ruff was an existing cached executable; nothing was installed. The first run's
five process tests hit sandbox denial of `/bin/ps`; the successful full rerun had
permission to inspect and signal only its synthetic child processes.

The launcher tests simulate Codex/Claude processes: they do not establish real
client approval behavior, sandbox socket access, or full mixed-team task success.
The prior live shell smoke and the remaining upstream correctness limitations
below remain the extent of actual-client evidence. Challenge review and real
client acceptance remain required before adopting this for production teams.

Run the opt-in launcher integration with the already-built adapter directory:

```sh
TIPS_TEST_REAL_DEXTER="$PWD/agent/lsp/dexter" \
DEXTER_ELIXIR_LIB_ROOT=/absolute/path/to/matching-elixir-source/lib \
  python3 -m unittest discover -s agent/teams/tests -t agent/teams -p 'test_*.py'
```

## Build and automated checks

- Built unmodified upstream `cd099f31b7701803292584887bb614628f721b0a` using
  `build.sh`; upstream Git status remained clean.
- Binary SHA-256: `c27410b4424dbccf1053f23a7faa6b3c1d4fcfd1d039589ba7d06d72047da63a`.
- The Go build emitted a sandbox module-cache write warning but completed with
  exit 0 and the expected binary checksum.
- 19 Python tests passed. Integration tests use the real pinned server and
  disposable **actual Git worktrees**. Protocol fault tests use a tiny adversarial
  subprocess; coordinate/edit validation tests exercise wide-impact pure logic.
- No Tips application code or dependencies were changed. Application Mix,
  ExUnit and Credo checks were not run for this Python-only integration change.

Run from this worktree:

```sh
DEXTER_ELIXIR_LIB_ROOT=/absolute/path/to/matching-elixir-source/lib \
DEXTER_BINARY="$PWD/agent/lsp/dexter/vendor/dexter" \
  python3 -m unittest discover -s agent/lsp/dexter/tests -v
```

### Standard-library configuration follow-up

The client now validates matching sources on `start`, saves the path/version per
worktree, and uses that environment for all later Dexter processes. Configuration
changes retire an old daemon with stock non-forced `stop`; unchanged `start` does
not restart it. Four added real-server tests cover missing/source-less paths,
version mismatch, migration of a legacy daemon and automatic daemon replacement,
and refusal to disconnect an attached teammate. All **23 tests passed** (17.8 s).
The regression tests failed against the original implementation before the fix.

On this machine, authentic Elixir 1.20.4 sources were exported from the clean
official-repository checkout at `759443e724f55bf58e71c0603644e99058918d52` into the
main checkout's ignored `agent/lsp/vendor/elixir-1.20.4/` directory. No runtime or
upstream source was changed. The prototype's old daemon was stopped normally and
restarted with the saved source path. The main checkout's language stack was not
started or changed.

Actual Tips `Enum.each` lookups at `lib/tips_web/user_auth.ex:180` then returned
documentation and definitions in authentic `enum.ex`. Separate client processes
had no `DEXTER_ELIXIR_LIB_ROOT` override: they used the saved worktree configuration.
Wall times were **132.6 ms hover** and **131.4 ms definition**. These are two smoke
observations, not a benchmark distribution or a claim about index freshness.
Evidence: main checkout `tmp/dexter-architecture-review/stdlib-fixed-live.json`.

The local build manifest supplies the checksum for the locally built binary.
For a different external build, audit its revision and pass its checksum when
calling `dx`; the integration test expects the local build or original audited
binary. No upstream release string is treated as sufficient identity.

## What passed

| Area | Evidence |
| --- | --- |
| Worktree isolation | Atomic edit changes hover in A, B retains original; definition points into A; a unique created module does not appear in B |
| Ancestor index hazard | Missing child database is refused; `start` initializes child; child definition and rename remain in child while parent has an index |
| Nested clones | Both nested worktrees and unregistered `.git` checkouts make the parent root fail closed |
| Shared clients | A live session survives another frontend's normal exit and forced process death; stock stop refuses an attached teammate |
| Saved writes | Two simultaneous replacements using one base hash produce one success and one stale-base error |
| Language methods | Every advertised request family has a callable named workflow; capability smoke checks valid wire requests |
| Follow-ups | Completion resolution/application, code-action selection/application, prepared incoming and qualified outgoing calls |
| Mutations | Module rename moves a file and reports both paths; function, variable and alias renames; format application; create and stale-base rejection |
| Recovery evidence | Ignored source touched by rename is included in snapshot and changed-file report; pre-existing dirty contents are retained |
| Diagnostics | Syntax error publication and later clearing; no compiler-readiness inference |
| Error handling | LSP error code/data preserved; timeout and frontend crash are errors; unimplemented watcher registration rejected |
| Text edits | UTF-16 surrogate pairs, CRLF/CR and Unicode separators; overlapping edits rejected; all proposed bases checked before client writes |

## Actual Codex and Claude smoke

Codex invoked the command through its shell tool. Fable invoked it through
Claude Code's shell tool, on the same prototype worktree and shared daemon.
Claude's corrected smoke returned capabilities and 50 `Tips` workspace symbols;
all returned URIs were inside the prototype. Client root, proxy root and daemon
log root agreed. Main Tips was refused because it contains nested checkouts.

The first live smoke **failed isolation**: stock Dexter selected the parent's
pre-existing 138 MB database, and symbol results included nine trees. No source
mutation was requested. That read-only probe refreshed derived parent index
state; the accidentally started parent daemon was stopped without force. The
client was corrected, tested and then rechecked by Fable. Earlier parent-daemon
timings are invalid as worktree-isolation performance evidence.

The corrected prototype initialized its own database (113 files; no fetched
project dependencies) and started its daemon in about **1.4 seconds**. Five warm
hover calls had a median of **661 ms**, including Python startup, full reconcile,
LSP session initialization and shutdown. One atomic replacement was reflected
in the verified new hover text after **738 ms** (`prototype-edit-latency.json`).
These are small-checkout observations,
not a comparison with the earlier dependency-rich ElixirLS benchmarks.

Local detailed evidence is retained in the main checkout's ignored
`tmp/dexter-architecture-review/`: `prototype-review.md`,
`live-smoke/cap2.json`, `live-smoke/ws2.json`, and
`prototype-smoke-isolated.json`.

## Still not established

- Two complete Codex/Claude teams concurrently editing two trees. The live
  cross-harness smoke covers reads in one tree; automated tests cover two trees
  and cooperating writers. Native harness editing tools still bypass the lock.
- Semantic correctness of every capability for every Elixir construct. Smoke
  coverage is not full parity proof. In particular, the pinned server returned
  null for an unqualified local outgoing-call fixture; a qualified call passed.
- Strict saved-revision freshness. Earlier stock fault injection proved that
  reindex can return success while stale symbols survive a read failure.
- Safe completion/recovery of partial server-side rename, or mutation crash
  recovery. A timeout/disconnect may leave server work running after the client
  releases its lock. Snapshots/diffs neither prevent nor detect every lost write.
- Dependency/path-dependency edits, compiler-generated symbols, stale copied
  databases, and all resource-operation failure paths under real project load.
- Identifying `.git`-less copied source trees as foreign. Dexter ignores
  `.gitignore`; such files can affect results and renames. The snapshot now
  captures them, but the adapter cannot infer whether they belong to the project.

The final Fable review found no blocking local client defect. Two conservative
behaviors remain: a directory disappearing during a scan fails that operation,
and mutations fail closed on excluded `.worktrees` source copies or source
symlinks escaping the root. Fix the layout or retry after filesystem activity;
these errors are not converted into empty language results.

Main Tips must be merge-only for this pilot while `.worktrees/` and fixture
clones live beneath it. Agents use a leaf worktree. Moving the team's worktree
layout is a separate decision; this prototype does not change production launchers.


## Typed modular refactor

The adapter and its tests now use the team harness's Ruff profile and strict
Pyright project; CI includes them in lint, formatting and type checking. Local
validation used Ruff 0.16.8 from the existing offline cache and installed Pyright
1.1.413, matching CI's versions; remote CI has not been run for this change.
No lint selection or complexity limit was relaxed. The test-only `S101`
exception matches the harness. Open-ended LSP payloads retain explicit dynamic
values; local process, snapshot, configuration and argument state are typed.

All 25 adapter tests passed with the pinned real Dexter binary and authentic
Elixir sources. The 85-test team suite included real Dexter and installed Codex
checks: 80 passed in the sandbox; five shutdown tests were blocked by sandbox
permission to run `/bin/ps`. All seven shutdown tests then passed with process
access. No live teams or model sessions were launched by these tests.

The maximum Ruff McCabe complexity in the adapter is 9 (limit 10); the old
`apply_workspace_edit`, `workflow` and `main` measured 17, 26 and 33. Splitting
responsibilities does not add a process, dependency, upstream patch or stronger
freshness/concurrency guarantee.

All three independent reviewers accepted the refactor. One intentional tightening
is that diagnostics and empty call-hierarchy results now also reject a source
file changed during the lookup (`changed_base`); previously those paths returned
before the final source check. This is not a shared-index freshness guarantee.

The third reviewer reproduced a 60-second syntax-diagnostics timeout using a
full Elixir Git checkout as the standard-library source. Both the original
`742d8f1` and the refactor failed in that environment; the same test passed with
the main checkout's vendored `lib` and `VERSION` layout, despite identical `lib`
contents. The cause remains unisolated. Use the validated vendored sources for
the pilot; do not infer that arbitrary source-checkout layouts have been tested.

## Outgoing call sites (2026-09-30)

`outgoing-calls` replaces stock `callHierarchy/outgoingCalls`, which returned null or a
short list for ordinary functions (four nulls and three two-row lists across seven
preserved trial receipts; every miss was a dropped call, none a wrong target). The
new path parses the saved source once with the public parser, prepares each call name
with the configured Dexter binary's `prepareCallHierarchy` in the same session and groups identical items into
the LSP outgoing list. Implementation: `dexter_client/outgoing.py`, `sites.exs` and
the existing workflow dispatch. No resolver, cache, index, service or new upstream
patch; generated targets use the packaged argument-count binary.

Hand-derived expectations were written before any run, from source, on two isolated
fixtures: eight common cases (`E1`-`E8`: qualified and aliased calls, pipe and capture
helpers, a bodiless default head, two same-arity clauses queried from either head, a
no-call control, a private helper calling generated functions, an ExUnit private helper
with `send`/`self`/an anonymous call) and a real `use Ecto.Repo` fixture with ecto
3.14.2 / ecto_sql 3.14.0 copied from the main lock (piped `insert!/1`, `one/1`,
`delete!/1`, adapter-injected `query!/1` and `/2`, an ExUnit helper, a no-call control).
The isolated prototype found 18 of 20 expected rows on the first fixture (the two
misses are Erlang-module calls, documented unsupported) and 9 of 9 on the real Ecto
fixture, with zero wrong targets, zero false positives and empty controls; the
`query!/2` label defect it exposed is fixed by the packaged arity binary.

Integrated run (2026-09-30, binary `d4ac1fd5`, helper `sites.exs` `250707cf`, fixtures
`fa9fb4a` and `2b7059f`, daemons started and stopped per fixture, one cold and one warm
`dx outgoing-calls` per query, exact expected sets compared; runner and receipts kept
outside the checkout):

| fixture | queries | expected rows | found | missed | wrong targets | false positives |
|---|---|---|---|---|---|---|
| common `E1`-`E8` (+ second heads `E4b`, `E5b`) | 10 | 20 | 18 | 2 (`:inet.is_ip_address/1`, `:ets.info/2`, Erlang, documented unsupported, reported as `unresolved_count: 1`) | 0 | 0 |
| real `use Ecto.Repo` `R1`-`R5` | 5 | 9 | 9 | 0 | 0 | 0 |

Every request returned `ok: true`, exit 0, and identical cold and warm results. Both
heads of a two-clause function (`E4`/`E4b`, `E5`/`E5b`) returned the same list with both
clauses in `clauses`. Both no-call controls returned an empty list. `Kernel.self/0` in `E8`
is a correct extra call not in the hand set. The real Ecto fixture labelled
`Shop.Repo.query!/2` and `Shop.Repo.query!/1` by the called arity, so the prototype's
label defect is gone in the integrated command. Wall time per request was 436-488 ms
(`elapsed_ms` 377-428), measured as request totals only; no attribution between
parser and prepares was measured in this run. Final checks reported by the root
integrator on the worktree: 12 ExUnit helper tests, 37 adapter tests, `ruff check`
and `ruff format --check` on 24 files, Pyright strict with 0 errors, scoped Credo pass.
Runner and receipts:
`/private/tmp/claude-501/-Users-chenghanlee-Software-Projects-tiny-big-agents-tips/6aff7bc9-f4ed-48da-b9cb-b1dfb48c812c/scratchpad/outgoing-acceptance/`
(`run_integrated.py`, `evidence/integrated.json`). No accuracy percentage is claimed for the population of Elixir
sources; the supported and unsupported forms are listed in
[the contract](README.md#outgoing-calls).

## References and local types (2026-09-30)

The patch extension covers imported bare captures, one-line imported calls,
aliased imports and bare local type definitions
([patch record](patches/README.md#retained-tests);
triage in the main checkout's `tmp/dexter-reference-triage/TRIAGE.md`).

Fixture and oracle: the references/type-definition fixture at commit `6958b68`
(20 reference positions, each with `include_declaration` false and true; 15
type-definition positions) and hand-derived `expected.json` (SHA-256 prefix
`92a0570c`), written from source before any run and held fixed. Scores are by
`file:line:column` at the name start; missing, wrong, duplicate and unsupported
rows are counted separately. `NA1` (aliased-import cursor), `TP1` (type
parameter) and `TN3` (parent type after a nested module closes) were diagnostic
controls, reported beside the ordinary rows.

Before, on the arity-only binary `d4ac1fd5` (backend rows, 2026-09-30): the
ordinary `normalize/1` positions returned 30 of 34 sites, missing the imported
captures `importer.ex:8` and `capture_only.ex:6` and both aliased-import calls
`aliased_importer.ex:7` and `:10`; `put/3` missed the capture `importer.ex:11`;
`NA1` returned nothing; `type-definition` returned nothing at the bare local
types `TD1`, `TS1`, `TN1`, `TN2`, `TN3`. No wrong references.

After, packaged binary `7f01cbf2` on a fresh clone of the fixture, one run per
cell, backend only (p15, 2026-09-30 12:49; independently rescored from the 55
raw reports against the same oracle):

| set | queries | expected rows | found | missing | wrong | duplicate |
|---|---|---|---|---|---|---|
| references, ordinary `N1`-`N9` | 9 x 2 | 34 each | 34 each | 0 | 0 | 0 |
| references, arity/declaration `P*`, `F*`, `K`, `D` | 10 x 2 | per oracle (`P3`, `P3c` 5) | all | 0 | 0 | 0 |
| references, aliased-import cursor `NA1` | 1 x 2 | 34 each | 34 each | 0 | 0 | 0 |
| type-definition, ordinary `TD*`, `TB`, `TF*`, `TS*`, `TN1`, `TN2` | 12 | per oracle | 12 correct | 0 | 0 | |
| type-definition, controls `TP2`, `TN3` | 2 | per oracle | 2 correct | 0 | 0 | |
| type-definition, control `TP1` | 1 | empty | `typed.ex:4` | 0 | 1 | |

Declaration rows appear only with `include_declaration: true` and match the
expected head lines. `TP1` is the one wrong row: the type parameter `t` in
`@type wrap(t)` resolves to the module's `@type t` because the bare-local
branch has no parameter scoping. It is recorded as a bounded limit; its
frequency in real code is unknown and no further check was added for it.

Warm `elapsed_ms` medians on this fixture: references 57.0 ms (n=40),
type-definition 47.1 ms (n=15); the arity-only rows from the earlier run measured
51.5 and 43.4 ms under different load. These are not a paired cost of the
patch, and the cost of scanning importing files on a large repository is not
measured.

Checks: 16 handler subtests with pre-fix failures recorded first; full
`go test ./...` passed with normal process permissions after a sandboxed attempt
failed three existing process-discovery cases; `go vet`, upstream lint using
the existing compatible analyzer, and module tidy diff clean; 37 adapter tests
passed on the packaged binary; Ruff check and format on 17 files and strict
Pyright clean. Evidence:
main checkout `tmp/dexter-reference-triage/patch-followup/` (`RESULT.md`,
`evidence/summary.json`, `evidence/raw/`, `root-checks/`).

Not established: reference completeness over Elixir sources, `use`-injected
consumers without an import row, interpolation, type-parameter scoping, rename
safety, index freshness. No accuracy percentage is claimed.

## Required TBA Go profile follow-up (2026-09-30)

The full custom TBA golangci-lint profile, including Staticcheck and NilAway,
was run on source `6e38b3c` and pre-extension parent `8f03fa4`. It reports
1,460 versus 1,461 findings; after accounting for shifted diagnostic lines,
the only difference is a corrected path-join argument in our generated-arity
test. All six affected regressions pass. No production code changed in this
follow-up; the rebuilt binary checksum remains `7f01cbf2…`.

This is not a strict-lint pass: inherited findings remain, including the
earlier generated-arity handler's cognitive complexity of 22 (limit 20).
The initial run's five additional taint findings in unchanged functions did
not recur; both reports are retained. See the
[required Go check](patches/README.md#required-go-static-analysis) for the
versioned profile, tool pins, comparison policy and evidence paths.
