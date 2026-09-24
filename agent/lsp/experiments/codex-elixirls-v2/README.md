# Codex + ElixirLS experiment v2

Date: 2026-09-24. Branch: `experiment/elixirls-codex-v2`.

**Result: MCP interoperability works. Do not roll out this bridge unchanged.**
The unmodified published `lsp-mcp-server@1.1.24` works with a real Codex client
and ElixirLS 0.31.1. It can return stale documentation after an ordinary edit by
the sole agent in a worktree. Requiring the agent to restart servers or open and
refresh files in a particular order is not an acceptable integration.

This experiment uses no code from the discarded bridge prototype. It changes no
active client configuration or team launcher. The existing checkout's unrelated
Claude integration work was left alone.

## Root problem and decision

The nine whys used to narrow the experiment:

1. Why integrate an LSP? Give Codex accurate definitions, references, documentation
   and compiler feedback while it works.
2. Why use semantic tools? Text matches alone cannot resolve all those questions.
3. Why reuse ElixirLS? It already understands the Elixir project and compiler.
4. Why use a bridge? Codex exposes the documented MCP client interface; ElixirLS
   exposes LSP. An existing adapter can connect them.
5. Why care about worktrees? Identical symbol names can mean different things at
   different revisions. Results must match the requested worktree.
6. Why did one-agent editing still produce old documentation? Saving a file on
   disk did not necessarily update the language server's view of that file.
7. Why not instruct the agent to refresh? Correctness would depend on hidden
   bookkeeping. Missed steps cause stale answers and unnecessary debugging.
8. Why require automatic synchronization? Accurate context must follow ordinary
   edits without an additional workflow. This confirms the root problem.
9. Why stress edits instead of adding more tools? A larger tool catalog does not
   solve stale context. This confirms the same root problem.

First principles: the language server holds mutable project state. The bridge
must keep that state aligned with saved files, and initialization is asynchronous.
One writer per worktree prevents competing edits; it does not deliver missing
file-change notifications.

Occam's razor: test a pinned existing bridge plus ordinary configuration first.
Do not build a project-specific indexer, daemon, confinement layer or restart
manager. Pareto: prioritize definition, references, hover, diagnostics, ordinary
edits and actual client lifecycle over the other tools in the package.

Inversion: try to obtain a plausible but wrong answer after a normal edit, query
during initialization, advance a Git checkout, request another worktree, and
disconnect a client. The edit test exposed a material correctness problem.

## Evidence

Versions and the installed entry-point checksum are in `versions.json`.
The npm dependency graph is pinned by `package-lock.json`. The bridge and
ElixirLS were not patched. The host used Elixir 1.20.4 / OTP 29.1, Node 26.9.0,
and Codex CLI 0.156.1. Tips started at commit `8150138`.

| Scenario | Observed result | Decision |
|---|---|---|
| Real Codex, synthetic Elixir project | Called all five exposed tools; correct hover, definition and two references | MCP compatibility demonstrated |
| Two Git worktrees, same symbols at different commits | Correct ALPHA/BETA documentation, root-specific definitions, exactly two/three references | Correct normal routing |
| Saved undefined local function, then repair | Error appeared in the edited root; repair cleared it; other root stayed clean | Eventual diagnostics work for an already-open file |
| Full Tips, local MCP client | Correct application hover/definition after initialization; references and error/repair worked | ElixirLS works on the real project through this bridge |
| Initial Tips queries | Hover was `null` and definition was empty before later successful queries, with no pending-state error | Empty first results cannot establish absence |
| First diagnostic after introducing error on Tips | Returned zero errors; a later read reported the error | A single clean diagnostic response is not a compile-completion signal |
| Change an unopened callee, query unchanged caller | Old documentation in six queries; still old in six more after explicitly opening callee | Fails automatic freshness requirement |
| Restart control | Same edited callee returned fresh documentation after server restart | Confirms a stale-state problem; not an accepted workflow |
| Pre-open and batch-index control | Refresh before/after editing worked, with fresh hover on the second query | Diagnostic control only; not an accepted workflow |
| Git checkout while server lives | First hover stale; later hover and references correct | Asynchronous refresh; not a permanent failure in this case |
| Explicit request for another root | Started an additional root-specific ElixirLS instance | Expected multi-root routing, not a blocker for one-agent-per-worktree use |
| Close MCP stdin alone | Bridge and ElixirLS remained alive after eight seconds | Raw-client lifecycle caveat |
| Send SIGTERM / end actual Codex session | All observed owned processes exited | Actual Codex lifecycle passed |

The cross-root test deliberately supplied the other worktree's path. No
spontaneous cross-worktree opening was observed. The user explicitly accepted
the normal path-routing behavior; no hard worktree confinement is proposed.

The first probe used a stricter exploratory checklist. Its raw results mark
cross-root access, EOF cleanup and immediate checkout freshness as failures.
The table above gives the final interpretation after follow-up tests and user
clarification. They are not equivalent to the reproducible edit-freshness failure.

## Minimal freshness reproduction

Only one agent/client is required. In a small Mix project:

1. Put `V2Target.answer/0` with ALPHA documentation in `lib/target.ex`.
2. Call it from `lib/caller.ex`.
3. Ask the bridge for hover at the call site; observe ALPHA.
4. Edit only `target.ex` on disk, changing ALPHA to CHANGED_CALLEE.
5. Query the unchanged caller repeatedly; observe ALPHA.
6. Call `lsp_diagnostics` on the target for the first time, then query the caller
   repeatedly; still observe ALPHA in the measured window.
7. As a control, stop that LSP using `lsp_stop_server` and query the caller again;
   observe CHANGED_CALLEE.

`stress_probe.py` reproduces this sequence. Logs record six one-second-spaced
queries before the explicit target query and six afterward.

Source inspection explains the likely mechanism: `prepareFile` synchronizes the
requested file only. `DocumentManagerImpl.syncWithDisk` sends `didChange` and
`didSave` for a changed file it already opened. The first open of an edited file
only sends `didOpen`. The examined implementation has no general disk watcher
to synchronize an unqueried callee. Reading a file with a shell tool does not
open it in this LSP client's document manager.

These are ordinary LSP synchronization responsibilities. The next candidate or
upstream fix must observe saved changes automatically, including previously
unopened files. No agent instructions to manage server freshness are acceptable.
Keep compilation/tests as verification; do not treat empty LSP results as proof.

## Reproduce

Run from an isolated Tips worktree with the documented Elixir/OTP versions,
`elixir-ls`, Node, Python, `unbuffer`, and Codex available. On this host ElixirLS
is `/opt/homebrew/bin/elixir-ls`; adjust `write_config` for another installation.
The probes require process-table access to verify lifecycle. They are experiments
with observed negative outcomes, not a passing CI suite.

```sh
experiment=agent/lsp/experiments/codex-elixirls-v2
run_dir="$PWD/tmp/elixirls-v2-replay"
mkdir -p "$run_dir/bridge"
cp "$experiment/package.json" "$experiment/package-lock.json" "$run_dir/bridge/"
npm ci --prefix "$run_dir/bridge" --cache "$run_dir/npm-cache" --ignore-scripts --no-audit --no-fund
bridge="$run_dir/bridge/node_modules/lsp-mcp-server/dist/index.js"
python3 "$experiment/probe.py" --bridge "$bridge" --output "$run_dir/basic"
python3 "$experiment/stress_probe.py" --bridge "$bridge" --output "$run_dir/stress"
```

Each output directory must be new. `probe.py` creates its own disposable Git
repository and linked worktree; their commits never enter Tips history. It
returns nonzero when its strict exploratory checks fail. The stress probe records
observations for interpretation rather than returning an acceptance verdict.

For the full application, install Tips dependencies in the isolated checkout and
run `tips_probe.py --bridge "$bridge" --workspace "$PWD" --output "$run_dir/tips"`.
It makes no model/API requests, writes `.lsp-mcp.json`, temporarily creates
`lib/codex_elixirls_v2_probe.ex`, and removes that source file during cleanup.
Run only where no `.lsp-mcp.json` needs preservation.

`codex_probe.py --fixture` runs actual Codex on a separately generated fixture
containing only `probe.fixture` output. It ignores user MCP configuration and
passes a temporary server definition through CLI overrides; it makes model
requests. Without `--fixture`, it queries Tips source. That latter run requires
the explicit data-transfer approval described below.

## Validation and limits

- Synthetic Mix projects compiled with warnings as errors and their ExUnit tests
  passed. A fixture formatting issue was corrected; its formatting check and test
  then passed. Credo is unavailable in the dependency-free fixture (task not found).
- Tips baseline compilation passed; existing dependency warnings were recorded.
  No persistent application source changes were made. The full application test
  suite, HEEx behavior, and high agent counts were not tested.
- Python syntax checks cover the committed experiment scripts. All observed
  experiment server processes were stopped after checks.
- npm's default cache was not writable in the sandbox; an experiment-local cache
  was used. An initial sandboxed probe could not use `ps` from a child process;
  it was cleaned up and rerun with process-table access. An initial Codex launch
  also required outer-sandbox approval for its app server.
- Automatic approval review rejected running Codex on Tips because its tool
  responses would send source-derived data to the Codex service without explicit
  approval. The actual Codex run used only synthetic source. Full Tips was tested
  locally through MCP. Full Tips-to-Codex validation remains unrun pending approval.

Raw transcripts, server logs and results remain under
`/private/tmp/tips-elixirls-codex-v2/tmp/elixirls-v2/`. The durable summary is
`evidence.json`. No global configuration was changed and no rollout is proposed.

Upstream references: [bridge](https://github.com/ProfessioneIT/lsp-mcp-server),
[Codex MCP](https://developers.openai.com/codex/mcp),
[ElixirLS](https://github.com/elixir-lsp/elixir-ls).
