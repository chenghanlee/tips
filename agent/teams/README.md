# Pair workflow

GitHub holds all workflow state: the issue, the PR with its reviews and checks, and [Project 15](https://github.com/users/chenghanlee/projects/15) (`--owner chenghanlee`). Read it when assigned, after a restart and at each handoff. Write decisions, findings and blockers there. Herdr only rings the next agent. [AGENTS.md](../../AGENTS.md) governs engineering; humans do [setup](SETUP.md) once.

| Role | Agent name | Does |
|---|---|---|
| User | n/a | Orders the board, marks tasks Ready, answers product, scope, purchase and credential questions, starts the dispatcher once |
| Dispatcher | `dispatcher` | Keeps the board true, picks tasks, starts and stops pairs, handles `blocked`. Writes no code and reviews nothing |
| Developer | `team-N-dev` | Implements and verifies the issue, opens the PR, repairs P0 and P1 findings, confirms the merge |
| Tester | `team-N-test` | Reviews the pushed head, runs the tests or the app, approves and publishes |

## Common path

```
USER         order the board · mark Ready · start the dispatcher once
DISPATCHER   tidy → pick → team.py start <issue> → set Active
DEVELOPER    code → push → PR with "Closes #<issue>" + auto-merge → team.py turn <pr> test
TESTER       review → findings → team.py turn <pr> dev      (loop until no P0 or P1)
TESTER       LGTM → publish_review.py → team.py turn <pr> dev
GITHUB       checks + status + resolved threads → merge → issue closes → Done
DEVELOPER    confirm the merge → ring the dispatcher "done"
DISPATCHER   team.py stop <issue> → next
```

1. **Dispatcher: tidy and pick.** Compare the board with reality: open PRs, live pairs (`herdr workspace list`), leftover worktrees and the latest `main` run. Start the top Ready task for each free slot (`team.max_teams` in [config.toml](config.toml)). Hold a task back only for a "blocked by" link, or when it names the same table or contract as an active issue.
2. **Dispatcher: record.** After a successful start, set Status Active and Agent on the Project item. End the turn; pairs ring you.
3. **Developer: build.** Fill factual gaps in the issue from the repository. Implement, verify, push. Open the PR with `Closes #<issue>` and enable auto-merge: `gh pr merge --auto --merge`.
4. **Developer: hand over.** `team.py turn <pr> test`, then stop using the tree, build and database until rung.
5. **Tester: review that SHA.** Run the tests; for UI tasks boot the app and check the acceptance scenarios in a browser. Report every P0 and P1 you can find in the first review. Before submitting, confirm the tree is clean and HEAD is still that SHA. Then `team.py turn <pr> dev`.
6. **Both: repair loop.** The developer fixes, pushes and hands back. The tester reviews the delta and resolves its threads once fixed or declined.
7. **Tester: approve** when no P0 or P1 remains: the [PR review record](#pr-review-record), then `team.py turn <pr> dev`.
8. **GitHub: merge.** Auto-merge needs `checks`, `release`, `tips/independent-review` and resolved threads. The merge closes the issue, the Project sets Done and the remote branch is deleted.
9. **Developer: confirm.** `gh pr checks <pr> --watch --required`, then `gh pr view <pr> --json state,mergedAt`. Ring `done` only on a confirmed merge; otherwise repair or report the actual blocker.
10. **Dispatcher: clean up.** `team.py stop <issue>`, then refill the slot. Tell the user which Backlog items are one edit from Ready.

## Commands

Run from the repository root of your checkout.

```
agent/teams/team.py start <issue>    dispatcher, in the main checkout: branch task/<issue> from origin/main,
                                     worktree .worktrees/<issue>, dependencies, Dexter, developer and tester
agent/teams/team.py turn <pr> test   developer: refuses unless the tree is clean and HEAD is the PR head;
                                     rings the tester with the PR URL and SHA
agent/teams/team.py turn <pr> dev    tester: never refuses; reports a checkout problem; rings the developer
agent/teams/team.py stop <issue>     dispatcher: refuses dirty, unmerged or foreign-owned work; stops the clients
                                     and Dexter, drops the pair's databases, removes the worktree and branch
herdr agent prompt dispatcher "<issue or PR URL> done"
herdr agent prompt dispatcher "<issue or PR URL> blocked: <question>"
```

`start` and `stop` take the issue number; `turn` and the review tools take the PR number. Rerunning `start` keeps a running client and relaunches a missing one. After a ring, end your turn: the reply arrives as a new prompt. The only wait is the developer's in step 9.

No label marks the turn. After a restart, read the PR: a head newer than the last review is the tester's turn, otherwise the developer's.

## Rules

- **Severity.** P0: a feature does not work, or authorization or data integrity is broken. P1: significantly hurts the user's experience, or a required acceptance test or local check is missing or failing. P2: minor; fix if trivial, decline with a reason, or file one batched follow-up issue.
- **Stuck.** A dispute unresolved after one round of evidence, or two failed repairs of one finding with no agreed next check: ring the dispatcher `blocked` with the question. Product and scope questions go the same way, at any time, PR or not.
- **Dispatcher on `blocked`.** One diagnostic pass if the question is technical; otherwise a clear question to the user. Set Status Blocked.
- **Red `main`.** Revert the merge that broke it, then fix forward. A developer whose CI is red for reasons outside its change checks `main` and rings the dispatcher.
- One issue, one PR; split bigger issues. The developer enables auto-merge; the tester publishes the status.
- The pair shares one worktree and takes turns. Each client has its own database and test port, set at launch; keep them in every test run. Scratch files go only under the worktree's `tmp/`.
- Published commits are fixed: merge `origin/main` when you need it, never rebase or force-push. Source changes happen in pair worktrees, never in the main checkout.
- Provider settings are read by path from the main checkout's `.env` (`TIPS_PROVIDER_ENV_FILE`). Never copy secrets into a worktree. Real-provider tests need the user's authorization on the issue.

## PR review record

Applies to every PR, pair or solo.

- Agents share one GitHub identity, so native approval does not work. Submit one `COMMENT` review per pass on the exact head, findings inline:

  ```bash
  gh api "repos/{owner}/{repo}/pulls/$PR/reviews" --input tmp/review.json --jq .html_url
  ```

  `tmp/review.json`: `{"commit_id": "<head SHA>", "event": "COMMENT", "body": "...", "comments": [{"path": "...", "line": 12, "body": "..."}]}`.
- An approval has `LGTM` alone on line one and the role and session on line two. Then publish the status: `agent/teams/publish_review.py --pr <pr> --sha <sha> --record <review URL>`. It refuses a wrong head, a wrong record or unresolved threads.
- `agent/teams/pr_review.py list <pr>` prints the recent reviews and every unresolved thread. The reviewer who opened a thread resolves it with `agent/teams/pr_review.py resolve <thread>`.
- `--owner-waiver` only on the user's explicit instruction.
