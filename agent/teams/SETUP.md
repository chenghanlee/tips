# Agent pairs: setup

For humans, from the repository root. Agents read the [pair workflow](README.md) instead.

## One-time setup

Install Python 3.12 and the [configured client CLIs](config.toml). Authenticate the clients and the GitHub CLI (`gh`) for this repository. Coding agents also need `unbuffer` (Expect): the Elixir skill requires it on Mix commands.

The user maintains third-party skills in the main checkout. Both locations are Git-ignored:

- `.agents/skills/`: `elixir`, `phoenix`, `ecto`, `otp`, `oban` and `herdr`, for Codex.
- `.claude/skills/`: the same five Elixir skills, for Claude.

Update matching copies together. `team.py start` links the main checkout's `.agents/skills/` into each worktree and checks only that the directory exists.

The repository owns one skill, the [Dexter reference](../skills/dexter/SKILL.md). Link it once into both locations from the main checkout:

```bash
ln -s ../../agent/skills/dexter .agents/skills/dexter
ln -s ../../agent/skills/dexter .claude/skills/dexter
```

Install only the `mix-credo` plugin, for the clients you use:

```bash
# Codex
codex plugin marketplace add georgeguimaraes/elixir-agent-tools
codex plugin add mix-credo@elixir-agent-tools

# Claude Code
claude plugin marketplace add georgeguimaraes/elixir-agent-tools
claude plugin install mix-credo@elixir-agent-tools
```

Generated settings enable Credo for both clients. Claude launches use `--settings` to disable known language-server plugins, including in linked worktrees; existing local settings files are preserved. Remove any old `mcp_servers.elixir-lsp` entry from Codex configuration; the launcher does not disable it.

Build Dexter with the [LSP guide](../lsp/README.md#build): the pinned source plus the local patch, one binary. Put matching Elixir sources in the main checkout's `agent/lsp/vendor/elixir-<version>/` (the source tree contains `lib/elixir/lib/enum.ex`), or set `DEXTER_ELIXIR_LIB_ROOT` to their `lib/` directory. Stop pairs before replacing the shared build.

Codex must be allowed to connect to Dexter's local Unix socket. The tested macOS `workspace-write` sandbox denies it with network access disabled; access works with network access enabled or a scoped `--allow-unix-socket /private/tmp/dexter-<uid>` allowance. Set the narrowest suitable user-owned permission before the first launch. With approval policy `never`, a denied connection cannot escalate. The launcher does not change sandbox settings.

## Start the dispatcher

In a Herdr pane (`HERDR_ENV=1`) at the main checkout:

```bash
claude --permission-mode auto 'Run herdr agent rename "$HERDR_PANE_ID" dispatcher. Then read agent/teams/README.md and act as the dispatcher.'
```

Start only one. Pairs ring it by the name `dispatcher`. It starts and stops pairs with `team.py` from this checkout; each pair gets its own Herdr workspace. Handle each client's repository trust prompt the first time. An unexpected approval prompt stops a launch; inspect it and follow the active approval policy.

## Configuration

Edit [config.toml](config.toml): the number of pairs, client, model and effort per role, port and database allocation, permissions and time budgets. Scripts read the main checkout's file; `TIPS_TEAM_CONFIG=/absolute/path` selects a staged one. Settings apply at the next launch.

| Allocation | Components |
|---|---|
| Database suffix | `team.db_suffix_prefix`, slot number, `roles.<role>.db_suffix` |
| Test port | `team.port_base` + slot number × `team.port_stride` + role `port_offset` |

`timeouts.dexter_startup_seconds` bounds the Dexter warm-up at start, Elixir version detection and the daemon stop at retirement. `TIPS_DEXTER_HOME` selects another shared Dexter build directory.

Set database connection limits in [compose.yaml](../../compose.yaml), overridden by `TIPS_DB_MAX_CONNECTIONS`. Recreate the database service to apply changes, only with no pairs running.

## Changing these scripts

Follow [development](development.md). For optional local checks, install Ruff and Pyright yourself; agents never install them.

## Milestones

Read the [Project 15 readme](https://github.com/users/chenghanlee/projects/15) with `gh project view 15 --owner chenghanlee`. Milestones and gate issues live there, never mirrored here.
