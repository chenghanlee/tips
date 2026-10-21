# Agent pairs: setup

This page is for the repository owner. Run these commands from the repository root.
Agents follow the [pair workflow](README.md).

The workflow and its diagram are in the [README](README.md#how-it-runs).

## One-time setup

In the GitHub ruleset "Reviewed main", require resolved conversations; add required status checks only for workflows that exist and run (during the [CI pause](../../AGENTS.md#github-ci-pause), none). Turn off the strict up-to-date requirement and do not require the `tips/independent-review` status. In Project 15, enable the "Item closed" workflow so closed issues get Status Done.

The team board is [Project 15](https://github.com/users/chenghanlee/projects/15). It holds the spec and brief issues. The dispatcher sets three fields: Status (Backlog, Ready, Active, In review, Blocked, Done), Kind (spec or brief) and Agent (text: the implementer entry). A new owner adds Kind and Agent to their project and updates the project number in [roles/dispatcher.md](roles/dispatcher.md):

```bash
gh project field-create <number> --owner <owner> --name Kind --data-type SINGLE_SELECT --single-select-options spec,brief
gh project field-create <number> --owner <owner> --name Agent --data-type TEXT
```

The dispatcher edits fields with `gh project item-edit`. The `gh` token needs the `project` scope.

### Before you fork

Everything owner-specific is in these places. Commit the changes before installing a release: `install.py` reads the repository identity from the commit it installs, and the harness root refuses a repository it was not created for.

- [config.toml](config.toml): `github.repository`, `github.projects`, `team.clone_url`, `team.psql` (an absolute executable and the connection of your compose database), and the models in every `[agents.<entry>]` and `[dispatcher]`.
- [roles/dispatcher.md](roles/dispatcher.md): the Project 15 link. [roles/designer.md](roles/designer.md): the Project 15 reference. These files are the agents' prompts; issue links kept as evidence can stay.
- Prerequisites on the machine: Herdr with its session hook, the Dexter build and matching Elixir sources ([LSP guide](../lsp/README.md)), the skills below, and the database from [compose.yaml](../../compose.yaml). Pair bootstrap also needs a Mix project with a `mix.lock` whose config honours `PGPORT`, `TIPS_DB_SUFFIX` and `TIPS_TEST_PORT` ([README](../../README.md#use-agents-optional)).

Install Python 3.12 and the [configured client CLIs](config.toml). Create the dispatcher's locked environment once per checkout, as in [development](development.md#dependencies-and-test-isolation), or install a harness release (below). Authenticate the clients and the GitHub CLI (`gh`) for this repository. Agents also need GNU `timeout` (macOS: `brew install coreutils`) and `unbuffer` (Expect): the Elixir skill requires it on Mix commands. Testers use `agent-browser` for manual browser review.

The user maintains third-party skills in these Git-ignored directories in the main checkout:

- `.agents/skills/`: `elixir`, `phoenix`, `ecto`, `otp`, `oban` and `herdr`, for Codex.
- `.claude/skills/`: the same five Elixir skills, for Claude.

Keep the Codex and Claude skill copies in sync. `team.py` checks that the main checkout's `.agents/skills/` exists, and `bootstrap.py` links it into each clone.

The repository tracks six skills: the [Dexter reference](../skills/dexter/SKILL.md), [design-software](../skills/design-software/SKILL.md), [implement-software](../skills/implement-software/SKILL.md), [review-software-correctness](../skills/review-software-correctness/SKILL.md), [review-software-design](../skills/review-software-design/SKILL.md) and the vendored [web-design-guidelines](../skills/web-design-guidelines/SKILL.md). Link them once into both locations from the main checkout:

```bash
for skill in dexter design-software implement-software review-software-correctness review-software-design web-design-guidelines; do
  ln -s ../../agent/skills/$skill .agents/skills/$skill
  ln -s ../../agent/skills/$skill .claude/skills/$skill
done
```

These links let clients discover skills from the main checkout. Agents must read tracked skills and their references from their own clone, because the linked directory points to the main checkout's copy.

Install only the `mix-credo` plugin, for the clients you use:

```bash
# Codex
codex plugin marketplace add georgeguimaraes/elixir-agent-tools
codex plugin add mix-credo@elixir-agent-tools

# Claude Code
claude plugin marketplace add georgeguimaraes/elixir-agent-tools
claude plugin install mix-credo@elixir-agent-tools
```

Generated settings enable Credo for both clients. Claude launches use `--settings` to disable known language-server plugins; existing local settings files are preserved. Remove any old `mcp_servers.elixir-lsp` entry from Codex configuration. The launcher does not disable that server.

Build Dexter using the [LSP guide](../lsp/README.md#build). The build uses the pinned source and local patch to produce one binary. Put matching Elixir sources in the main checkout's `agent/lsp/vendor/elixir-<version>/` (the source tree contains `lib/elixir/lib/enum.ex`), or set `DEXTER_ELIXIR_LIB_ROOT` to their `lib/` directory. Stop pairs before replacing the shared build.

Codex launches with approval policy `never` and `-C <allocation directory>`; denied actions cannot escalate, and the launcher does not change sandbox settings. Workers run with your current client settings: worker sandbox profiles are deferred by the user's decision of 2026-10-14 ([#437](https://github.com/chenghanlee/tips/issues/437)). Before the first pair, allow Codex to reach GitHub over HTTPS, the Herdr and Dexter Unix sockets, and the local database and test port. `--allow-unix-socket` is a flag of `codex sandbox`, not of the interactive client the launcher starts. Verify in a launched tester, once the repository has a Mix project: `gh pr view 331 --json state`, `herdr agent get "$HERDR_PANE_ID"`, `"$TIPS_DEXTER" lookup <a module of the app>` and `unbuffer mix test`.

### Browser access for the tester

In `~/.codex/config.toml`, append the absolute path to `~/.agent-browser` to the
existing `[sandbox_workspace_write].writable_roots` list. Preserve its other
entries. This lets the tester write to `~/.agent-browser`. See the
[Codex configuration reference](https://developers.openai.com/codex/config-reference/).

Chrome cannot start inside the Codex sandbox. Add this rule to
`~/.codex/rules/default.rules` so `agent-browser open` runs outside it:

```
prefix_rule(pattern=["agent-browser", "open"], decision="allow")
```

After changing permissions or rules, start a new tester session and run this
preflight there, one command per call, in the
[required form](README.md#manual-browser-review):

```sh
agent-browser open about:blank --session preflight
agent-browser close --session preflight
```

If opening fails with `Chrome exited early` or `without writing DevToolsActivePort`,
first follow the close-and-reopen recovery in [manual browser review](README.md#manual-browser-review).
A daemon started inside the sandbox can survive a failed launch, so retrying
`open` alone can still fail even with the allow rule installed.

If recovery fails or `agent-browser open` reports another error, keep the full error
and run `agent-browser doctor` in the same tester session. Doctor's launch test starts
a separate browser. It can fail inside the Codex sandbox even when the approved
`open` command works; the quick/offline doctor does not check browser launch. Fix the
browser launch failure before assigning manual browser review; do not disable Chrome's sandbox or
silently switch to the user's personal browser profile. ChromeDriver for local
Wallaby tests is a separate prerequisite; the application's development guide names
it once the project has browser tests.

### Claude auto-mode repository context

In `~/.claude/settings.json`, keep each `autoMode.environment` statement limited to
the repository it describes. If a statement says another repository is the only
trusted repository or has no protected branches, limit that claim to that repository.
Keep the repository's other rules. Add this Tips-specific entry:

> github.com/chenghanlee/tips is a trusted repository. Its main branch is protected
> by Reviewed main: PRs, checks, release and resolved review threads are required,
> with no bypass actors. Required approving reviews is 0 because the agents share one
> GitHub identity; the merge-confirming tester merges after reading the LGTM reviews.

Preserve other settings and rule lists. Do not add a merge or handoff allow rule.
Pair clients launch with allow rules for their own GitHub writes (`gh issue edit`,
`gh issue comment`, `gh pr create`, `gh pr edit`, `gh pr comment`, `gh pr review`) and
the harness scripts they run (`board.py`, `pr_review.py`); the
classifier judges everything else, including the merge and the handoff.
Run `claude auto-mode config` to inspect the active context and
`claude auto-mode critique` to find contradictory rules, then start a new
session. Correcting the context may not fix the handoff denial. An existing
denial still needs the user's explicit retry approval through the supported
permission flow. See [Claude auto-mode configuration](https://code.claude.com/docs/en/auto-mode-config).

## Start the dispatcher

The launcher starts Claude in restricted mode with no built-in tools (`--restricted
--tools ""`) and one MCP server, [adapter.py](adapter.py), under `--strict-mcp-config`.
The launcher sets the server, `--settings`, the session ID and the environment. User,
project and local settings files, CLAUDE.md files, other MCP servers and Remote Control
are not loaded. The dispatcher's system prompt is two role files, [common.md](roles/common.md)
and [dispatcher.md](roles/dispatcher.md), read by the launcher before start.

A restricted client reports no session to Herdr. The launcher execs the client, which
keeps the launcher's process ID, so it records that ID, its start time, the pane and the
session in `state/dispatcher.json` under the [harness root](#install-a-harness-release). When Herdr shows
that process in the pane, ready for input, it names the pane `dispatcher` and sends the
first prompt, `Begin.`, through Herdr, once the adapter has listed its tools to that
session (`state/dispatcher.ready`). If that does not happen within
`timeouts.launch_seconds`, or naming or prompting fails, a Herdr notification and
`team.py status` say what happened and what to run. Check the pane, then run them
yourself:

```bash
herdr agent rename <pane> dispatcher
herdr agent prompt <pane> "Begin."
```

If the prompt itself failed, `Begin.` may still have arrived: send it again only if the
pane shows no `Begin.` turn.

It refuses to start while that process runs, or while an unrecorded agent is named
`dispatcher`.

From a plain shell in a Herdr pane (`HERDR_ENV=1`) at the main checkout:

```bash
agent/teams/dispatch
```

From Codex or Claude Code already running inside Herdr, use the shell tool to run:

```bash
agent/teams/dispatch --new-pane
```

This opens a sibling pane without changing focus and runs the dispatcher there.
The agent that ran `dispatch --new-pane` keeps running. Check the new pane for startup
or approval prompts; the command can return before the dispatcher is ready. Run the
script in the main checkout.

Start one dispatcher. Agents contact it using the name `dispatcher`. It chooses tasks
from the backlog using priority order, dependencies and product value; you do not
need to mark them Ready.

The dispatcher does not monitor GitHub. After changing priorities or external facts,
type `board changed` in its pane. Answer its product and scope questions there.
Each message gives the dispatcher full context, so it compacts at the configured
threshold (`dispatcher.compact_percent`) and reloads state from GitHub.

The dispatcher's tools run the `team.py` beside its adapter: the installed release's, or the checkout's when started from a checkout. Clients start in their
allocation directory, so a client may ask whether to trust it. On 2026-10-14, a fresh
allocation under `../agent_teams/tips/` on this machine showed no trust or import
dialog for Claude Code 2.1.299 or Codex 0.162.1; Codex only warned that `-c` overrides
run without its shared background server. If a trust prompt appears, it stops that
launch: inspect it and decide; do not trust a directory you did not expect. If an
approval prompt stops launch, inspect it and follow the active approval policy.

## Install a harness release

Run this once per harness release from the main checkout, after draining every team and stopping the dispatcher (`/exit` in its pane). A running dispatcher keeps the old release's modules in memory while its configuration reads come through the new `harness` link. Restart it from the new release afterwards:

```bash
python3 agent/teams/install.py <commit>
```

The commit must be merged into `origin/main`, and the checkout's tracked files must be
clean. The command copies AGENTS.md and `agent/teams` from that commit, creates the
locked environment (`--require-hashes`, wheels only) and records the commit, the
repository, this checkout's path and the root in `install.json`. The root defaults to
`agent_teams/<name>/` in the main checkout's parent directory, where `<name>` is the
repository name in `github.repository` (`agent_teams/tips/`); `--root` selects another
directory. The root is created on first use, and its `repository.json` must name the
configured repository. `TIPS_TEAM_HARNESS`, an absolute `<root>/harness` path, overrides
the root for the launcher and `team.py`. The install is a copy; it does not protect the
root from writes.
`releases/<commit>-<time>/` holds each release and `harness` points at the current one.
The switch is one atomic rename. A failed install deletes only its own unfinished
release, so the previous one keeps working. The install never changes `state/` or
`allocations/`, and it refuses while the target root's `state/` holds a team record or an
allocation that is neither recorded nor retired, or while a dispatcher or a `team.py` command runs (`state/dispatcher.lock` or `state/.lock` is held). Earlier releases stay on disk; to roll back, install the earlier commit again.
Start the installed dispatcher with `<root>/harness/agent/teams/dispatch`.

Workers read tracked roles and skills from their own checkout. Work and review heads
used with a changed workflow release must include that workflow change. If continuing
an older branch, merge `origin/main` into it before handing it to the new release;
do not rebase or force-push. A newly opened PR can still have old instructions, so its
opening date is not evidence of compatibility. Do not upgrade running teams in place.

## Configuration

Edit [config.toml](config.toml) for slots, agent and dispatcher settings, resource
allocation, permissions and time limits. `[github]` names the repository every GitHub
call uses, and for each project the dispatcher may edit, the fields it may set.
`timeouts.github_seconds` (default 30) bounds each GitHub operation, all its calls
together. The one exception is stop's check for a merged PR, which holds the store lock
and so uses `timeouts.shell_seconds`. Each `[agents.<entry>]` defines a role,
client, model, effort, optional persona, database suffix and port offset.
Briefs name entries in `Implementer:` and `Required reviews:`.

A configured entry can run in several allocations. Each launch records its
resources, and the team's Herdr workspace and tabs, in `<root>/state/<slot>.json`
([allocations](README.md#allocations)); restart, handoff and cleanup read that record.
`github.repository` names the repository and the root; `team.clone_url` is what each
client clones; `team.psql` is the fixed argv [cleanup](README.md#cleanup) uses to list
and drop a retired team's databases (the shipped value is the compose database's local development
connection). A checkout's scripts use the main checkout's config; an installed harness
uses its release's config, `<root>/harness/agent/teams/config.toml`.
`TIPS_TEAM_CONFIG=/absolute/path` selects another file. Launched clients get the file the
launcher read. Settings apply at the next launch;
a relaunched client keeps its recorded database, port and client kind and takes its
model, effort and persona from the current file.

| Allocation | Components |
|---|---|
| Database suffix | `team.db_suffix_prefix`, slot number, `g`, generation, `agents.<entry>.db_suffix` |
| Test port | `team.port_base` + slot number × `team.port_stride` + entry `port_offset` |

`timeouts.lock_seconds` bounds how long `start`, `design`, `review`, `reset` or `stop` waits for
another one to finish.

`timeouts.dexter_startup_seconds` bounds the Dexter warm-up at start, Elixir version detection and the daemon stop during cleanup. `TIPS_DEXTER_HOME` selects another shared Dexter build directory.

Set database connection limits in [compose.yaml](../../compose.yaml). `TIPS_DB_MAX_CONNECTIONS` overrides those limits. Recreate the database service to apply changes. Do this only when no pairs are running.

## Launch recovery

`team.py` records each client's task-submission state before the client can act on it:

| State | Meaning |
|---|---|
| `never_submitted` | Nothing was sent, or the operator ran `reset` after checking the client's work. `start` or `review` may launch the client. |
| `unknown` | Written before the client starts. The launch stopped before Herdr confirmed the task prompt. |
| `submitted` | Herdr sent the task prompt. It does not mean the task is done. |

A Claude client holds its brief as its system prompt; its task prompt is `Begin.`. A
Codex client starts with no instructions and gets its brief as its task prompt, because
no tested signal yet shows that Codex accepted a task passed at start.

After an interrupted `start` or `review`, rerun it:

- A running client with its recorded name, kind and allocation is kept, and nothing is
  resent. If its task submission is `unknown`, the command says so. Read the pane. If
  the client never got its task, exit it, then reset it as below.
- A stopped client whose task submission is `unknown` or `submitted` is refused: it may
  have done its task and exited. You, the operator, decide whether to replay it. Check
  the brief, the PR and its reviews. To replace it, run
  `agent/teams/team.py reset <brief> <entry>`, then rerun the command. The replacement
  gets its task again.
- A client with no record entry is recorded as `unknown` and refused when an earlier
  allocation of its entry for the same issue that was never retired, a Herdr workspace
  of the issue or a Herdr client with its name remains: a lost record does not prove that
  nothing was sent. Database names carry the generation, so an earlier launch's
  databases belong to that allocation. Close any earlier workspace, then reset it as
  above.
- Another client in a recorded pane, a live client the record never started, a client
  whose session differs from the recorded one, or a client that reports no session is
  refused. Inspect the pane. `team.py` assigns each Claude client's session id at
  launch; a Codex client's is recorded when Herdr first reports it. Herdr reports
  sessions through the user hook, so keep that hook installed.

`start`, `design`, `review`, `reset` and `stop` hold a lock on `<root>/state/.lock`. A
command that waits longer than `timeouts.lock_seconds` stops with a `Busy` error; rerun
it when the other command has finished. The lock is released when its holder exits,
including after a crash. Keep the root on a local filesystem: the
lock and the durable record writes are not reliable on a network filesystem.

## Development

Follow [development](development.md). For optional local checks, install Ruff and Pyright yourself; agents never install them. Milestones and gate issues live in the [Project 15 readme](https://github.com/users/chenghanlee/projects/15) (`gh project view 15 --owner chenghanlee`); do not copy them here.
