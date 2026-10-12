# Team workflow

Issues, PRs and reviews on GitHub are the state; Herdr messages start turns. One
dispatcher chooses work, opens features, starts pairs and launches reviewers. An
implementer and a merge-confirming tester share one worktree and take turns; every
other reviewer works from its own worktree pinned at the PR head. Follow
[AGENTS.md](../../AGENTS.md), [developing-software](../skills/developing-software/SKILL.md)
and [reviewing-code](../skills/reviewing-code/SKILL.md). Your role file says what you
own: [dispatcher](roles/dispatcher.md), [designer](roles/designer.md),
[implementer](roles/implementer.md), [tester](roles/tester.md). Everyone reads
[common rules](roles/common.md). The user completes [setup](SETUP.md) once.

## How it runs

```
USER         set goals · answer product questions · start the dispatcher once
DISPATCHER   open a feature → designers agree a spec and briefs → team.py start <brief>
IMPLEMENTER  Q&A on the brief → code → push → PR "Closes #<brief>" → team.py turn <pr> <tester>
TESTER       ask the dispatcher to launch the other reviewers → review the head
DISPATCHER   team.py review <pr> <entry> for each
REVIEWERS    review from pinned worktrees → notify the tester with the review URL
TESTER       findings → team.py turn <pr> <implementer>   (repeat until no P0 or P1)
TESTER       every required review LGTM on the head · checks green → gh pr merge → "done"
DISPATCHER   team.py stop <brief> → next
```

Agents are `[agents.<entry>]` entries in [config.toml](config.toml). A brief names
its agents: `Implementer: <entry>` and `Required reviews: <entry>, <entry>`, testers
first; the first tester confirms the merge. A launched client is `team-<slot>-<entry>`
in Herdr; its records carry the entry name. Launches are recorded in the main
checkout's `agent/teams/allocations/<slot>.json`, which restart and teardown read.

## Commands

Run them from the root of your checkout. The dispatcher runs `start`, `review` and
`stop` from the main checkout.

| Command | Caller | Effect |
|---|---|---|
| `agent/teams/team.py start <brief>` | Dispatcher | Read `Implementer:` and `Required reviews:`. Create `task/<brief>` from `origin/main`, the `.worktrees/<brief>` worktree, dependencies and Dexter; launch the implementer and the merge-confirming tester in their own workspaces; write the allocation record; post one EVENT per launch on the brief. |
| `agent/teams/team.py turn <pr> <tester entry>` | Implementer | Require a clean tree at the PR head, run from the pair checkout, and a PR that closes the brief. Notify the tester with the PR URL, SHA and the `review` commands for reviewers not yet launched. |
| `agent/teams/team.py turn <pr> <implementer entry>` | Tester | Notify the implementer even if the tree is dirty; the message includes any mismatch. |
| `agent/teams/team.py review <pr> <entry>` | Dispatcher | For a reviewer in the brief other than the merge-confirming tester: create `.worktrees/review-<pr>-<entry>` detached at the PR head with its own database suffix, port, dependencies and Dexter, and launch the reviewer there. |
| `agent/teams/team.py stop <brief>` | Dispatcher | Refuse dirty, unmerged or foreign-owned work. Stop every recorded client and Dexter, drop the slot's databases, remove its worktrees, branch and workspaces, delete the record. |
| `agent/teams/board.py post <issue> <TYPE>` | Any agent | Post a comment with the attribution header, body on stdin; print its URL. An identical comment is reused, never doubled. |
| `agent/teams/board.py read <issue> [--after <comment URL>]` | Any agent | Print the issue body, then every comment or only those after a checkpoint. |
| `agent/teams/board.py usage <issue>...` | Dispatcher | Tokens per launched session and model, from the session logs. |
| `agent/teams/pr_review.py list <pr>` | Any agent | Recent reviews and every unresolved thread. |
| `agent/teams/pr_review.py resolve <thread>` | Thread opener | Resolve your own thread. |
| `herdr agent prompt dispatcher "<URL> review: run <review commands>"` | Tester | Ask for the reviewers the handoff names as not launched. |
| `herdr agent prompt team-<slot>-<entry> "<review URL>"` | Other reviewer | Tell the merge-confirming tester a review exists. |
| `herdr agent prompt dispatcher "<URL> done"` | Tester | The PR merged. |
| `herdr agent prompt dispatcher "<comment URL> blocked"` | Turn holder | A blocker is recorded. |

Rerunning `start` or `review` keeps a running client and relaunches a missing one from
its record. A client whose startup did not complete is refused: inspect its pane, exit
it if idle, rerun. `review` reads the brief's current `Required reviews:` line, so an
added reviewer only needs its command; a changed implementer or merge-confirming
tester is refused.

## Turns

Every message starts a turn with the recipient's full context. Send only handoffs,
`done`, `blocked`, the dispatcher's answer to a blocker, a review URL to the
merge-confirming tester, a new-head notice to a reviewer, and the tester's launch
request. No acknowledgments or progress updates. Put everything the recipient needs
in the message or the linked record. After sending, end your turn. If sending fails
you still hold the turn: report `blocked` with the exact command and error; nobody
delivers a denied message another way.

After a restart, no label tracks the turn. Read the PR, the reviews of its head and
the required checks, and take the first matching row:

| Condition | Turn |
|---|---|
| No PR | Implementer: open it. |
| A required check failed | Implementer: fix it. |
| The latest review of the head by any reviewer in `Required reviews:` is not an LGTM | Implementer: address it. |
| The head has no review | Tester: review it. |
| The tester's latest review is an LGTM and a required reviewer has not reviewed the head | Tester: notify that reviewer, or report `blocked` when it is not launched. |
| Every required reviewer's latest review of the head is an LGTM | Tester: merge. |

## PR review record

Agents share one GitHub identity, so native approval is off. Submit one `COMMENT`
review per pass on the exact head, findings inline:

```sh
gh api "repos/{owner}/{repo}/pulls/$PR/reviews" --input tmp/review.json --jq .html_url
```

```json
{"commit_id": "<head SHA>", "event": "COMMENT", "body": "...",
 "comments": [{"path": "...", "line": 12, "body": "..."}]}
```

The body's first line is `LGTM` alone or the decision; the second is
`<entry>, <session>`. Record first findings before reading the PR description or
another review. The reviewer who opened a thread resolves it. A new head voids every
LGTM; review the changes since your last review.

### Severity

| Severity | Condition |
|---|---|
| P0 | A feature cannot complete, an unauthorized action succeeds, or stored data is lost or corrupted. |
| P1 | An acceptance scenario fails, a required test or check is missing or failing, or the change significantly harms the user's experience. |
| P2 | Any other finding. |

The implementer fixes every P0 and P1. For P2s: fix, decline with a reason, or file
one follow-up issue for all deferred P2s.

### Merge

The merge-confirming tester merges when every reviewer in `Required reviews:` has an
LGTM as its latest review of the head, every thread is resolved, and the required
checks pass:

```sh
timeout "$TIPS_CHECK_TIMEOUT_SECONDS" gh pr checks <pr> --watch --required
gh pr merge <pr> --merge --match-head-commit <sha>
```

A failed check goes back to the implementer with `turn`. Any other refusal is
`blocked` with the exact error. Merging closes the brief and deletes the branch; then
notify the dispatcher `done`.

## Report and resolve blockers

Report `blocked` when a product or scope question arises, when both sides of a
finding have evidence and still disagree, or when two fixes leave the same finding
failing. Comment on the issue with your name, the question and the evidence; notify
the dispatcher with the comment URL; end your turn. The dispatcher sets Blocked,
answers technical questions from the cited code, asks the user about product, scope
or anything it cannot answer, records the answer on the issue, sets Active and
notifies the agent. A denied command is never run for the agent or retried on its
behalf.

If an implementer's failing check also fails on the latest `main` run: implementer
reports `blocked` with both run links; dispatcher opens the revert with
`gh pr revert <pr>`, merges it after checks, and the fix follows.

## Constraints

- One PR per issue. Out-of-scope findings become a new issue, not more PR.
- The pair shares one worktree and takes turns; other reviewers have their own.
  Each client has its own database and test port from launch; keep them in every run.
- Scratch goes in the worktree's `tmp/`. Source changes happen in worktrees, never the
  main checkout.
- Never rewrite published commits: merge `origin/main`, no rebase or force-push.
- Provider settings come from the main checkout's `.env` through
  `TIPS_PROVIDER_ENV_FILE`; never copy secrets into a worktree. Real-provider tests need
  the user's authorization on the issue.

## Manual browser review

Clients launch with `MIX_ENV=test`. Wait for `mix test` to exit, then start the app on
the same port:

```sh
MIX_ENV=dev unbuffer mix ecto.setup && MIX_ENV=dev PORT="$TIPS_TEST_PORT" unbuffer mix do assets.setup, assets.build, phx.server
```

Drive it with `agent-browser`. Codex testers start each session with exactly this
command, alone in its tool call, replacing only `<name>`:

```sh
agent-browser open about:blank --session <name>
```

Any other form can start Chrome inside the Codex sandbox and fail with
`Chrome exited early`. If `open` fails that way or with
`without writing DevToolsActivePort`, run `agent-browser close --session <name>`, then
`open` again, then `agent-browser get url --session <name>`, each in its own tool call;
the last prints `about:blank`. If that fails, keep the full error and follow the
[browser setup diagnostics](SETUP.md#browser-access-for-the-tester); do not disable
Chrome's sandbox or use the user's browser profile. Read mail at `/dev/mailbox`. Stop
the server before handing off.
