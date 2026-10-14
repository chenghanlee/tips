# Team workflow

GitHub issues, PRs and reviews store the workflow state. Herdr messages start turns. One
dispatcher chooses work, opens features, starts pairs and launches reviewers. An
implementer and a merge-confirming tester share one worktree and take turns. Every other
reviewer uses a separate worktree checked out at the PR head. Follow
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
DISPATCHER   open a feature → designers agree on a spec and briefs → team.py start <brief>
IMPLEMENTER  ask questions only when answers affect the work → code → push → PR "Closes #<brief>" → team.py turn <pr> <tester>
TESTER       ask the dispatcher to launch the other reviewers → review the head
DISPATCHER   team.py review <pr> <entry> for each
REVIEWERS    review from pinned worktrees → notify the tester with the review URL
TESTER       findings → team.py turn <pr> <implementer>   (repeat until no P0 or P1)
TESTER       every required review LGTM on the head · required checks pass → gh pr merge → "done"
DISPATCHER   team.py stop <brief> → next
```

Agents are `[agents.<entry>]` entries in [config.toml](config.toml). A brief names its
agents: `Implementer: <entry>` and `Required reviews: <entry>, <entry>`, testers first.
The first tester confirms the merge. A launched client is `team-<slot>-<entry>` in
Herdr; records use the entry name. Launches are recorded in the main checkout's
`agent/teams/allocations/<slot>.json`. The restart and cleanup commands read this
record.

## Commands

Run them from the root of your checkout. The dispatcher runs `start`, `review` and
`stop` from the main checkout.

| Command | Caller | Effect |
|---|---|---|
| `agent/teams/team.py start <brief>` | Dispatcher | Read `Implementer:` and `Required reviews:`. Create branch `task/<brief>` from `origin/main` and worktree `.worktrees/<brief>`. Set up dependencies and Dexter. Launch the implementer and merge-confirming tester in the team's workspace (see [Herdr layout](#herdr-layout)), write the allocation record, and post one EVENT per launch on the brief. |
| `agent/teams/team.py turn <pr> <tester entry>` | Implementer | Run from the pair checkout. Require a clean tree at the PR head and a PR that closes the brief. Notify the tester with the PR URL, SHA and the `review` commands for reviewers not yet launched. |
| `agent/teams/team.py turn <pr> <implementer entry>` | Tester | Notify the implementer even if the tree has uncommitted changes. Include any mismatch in the message. |
| `agent/teams/team.py review <pr> <entry>` | Dispatcher | For a reviewer in the brief other than the merge-confirming tester: create `.worktrees/review-<pr>-<entry>` detached at the PR head with its own database suffix, port, dependencies and Dexter, and launch the reviewer there, in the team's workspace. |
| `agent/teams/team.py stop <brief>` | Dispatcher | Refuse dirty, unmerged or foreign-owned work. Stop every recorded client and Dexter, drop the slot's databases, remove its worktrees, branch and workspace, delete the record. |
| `agent/teams/board.py post <issue> <TYPE>` | Any agent | Read the body from stdin. Add the attribution header. Print the comment URL. If an identical comment already exists, reuse it instead of posting another. |
| `agent/teams/board.py read <issue> [--after <comment URL>]` | Any agent | Print the issue body, then every comment or only those after a checkpoint. |
| `agent/teams/board.py usage <issue>...` | Dispatcher | Tokens per launched session and model, from the session logs. |
| `agent/teams/pr_review.py list <pr>` | Any agent | Recent reviews and every unresolved thread. |
| `agent/teams/pr_review.py resolve <thread>` | Thread opener | Resolve your own thread. |
| `herdr agent prompt dispatcher "<URL> review: run <review commands>"` | Tester | Ask the dispatcher to launch each reviewer the handoff lists as not launched. |
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

Rerunning `start` or `review` keeps a running client and relaunches a missing one from
its record. The command refuses a client whose startup did not complete. Inspect its
pane. Exit the client if it is idle. Then rerun the command. `review` reads the brief's
current `Required reviews:` line. To add a reviewer, run its command. The command
rejects changes to the implementer or merge-confirming tester.

## Turns

Every message starts a turn with the recipient's full context. Send only handoffs,
`done`, `blocked`, the dispatcher's answer to a blocker, a review URL to the
merge-confirming tester, a new-head notice to a reviewer, the tester's launch request,
and the design-phase messages the [designer role](roles/designer.md) lists. Do not send
acknowledgments or progress updates. Put everything the recipient needs in the message
or the linked record. After sending, end your turn. If sending fails, keep the turn.
Report `blocked` with the exact command and error. Do not deliver a denied message
another way.

No label shows who has the turn. After a restart, read the PR, reviews of its current
head and the required checks. Use the first matching row:

| Condition | Turn |
|---|---|
| No PR | Implementer: open it. |
| A required check failed | Implementer: fix it. |
| The latest review of the head by any reviewer in `Required reviews:` is not an LGTM | Implementer: address it. |
| The head has no review | Tester: review it. |
| The tester's latest review is an LGTM and a required reviewer has not reviewed the head | Tester: notify that reviewer, or report `blocked` when it is not launched. |
| Every required reviewer's latest review of the head is an LGTM | Tester: merge. |

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

A `Masking risk:` row also names its control and the assertion the control fails.

## Affected code
Changed public functions, schemas, changesets, migrations, config, PubSub topics,
Oban workers, shared fixtures; the callers and entry points each reaches. For a
changed fact, its construct, update, read, reset, removal and late-callback paths.

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

Merge-confirming tester: merge when every reviewer in `Required reviews:` has an LGTM as
its latest review of the head, every thread is resolved, and the required checks pass:

```sh
timeout "$TIPS_CHECK_TIMEOUT_SECONDS" gh pr checks <pr> --watch --required
gh pr merge <pr> --merge --match-head-commit <sha>
```

If a check fails, run `agent/teams/team.py turn <pr> <implementer entry>` to notify the
implementer. If merge is refused for another reason, report `blocked` with the exact
error. After the merge closes the brief and deletes the branch, notify the dispatcher
with `done`.

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
- The pair shares one worktree and takes turns; other reviewers have their own. Keep
  each client's assigned database and test port in every run.
- Put temporary files in the worktree's `tmp/`. Make source changes in worktrees, never
  the main checkout.
- Never rewrite published commits: merge `origin/main`, no rebase or force-push.
- Provider settings come from the main checkout's `.env` through
  `TIPS_PROVIDER_ENV_FILE`. Never copy secrets into a worktree. Real-provider tests need
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
