# Agent teams: setup

Humans: perform setup from the repository root. Agents use the [operating agreement](README.md) and their role card during events; no setup reading is needed.

## One-time setup

Install Python 3.12 and [configured client CLIs](config.toml). Authenticate clients and GitHub CLI (`gh`) for this repository. Merges require GNU `timeout` on `PATH`: macOS `brew install coreutils`; Linux distribution `coreutils` package. Coding agents also need `unbuffer` (Expect): the Elixir skill requires it on Mix commands.

The user maintains the skills by hand as plain folders in the main checkout. Both locations are Git-ignored:

- `.agents/skills/`: `elixir`, `phoenix`, `ecto`, `otp`, `oban` and `herdr`, for Codex.
- `.claude/skills/`: the same five Elixir skills, for Claude.

Update matching copies together, then check that the skills appear in each client's skill list. Provisioning links the main checkout's `.agents/skills/` into each worktree and checks only that the directory exists, not the individual skills.

Install only the `mix-credo` plugin, for the clients you use:

```bash
# Codex
codex plugin marketplace add georgeguimaraes/elixir-agent-tools
codex plugin add mix-credo@elixir-agent-tools

# Claude Code
claude plugin marketplace add georgeguimaraes/elixir-agent-tools
claude plugin install mix-credo@elixir-agent-tools
```

Generated settings enable Credo for both clients. Run explicit Mix checks after edits. Follow plugin trust prompts. Claude launches use `--settings` to disable known language-server plugins, including in linked worktrees; existing local settings files are preserved. Remove any old `mcp_servers.elixir-lsp` entry from Codex configuration; launchers do not disable it. Unrelated MCP servers remain available in coding sessions.

Build Dexter with the [LSP guide](../lsp/README.md#build): the pinned source plus the local patch, one binary. Put matching Elixir sources in the main checkout's `agent/lsp/vendor/elixir-<version>/` (the source tree contains `lib/elixir/lib/enum.ex`), or set `DEXTER_ELIXIR_LIB_ROOT` to their `lib/` directory. Provisioning selects the target worktree's Elixir version and binds the source path into the worktree's generated files. Keep the shared tools/sources independent of task worktrees.

Task and review checkouts use their own instruction files; the helper does not copy instructions. Before launching on a new shared Dexter build, verify that the assigned revision has compatible instructions. Stop teams before replacing the shared build, then re-provision.

Codex must be allowed to connect to Dexter's local Unix socket. The tested macOS `workspace-write` sandbox denies it with network access disabled; the reviewer verified access with network access enabled or a scoped `--allow-unix-socket /private/tmp/dexter-<uid>` sandbox allowance. Check the installed Codex sandbox options and set the narrowest suitable user-owned permission before first launch. With approval policy `never`, a denied connection cannot escalate. The launcher does not change sandbox settings.

## Starting the lead TPM

Run every lifecycle command in a Herdr terminal (`HERDR_ENV=1` set by Herdr) from the main checkout. During setup, handle each client's repository trust prompt. Unexpected approval prompts stop a launch; inspect them and follow the active approval policy. Launchers never edit home-directory trust settings.

```bash
agent/teams/team.py start lead
```

Do not run it while another live agent owns `lead-tpm`. The lead TPM starts and retires teams from this checkout; coding panes remain shells until assigned.

## Configuration

Edit [config.toml](config.toml): team limits; client/model/effort per role; port/database allocation; permissions; coordinator compaction; time budgets. Scripts read the canonical main checkout's file. Use `TIPS_TEAM_CONFIG=/absolute/path` for staged configuration in a disposable pilot. Settings apply next launch. `timeouts.dexter_startup_seconds` bounds the index wait of the provisioning warm-up; it does not require rebuilding Dexter. The same value limits Elixir version detection and the daemon stop at retirement: a run that exceeds it is ended, even a valid slow one. `roles.lead_ui` sets the client, model and effort only; a UI lead uses `roles.lead`'s port and database.

Claude and Codex both use the generated `$TIPS_DEXTER` command from their shell tool.
Existing shell approval and sandbox policies remain in force; no permission exception
is added. Claude uses the configured permission mode. The lead TPM runs without Dexter;
coding launches do not inherit its compaction setting.

| Allocation | Components |
|---|---|
| Database suffix | `team.db_suffix_prefix`, team number, `roles.<role>.db_suffix` |
| Test port | `team.port_base` + team number × `team.port_stride` + role `port_offset` |

Generated worktree files point at the shared Dexter binary; reviewed revisions need not contain the build. The helper warms up Dexter even when invoked without `--start`; it fetches locked dependencies first for a new checkout or a review head, and leaves a resumed developer worktree's dependencies alone. For staged pilots, `TIPS_DEXTER_HOME` selects the shared build directory. Configuration/tooling changes require disposable pilots verifying both the client root and the `TIPS_DEXTER` root in each actual client. Before scaling, measure simultaneous cold-start capacity; configured team limits do not verify it.

Set database connection limits in [compose.yaml](../../compose.yaml), overridden by `TIPS_DB_MAX_CONNECTIONS`. Recreate the database service to apply changes, only with no teams running. Agent launch settings never restart PostgreSQL or existing clients.

## Check changes to these scripts

Follow [Changing agent/teams scripts](README.md#changing-agentteams-scripts): check commands, CI evidence, test constraints and `# noqa: S603` limits. [pyproject.toml](pyproject.toml) uses the harness's Python profile: strict types, complexity limit 10, same lint rules. Only Python files under `tests/` get the test-assertion exception. For optional local developer checks, install Ruff/Pyright yourself; agents never install them.

## Milestones

Read the [Project 15 readme](https://github.com/users/chenghanlee/projects/15) with `gh project view 15 --owner chenghanlee`. Milestones, gate issues and dev-adapter policy live there, never mirrored here. Gates name environment, revision, evidence and unresolved blockers.
