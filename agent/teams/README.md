# Pair workflow

GitHub stores workflow state in the issue, the PR reviews and checks, and
[Project 15](https://github.com/users/chenghanlee/projects/15) (`--owner chenghanlee`).
Read these records when assigned, after a restart and at each handoff. Record
decisions, findings and blockers there. Use Herdr to notify the next agent.
[AGENTS.md](../../AGENTS.md) owns repository boundaries, navigation, checks and skill
routing. [Developing-software](../skills/developing-software/SKILL.md) owns design and
testing rules; [reviewing-code](../skills/reviewing-code/SKILL.md) owns review methods.
This document owns pair coordination. The user completes [setup](SETUP.md) once.

| Role | Agent name | Responsibilities |
|---|---|---|
| User | n/a | Set product goals and constraints. Answer unresolved product, scope, purchase and credential questions. Start the dispatcher once; notify it when priorities or external facts change. |
| Dispatcher | `dispatcher` | Act as the Tips technical program manager: prioritize work, prepare eligible tasks, update the board, start and stop pairs, launch reviewers, and handle blockers. Do not write code or review changes. Design-tier duties: [roles/dispatcher.md](roles/dispatcher.md). |
| Designer | `team-N-<entry>` | Design one feature as lead or critic, then review its PRs: [roles/designer.md](roles/designer.md). Design rounds are launched by hand in the trial; PR review through `team.py review`. |
| Implementer | `team-N-<entry>` | Implement and verify the brief, open the PR, address findings and fix failed checks. Design-tier duties: [roles/implementer.md](roles/implementer.md). |
| Tester | `team-N-<entry>` | Review the pushed PR head, run tests or the app, publish approval and confirm the merge. Design-tier duties: [roles/tester.md](roles/tester.md). |

Every swarm role also reads [roles/common.md](roles/common.md). Agents are
`[agents.<entry>]` entries in [config.toml](config.toml). A brief issue names its
agents: `Implementer: <entry>` and `Required reviews: <entry>, <entry>`, the reviewers
whose LGTM the merge needs. The first tester in `Required reviews:` confirms the merge
and shares the pair checkout with the implementer; every other tester and the
reviewing designer reviews from its own worktree pinned at the PR head. A launched
client's Herdr name is `team-<slot>-<entry>`; its reviews are attributed to the entry
name. Launches are recorded in the main checkout's `agent/teams/allocations/<slot>.json`,
which restart, handoff and teardown read.

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
   `agent/teams/team.py start <brief>`. After a successful start, set Status Active
   and Agent on the Project item. Reassess the remaining candidates for each free slot.
7. If no task is eligible, identify the prerequisite or decision that would unlock
   the next useful task. Resolve it within your authority or report the specific
   blocker and who must act. An empty Ready queue alone is not a reason to stop.
8. End your turn after assigning work or reporting the blocker. Pairs notify you
   when they finish or need help; no polling loop is required.

### 2. Implementer: implement and hand off

1. Use the repository to fill in missing facts in the brief.
2. Plan, implement and verify using [developing-software](../skills/developing-software/SKILL.md)
   from this worktree, then push the change.
3. Open the PR with `Closes #<brief>` and enable auto-merge:
   `gh pr merge <pr> --auto --merge`. The closing reference is how `review` and the
   publisher find the brief; keep it.
4. Run `agent/teams/team.py turn <pr> <tester entry>`. When the brief names reviewers
   that are not launched yet, the command also asks the dispatcher to launch them.
5. After a successful handoff, stop using the worktree, build and database until
   the tester returns the turn.

### 3. Tester: review the pushed head

1. Record the PR head SHA. Read [reviewing-code](../skills/reviewing-code/SKILL.md)
   from this worktree to establish scope and review that head against the shared
   design and testing standard. Run the tests. For UI tasks, also check acceptance
   scenarios through [manual browser review](#manual-browser-review).
2. If required review work stays blocked, follow the
   [blocker procedure](#report-and-resolve-blockers).
3. Confirm the worktree is clean and HEAD matches the reviewed SHA. Report every P0
   and P1 in the first review. With findings: submit the review and run
   `agent/teams/team.py turn <pr> <implementer entry>`. Without: continue to approval.

Other reviewers (a second tester, the reviewing designer) review the same head from
their own pinned worktrees, launched by the dispatcher with `team.py review`. They
submit their review record, ring the merge-confirming tester by Herdr name with the
review URL, and end their turn. They never run `turn`. For a new head they fetch,
check out the head detached, reindex and review the changes since their previous
review.

For fixes, check each repair and the scenarios it affects, and apply the skill to new
behaviour or design.

### 4. Implementer and tester: address findings

1. Implementer: fix every P0 and P1. Address each P2 under the [severity rules](#severity).
   Follow [Repair and refactor](../skills/developing-software/SKILL.md#repair-and-refactor).
2. Implementer: push and hand off to the tester.
3. Tester: review the changes since the previous review, as step 3 says for fixes.
   Resolve each thread that is fixed or declined with a reason.
4. Repeat until the approval conditions are met.

### 5. Tester: approve and confirm the merge

Approve when no P0 or P1 remains and every thread is resolved. Submit the
[PR review record](#pr-review-record) without waiting for CI. Keep the turn. Then read
each other required reviewer's latest review of this head: one with findings means
`turn <pr> <implementer entry>`; one absent means ring that reviewer by Herdr name
with the PR URL and head, or report `blocked` when it is not launched; all LGTM means
publish with one `--record` per reviewer. The publisher refuses a missing,
superseded, duplicate or wrong-head record.

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
| PR not merged and a required check failed | Run `agent/teams/team.py turn <pr> <implementer entry>`. |
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
dispatcher with `done`. Otherwise, return to the implementer if a required check
failed; report `blocked` for any other outcome, including an API error. Include
the current merge state or exact error. Do not repeat either wait in this turn.

### 6. Dispatcher: remove the pair and assign the next task

Confirm the PR merged. If not, handle the message as blocked.

Run `agent/teams/team.py stop <brief>`, then select another task for the free slot.
Apply the selection process above, including Backlog and resolved blockers.

## Commands

Run commands from the repository root of your checkout. The dispatcher runs
`start` from the main checkout.

| Command | Caller | Effect |
|---|---|---|
| `agent/teams/team.py start <brief>` | Dispatcher | Read the brief's `Implementer:` and `Required reviews:` lines. Create `task/<brief>` from `origin/main`, the `.worktrees/<brief>` worktree, dependencies and Dexter; launch the implementer and the merge-confirming tester, each in its own workspace; write the allocation record. |
| `agent/teams/team.py turn <pr> <tester entry>` | Implementer | Require a clean tree and HEAD matching the PR head. Notify the tester with the PR URL and SHA. Ask the dispatcher to launch reviewers not yet launched. |
| `agent/teams/team.py turn <pr> <implementer entry>` | Tester | Notify the implementer even if the tree is dirty or HEAD differs. Include any mismatch in the message. |
| `agent/teams/team.py review <pr> <entry>` | Dispatcher | For a reviewer named in the brief other than the merge-confirming tester: create `.worktrees/review-<pr>-<entry>` detached at the PR head with its own database suffix, port, dependencies and Dexter, and launch the reviewer there. |
| `agent/teams/team.py stop <brief>` | Dispatcher | Refuse dirty, unmerged or foreign-owned work. Stop every recorded client and Dexter, drop the slot's databases, remove its worktrees, branch and workspaces, and delete the record. |
| `herdr agent prompt dispatcher "<issue or PR URL> done"` | Tester | Notify the dispatcher that the PR merged. |
| `herdr agent prompt dispatcher "<blocker comment URL> blocked"` | Current turn holder | Notify the dispatcher of a recorded blocker. |
| `herdr agent prompt team-<slot>-<entry> "<review URL>"` | Other reviewer | Tell the merge-confirming tester that a review record exists. |

`start` and `stop` take the brief number. `turn`, `review` and the review tools take
the PR number. Rerunning `start` or `review` keeps a running client and relaunches a
missing one from the record; a brief whose roster changed must be stopped first.

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
| No PR exists | Implementer: implement and open the PR. |
| A required check failed | Implementer: fix the failure. |
| The current head has reviews and the latest is not an LGTM | Implementer: address the review. |
| A reviewer named in `Required reviews:` has a latest review of this head that is not an LGTM | Implementer: address it. |
| The current head has no reviews | Tester: review it. |
| The tester's latest review is an LGTM and a reviewer named in `Required reviews:` has not reviewed this head | Tester: keep the turn; ring that reviewer by Herdr name, or report `blocked` when it is not launched so the dispatcher runs `review`. |
| The current head is approved | Tester: complete approval publication and merge confirmation. |

## Rules

### Severity

Use the first matching severity:

| Severity | Condition |
|---|---|
| P0 | A feature cannot complete, an unauthorized action succeeds, or stored data is lost or corrupted. |
| P1 | An acceptance scenario fails, a required test or check is missing or failing, or the change significantly harms the user's experience. |
| P2 | Any other finding. |

The implementer must fix every P0 and P1. For P2s, fix them, decline them with a
reason, or file one follow-up issue for all deferred P2s.

### Messages between agents

Every message starts a turn using the recipient's full context. Send only:

- `team.py turn` handoffs.
- `done` notifications.
- `blocked` reports.
- The dispatcher's answer to a blocker.
- A reviewer's review URL to the merge-confirming tester, and the tester's new-head
  ring to a reviewer.
- `turn`'s request that the dispatcher launch reviewers.

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

If an implementer's failing check also fails on the latest `main` run:

1. Implementer: report `blocked` with both run links.
2. Dispatcher: find the merge that broke `main` and open its revert with
   `gh pr revert <pr>`.
3. Dispatcher: enable auto-merge with `gh pr merge <revert pr> --auto --merge`
   and ask the user for an owner waiver on the revert PR.
4. Fix the underlying problem after the revert merges.

### Worktree and provider constraints

- Use one PR per issue. If an issue needs multiple PRs, report `blocked` and ask
  for the issue to be split.
- The pair shares one worktree and takes turns. Other reviewers have their own
  worktrees. Each client has its own database and test port, set at launch. Preserve
  these settings in every test run.
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
can start Chrome inside the Codex sandbox and fail with `Chrome exited early`.
After it succeeds, use any `agent-browser` command. Repeat it after `close`.

Read mail at `/dev/mailbox`. The development
app calls real providers; test those scenarios only with the user's authorization
on the issue. Stop the server before handing off or notifying the dispatcher.

#### Recover a failed browser launch

If `open` fails with `Chrome exited early` or `without writing DevToolsActivePort`,
the session may have a daemon started inside the Codex sandbox. Retrying `open`
reuses that daemon. Close only your failed session, then reopen it and verify
the connection. Replace `<name>` with the same session name throughout and run
each command in a separate tool call:

```sh
agent-browser close --session <name>
```

```sh
agent-browser open about:blank --session <name>
```

```sh
agent-browser get url --session <name>
```

The last command should print `about:blank`. If recovery fails, retain the full
error and follow the [browser setup diagnostics](SETUP.md#browser-access-for-the-tester).
Do not disable Chrome's sandbox or switch to the user's personal browser profile.

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

Every review body has the same two first lines: `LGTM` alone for an approval, or the
decision otherwise; then `<entry name>, <session>`. Attribution is the second line up
to its first comma, matched exactly against the brief's `Required reviews:` names. To approve, publish the status:

```sh
agent/teams/publish_review.py --pr <pr> --sha <sha> --record <review URL>
```

The command refuses a wrong head, a wrong record or unresolved threads. When the
PR's linked issue (GitHub's closing reference, any keyword) has a line
`Required reviews: <name>, <name>`, every named reviewer's latest review of the head
must be an LGTM attributed to that name, and every review of the head must be
attributed to a named reviewer; repeat `--record` for each. The command refuses a
missing, superseded, duplicate or unlisted record, an unattributed review, an empty
or repeated name, and two linked issues that both name reviewers. This is a check at
publication time through one shared account: it catches omission, stale heads and
superseded decisions; it does not authenticate who wrote a review or an issue body.

To read reviews and resolve threads:

| Command | Effect |
|---|---|
| `agent/teams/pr_review.py list <pr>` | Print recent reviews and every unresolved thread. |
| `agent/teams/pr_review.py resolve <thread>` | Resolve a thread. Only the reviewer who opened it may do this. |

Use `--owner-waiver` only on the user's explicit instruction.
