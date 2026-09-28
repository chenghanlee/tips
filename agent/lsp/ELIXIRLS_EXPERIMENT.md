# Codex + ElixirLS worktree experiment

This opt-in path runs one stdio MCP bridge and one ElixirLS process per Git
worktree. It keeps the existing team database/port allocation and safe retirement
workflow. It does not replace Expert by default or configure Claude.

## Isolation boundaries

| Resource | Ownership |
|---|---|
| Git objects, installed bridge, Elixir/Erlang, ElixirLS release | Shared |
| `deps/`, `_build/`, `.elixir_ls/` | Separate ordinary directories per worktree |
| LSP workspace, cwd and environment | Explicitly assigned to that worktree |
| Database suffix and test port | Existing team/role allocation, passed to both Codex and MCP |
| Server transport | stdio; ElixirLS's native TCP MCP service is disabled |

The launcher rejects symlinked project directories and source queries outside
the assigned root. It removes inherited `MIX_BUILD_PATH`, `MIX_BUILD_ROOT` and
`MIX_DEPS_PATH`. The team launch clears them from the agent's shell too. Do not
configure absolute shared project build/dependency paths in `mix.exs` or use
hard-linked source/build files. These checks prevent common mistakes; they are
not a security boundary against arbitrary shell access.

An advisory lock in `.elixir_ls/codex.lock` rejects a second instance of this
launcher in the same worktree. Editors that do not use this launcher do not
respect that lock. Give each concurrently writing agent/editor its own worktree.
Never delete or replace `.elixir_ls/` while its server is running.

Mix/Hex user homes do not need to be duplicated for this pilot. Dependencies
must already be available in each worktree; run `mix deps.get --check-locked`
there during setup. The launcher does not install dependencies or wait for a
complete project compilation. ElixirLS settings are delivered through LSP
`workspace/configuration`, not VS Code settings: auto-build enabled, dependency
fetching and Dialyzer disabled, and the assigned `MIX_ENV` (default `test`).

## Try it without replacing shared tools

Prerequisites: the [bridge build tools](README.md#build-and-validate), Python
3.12+, and an installed `elixir-ls` on `PATH`. The pilot was tested with
ElixirLS 0.31.1, Elixir 1.20.4 and OTP 29.1. Set `TIPS_ELIXIRLS_COMMAND` to an
absolute executable path if needed.

Build a private copy in the experiment worktree:

```bash
export TIPS_ELIXIR_TOOLS="$PWD/agent/lsp/vendor"
agent/lsp/build_install_mcp_bridge.sh
python3 -m unittest discover -s agent/lsp/tests -v
python3 agent/lsp/pilot_elixirls.py "$PWD/tmp/elixirls-pilot-1"
```

Use a new output directory for each run. The pilot creates a synthetic Git
repository with two real worktrees, runs both servers concurrently, checks
navigation, saves a compiler error in one, verifies separation, and checks
independent shutdown and lock reuse. It retains worktrees and logs even on
failure. No application databases, remote repositories or live agents are used.

For a standalone Codex session, use explicit absolute paths in its MCP config:

```toml
[mcp_servers.elixir-lsp]
command = "python3"
args = ["/path/to/experiment/agent/lsp/launch_worktree_elixirls.py", "/path/to/assigned/worktree"]
cwd = "/path/to/assigned/worktree"
startup_timeout_sec = 120
tool_timeout_sec = 120
enabled_tools = ["definition", "references", "hover", "diagnostics"]

[mcp_servers.elixir-lsp.env]
TIPS_ELIXIR_TOOLS = "/path/to/experiment/agent/lsp/vendor"
MIX_ENV = "test"
# Add this worktree's allocated PGPORT, TIPS_DB_SUFFIX and TIPS_TEST_PORT.
```

Start Codex with `--no-daemon -C /path/to/assigned/worktree` so each session
owns its server environment. Follow [Codex MCP configuration](https://developers.openai.com/codex/mcp)
for standalone client setup. Generated team configuration explicitly includes
the allocated database and port values.

Once these changes are reviewed and available in the canonical main checkout,
the existing `agent/teams/task_worktree.py` accepts `--lsp elixirls` for Codex
roles. All its other task/team/pane arguments remain required. It intentionally
uses the canonical main checkout's launcher; running a modified helper from a
feature worktree does not install that launcher in main. Do not copy over a
live team's configuration to try this experiment.

## Diagnostics and cleanup

The old generic bridge sent `didChange` without `didSave`. With ElixirLS this
could report no diagnostics while a saved file contained a compiler error.
The new mode sends both and avoids repeatedly rebuilding unchanged files when
reading diagnostics.

ElixirLS publishes parser diagnostics before compilation finishes. Even a
matching document version and an empty list do not prove compilation succeeded.
The tool therefore labels results as **compiler completion unverified**. Run
`mix compile --warnings-as-errors` and the relevant tests before accepting work.
The pilot's observed error/repair transition is evidence for that fixture, not
a guarantee against all incremental compilation/timestamp races.

Closing the MCP client shuts down its server; it does not delete source or drop
databases. Keep shutdown separate from retirement. Use the existing team
retirement checks for stopped processes, dirty worktrees and owned database
names. Do not add unconditional `git worktree remove --force`, `rmtree`, branch
deletion or `mix ecto.drop` to a failure handler. A Python `finally` block does
not survive SIGKILL or power loss.

## Validation scope

The automated pilot covers two concurrent real ElixirLS servers and real MCP
requests. Launcher tests cover root validation, shared-directory refusal,
environment isolation and lock release. Team integration tests cover generated
Codex configuration and preserve the existing lifecycle behavior.

The initial run also launched two real Codex CLI sessions concurrently. Both
completed `hover`, `definition`, `references` and `diagnostics` against their
own fixture roots. The patched bridge passed `go vet` and its affected package
tests; all 78 team tests and four launcher tests passed. Pyright and the local
documentation checker passed. Ruff was unavailable in the test environment.

This is an experiment, not approval for rollout. The synthetic pilot does not
exercise Phoenix listeners, actual PostgreSQL provisioning, a full team load,
or the complete real-client commit/push/handoff workflow required by
[the adoption checklist](README.md#check-changes).
