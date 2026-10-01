# Agent teams: setup

Humans: perform setup from the repository root. Agents use the [operating agreement](README.md) and their role card during events; no setup reading is needed.

## One-time setup

Install Python 3.12 and [configured client CLIs](config.toml). Authenticate clients and GitHub CLI (`gh`) for this repository. Merges require GNU `timeout` on `PATH`: macOS `brew install coreutils`; Linux distribution `coreutils` package.

From the main checkout, install pinned [Elixir Agent Tools](https://github.com/georgeguimaraes/elixir-agent-tools) for required skills/Mix plugins:

```bash
git clone https://github.com/georgeguimaraes/elixir-agent-tools.git agent/elixir-agent-tools
git -C agent/elixir-agent-tools checkout --detach ac3a5a1661a087158b39d5eb742b3c25fe3c7b44
mkdir -p .agents/skills
for skill in elixir phoenix ecto otp oban; do
  ln -s "$PWD/agent/elixir-agent-tools/plugins/elixir-dev/skills/$skill" ".agents/skills/$skill"
done
```

Inspect existing destinations before replacing these Git-ignored dependencies. Keep the source checkout: launchers link main checkout's `.agents/skills` into worktrees without downloading skills.

From the main checkout, install plugins for clients you use:

```bash
# Codex
codex plugin marketplace add "$PWD/agent/elixir-agent-tools"
codex plugin add mix-compile@elixir-agent-tools
codex plugin add mix-credo@elixir-agent-tools

# Claude Code (user scope makes the installations available across worktrees)
claude plugin marketplace add "$PWD/agent/elixir-agent-tools"
claude plugin install --scope user elixir-dev@elixir-agent-tools
claude plugin install --scope user mix-compile@elixir-agent-tools
claude plugin install --scope user mix-credo@elixir-agent-tools
```

Codex discovers linked `.agents/skills`; never also install Codex `elixir-dev`. Claude loads the same five skills through `elixir-dev`. Generated configs enable both Mix check plugins. Follow plugin trust prompts. Claude launches use `--settings` to disable known language-server plugins, including in linked worktrees; existing local settings files are preserved. Remove any legacy `mcp_servers.elixir-lsp` entry before the pilot, including the main checkout's `.codex/config.toml`: launchers do not disable it. Unrelated MCP servers remain available in coding sessions.

Build Dexter with the [LSP guide](../lsp/README.md#build): the pinned source plus the local patch, one binary. Put matching Elixir sources in the main checkout's `agent/lsp/vendor/elixir-<version>/` (the source tree contains `lib/elixir/lib/enum.ex`), or set `DEXTER_ELIXIR_LIB_ROOT` to their `lib/` directory. Provisioning selects the target worktree's Elixir version and binds the source path into the worktree's generated files. Keep the shared tools/sources independent of task worktrees.

Merge the Dexter integration, including root `AGENTS.md` and `CLAUDE.md`, into
`origin/main` before provisioning normal tasks. New developer branches start from
the helper's freshly fetched `origin/main` and inherit these instructions from that
commit; installing the binary alone does not update them. Existing task branches
must merge the updated `origin/main`, and review refs must include the instructions,
before starting a Dexter session. With teams stopped, update the canonical checkout
and build its pinned Dexter before launching new teams. The helper does not copy
instructions over a task branch's files.

Codex must be allowed to connect to Dexter's local Unix socket. The tested macOS `workspace-write` sandbox denies it with network access disabled; the reviewer verified access with network access enabled or a scoped `--allow-unix-socket /private/tmp/dexter-<uid>` sandbox allowance. Check the installed Codex sandbox options and set the narrowest suitable user-owned permission before the pilot. With approval policy `never`, a denied connection cannot escalate. The launcher does not change sandbox settings.

## Starting the lead TPM

Run every lifecycle command in a Herdr terminal (`HERDR_ENV=1` set by Herdr) from the main checkout. During setup, handle each client's repository trust prompt. Unexpected approval prompts stop a launch; inspect them and follow the active approval policy. Launchers never edit home-directory trust settings.

```bash
agent/teams/team.py start lead
```

Do not run it while another live agent owns `lead-tpm`. The lead TPM starts and retires teams from this checkout; coding panes remain shells until assigned.

## Configuration

Edit [config.toml](config.toml): team limits; client/model/effort per role; port/database allocation; permissions; coordinator compaction; time budgets. Scripts read the canonical main checkout's file. Use `TIPS_TEAM_CONFIG=/absolute/path` for staged configuration in a disposable pilot. Settings apply next launch. `timeouts.dexter_startup_seconds` bounds the index wait of the provisioning warm-up and of each Claude LSP start; it does not require rebuilding Dexter.

Codex uses the generated `$TIPS_DEXTER` command; Claude uses its native LSP tool
through the generated plugin. Existing shell approval and sandbox policies remain
in force; no MCP-specific permission exception is added. Claude uses the configured permission mode. Coordinators run without LSP;
coding launches do not inherit coordinator compaction settings.

| Allocation | Components |
|---|---|
| Database suffix | `team.db_suffix_prefix`, team number, `roles.<role>.db_suffix` |
| Test port | `team.port_base` + team number × `team.port_stride` + role `port_offset` |

Generated worktree files point at the shared Dexter binary; reviewed revisions need not contain the build. The helper warms up Dexter even when invoked without `--start`. For staged pilots, `TIPS_DEXTER_HOME` selects the shared build directory. Configuration/tooling changes require disposable pilots verifying both client and LSP roots in each actual client. Before scaling, measure simultaneous cold-start capacity; configured team limits do not verify it.

Set database connection limits in [compose.yaml](../../compose.yaml), overridden by `TIPS_DB_MAX_CONNECTIONS`. Recreate the database service to apply changes, only with no teams running. Agent launch settings never restart PostgreSQL or existing clients.

## Check changes to these scripts

Follow [shared Checks](README.md#shared-rules): check commands, CI evidence, test constraints and `# noqa: S603` limits. [pyproject.toml](pyproject.toml) uses the harness's Python profile: strict types, complexity limit 10, same lint rules. Only Python files under `tests/` get the test-assertion exception. For optional local developer checks, install Ruff/Pyright yourself; agents never install them.

## Milestones

Read the [Project 15 readme](https://github.com/users/chenghanlee/projects/15) with `gh project view 15 --owner chenghanlee`. Milestones, gate issues and dev-adapter policy live there, never mirrored here. Gates name environment, revision, evidence and unresolved blockers.
