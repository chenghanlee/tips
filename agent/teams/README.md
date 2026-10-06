# Pair workflow

GitHub holds all workflow state: the issue, the PR with its reviews and checks, and [Project 15](https://github.com/users/chenghanlee/projects/15) (`--owner chenghanlee`). Read it when assigned, after a restart and at each handoff. Write decisions, findings and blockers there. Herdr only rings the next agent. [AGENTS.md](../../AGENTS.md) governs engineering; humans do [setup](SETUP.md) once.

| Role | Agent name | Does |
|---|---|---|
| User | n/a | Orders the board, marks tasks Ready, answers product, scope, purchase and credential questions, starts the dispatcher once |
| Dispatcher | `dispatcher` | Keeps the board true, picks tasks, starts and stops pairs, handles `blocked`. Writes no code and reviews nothing |
| Developer | `team-N-dev` | Implements and verifies the issue, opens the PR, repairs P0 and P1 findings, confirms the merge |
| Tester | `team-N-test` | Reviews the pushed head, runs the tests or the app, approves and publishes |

## Common path

1. **Dispatcher: tidy and pick.** At startup and after each `done` or `blocked`, read the open PRs, the live pairs (`herdr workspace list`), the worktrees (`git worktree list`) and the latest `main` run. Set Done on merged issues. For an issue with a live pair, keep Blocked while its question is unanswered; otherwise set Active. Leave other statuses as the user set them. Then start the first Ready item in board order for each free slot (`team.max_teams` in [config.toml](config.toml)). Skip an item only when it has an open "blocked by" issue, or when its body and an active issue's body name the same database table, API or data rule.
2. **Dispatcher: record.** After a successful start, set Status Active and Agent on the Project item. End the turn; pairs ring you.
3. **Developer: build.** Fill factual gaps in the issue from the repository. Implement, verify, push. Open the PR with `Closes #<issue>` and enable auto-merge: `gh pr merge --auto --merge`.
4. **Developer: hand over.** `team.py turn <pr> test`, then stop using the tree, build and database until rung.
5. **Tester: review that SHA.** Run the tests; for UI tasks boot the app and check the acceptance scenarios in a browser. Report every P0 and P1 you find in the first review. Before submitting, confirm the tree is clean and HEAD is still that SHA. If a P0 or P1 remains, submit the findings and run `team.py turn <pr> dev`; otherwise go to step 7.
6. **Both: repair loop.** The developer fixes, pushes and hands back. The tester reviews the delta and resolves its threads once fixed or declined.
7. **Tester: approve** when no P0 or P1 remains: the [PR review record](#pr-review-record), then `team.py turn <pr> dev`.
8. **GitHub: merge.** Auto-merge needs `checks`, `release`, `tips/independent-review` and resolved threads. The merge closes the issue, the Project sets Done and the remote branch is deleted.
9. **Developer: confirm.** Run `timeout "$TIPS_CHECK_TIMEOUT_SECONDS" gh pr checks <pr> --watch --required` once, then `gh pr view <pr> --json state,mergedAt`. Ring `done` only when the PR is merged. Otherwise repair a failed check, or ring `blocked` with the pending check or merge blocker.
10. **Dispatcher: clean up.** `team.py stop <issue>`, then refill the slot. Tell the user which Backlog items are one edit from Ready.

## Commands

Run from the repository root of your checkout.

```
agent/teams/team.py start <issue>    dispatcher, in the main checkout: branch task/<issue> from origin/main,
                                     worktree .worktrees/<issue>, dependencies, Dexter, developer and tester
agent/teams/team.py turn <pr> test   developer: refuses unless the tree is clean and HEAD is the PR head;
                                     rings the tester with the PR URL and SHA
agent/teams/team.py turn <pr> dev    tester: rings the developer even when the tree is dirty or HEAD differs,
                                     and reports that mismatch
agent/teams/team.py stop <issue>     dispatcher: refuses dirty, unmerged or foreign-owned work; stops the clients
                                     and Dexter, drops the pair's databases, removes the worktree and branch
herdr agent prompt dispatcher "<issue or PR URL> done"
herdr agent prompt dispatcher "<issue or PR URL> blocked: <question>"
```

`start` and `stop` take the issue number; `turn` and the review tools take the PR number. Rerunning `start` keeps a running client and relaunches a missing one. After a handoff is sent, end your turn; the partner's ring arrives as a new prompt. If the send fails, report the exact error: the turn is still yours. The only wait is the developer's in step 9.

No label marks the turn. After a restart it is the developer's turn if no PR exists or the latest review's `commit_id` equals the PR head; otherwise it is the tester's.

## Rules

- **Severity.** Use the first that matches. P0: a feature cannot complete, an unauthorized action succeeds, or stored data is lost or corrupted. P1: an acceptance scenario fails, a required test or check is missing or failing, a new test catches no defect that the existing tests miss, or the change significantly hurts the user's experience. P2: everything else; it never blocks approval. The developer fixes it, declines it with a reason, or files one follow-up issue for all deferred P2s.
- **Stuck.** Whoever holds the turn rings the dispatcher `blocked` with the question and the evidence when both of you have answered a finding with evidence and still disagree, or when two fixes leave the same finding failing and you do not agree on the next check. A rerun without a fix is not a fix. Product and scope questions go the same way at once, PR or not.
- **Dispatcher on `blocked`.** Set Status Blocked. Answer a technical question from the reported error and the cited code; send a product or scope question, or one you cannot answer, to the user. Then record the answer on the issue, set Status Active and ring the agent that asked.
- **Red `main`.** A developer whose failing check also fails on the latest `main` run rings the dispatcher `blocked` with both run links. The dispatcher finds the merge that broke `main`, opens its revert with `gh pr revert <pr>` and asks the user for an owner waiver on the revert PR. Fix forward after the revert merges.
- One issue, one PR. If the issue needs more than one PR, ring the dispatcher `blocked` and ask for a split.
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
