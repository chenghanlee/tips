# Pair workflow

GitHub stores workflow state in the issue, the PR reviews and checks, and
[Project 15](https://github.com/users/chenghanlee/projects/15) (`--owner chenghanlee`).
Read these records when assigned, after a restart and at each handoff. Record
decisions, findings and blockers there. Use Herdr to notify the next agent.
[AGENTS.md](../../AGENTS.md) owns repository boundaries, navigation, checks and skill
routing. [Developing-software](../skills/developing-software/SKILL.md) owns design and
testing rules; [reviewing-code](../skills/reviewing-code/SKILL.md) owns review methods.
This document owns shared coordination. Read it and your role procedure from the
current worktree; retrieve linked detail before the action it governs. The user completes [setup](SETUP.md) once.

| Role | Agent name | Responsibilities |
|---|---|---|
| User | n/a | Set product goals and constraints. Answer unresolved product, scope, purchase and credential questions. Start the dispatcher once; notify it when priorities or external facts change. |
| [Dispatcher](dispatcher.md) | `dispatcher` | Act as the Tips technical program manager: prioritize work, prepare eligible tasks, update the board, start and stop pairs, and handle blockers. Do not write code or review changes. |
| [Developer](developer.md) | `team-N-dev` | Implement and verify the issue, open the PR, address findings and fix failed checks. |
| [Tester](tester.md) | `team-N-test` | Review the pushed PR head, run tests or the app, publish approval and confirm the merge. |

## Role procedures

Read your role procedure on launch or recovery. It owns your next action:
[developer](developer.md), [tester](tester.md), or [dispatcher](dispatcher.md).
Before manual browser work, read [browser review](browser-review.md); before posting
a PR review, read the [PR review record](pr-review-record.md).

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
your pane. The only waits are the tester's bounded check and merge waits in the [tester approval procedure](tester.md#approve-and-confirm-the-merge).

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

## Recover task context

After restart or compaction, reread AGENTS, this shared workflow and your role file.
Determine the turn using the table above before using the worktree. Read the issue,
`git status`, `git diff`, `git log origin/main..HEAD`, and the PR and reviews when a
PR exists. Reload each required skill before its next use, then retrieve the
references needed for the next decision. These records establish the current task;
do not reconstruct a prior plan from memory.

For long work, an optional `tmp/dev-state.md` or `tmp/test-state.md` can preserve
useful knowledge that is expensive to reconstruct. Use Goal, Progress, What worked,
What did not, and Next steps to record only the useful current conclusions and
sources, rejected approaches and reasons, expensive observations with output
pointers, and unfinished scope. Include the HEAD at writing and any uncommitted
changes affecting observations. Reuse an adequate task note; if it is elsewhere,
put its path in the per-role file. No installed handoff skill is required. Keep
scratch under `tmp/`, not a shared root `HANDOFF.md` that would dirty the checkout.

Read the note if present, but check mutable facts against current records. It is
fallible scratch, not ownership authority or a second product contract. Durable
contract decisions belong in the existing issue or owning document. If a rationale
or result cannot be recovered, disclose the gap rather than inventing it.

Rerun checks whose relevant results are absent, invalidated or uncertain, and focused
checks needed to settle a consequential doubt. A changed HEAD is a staleness cue,
not automatic invalidation: consider changes to the tested code, configuration,
dependencies, environment and workload. Existing pre-push checks, exact-head review
and provider authorization still apply. Do not repeat costly or external work
that reliable records already establish.

Repeated investigations, unexplained contradictions, or uncertainty about ownership
or verification are cues to reconcile the records. If that fails, report the
concrete blocker and note location through the existing blocker procedure. At a
safe boundary, saving useful state, using the client's native compaction, then
following this recovery route is an option. A note alone does not remove context.
The dispatcher can arrange [client recovery with the user](dispatcher.md#context-recovery).
There is no checkpoint schedule, mandatory note, new handoff gate or automatic reset.

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

### Address findings

1. Developer: fix every P0 and P1. Address each P2 under the [severity rules](#severity).
   Follow [Repair and refactor](../skills/developing-software/references/design-and-change.md#repair-and-refactor).
2. Developer: push and hand off to the tester.
3. Tester: review the changes since the previous review, as the [tester procedure](tester.md#review-the-pushed-head) says for fixes.
   Resolve each thread that is fixed or declined with a reason.
4. Repeat until the approval conditions are met.

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

The dispatcher follows [Resolve blockers](dispatcher.md#resolve-blockers).

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
