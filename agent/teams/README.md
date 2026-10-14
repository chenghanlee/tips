# Team workflow

GitHub issues, PRs and reviews store the workflow state. Herdr messages start turns. One
dispatcher chooses work, opens features, starts pairs and launches reviewers and
designers. Every launched client gets its own [allocation](#allocations) and its own clone
of the repository; no two clients share a checkout. Follow
[AGENTS.md](../../AGENTS.md) and the skill for your task:
[design-software](../skills/design-software/SKILL.md),
[implement-software](../skills/implement-software/SKILL.md),
[review-software-correctness](../skills/review-software-correctness/SKILL.md) or
[review-software-design](../skills/review-software-design/SKILL.md). Your role file
lists your responsibilities: [dispatcher](roles/dispatcher.md),
[designer](roles/designer.md), [implementer](roles/implementer.md),
[tester](roles/tester.md). Read the [common rules](roles/common.md). The user completes
[setup](SETUP.md) once.

## How it runs

```
USER         set goals · answer product questions · start the dispatcher once · report an agent that has stopped
DISPATCHER   open a feature → team.py design <spec> <entry> → designers agree on a spec and briefs → team.py start <brief>
EVERY CLIENT bootstrap.py prepares its own clone before its first task
IMPLEMENTER  ask questions only when answers affect the work → code → push → PR "Closes #<brief>" → team.py turn <pr> <tester>
             (notifies every required reviewer of the head; asks the dispatcher to launch missing ones)
DISPATCHER   team.py review <pr> <entry> for each requested reviewer
REVIEWERS    bootstrap.py --commit <head> → review the head → notify the tester with the review URL
TESTER       any review with findings → team.py turn <pr> <implementer>   (repeat until no P0 or P1)
TESTER       pr_review.py observe <pr> reports ready → gh pr merge → "done"
DISPATCHER   team.py stop <brief> → every client runs retirement.py → team.py stop <brief> → next
```

Agents are `[agents.<entry>]` entries in [config.toml](config.toml). A brief names its
agents: `Implementer: <entry>` and `Required reviews: <entry>, <entry>`, testers first.
The first tester confirms the merge. A launched client is `team-<slot>-<entry>` in
Herdr; records use the entry name. Launches are recorded in the harness root's
`state/<slot>.json`, with each client's allocation and task-submission state.
`start`, `design`, `review`, `reset` and `stop` read this record and run one at a time
([launch recovery](SETUP.md#launch-recovery)).

### Allocations

The harness root is `agent_teams/<repository name>/` beside the main checkout (for this
repository, `../agent_teams/tips/`). An absolute `TIPS_TEAM_HARNESS` names
`<root>/harness` instead, and an installed harness uses the root its `install.json`
records. `team.py` creates the root on first use with `repository.json` naming
`github.repository`, and refuses a root that names another repository, including
another owner's repository with the same name. Each launch creates an allocation whose
ID (`g<generation>-<entry>`) never repeats:

| Path | Holds | Written by |
|---|---|---|
| `allocations/<id>/` | The client's working directory | The client |
| `allocations/<id>/project/` | The client's own clone; empty until `bootstrap.py` runs | The client |
| `allocations/<id>/logs/` | Full logs of `bootstrap.py`; `deps-fetched`, the digest of the `mix.lock` last fetched successfully | The client |
| `state/<id>/bootstrap.json` | The issue and entry, what to clone and check out, the Dexter binary and sources | `team.py` |
| `state/<id>/retired.json` | What `stop` retained and why | `team.py` |
| `state/<slot>.json`, `state/.lock`, `state/generation` | Records, the store lock, the last generation | `team.py` |

`team.py` runs no Git, Mix or Dexter command in a project. The client does:
`python3 <harness>/bootstrap.py [--commit <sha>]` clones into an empty project (the
implementer on `task/<brief>`, others detached at the commit or at `origin/main`), or
fetches an existing clone without resetting it. Without `--commit`, it finishes the
checkout of a clone that an interrupted run left off it, and refuses one with commits or
files not on origin. With `--commit`, it refuses a dirty clone and a commit that no
origin branch contains. Then it runs `mix deps.get --check-locked`
unless a fetch for the current `mix.lock` already succeeded, writes the git-ignored Dexter wrapper and skills link, starts Dexter
and updates its index. Running them is the proof that the client can clone, fetch and
index. The console shows at most 8 KiB;
the full log is in `logs/`. Each database name is `tips_test` or `tips_dev`, then
`db_suffix_prefix`, the slot, `g`, the generation and the entry's `db_suffix`, so no
generation reuses another's databases.

**Accepted risk.** Workers retain broad authority. Mistakes, misleading instructions or deliberate actions can modify the harness, records or other allocations, and a worker can perform an operation the dispatcher asks for outside the dispatcher's tool surface. Restricted dispatcher tools remove its direct execution authority (RP8c direct retry prevented) but do not enforce a worker or deputy boundary; the no-proxy rule stays procedural. The sibling root reduces accidental edits from ordinary checkout operations; it does not prevent absolute-path writes. Shared-state corruption can defeat recovery assumptions or lose work. Accepted for this MVP. Revisit after an unauthorized cross-allocation or control-file write, or a delegated denial bypass, in normal use. E0's failures stay recorded as facts, not as passing tests.

## Commands

Run worker commands from your own allocation. The dispatcher runs `start`, `design`,
`review` and `stop` from the main checkout. Only the operator (the user) runs `reset`.

| Command | Caller | Effect |
|---|---|---|
| `agent/teams/team.py start <brief>` | Dispatcher | Read `Implementer:` and `Required reviews:`. Create an allocation for the implementer (bootstrap branch `task/<brief>`) and the merge-confirming tester. Launch both in the team's workspace (see [Herdr layout](#herdr-layout)), write the record, and post one EVENT per launch on the brief. |
| `agent/teams/team.py design <spec> <entry>` | Dispatcher | Launch a designer entry for the spec issue in its own allocation, in the spec's team workspace, and post its launch EVENT on the spec. The spec body names the lead and the critics. |
| `agent/teams/team.py turn <pr> <tester entry>` | Implementer | Require your own clone to be clean at the PR head and the PR to close the brief. Record the PR's failures (see `observe`); refuse while a merge conflict finding is open. Notify every launched required reviewer of the head and the `bootstrap.py --commit` command that moves its clone there. For each reviewer not launched, post a pending EVENT on the PR and ask the dispatcher to run its `review` command. Try every send; report each failed one. |
| `agent/teams/team.py turn <pr> <implementer entry>` | Tester | Record the PR's failures, then notify the implementer with the open findings. Your clone's state does not block it. |
| `agent/teams/team.py review <pr> <entry>` | Dispatcher | For a reviewer in the brief other than the merge-confirming tester: create its allocation, configured for the PR head, with its own database suffix and port, and launch the reviewer in the team's workspace. |
| `agent/teams/team.py reset <issue> <entry>` | Operator | Record the operator's decision, after checking a stopped client's work on the issue and PR, that `start`, `design` or `review` may launch a replacement in the same allocation that gets the task again. Refuse a running client. |
| `agent/teams/team.py stop <issue>` | Dispatcher | See [Retirement](#retirement). |
| `agent/teams/team.py clean` | Operator | List retained allocations with their reasons. Deletes nothing. |
| `python3 <harness>/bootstrap.py [--commit <sha>]` | Launched client | Prepare your own clone, as [Allocations](#allocations) says. |
| `python3 <harness>/retirement.py` | Launched client | Fetch origin, then post your clone's state on the issue: clean, unpushed commits, HEAD merged into `origin/main`. Changes nothing. |
| `agent/teams/board.py post <issue> <TYPE>` | Any agent | Read the body from stdin. Add the attribution header. Print the comment URL. If an identical comment already exists, reuse it instead of posting another. |
| `agent/teams/board.py read <issue> [--after <comment URL>]` | Any agent | Print the issue body, then every comment or only those after a checkpoint. |
| `agent/teams/board.py usage <issue>...` | Dispatcher | Tokens per launched session and model, from the session logs. |
| `agent/teams/pr_review.py list <pr>` | Any agent | Recent reviews and every unresolved thread. Display only. |
| `agent/teams/pr_review.py observe <pr>` | Launched client | Read the head, base, mergeability, checks and reviews within one 30-second deadline; refuse a read during which the head or base changed. Required checks are the contexts the base branch's effective rules require; a required check that has not reported blocks, and other checks are only shown. Record each failure once as a FINDING on the PR; append a resolution naming the finding comment's ID when passing evidence for the same check appears; a resolution closes only the findings that the observation read as open. Unavailable evidence records and resolves nothing. Exit 0 only when the PR can merge at this head. |
| `agent/teams/pr_review.py resolve <thread>` | Thread opener | Resolve your own thread. |
| `herdr agent prompt team-<slot>-<entry> "<review URL>"` | Other reviewer | Tell the merge-confirming tester a review exists. |
| `herdr agent prompt dispatcher "<URL> done"` | Tester | The PR merged. |
| `herdr agent prompt dispatcher "<comment URL> blocked"` | Turn holder | A blocker is recorded. |

### Herdr layout

Each team has one Herdr workspace, labelled `team-<slot>-<brief>`. It has one tab per
role: `designers`, `implementers` and `reviewers`. The merge-confirming tester and
additional testers share `reviewers`. Each client is a pane in its role's tab, named
after the client; a second client of a role is split off the tab's last pane. A tab
opens with its first client. `start` and `review` reopen a closed pane in the same
workspace and tab; `stop` refuses a workspace that holds a pane the record does not
name, and otherwise closes the whole workspace.

Rerunning `start`, `design` or `review` keeps a running client and sends it nothing. It
refuses a stopped client that may have received its task, and a client whose record is
missing while an earlier allocation, workspace or Herdr client of it remains. The dispatcher
reports that refusal to the user; only the operator decides on a replay
([launch recovery](SETUP.md#launch-recovery)). `review` reads the brief's
current `Required reviews:` line. To add a reviewer, run its command. The command
rejects changes to the implementer or merge-confirming tester.

### Retirement

`team.py stop <issue>` for a brief first refuses, asking no client and changing nothing,
unless GitHub shows the brief closed by a merged PR within `timeouts.shell_seconds`. It
then needs a retirement report from every client of the team, from its current launch; a
report from an earlier launch does not count. A client that never launched, with no
launch id and its task never submitted, has no session and needs no report. Until each
has one, it changes nothing: it asks each running client to run `retirement.py`, prints
the command the operator runs for a stopped client, and keeps every resource reserved.
With every report, it:

1. Refuses, stopping nothing and keeping the record, databases, files and reservation,
   unless every report shows a clean clone with no unpushed commits and, for a brief,
   HEAD merged into `origin/main`. Preserve the work, have the client report again, then
   rerun stop.
2. Refuses a pane in the workspace that the record does not name, and another client in
   an allocation.
3. Stops the recorded clients and closes the workspace.
4. Stops each project's Dexter daemon with the binary that bootstrap used.
5. Keeps the reservation while any of the team's ports still answers.
6. Drops the team's databases and their numbered partitions with the configured
   `team.psql`, without `FORCE`. A refused drop keeps the rest and the reservation. A
   design team keeps its databases.
7. Removes only empty allocation directories, writes `state/<id>/retired.json` with the
   retained paths and reasons, and deletes the record.

Project and log files are never deleted: a process outside the pane can still write
there. `agent/teams/team.py clean` lists each retained allocation with its reasons and
deletes nothing. The operator deletes one by hand, naming its ID
(`rm -rf <root>/allocations/<id>`), only after establishing that its work is preserved
and every writer has stopped; an earlier listing or a closed pane is not enough. If
unsure, keep it.

## Turns

Every message starts a turn with the recipient's full context. Send only handoffs,
`done`, `blocked`, the dispatcher's answer to a blocker, a review URL to the
merge-confirming tester, and the design-phase messages the [designer role](roles/designer.md) lists. Do not send
acknowledgments or progress updates. Put everything the recipient needs in the message
or the linked record. After sending, end your turn. If sending fails, keep the turn.
Report `blocked` with the exact command and error. Do not deliver a denied message
another way.

No label shows who has the turn. After a restart, read the PR, reviews of its current
head and the required checks. Use the first matching row:

| Condition | Turn |
|---|---|
| No PR | Implementer: open it. |
| A required check failed, or a FINDING is open | Implementer: fix it. |
| The latest review of the head by any reviewer in `Required reviews:` is not an LGTM | Implementer: address it. |
| A required reviewer has not reviewed the head | That reviewer: review it. The handoff notified it or asked the dispatcher to launch it. |
| `agent/teams/pr_review.py observe <pr>` reports ready to merge | Tester: merge. |

## PR review record

Use `COMMENT` reviews instead of native approvals because agents share one GitHub
identity. Submit one `COMMENT` review per pass on the current PR head and put findings
in inline comments:

```sh
gh api "repos/{owner}/{repo}/pulls/$PR/reviews" --input tmp/review.json --jq .html_url
```

```json
{"commit_id": "<head SHA>", "event": "COMMENT", "body": "...",
 "comments": [{"path": "...", "line": 12, "body": "..."}]}
```

Put either `LGTM` alone or the review decision on the first line of the body. Put
`<entry>, <session>` on the second line. Record your initial findings before reading the
PR body or another review. Resolve a thread only if you opened it. A new head
invalidates every LGTM. Review the changes since your last review.

### PR body

The PR body is the implementer's handoff to every reviewer. Only the implementer edits
it. Sections, in this order:

```markdown
Closes #<brief>

## Outcome
One paragraph: what works now.

## Scenarios
| Scenario | Test | Run |
|---|---|---|
| 1 <title> | test/path_test.exs:"name" | CI run URL or local command |

## Affected code
Changed public functions, schemas, changesets, migrations, config, PubSub topics,
Oban workers, shared fixtures; the callers and entry points each reaches.

## Tests without a scenario line
Test name and one-line reason, or "none".

## Decisions
Choices made during implementation that the brief does not record, one line each
with the reason, or "none".

## Follow-up
Issue URL for deferred work, or "none".

## Checks not run by CI
Command and result, or "none".
```

Reviewers: read the brief and the diff before the PR body. Verify the body's claims
rather than repeating the work it records.

### Severity

| Severity | Condition |
|---|---|
| P0 | A feature cannot complete, an unauthorized action succeeds, or stored data is lost or corrupted. |
| P1 | An acceptance scenario fails or is unproven, a required test or check is missing or failing, the change violates a [required rule](../skills/design-software/SKILL.md#required-rules), an error on an affected path is hidden, or the change significantly harms the user's experience. |
| P2 | Any other finding. |

Implementer: fix every P0 and P1. For P2s, fix them, decline them with a reason, or
defer them in one follow-up issue linked from the PR body. A deferral recorded in the
brief's decisions table or in a linked follow-up issue settles P2 findings on that
point. It never settles a P0 or P1 condition.

### Merge

Merge-confirming tester: wait for the required checks, then merge only when `observe`
reports the PR ready at the head: every reviewer in `Required reviews:` has an LGTM as its
latest review of that head, every thread is resolved, the required checks pass, GitHub
reports it mergeable and no FINDING is open.

```sh
timeout "$TIPS_CHECK_TIMEOUT_SECONDS" gh pr checks <pr> --watch --required
agent/teams/pr_review.py observe <pr>
gh pr merge <pr> --merge --match-head-commit <sha>
```

If a check failed or `observe` records a finding, run
`agent/teams/team.py turn <pr> <implementer entry>` to notify the implementer. If `observe`
reports evidence unavailable, run it again later; unavailable never counts as ready. If
merge is refused for another reason, report `blocked` with the exact error.

A finding that no later check can resolve, for example after a required check was renamed
or removed, is resolved by hand. Post a FINDING whose first body line is the finding's
`TEAM_FINDING` marker with `"state":"resolved"` and `"resolves":<id>`, followed by the
reason: `agent/teams/board.py post <pr> FINDING`. `<id>` is the number after
`#issuecomment-` in the open finding's URL; a resolution closes only that comment's finding.
After the merge closes the brief and deletes the branch, notify the dispatcher with `done`.

## Report and resolve blockers

Report `blocked` if you have a product or scope question, if both sides of a finding
have evidence but still disagree, or if the same finding remains after two fixes.
Comment on the issue with your name, the question and the evidence. Notify the
dispatcher with the comment URL. End your turn. Dispatcher: set Blocked. Answer
technical questions from the cited code. Ask the user about product, scope or anything
you cannot answer. Record the answer on the issue. Set Active and notify the agent. Do
not run or retry a denied command on another agent's behalf.

If an implementer's failing check also fails on the latest `main` run, the implementer
reports `blocked` with both run links. The dispatcher opens the revert with `gh pr revert <pr>` and merges it after checks pass. Then fix the original issue.

## Constraints

- One PR per issue. Open a new issue for work outside the scope. Keep that work out of
  the current PR.
- Each client works only in its own clone. Keep its assigned database and test port in
  every run.
- Put temporary files in your clone's `tmp/`. Never change the main checkout.
- Never rewrite published commits: merge `origin/main`, no rebase or force-push.
- Provider settings come from the main checkout's `.env` through
  `TIPS_PROVIDER_ENV_FILE`. Never copy secrets into a clone. Real-provider tests need
  the user's authorization on the issue.

## Manual browser review

Codex clients cannot run Wallaby browser tests on macOS: the Codex sandbox kills the
Chrome that chromedriver starts, and each attempt leaves a crash dialog
([#432](https://github.com/chenghanlee/tips/issues/432)). Wallaby runs on the
implementer's Claude client; the tester verifies the retained log. The exact
`agent-browser open about:blank --session <name>`, `get url` and `close` sequence below
succeeded from this machine's configured Codex client on 2026-10-14 (agent-browser
0.38.1, codex-cli 0.162.1). Codex manual review still needs the
[browser setup](SETUP.md#browser-access-for-the-tester) and that preflight in the
tester's own session.

Clients launch with `MIX_ENV=test`. Wait for `mix test` to exit, then start the app on
the same port:

```sh
MIX_ENV=dev unbuffer mix ecto.setup && MIX_ENV=dev PORT="$TIPS_TEST_PORT" unbuffer mix do assets.setup, assets.build, phx.server
```

Use `agent-browser` to test the app. Codex testers start each session with exactly this
command, alone in its tool call, replacing only `<name>`:

```sh
agent-browser open about:blank --session <name>
```

Other forms of `agent-browser open` can start Chrome inside the Codex sandbox and fail
with `Chrome exited early`. If `open` fails with that error or with `without writing DevToolsActivePort`, run `agent-browser close --session <name>`, then `agent-browser open about:blank --session <name>` again, then `agent-browser get url --session <name>`,
each in its own tool call. The last command prints `about:blank`. If this recovery
fails, keep the full error and follow the [browser setup diagnostics](SETUP.md#browser-access-for-the-tester). Do not disable Chrome's sandbox or
use the user's browser profile. Read mail in `/dev/mailbox`. Stop the server before
handing off.
