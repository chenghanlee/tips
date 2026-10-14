# Agent pairs: setup

This page is for the repository owner. Run these commands from the repository root.
Agents follow the [pair workflow](README.md).

## How it runs

```
USER         set goals · answer product questions · start the dispatcher once · report an agent that has stopped
DISPATCHER   open a feature → designers agree on a spec and briefs → team.py start <brief>
IMPLEMENTER  ask questions only when answers affect the work → code → push → PR "Closes #<brief>" → team.py turn <pr> <tester>
TESTER       ask the dispatcher to launch the other reviewers → review the head
DISPATCHER   team.py review <pr> <entry> for each
REVIEWERS    review from pinned worktrees → notify the tester with the review URL
TESTER       findings → team.py turn <pr> <implementer>   (repeat until no P0 or P1)
TESTER       every required review LGTM on the head · required checks pass → gh pr merge → "done"
DISPATCHER   team.py stop <brief> → next
```

## One-time setup

In the GitHub ruleset "Reviewed main", require `checks`, `release` and resolved conversations. Turn off the strict up-to-date requirement and do not require the `tips/independent-review` status. In Project 15, enable the "Item closed" workflow so closed issues get Status Done.

The team board is [Project 16](https://github.com/users/chenghanlee/projects/16). It holds the spec and brief issues. It was created on 2026-10-12 with these commands. A new owner should repeat them and update the project number in [roles/dispatcher.md](roles/dispatcher.md):

```bash
gh project create --owner <owner> --title "Tips swarm"
gh project field-create <number> --owner <owner> --name Kind --data-type SINGLE_SELECT --single-select-options spec,brief
gh project field-create <number> --owner <owner> --name Feature --data-type TEXT
gh project field-create <number> --owner <owner> --name Phase --data-type SINGLE_SELECT --single-select-options "Design,Q&A,Implement,Review,Done"
gh project field-create <number> --owner <owner> --name Implementer --data-type TEXT
```

The dispatcher edits fields with `gh project item-edit`. The `gh` token needs the `project` scope.

Install Python 3.12 and the [configured client CLIs](config.toml). Authenticate the clients and the GitHub CLI (`gh`) for this repository. Agents also need GNU `timeout` (macOS: `brew install coreutils`) and `unbuffer` (Expect): the Elixir skill requires it on Mix commands. Testers use `agent-browser` for manual browser review.

The user maintains third-party skills in these Git-ignored directories in the main checkout:

- `.agents/skills/`: `elixir`, `phoenix`, `ecto`, `otp`, `oban` and `herdr`, for Codex.
- `.claude/skills/`: the same five Elixir skills, for Claude.

Keep the Codex and Claude skill copies in sync. `team.py start` links the main checkout's `.agents/skills/` into each worktree and checks only that the directory exists.

The repository tracks five skills: the [Dexter reference](../skills/dexter/SKILL.md), [design-software](../skills/design-software/SKILL.md), [implement-software](../skills/implement-software/SKILL.md) and [review-software-correctness](../skills/review-software-correctness/SKILL.md). Link them once into both locations from the main checkout:

```bash
for skill in dexter design-software implement-software review-software-correctness review-software-design; do
  ln -s ../../agent/skills/$skill .agents/skills/$skill
  ln -s ../../agent/skills/$skill .claude/skills/$skill
done
```

These links let clients discover skills from the main checkout. Agents must read tracked skills and their references from their own worktree, because the linked directory points to the main checkout's copy.

Install only the `mix-credo` plugin, for the clients you use:

```bash
# Codex
codex plugin marketplace add georgeguimaraes/elixir-agent-tools
codex plugin add mix-credo@elixir-agent-tools

# Claude Code
claude plugin marketplace add georgeguimaraes/elixir-agent-tools
claude plugin install mix-credo@elixir-agent-tools
```

Generated settings enable Credo for both clients. Claude launches use `--settings` to disable known language-server plugins, including in linked worktrees; existing local settings files are preserved. Remove any old `mcp_servers.elixir-lsp` entry from Codex configuration. The launcher does not disable that server.

Build Dexter using the [LSP guide](../lsp/README.md#build). The build uses the pinned source and local patch to produce one binary. Put matching Elixir sources in the main checkout's `agent/lsp/vendor/elixir-<version>/` (the source tree contains `lib/elixir/lib/enum.ex`), or set `DEXTER_ELIXIR_LIB_ROOT` to their `lib/` directory. Stop pairs before replacing the shared build.

Codex launches with approval policy `never`; denied actions cannot escalate, and the launcher does not change sandbox settings. Before the first pair, allow Codex to reach GitHub over HTTPS, the Herdr and Dexter Unix sockets, and the local database and test port. `--allow-unix-socket` is a flag of `codex sandbox`, not of the interactive client the launcher starts. Verify in a launched tester: `gh pr view 331 --json state`, `herdr agent get "$HERDR_PANE_ID"`, `"$TIPS_DEXTER" lookup Tips.Repo` and `unbuffer mix test`.

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
Wallaby tests is a separate prerequisite in the
[browser test guide](../../docs/development/local-development.md#browser-tests-and-ci).

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
Run `claude auto-mode config` to inspect the active context and
`claude auto-mode critique` to find contradictory rules, then start a new
session. Correcting the context may not fix the handoff denial. An existing
denial still needs the user's explicit retry approval through the supported
permission flow. See [Claude auto-mode configuration](https://code.claude.com/docs/en/auto-mode-config).

## Start the dispatcher

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
from the backlog using milestone order, dependencies and product value; you do not
need to mark them Ready.

The dispatcher does not monitor GitHub. After changing priorities or external facts,
type `board changed` in its pane. Answer its product and scope questions there.
Each message gives the dispatcher full context, so it compacts at the configured
threshold (`dispatcher.compact_percent`) and reloads state from GitHub.

The dispatcher runs `team.py` from the main checkout. Handle each client's initial
repository trust prompt. If an approval prompt stops launch, inspect it and follow
the active approval policy.

## Configuration

Edit [config.toml](config.toml) for slots, agent and dispatcher settings, resource
allocation, permissions and time limits. Each `[agents.<entry>]` defines a role,
client, model, effort, optional advisor and persona, database suffix and port offset.
Briefs name entries in `Implementer:` and `Required reviews:`.

A configured entry can run in several allocations. Each launch records its
resources, and the team's Herdr workspace and tabs, in
`agent/teams/allocations/<slot>.json`; restart, handoff and cleanup read that record. Scripts use the main checkout's config unless
`TIPS_TEAM_CONFIG=/absolute/path` selects another file. Settings apply at the next launch;
a relaunched client keeps its recorded database, port and client kind and takes its
model, effort, advisor and persona from the current file.

A Claude entry launches with `--advisor <advisor>` when its `advisor` is set; this requires access to that model. Entries without one leave the advisor setting to the client. The dispatcher launches with `--advisor fable` when its model name is nonempty and does not contain Fable.

| Allocation | Components |
|---|---|
| Database suffix | `team.db_suffix_prefix`, slot number, `agents.<entry>.db_suffix` |
| Test port | `team.port_base` + slot number × `team.port_stride` + entry `port_offset` |

`timeouts.lock_seconds` bounds how long `start`, `review`, `reset` or `stop` waits for
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

- A running client with its recorded name, kind and worktree is kept, and nothing is
  resent. If its task submission is `unknown`, the command says so. Read the pane. If
  the client never got its task, exit it, then reset it as below.
- A stopped client whose task submission is `unknown` or `submitted` is refused: it may
  have done its task and exited. You, the operator, decide whether to replay it. Check
  the brief, the PR and its reviews. To replace it, run
  `agent/teams/team.py reset <brief> <entry>`, then rerun the command. The replacement
  gets its task again.
- A client with no record entry is recorded as `unknown` and refused when its worktree,
  task branch, a Herdr workspace of its brief, a Herdr client with its name or its
  databases remain: a lost record does not prove that nothing was sent. Close any
  earlier workspace, then reset it as above.
- Another client in a recorded pane, a live client the record never started, or a
  client whose session differs from the recorded one is refused. Inspect the pane.
  `team.py` assigns each Claude client's session id at launch; a Codex client's is
  recorded when Herdr first reports it.

`start`, `review`, `reset` and `stop` hold a lock on `agent/teams/allocations/.lock`. A
command that waits longer than `timeouts.lock_seconds` stops with a `Busy` error; rerun
it when the other command has finished. The lock is released when its holder exits,
including after a crash. Keep `agent/teams/allocations/` on a local filesystem: the
lock and the durable record writes are not reliable on a network filesystem.

### Records from an older team.py

`team.py` refuses records without a version. A default state could relaunch a client
that already did its task. Before you install this version, drain each old record with
the `team.py` that wrote it:

- Merged brief: run its `stop`.
- Brief in progress: write down each client's name and session (the brief's launch
  EVENTs show them, so `board.py usage` still counts them), exit its clients, close its
  Herdr workspace and move the record out of `agent/teams/allocations/`. With this
  version, `start` then refuses because the worktree remains and records the clients as
  `unknown`; reset each client after checking its work, then rerun `start`. The worktree
  keeps its work.

## Changing these scripts

Follow [development](development.md). For optional local checks, install Ruff and Pyright yourself; agents never install them.

## Milestones

Read the [Project 15 readme](https://github.com/users/chenghanlee/projects/15) with `gh project view 15 --owner chenghanlee`. Keep milestones and gate issues there; do not copy them here.
