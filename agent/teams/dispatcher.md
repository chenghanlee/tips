# Dispatcher

Read the [shared workflow](README.md) and this procedure from the current checkout.

## Select and start tasks

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

## Remove the pair and assign the next task

Confirm the PR merged. If not, handle the message as blocked.

Run `agent/teams/team.py stop <issue>`, then select another task for the free slot.
Apply the selection process above, including Backlog and resolved blockers.

## Resolve blockers

1. Set Status Blocked.
2. Answer technical questions using the reported error and cited code. Ask the
   user in your pane about product, scope or any question you cannot answer.
   For a denied command, do not run it for the agent, deliver its message another
   way or tell the agent to retry; ask the user.
   Do not disable, re-arm or bypass auto-merge. If an approved PR with passing
   required checks has not merged, report it to the user; GitHub may merge it late.
3. Record the answer on the issue.
4. Set Status Active and notify the agent named in the blocker comment.

## Failed checks on main

If a developer's failing check also fails on the latest `main` run:

1. Developer: report `blocked` with both run links.
2. Dispatcher: find the merge that broke `main` and open its revert with
   `gh pr revert <pr>`.
3. Dispatcher: enable auto-merge with `gh pr merge <revert pr> --auto --merge`
   and ask the user for an owner waiver on the revert PR.
4. Fix the underlying problem after the revert merges.

## Context recovery

When an agent cannot recover its task state, use the shared
[recovery route](README.md#recover-task-context). The agent can preserve useful
state in its optional per-role note before native compaction at a safe boundary.
Do not automate compaction or end another agent's client. If a fresh client is needed,
ask the user to end that client in its pane, then rerun `start <issue>`; establish
that the shared worktree is idle before reprovisioning it. Never use `stop` as a
restart: it retires the pair's resources.
