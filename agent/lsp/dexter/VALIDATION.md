# Prototype validation

The original record below describes the stock-backend prototype. The local
argument-count correction has a separate [patch validation record](patches/README.md)
with its final binary, tests, measured cost and remaining limits.

2026-09-29. Branch `experiment/dexter-agent-prototype`.

This is a working **prototype of the transport and workflows**, not a release
claim that stock Dexter satisfies strict freshness and mutation correctness.

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
