# Pair workflow

GitHub records all workflow state: the issue, the PR with its reviews and checks, and [Project 15](https://github.com/users/chenghanlee/projects/15) (`--owner chenghanlee`). Read it when assigned, after a restart and at each handoff. Write decisions, findings and blockers there. Herdr only rings the next agent. [AGENTS.md](../../AGENTS.md) governs engineering; humans do [setup](SETUP.md) once.

| Role | Agent name | Does |
|---|---|---|
| User | n/a | Orders the board, marks tasks Ready and tells the dispatcher, answers product, scope, purchase and credential questions, starts the dispatcher once |
| Dispatcher | `dispatcher` | Updates the board, picks tasks, starts and stops pairs, handles `blocked`. Writes no code and reviews nothing |
| Developer | `team-N-dev` | Implements and verifies the issue, opens the PR, repairs findings and failed checks |
| Tester | `team-N-test` | Reviews the pushed head, runs the tests or the app, approves, publishes and confirms the merge |

## Common path

1. **Dispatcher: tidy and pick.** At startup, after each `done` or `blocked` and when the user says the board changed, read the open PRs, the live pairs (`herdr workspace list`), the worktrees (`git worktree list`) and the latest `main` run. Set Done on merged issues. For an issue with a live pair, keep Blocked while its question is unanswered; otherwise set Active. Leave other statuses as the user set them. Then start the first Ready item in board order for each free slot (`team.max_teams` in [config.toml](config.toml)). Skip an item only when it has an open "blocked by" issue, or when its body and an active issue's body name the same database table, API or data rule.
2. **Dispatcher: record.** After a successful start, set Status Active and Agent on the Project item. End the turn; pairs ring you.
3. **Developer: build.** Use the repository to fill in missing facts in the issue. Implement, verify, push. Open the PR with `Closes #<issue>` and enable auto-merge: `gh pr merge --auto --merge`.
4. **Developer: hand over.** `team.py turn <pr> test`, then stop using the worktree, build and database until your partner rings you.
5. **Tester: review that SHA.** Run the tests; for UI tasks also check the acceptance scenarios by [manual browser review](#rules). Report every P0 and P1 you find in the first review. Before submitting, confirm the worktree is clean and HEAD is still that SHA. If you have any finding, submit the review and run `team.py turn <pr> dev`; otherwise go to step 7.
6. **Both: repair loop.** The developer fixes every P0 and P1, fixes or declines each P2, pushes and hands back. The tester reviews the delta and resolves each thread that is fixed or declined with a reason.
7. **Tester: approve** when no P0 or P1 remains and every thread is resolved: submit and publish the [PR review record](#pr-review-record) without waiting for CI, keep the turn and go to step 9.
8. **GitHub: merge.** Auto-merge needs `checks`, `release`, `tips/independent-review` and resolved threads. The merge closes the issue, the Project sets Done and the remote branch is deleted.
9. **Tester: confirm.** Run `timeout "$TIPS_CHECK_TIMEOUT_SECONDS" gh pr checks <pr> --watch --required` once. Whether it passes, fails or times out, then run `gh pr view <pr> --json state,mergedAt`. Merged: ring the dispatcher `done`. Not merged and a required check failed: `team.py turn <pr> dev`. Otherwise ring the dispatcher `blocked` with the pending check or merge blocker. Do not repeat the watch.
10. **Dispatcher: clean up.** `team.py stop <issue>`, then refill the slot. If a slot stays free because no Ready item can start, tell the user.

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
herdr agent prompt dispatcher "<blocker comment URL> blocked"
```

`start` and `stop` take the issue number; `turn` and the review tools take the PR number. Rerunning `start` keeps a running client and relaunches a missing one. After a handoff is sent, end your turn; the partner's ring arrives as a new prompt. If the send fails, report the exact error: the turn is still yours. The only wait is the tester's in step 9.

No label marks the turn. After a restart, read the PR, the reviews of its head and its required checks. It is the developer's turn if no PR exists, if a required check has failed, or if this head has reviews and the latest is not an LGTM. Otherwise it is the tester's: review an unreviewed head, or finish steps 7 and 9 on an approved one.

## Rules

- **Severity.** Use the first that matches. P0: a feature cannot complete, an unauthorized action succeeds, or stored data is lost or corrupted. P1: an acceptance scenario fails, a required test or check is missing or failing, or the change significantly hurts the user's experience. P2: everything else. The developer fixes it, declines it with a reason, or files one follow-up issue for all deferred P2s.
- **Messages between agents.** Every message starts a turn over the recipient's whole context. Send only these: `team.py turn`, `done`, `blocked`, and the dispatcher's answer to `blocked`. Never send an acknowledgment, a progress or status update, thanks or a reply that only confirms receipt. Put everything the recipient needs in that one message or behind its link.
- **Ringing `blocked`.** First comment on the issue: your agent name, the question or blocker, and its evidence. Then ring the dispatcher with that comment's URL and end your turn. The answer arrives as a ring.
- **Stuck.** Whoever holds the turn rings the dispatcher `blocked` when both of you have answered a finding with evidence and still disagree, or when two fixes leave the same finding failing and you do not agree on the next check. A rerun without a fix is not a fix. Product and scope questions go the same way at once, PR or not.
- **Dispatcher on `blocked`.** Set Status Blocked. Answer a technical question from the reported error and the cited code; ask the user, in your pane, a product or scope question or one you cannot answer. Then record the answer on the issue, set Status Active and ring the agent the comment names.
- **Red `main`.** A developer whose failing check also fails on the latest `main` run rings the dispatcher `blocked` with both run links. The dispatcher finds the merge that broke `main`, opens its revert with `gh pr revert <pr>`, enables auto-merge with `gh pr merge <revert pr> --auto --merge` and asks the user for an owner waiver on the revert PR. Fix forward after the revert merges.
- Use one PR per issue. If the issue needs more than one PR, ring the dispatcher `blocked` and ask for a split.
- The pair shares one worktree and takes turns. Each client has its own database and test port, set at launch; keep them in every test run. Scratch files go only under the worktree's `tmp/`.
- **Manual browser review.** Clients launch with `MIX_ENV=test`, which runs tests but cannot serve a manual session. Run `MIX_ENV=dev PORT="$TIPS_TEST_PORT" unbuffer mix do ecto.create, ecto.migrate, assets.setup, assets.build, phx.server`, drive the app with `agent-browser` and read mail at `/dev/mailbox`. The dev app calls real providers: exercise such a scenario only with the user's authorization on the issue. Stop the server before you hand back or ring.
- Never rewrite published commits: merge `origin/main` when needed; do not rebase or force-push. Source changes happen in pair worktrees, never in the main checkout.
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
