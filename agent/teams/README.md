# Pair workflow

GitHub stores workflow state in the issue, the PR reviews and checks, and
[Project 15](https://github.com/users/chenghanlee/projects/15) (`--owner chenghanlee`).
Read these records when assigned, after a restart and at each handoff. Record
decisions, findings and blockers there. Use Herdr to notify the next agent.
[AGENTS.md](../../AGENTS.md) defines engineering rules. The user completes
[setup](SETUP.md) once.

| Role | Agent name | Responsibilities |
|---|---|---|
| User | n/a | Set product goals and constraints. Answer unresolved product, scope, purchase and credential questions. Start the dispatcher once; notify it when priorities or external facts change. |
| Dispatcher | `dispatcher` | Act as the Tips technical program manager: prioritize work, prepare eligible tasks, update the board, start and stop pairs, and handle blockers. Do not write code or review changes. |
| Developer | `team-N-dev` | Implement and verify the issue, open the PR, address findings and fix failed checks. |
| Tester | `team-N-test` | Review the pushed PR head, run tests or the app, publish approval and confirm the merge. |

## Common path

### 1. Dispatcher: select and start tasks

At startup, after each `done` or `blocked` message, and when the user reports a
board change:

1. Read the Project 15 readme for milestone order and gates, the board and open
   issues, open PRs, running pairs (`herdr workspace list`), worktrees
   (`git worktree list`) and the latest `main` run. Read candidate issues, their
   prerequisite links, relevant design sections and recent decisions before choosing.
2. Set merged issues to Done. For an issue with a running pair, keep Blocked if
   its question is unanswered; otherwise set Active. For other blocked issues,
   check the recorded reason. Clear a dependency blocker only when its prerequisites
   are complete; keep unanswered questions, missing access and explicit user holds.
3. For each free slot, choose the eligible task with the highest value for the
   current milestone. Follow explicit user priorities. Otherwise prioritize work
   that unblocks the milestone gate or other tasks, completes a usable product
   flow, or fixes a demonstrated regression. Use board order to break ties.
   Prefer product progress over optional tooling. The slot limit is
   `team.max_teams` in [config.toml](config.toml); do not fill slots with conflicting work.
4. Consider Backlog as well as Ready. Ready means the dispatcher has checked that
   the task can start; it does not require the user to select it. Before starting,
   confirm prerequisites are complete, the issue has a bounded outcome and
   acceptance scenarios, and no running pair or open PR already owns the work.
   Defer a task if its issue body and an active issue's body name the same database
   table, API or data rule. Package parents are summaries, not pair assignments.
5. Fill in missing task details or split work into one-PR issues using the existing
   design and decisions. Resolve technical sequencing yourself. Ask the user only
   when a product or scope decision is not settled, or their access, purchase or
   approval is required. Do not change requirements or waive gates to make work eligible.
6. Record the selection decision and its reason on the issue, set Ready, and run
   `agent/teams/team.py start <issue>`. After a successful start, set Status Active
   and Agent on the Project item. Reassess the remaining candidates for each free slot.
7. If no task is eligible, identify the prerequisite or decision that would unlock
   the next useful task. Resolve it within your authority or report the specific
   blocker and who must act. An empty Ready queue alone is not a reason to stop.
8. End your turn after assigning work or reporting the blocker. Pairs notify you
   when they finish or need help; no polling loop is required.

### 2. Developer: implement and hand off

1. Use the repository to fill in missing facts in the issue.
2. Implement, verify and push the change.
3. Open the PR with `Closes #<issue>` and enable auto-merge:
   `gh pr merge <pr> --auto --merge`.
4. Run `agent/teams/team.py turn <pr> test`.
5. After a successful handoff, stop using the worktree, build and database until
   the tester returns the turn.

### 3. Tester: review the pushed head

1. Review the PR head SHA and run the tests. For UI tasks, also check acceptance
   scenarios through [manual browser review](#manual-browser-review).
2. Report every P0 and P1 you find in the first review.
3. Before submitting the review, confirm that the worktree is clean and HEAD
   still matches the reviewed SHA.
4. If you have findings, submit the review and run
   `agent/teams/team.py turn <pr> dev`.
5. If you have no findings, continue to approval.

### 4. Developer and tester: address findings

1. Developer: fix every P0 and P1. Address each P2 under the [severity rules](#severity).
2. Developer: push and hand off to the tester.
3. Tester: review the changes since the previous review. Resolve each thread
   that is fixed or declined with a reason.
4. Repeat until the approval conditions are met.

### 5. Tester: approve and confirm the merge

Approve when no P0 or P1 remains and every thread is resolved. Submit and publish
the [PR review record](#pr-review-record) without waiting for CI. Keep the turn.

Auto-merge requires `checks`, `release`, `tips/independent-review` and resolved
threads. A merge closes the issue, sets the Project item to Done and deletes the
remote branch.

Run this watch command once each time the turn reaches this step:

```sh
timeout "$TIPS_CHECK_TIMEOUT_SECONDS" gh pr checks <pr> --watch --required
```

Whether it passes, fails or times out, then run:

```sh
gh pr view <pr> --json state,mergedAt,mergeStateStatus,autoMergeRequest
```

Use the first matching outcome:

| Outcome | Action |
|---|---|
| PR merged | Notify the dispatcher with `done`. |
| PR not merged and a required check failed | Run `agent/teams/team.py turn <pr> dev`. |
| Checks passed, PR open, auto-merge enabled, merge state neither `BLOCKED` nor `DIRTY` | Run the bounded merge wait below. |
| Any other outcome | Report `blocked` to the dispatcher with the pending check or merge blocker. |

GitHub may take several minutes to merge after checks pass. Run this once; it
rechecks every 15 seconds and uses the existing check timeout as its ceiling:

```sh
timeout "$TIPS_CHECK_TIMEOUT_SECONDS" sh -c '
  while :; do
    result=$(gh pr view "$1" --json state,mergeStateStatus,autoMergeRequest \
      --jq "[.state, .mergeStateStatus, (.autoMergeRequest != null)] | join(\" \")") || exit 1
    case "$result" in
      "MERGED "*) exit 0 ;;
      "OPEN BLOCKED "*|"OPEN DIRTY "*) echo "$result"; exit 1 ;;
      "OPEN "*" true") sleep 15 ;;
      *) echo "Merge wait stopped: $result"; exit 1 ;;
    esac
  done
' sh <pr>
```

After the wait exits or times out, read the PR state again. If merged, notify the
dispatcher with `done`. Otherwise, return to the developer if a required check
failed; report `blocked` for any other outcome, including an API error. Include
the current merge state or exact error. Do not repeat either wait in this turn.

### 6. Dispatcher: remove the pair and assign the next task

Confirm the PR merged. If not, handle the message as blocked.

Run `agent/teams/team.py stop <issue>`, then select another task for the free slot.
Apply the selection process above, including Backlog and resolved blockers.

## Commands

Run commands from the repository root of your checkout. The dispatcher runs
`start` from the main checkout.

| Command | Caller | Effect |
|---|---|---|
| `agent/teams/team.py start <issue>` | Dispatcher | Create `task/<issue>` from `origin/main`, the `.worktrees/<issue>` worktree, dependencies, Dexter, and developer and tester clients. |
| `agent/teams/team.py turn <pr> test` | Developer | Require a clean tree and HEAD matching the PR head. Notify the tester with the PR URL and SHA. |
| `agent/teams/team.py turn <pr> dev` | Tester | Notify the developer even if the tree is dirty or HEAD differs. Include any mismatch in the message. |
| `agent/teams/team.py stop <issue>` | Dispatcher | Refuse dirty, unmerged or foreign-owned work. Stop the clients and Dexter, drop the pair's databases, and remove its worktree and branch. |
| `herdr agent prompt dispatcher "<issue or PR URL> done"` | Tester | Notify the dispatcher that the PR merged. |
| `herdr agent prompt dispatcher "<blocker comment URL> blocked"` | Current turn holder | Notify the dispatcher of a recorded blocker. |

`start` and `stop` take the issue number. `turn` and the review tools take the PR
number. Rerunning `start` keeps a running client and relaunches a missing one.

After sending a handoff, end your turn. The other agent's message starts a new
turn. If sending fails, you still hold the turn: report `blocked` to the dispatcher
with the exact command and error using [the blocker procedure](#report-and-resolve-blockers).
This reports the failure; the dispatcher must not deliver a denied handoff by
another route. If the report is also denied, report both errors to the user in
your pane. The only waits are the tester's bounded check and merge waits in step 5.

### Determine the turn after a restart

No label tracks the turn. Read the PR, reviews of its current head and required
checks. Use the first matching condition:

| Condition | Turn holder and action |
|---|---|
| No PR exists | Developer: implement and open the PR. |
| A required check failed | Developer: fix the failure. |
| The current head has reviews and the latest is not an LGTM | Developer: address the review. |
| The current head has no reviews | Tester: review it. |
| The current head is approved | Tester: complete approval publication and merge confirmation. |

## Rules

### Severity

Use the first matching severity:

| Severity | Condition |
|---|---|
| P0 | A feature cannot complete, an unauthorized action succeeds, or stored data is lost or corrupted. |
| P1 | An acceptance scenario fails, a required test or check is missing or failing, or the change significantly harms the user's experience. |
| P2 | Any other finding. |

The developer must fix every P0 and P1. For P2s, fix them, decline them with a
reason, or file one follow-up issue for all deferred P2s.

### Messages between agents

Every message starts a turn using the recipient's full context. Send only:

- `team.py turn` handoffs.
- `done` notifications.
- `blocked` reports.
- The dispatcher's answer to a blocker.

Do not send acknowledgments, progress or status updates, thanks, or replies that
only confirm receipt. Include everything the recipient needs in one message or
in the linked record.

### Report and resolve blockers

To report `blocked`:

1. Comment on the issue with your agent name, the question or blocker, and evidence.
2. Notify the dispatcher with the comment URL.
3. End your turn. The dispatcher will send the answer in a new message.

The current turn holder must report `blocked` when:

- Both agents have responded to a finding with evidence and still disagree.
- Two fixes leave the same finding failing and the agents disagree on the next
  check. A rerun without a fix does not count as a fix.
- A product or scope question arises. Report it immediately, whether or not a PR exists.

Dispatcher actions:

1. Set Status Blocked.
2. Answer technical questions using the reported error and cited code. Ask the
   user in your pane about product, scope or any question you cannot answer.
   For a denied command, do not run it for the agent, deliver its message another
   way or tell the agent to retry; ask the user.
   Do not disable, re-arm or bypass auto-merge. If an approved PR with passing
   required checks has not merged, report it to the user; GitHub may merge it late.
3. Record the answer on the issue.
4. Set Status Active and notify the agent named in the blocker comment.

### Failed checks on main

If a developer's failing check also fails on the latest `main` run:

1. Developer: report `blocked` with both run links.
2. Dispatcher: find the merge that broke `main` and open its revert with
   `gh pr revert <pr>`.
3. Dispatcher: enable auto-merge with `gh pr merge <revert pr> --auto --merge`
   and ask the user for an owner waiver on the revert PR.
4. Fix the underlying problem after the revert merges.

### Worktree and provider constraints

- Use one PR per issue. If an issue needs multiple PRs, report `blocked` and ask
  for the issue to be split.
- The pair shares one worktree and takes turns. Each client has its own database
  and test port, set at launch. Preserve these settings in every test run.
- Put scratch files only in the worktree's `tmp/` directory.
- Never rewrite published commits. Merge `origin/main` when needed; do not rebase
  or force-push.
- Make source changes in pair worktrees, never in the main checkout.
- Read provider settings from the main checkout's `.env` through
  `TIPS_PROVIDER_ENV_FILE`. Never copy secrets into a worktree.
- Real-provider tests require the user's authorization on the issue.

### Manual browser review

Clients launch with `MIX_ENV=test`, which runs tests but cannot serve a manual
browser session. Wait for `mix test` to exit before starting the app: both use
`$TIPS_TEST_PORT`. Start the app with:

```sh
MIX_ENV=dev unbuffer mix ecto.setup && MIX_ENV=dev PORT="$TIPS_TEST_PORT" unbuffer mix do assets.setup, assets.build, phx.server
```

Use `agent-browser` to test the app. Codex testers: start each browser session
with this exact command, replacing only `<name>`:

```sh
agent-browser open about:blank --session <name>
```

Run it alone: no `&&`, no shell variables, nothing before `open`. Any other form
starts Chrome inside the Codex sandbox and fails with `Chrome exited early`.
After it succeeds, use any `agent-browser` command. Repeat it after `close`.

Read mail at `/dev/mailbox`. The development
app calls real providers; test those scenarios only with the user's authorization
on the issue. Stop the server before handing off or notifying the dispatcher.

## PR review record

These requirements apply to every PR, pair or solo.

Agents share one GitHub identity, so native approval does not work. Submit one
`COMMENT` review per pass on the exact PR head, with findings inline:

```sh
gh api "repos/{owner}/{repo}/pulls/$PR/reviews" --input tmp/review.json --jq .html_url
```

Use this structure for `tmp/review.json`:

```json
{
  "commit_id": "<head SHA>",
  "event": "COMMENT",
  "body": "...",
  "comments": [{"path": "...", "line": 12, "body": "..."}]
}
```

For approval, put `LGTM` alone on the first line of the review body and the role
and session on the second line. Then publish the status:

```sh
agent/teams/publish_review.py --pr <pr> --sha <sha> --record <review URL>
```

The command refuses a wrong head, a wrong record or unresolved threads.

To read reviews and resolve threads:

| Command | Effect |
|---|---|
| `agent/teams/pr_review.py list <pr>` | Print recent reviews and every unresolved thread. |
| `agent/teams/pr_review.py resolve <thread>` | Resolve a thread. Only the reviewer who opened it may do this. |

Use `--owner-waiver` only on the user's explicit instruction.
