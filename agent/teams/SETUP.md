# Agent teams: setup

Humans: perform setup from the repository root. Agents use the [operating agreement](README.md) and their role card during events; no setup reading is needed.

## One-time setup

Install Python 3.12 and [configured client CLIs](config.toml). Authenticate clients and GitHub CLI (`gh`) for this repository. Merges require GNU `timeout` on `PATH`: macOS `brew install coreutils`; Linux distribution `coreutils` package.

From the main checkout, install pinned [Elixir Agent Tools](https://github.com/georgeguimaraes/elixir-agent-tools) for engineering skills:

```bash
git clone https://github.com/georgeguimaraes/elixir-agent-tools.git agent/elixir-agent-tools
git -C agent/elixir-agent-tools checkout --detach ac3a5a1661a087158b39d5eb742b3c25fe3c7b44
mkdir -p .agents/skills
for skill in elixir phoenix ecto otp oban; do
  ln -s "$PWD/agent/elixir-agent-tools/plugins/elixir-dev/skills/$skill" ".agents/skills/$skill"
done
```

Inspect existing destinations before replacing these Git-ignored dependencies. Keep the source checkout: launchers link main checkout's `.agents/skills` into worktrees without downloading skills.

For Claude Code, install the engineering skills plugin from that checkout:

```bash
# Claude Code (user scope makes the installation available across worktrees)
claude plugin marketplace add "$PWD/agent/elixir-agent-tools"
claude plugin install --scope user elixir-dev@elixir-agent-tools
```

Codex discovers linked `.agents/skills`; never also install Codex `elixir-dev`. Claude loads the same five skills through `elixir-dev`. Generated configs disable automatic Mix plugins, the old Expert integration and Dexter's native LSP plugin. Agents run project checks explicitly.

Install stock Dexter with the [Dexter guide](../lsp/README.md#install), then start new client sessions. Both clients use the pinned binary's CLI; no Dexter plugin is needed. If `dexter-lsp@dexter` is installed globally, team launches disable it per session and leave the global installation intact. Keep the installation independent of task worktrees.

Merge the Dexter integration, including root `AGENTS.md` and `CLAUDE.md`, into
`origin/main` before provisioning normal tasks. New developer branches start from
the helper's freshly fetched `origin/main` and inherit these instructions from that
commit; installing the binary alone does not update them. Existing task branches
must merge the updated `origin/main`, and review refs must include the instructions,
before starting a Dexter session. With teams stopped, update the canonical checkout
and install its pinned Dexter before launching new teams. The helper does not copy
instructions over a task branch's files.

## Starting the lead TPM

Run every lifecycle command in a Herdr terminal (`HERDR_ENV=1` set by Herdr) from the main checkout. During setup, handle each client's repository trust prompt. Unexpected approval prompts stop a launch; inspect them and follow the active approval policy. Launchers never edit home-directory trust settings.

```bash
agent/teams/team.py start lead
```

Do not run it while another live agent owns `lead-tpm`. The lead TPM starts and retires teams from this checkout; coding panes remain shells until assigned.

## Configuration

Edit [config.toml](config.toml): team limits; client/model/effort per role; port/database allocation; permissions; coordinator compaction; time budgets. Scripts read the canonical main checkout's file. Use `TIPS_TEAM_CONFIG=/absolute/path` for staged configuration in a disposable pilot. Settings apply next launch.

Client approval and sandbox policies remain separate from Dexter. Claude permission mode uses the team config. Coordinator launches use configured compaction; coding launches do not inherit it. Codex shell environment settings receive the existing team values; no daemon launch workaround is required.

| Allocation | Components |
|---|---|
| Database suffix | `team.db_suffix_prefix`, team number, `roles.<role>.db_suffix` |
| Test port | `team.port_base` + team number × `team.port_stride` + role `port_offset` |

Both clients use main checkout's Dexter installation in the assigned worktree. Configuration/tooling changes require disposable pilots verifying client and Dexter roots. Before scaling, measure simultaneous cold-start capacity; configured team limits do not verify it.

Set database connection limits in [compose.yaml](../../compose.yaml), overridden by `TIPS_DB_MAX_CONNECTIONS`. Recreate the database service to apply changes, only with no teams running. Agent launch settings never restart PostgreSQL or existing clients.

## Check changes to these scripts

Follow [shared Checks](README.md#shared-rules): four commands, CI evidence, test constraints and `# noqa: S603` limits. [pyproject.toml](pyproject.toml) uses the harness's Python profile: strict types, complexity limit 10, same lint rules. Only Python files under `tests/` get the test-assertion exception. For optional local developer checks, install Ruff/Pyright yourself; agents never install them.

## Milestones

Read the [Project 15 readme](https://github.com/users/chenghanlee/projects/15) with `gh project view 15 --owner chenghanlee`. Milestones, gate issues and dev-adapter policy live there, never mirrored here. Gates name environment, revision, evidence and unresolved blockers.
