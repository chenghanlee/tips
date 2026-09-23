# Agent teams: setup

One-time machine setup and the settings behind the [operating agreement](README.md). Humans read this; agents do not need it at an event. Run the commands from the repository root.

## One-time setup

Install Python 3.12 and the client CLIs selected in [config.toml](config.toml), and authenticate those clients and GitHub CLI (`gh`) for this repository. The merge commands also need GNU `timeout` on `PATH`: on macOS, `brew install coreutils`; on Linux, your distribution's `coreutils` package.

The required skills and Mix plugins come from [Elixir Agent Tools](https://github.com/georgeguimaraes/elixir-agent-tools). From the main checkout, install the pinned source and link its five skills:

```bash
git clone https://github.com/georgeguimaraes/elixir-agent-tools.git agent/elixir-agent-tools
git -C agent/elixir-agent-tools checkout --detach ac3a5a1661a087158b39d5eb742b3c25fe3c7b44
mkdir -p .agents/skills
for skill in elixir phoenix ecto otp oban; do
  ln -s "$PWD/agent/elixir-agent-tools/plugins/elixir-dev/skills/$skill" ".agents/skills/$skill"
done
```

These are ignored local dependencies. If a destination already exists, inspect it before replacing it. The task launcher links the main checkout's `.agents/skills` into each worktree; it does not download skills. Keep the source checkout in place.

Install the plugins for each client you use, from the same main checkout:

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

Codex discovers the linked `.agents/skills`; do not also install `elixir-dev` for Codex. Claude loads the same five skills through the `elixir-dev` plugin. The generated client configs enable the two Mix check plugins. Follow each client's plugin trust prompts during setup. Tips uses its own patched LSP bridge; the generated Claude config disables the upstream `elixir-lsp` plugin.

Build the shared Expert and MCP bridge binaries with the [LSP setup guide](../lsp/README.md#build-and-validate), then start new client sessions. Keep the installed bridge and Expert available independently of task worktrees.

## Starting the lead TPM

Run lifecycle commands in a Herdr terminal, where `HERDR_ENV=1` is set by Herdr, from the main checkout. Handle each client's repository trust prompt during initial setup; an unexpected approval prompt stops a launch, so inspect it and follow the active approval policy. The launcher does not edit home-directory trust settings.

```bash
agent/teams/team.py start lead
```

Do not run it while another live agent owns `lead-tpm`. The lead TPM starts and retires teams from there. Coding panes stay at the shell until assigned.

## Configuration

Edit [config.toml](config.toml) to change team limits, client, model and effort by role, port and database allocation, permission modes, coordinator compaction and time budgets. Scripts read the canonical main checkout's file; `TIPS_TEAM_CONFIG=/absolute/path` selects a staged configuration for a disposable pilot. Settings take effect on the next launch. The patched bridge has a compiled request deadline; changing its corresponding client timeout requires rebuilding and retesting the bridge too.

The generated Codex config applies `launch.codex_lsp_approval_mode` only to the four enabled LSP tools and leaves the overall approval and sandbox policies in place, using the [supported per-tool MCP setting](https://developers.openai.com/codex/mcp). Codex approval policy does not change or guarantee its sandbox. Claude's permission mode comes from the same config. Coordinator launches use the configured compaction; coding launches do not inherit it.

Database suffixes combine `team.db_suffix_prefix`, the team number and `roles.<role>.db_suffix`. Test ports combine `team.port_base`, team number times `team.port_stride`, and the role's `port_offset`. Both clients invoke the main checkout's LSP wrapper with the assigned absolute worktree root; review revisions do not need to contain that wrapper.

Configuration and tooling changes require a disposable actual-client pilot that checks both the client root and the LSP root for each client. The configured team limit is not a verified simultaneous cold-start capacity; measure it before scaling up.

The database connection limit is configured in [compose.yaml](../../compose.yaml), with `TIPS_DB_MAX_CONNECTIONS` as the standard Compose override. Apply it by recreating the database service only while no teams are running. Agent launch settings do not restart PostgreSQL or existing clients.

## Check changes to these scripts

Changes under `agent/teams` run these four commands with Python 3.12 and the installed Ruff and Pyright tools:

```sh
ruff check agent/teams
ruff format --check agent/teams
pyright --project agent/teams/pyproject.toml
python3 -m unittest discover -s agent/teams/tests -t agent/teams -p 'test_*.py'
```

The required `checks` job runs the same four commands. Reviewers do not rerun them locally: they open the `checks` run for the exact reviewed head, confirm each step ran and passed, and link that run in their round.

[pyproject.toml](pyproject.toml) follows the harness's Python profile: strict types, a complexity limit of 10, and the same lint rules. The test assertion exception applies only to Python files under `tests/`. The scripts and tests use only the standard library.

Tests use disposable Git repositories, a fake Herdr CLI, and owned child processes. They do not operate live teams. Process tests require permission to run `ps` and signal their own children.

Two reviewed S603 exceptions carry inline `# noqa: S603`: the shared command runner `team.py:execute` and the process-test launcher `StopAgentTest.client`. Both accept variable argument lists but run without a shell, on a resolved executable with fixed or test-owned arguments. Suppress nothing else. Review any change to these calls for trusted executable selection and argument handling; the passing lint does not prove subprocess safety.

## Milestones

Milestones, their gate issues and the dev-adapter policy live in the [Project 15 readme](https://github.com/users/chenghanlee/projects/15); read it with `gh project view 15 --owner chenghanlee`. It is not mirrored in this repository. Each gate names its environment, revision, evidence and unresolved blockers.
