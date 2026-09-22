# Local Expert and MCP startup fixes

Each coding client has its own bridge and Expert rooted in its assigned worktree. Shared binaries and the engine preparation cache live outside those worktrees. The canonical `scripts/elixir_lsp.sh` accepts an absolute root; the helper passes it for both clients, including reviews of commits predating the wrapper. [agent-team.toml](../../config/agent-team.toml) controls client settings; [goal-prompt.md](goal-prompt.md) describes launch and cleanup.

The local Expert patch preserves typed reference outcomes through JSON-RPC:

| Outcome | Bridge behavior |
|---|---|
| Locations, including a successful empty search | Return immediately. |
| `index_not_ready` | Retry within the request deadline. |
| `index_failed`, `query_failed`, `unresolved_symbol` | Report the error immediately. |

A timeout is an error, never a successful empty result. Project-root ETS identity prevents same-basename projects sharing a search backend. An outer preparation lock protects the shared engine cache; no private engine caches or compiler optimization overrides are added. Definition, hover and diagnostics retain the bridge's existing startup adapters and their documented limitations in the patch tests.

The bridge initializes Expert at client MCP startup so compilation overlaps briefing. Neither launcher adds a runtime LSP probe or waits for compilation. EOF, SIGTERM and parent exit invoke bridge cleanup; client shutdown must still verify all owned descendants, because engines can use separate process groups. Conversation reset does not restart or reroot the LSP.

## Build and validate

Build from a worktree. Set the destination explicitly; installing does not restart existing clients:

```bash
export TIPS_ELIXIR_TOOLS=/absolute/path/to/main/.elixir-tools
scripts/build_expert.sh
scripts/build_elixir_bridge.sh
python3 scripts/test_elixir_references_live.py --tools-dir "$TIPS_ELIXIR_TOOLS"
```

The build scripts pin upstream sources, apply the checked-in patches and run their affected tests before installation. Expert builds a versioned plain release and swaps a symlink; bridge installation atomically replaces its binary. Keep both patched components together. No upstream submission is assumed. The Expert build checks formatting and strict Credo on changed files and targeted ExUnit tests. Pinned upstream emits existing warnings on this host's newer Elixir, so a successful release is not evidence of a clean whole-project warnings-as-errors build.

The current bridge request deadline is compiled into its patch. The helper refuses a conflicting `timeouts.mcp_tool_seconds`; changing that contract requires rebuilding and validating both sides. Equal client/bridge deadlines do not guarantee receipt of a bridge timeout at the boundary. Queue time before a sequential MCP handler begins can lie outside its handler deadline.

Run `python3 scripts/test_task_worktree.py` and `python3 scripts/test_team.py` for disposable launcher/lifecycle integration tests. After tooling or launcher changes, pilot both real interactive clients with disposable worktrees. Verify client cwd and actual LSP workspace, references in the assigned root, reviewer advance and complete descendant exit. `mcp get` alone proves configuration, not runtime root. Never replace that pilot with a second probe LSP.

## Evidence and limits

The earlier lifecycle run recorded five real cold **MCP sessions**, each returning exact own-root references in roughly 97–104 seconds; warm calls took roughly 36–55 milliseconds. A follow-up tracked ten processes per session through complete exit. Actual Claude initialized its MCP server and began compilation before a model prompt, then exited cleanly. This was not five actual Codex agents or evidence of capacity for every team's coding clients simultaneously. The configured team cap remains a trial.

Original host evidence: `/private/tmp/tips-lsp-timeout-120/LIFECYCLE_RESULTS.md`. Disposable integration tests cover launcher behavior; they do not establish model availability, trust configuration or full cold-worker capacity.

## Integrated client pilot (2026-09-22)

Both interactive clients returned the exact expected fourteen reference locations in their assigned worktrees, with no foreign-root paths. The bridge process arguments also named the correct root. Codex needed explicit approval for the four enabled LSP tools; the generated config now takes that scoped setting from `launch.codex_lsp_approval_mode`. Its overall approval and sandbox policies stay in place.

A live Claude reviewer advanced to a different SHA, stopped its old client and descendants, then restarted successfully. The pilot exposed a stale Herdr name after physical exit. Shared shutdown now releases that name only after verifying process exit; an `agent_not_found` response means Herdr already released it. Other errors still fail.

Team startup created four labeled panes and launched only the TPM, with the configured environment and no Elixir bridge. After initial repository trust approval, both clients launched in fresh sibling worktrees without another trust prompt or keypress. This is evidence for the installed client pair, not a promise about future versions or other trust settings.

The pilot used a disposable clone and a scratch copy of the shared Expert cache, with a test-only cache-path redirect. It did not replace installed tools or modify production sessions. It does not establish cold-start capacity for all teams. Launcher and shutdown regression suites pass with 47 tests; the earlier Linux run also passed before the final pilot fixes.

Final shutdown left no surviving owned processes across 122 captured PID/start-time identities. The two test workspaces, disposable clone and copied release/cache were removed; logs and source/config snapshots remain in `/private/tmp/tips-client-pilot-wbzwtaim/RESULTS.md` and its accompanying evidence files. The pilot did not run database cleanup or restart PostgreSQL.
