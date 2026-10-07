# Agent pairs: setup

For humans, from the repository root. Agents read the [pair workflow](README.md) instead.

## How it runs

```
USER         set goals and constraints · answer decisions · start the dispatcher once
DISPATCHER   assess milestone → prioritize eligible work → set Ready → start pair → set Active
DEVELOPER    code → push → PR with "Closes #<issue>" + auto-merge → team.py turn <pr> test
TESTER       review → findings → team.py turn <pr> dev      (loop until no P0 or P1)
TESTER       LGTM → publish_review.py
GITHUB       checks + status + resolved threads → merge → issue closes → Done
TESTER       confirm the merge → ring the dispatcher "done"
DISPATCHER   team.py stop <issue> → next
```

## One-time setup

In GitHub: enable "Allow auto-merge" on the repository; in the ruleset "Reviewed main" turn off the strict up-to-date requirement and keep `checks`, `release`, `tips/independent-review` and resolved conversations; in Project 15 enable the workflow "Item closed" so a closed issue gets Status Done.

Install Python 3.12 and the [configured client CLIs](config.toml). Authenticate the clients and the GitHub CLI (`gh`) for this repository. Agents also need GNU `timeout` (macOS: `brew install coreutils`) and `unbuffer` (Expect): the Elixir skill requires it on Mix commands. Testers use `agent-browser` for manual browser review.

The user maintains third-party skills in these Git-ignored directories in the main checkout:

- `.agents/skills/`: `elixir`, `phoenix`, `ecto`, `otp`, `oban` and `herdr`, for Codex.
- `.claude/skills/`: the same five Elixir skills, for Claude.

Update matching copies together. `team.py start` links the main checkout's `.agents/skills/` into each worktree and checks only that the directory exists.

The repository versions two skills, the [Dexter reference](../skills/dexter/SKILL.md) and [reviewing-code](../skills/reviewing-code/SKILL.md). Link them once into both locations from the main checkout:

```bash
ln -s ../../agent/skills/dexter .agents/skills/dexter
ln -s ../../agent/skills/dexter .claude/skills/dexter
ln -s ../../agent/skills/reviewing-code .agents/skills/reviewing-code
ln -s ../../agent/skills/reviewing-code .claude/skills/reviewing-code
```

These links serve discovery in the main checkout. A pair tester reads the versioned file in its own worktree, as the pair workflow says, because the linked skills directory points at the main checkout's copy.

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

Codex launches with approval policy `never`, so a denied action cannot escalate, and the launcher does not change sandbox settings. Before the first pair, allow Codex to reach GitHub over HTTPS, the Herdr and Dexter Unix sockets, and the local database and test port. `--allow-unix-socket` is a flag of `codex sandbox`, not of the interactive client the launcher starts. Verify in a launched tester: `gh pr view 331 --json state`, `herdr agent get "$HERDR_PANE_ID"`, `"$TIPS_DEXTER" lookup Tips.Repo` and `unbuffer mix test`.

### Browser access for the tester

In `~/.codex/config.toml`, append the absolute path to `~/.agent-browser` to the
existing `[sandbox_workspace_write].writable_roots` list. Preserve its other
entries. This addresses the denied home-directory write. See the
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
first follow the [close-and-reopen recovery](README.md#recover-a-failed-browser-launch).
A daemon started inside the sandbox can survive a failed launch, so retrying
`open` alone can still fail even with the allow rule installed.

If recovery fails or opening reports another error, retain the full error and
run `agent-browser doctor` in that same tester. Doctor's launch test starts a
separate browser and can fail inside the Codex sandbox even when the approved
`open` command works; the quick/offline doctor is not a launch check. Resolve the
failure before assigning manual browser review; do not disable Chrome's sandbox or
silently switch to the user's personal browser profile. ChromeDriver for local
Wallaby tests is a separate prerequisite in the
[browser test guide](../../docs/development/local-development.md#browser-tests-and-ci).

### Claude auto-mode repository context

In `~/.claude/settings.json`, keep `autoMode.environment` statements scoped to
the repository they describe. Qualify any existing claim that another repository
is the only trusted repository or has no protected branches; retain that
repository's other rules. Add this Tips-specific entry:

> github.com/chenghanlee/tips is a trusted repository. Its main branch is protected
> by Reviewed main: PRs, checks, release, tips/independent-review and resolved review
> threads are required, with no bypass actors. A separate tester publishes
> tips/independent-review for the exact PR head. Required approving reviews is 0
> because the agents share one GitHub identity.

Preserve other settings and rule lists. Do not add a merge or handoff allow rule.
Run `claude auto-mode config` to check the effective context and
`claude auto-mode critique` to check for contradictory rules, then start a new
session. Corrected context is not a proven fix for the handoff denial. An existing
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
The calling agent remains available. Inspect the new pane for startup or approval
prompts; successful command submission does not mean the dispatcher is ready.
Use the script in the main checkout.

Start only one. Pairs notify it by the name `dispatcher`. It chooses and prepares the next task from the backlog using the milestone plan, dependencies and product value; you do not need to mark tasks Ready. Nothing watches GitHub: after changing priorities or external facts, type `board changed` in its pane. It asks unresolved product and scope questions in that pane; answer there. Every ring starts a turn over its whole context, so it compacts early (`dispatcher.compact_percent`); GitHub holds the state it needs. It starts and stops pairs with `team.py` from this checkout; each pair gets its own Herdr workspace. Handle each client's repository trust prompt the first time. An unexpected approval prompt stops a launch; inspect it and follow the active approval policy.

## Configuration

Edit [config.toml](config.toml): the number of pairs, client, model and effort per role, the dispatcher's model, effort and compaction point, port and database allocation, permissions and time budgets. Scripts read the main checkout's file; `TIPS_TEAM_CONFIG=/absolute/path` selects a staged one. Settings apply at the next launch.

Claude launches with `--advisor fable` when its configured model is nonempty and does not name Fable; this requires Fable access. Fable models and an empty model (the client default) leave the advisor setting to the client.

| Allocation | Components |
|---|---|
| Database suffix | `team.db_suffix_prefix`, slot number, `roles.<role>.db_suffix` |
| Test port | `team.port_base` + slot number × `team.port_stride` + role `port_offset` |

`timeouts.dexter_startup_seconds` bounds the Dexter warm-up at start, Elixir version detection and the daemon stop at retirement. `TIPS_DEXTER_HOME` selects another shared Dexter build directory.

Set database connection limits in [compose.yaml](../../compose.yaml), overridden by `TIPS_DB_MAX_CONNECTIONS`. Recreate the database service to apply changes, only with no pairs running.

## Changing these scripts

Follow [development](development.md). For optional local checks, install Ruff and Pyright yourself; agents never install them.

## Milestones

Read the [Project 15 readme](https://github.com/users/chenghanlee/projects/15) with `gh project view 15 --owner chenghanlee`. Keep milestones and gate issues there; do not copy them here.
