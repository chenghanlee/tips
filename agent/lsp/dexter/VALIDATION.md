# Prototype validation

2026-09-29. Branch `experiment/dexter-agent-prototype`.

This is a working **prototype of the transport and workflows**, not a release
claim that stock Dexter satisfies strict freshness and mutation correctness.

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
DEXTER_BINARY="$PWD/agent/lsp/dexter/vendor/dexter" \
  python3 -m unittest discover -s agent/lsp/dexter/tests -v
```

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
