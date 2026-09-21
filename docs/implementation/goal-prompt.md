# Goal: implement every issue in the Tips project

Every agent reads this file. Process rules are in [agent-workflow.md](agent-workflow.md). Engineering guidance is in `AGENTS.md`. When this file and those files disagree, this file is wrong: fix it, do not improvise.

## Goal

Every issue in [GitHub Project 15](https://github.com/users/chenghanlee/projects/15) is **Done** or **Blocked on the user**. Child issues created during the run count. The run stops when nothing else can move.

## Structure

One **lead TPM** and up to **five teams** work at the same time. The lead TPM assigns issues, checks file overlap, runs the merge queue, creates and retires teams, keeps `status.md`, and is the only agent that talks to the user. Each team runs the team loop below for one issue at a time.

| Herdr name | Workspace label | Kind and launch | Role |
|---|---|---|---|
| `lead-tpm` | `tips-master` | `claude --effort high` | Lead TPM. Oversight, assignment, merge queue, reporting. |
| `team-N-tpm` | `tips-team-N` | `claude --effort medium` | Team TPM. Runs the team loop, readiness, dispatch, Project state, talks to `lead-tpm`. |
| `team-N-lead` | `tips-team-N` | `codex -m gpt-6-astra -c model_reasoning_effort=high` | Tech lead. Readiness amendments, whole-PR design review, `tips/independent-review`, merge. |
| `team-N-dev` | `tips-team-N` | `codex -m gpt-5.6-sol -c model_reasoning_effort=xhigh -C <worktree>` | Developer. Implements one issue with integration-first TDD in its worktree. |
| `team-N-test` | `tips-team-N` | `claude --model opus --effort xhigh` | Tester. Adversarial per-commit review; runs the tests and checks itself. |

The developer is always Codex Sol. `gpt-5.6-sol` is the Sol model this Codex account offers; `gpt-6-sol` returns a 400 on it. Change the model only with the user's decision, in both this table and `scripts/task_worktree.sh`.

`N` is 1 to 5. Every name is unique across the Herdr session, so any agent can address any other by name from any workspace. Names are cleared when an agent exits or resets (`/clear` and `/new` both clear the name). The team TPM re-applies its team's names at the start of every iteration and right after every reset. An agent that starts a fresh session re-applies its own name first:

```bash
herdr agent rename <pane-id> team-N-<role>
```

Pane IDs come from `herdr agent list` and `herdr pane list --workspace <id>`. Never hard-code them in documents or scripts.

### Team resources

Team N owns a fixed port and database block, independent of the issue. Reuse it for every issue the team works on.

| Member | Ports | Database suffix |
|---|---|---|
| `team-N-dev` | `TIPS_TEST_PORT=41N0` | `TIPS_DB_SUFFIX=_tN` |
| `team-N-test` | `TIPS_TEST_PORT=41N1` | `TIPS_DB_SUFFIX=_tNr` |
| `team-N-lead` | `TIPS_TEST_PORT=41N2` | `TIPS_DB_SUFFIX=_tNl` |

Always with `PGPORT=5433 MIX_ENV=test`. Example for team 2's tester: `PGPORT=5433 TIPS_DB_SUFFIX=_t2r TIPS_TEST_PORT=4121 MIX_ENV=test`. The lead TPM uses `_lead` and port `4190` for its own checks.

## Communication

- **Inside a team**, members message each other directly: `herdr agent prompt <name> "<text>"`. Add `--wait` only for a short reply.
- **Between teams**, only TPMs talk: `team-1-tpm` to `team-2-tpm`. Handoffs and questions are fine. Anything that changes scope, order, ownership or files goes through `lead-tpm`.
- **Team to lead**: the team TPM messages `lead-tpm` for assignment, own-list approval, merge slots, blockers and completion. The lead TPM messages the team TPM only.
- **Long exchanges** (design challenges, review feedback with code) go in a shared file: `docs/implementation/communication/<YYYY-MM-DD>-<agent_1>-<agent_2>-<issue>.md` in the main checkout. The folder is gitignored. Send the path over Herdr.
- **Durable records** are GitHub comments on the issue or PR, in the templates from agent-workflow.md. Communication files are scratch. If it is not on GitHub, it did not happen.
- TPMs track progress from GitHub, not from pane output.
- Only `lead-tpm` talks to the user. Team TPMs send user-facing blockers to `lead-tpm`.

## Main checkout rule

Nobody switches branches, commits or edits files in the main checkout. Every commit, including `status.md` and step-0 landings, happens in a worktree under `.worktrees/`. Claude agents run with the main checkout as their cwd and read it only. Codex developers run in their task worktree. Testers and tech leads read PR heads in their own detached worktrees, named `.worktrees/<issue>-review-team-N-<role>`, and remove them after the merge.

## Lead TPM loop

`lead-tpm` runs this on every message from a team TPM and at least every 10 minutes on a timer. The timer tick exists to catch a stuck team or an unrecoverable error that nobody reported.

**L1. Reconcile.** Read open PRs, failed checks, Active, In review and Blocked issues and their latest comments. Read `herdr agent list`. Fix Project state that disagrees with GitHub. A team whose agents are `blocked` on a permission prompt, `unknown`, or silent for more than 20 minutes with no GitHub progress is inspected: read its panes, then message its TPM. Reassign ownership only after inspecting branch and worktree evidence, and only explicitly.

**L2. Assign.** For each idle team, pick the next issue on the critical path whose prerequisites are Done: P0, then P1, then P2, and so on. Prefer an issue in the package the team last worked in. Never assign an issue whose likely files overlap an active issue. Message the team TPM with the issue URL. If no assignable issue exists for a team, retire it (L5).

**L3. Approve own lists.** When a team TPM sends an own list after readiness, compare it against every active issue's own list. No overlap allowed. Shared files (`mix.exs`, `mix.lock`, `.github/workflows/*`, `config/*`, `test/test_helper.exs`, `test/support/**`, `lib/tips_web/router.ex`, `priv/repo/seeds.exs`, `docs/design/**`) need a one-line reservation in the own list, which the lead TPM approves or moves to another issue. Reply "own-list approved" or name the conflict and the issue that holds it.

**L4. Merge queue.** Keep a first-in-first-out queue of PRs whose whole-PR review accepted. Grant one merge slot at a time. The team tech lead updates its branch from `main`, waits for green `checks` and `release`, merges, runs integrated checks on `main`, records the merge SHA, and reports back. Then grant the next slot. Other teams do not update their branches until their slot, unless the lead TPM tells them a merged change affects them. If integrated checks on `main` fail, stop the queue, and route the repair to the team that merged.

**L5. Teams.** Start with two teams. Create a team when an assignable issue exists with no overlap risk and fewer than five teams are up. Retire a team when it has been idle for a full tick with nothing assignable. Creating a team: `herdr workspace create --label tips-team-N --cwd <main checkout> --no-focus`, split the root pane into four, start the four agents from the Structure table with `herdr agent start <name> --kind <claude|codex> --pane <id> --timeout 120000 -- <launch args>`, then brief the TPM with this file's path and the team number. Retiring a team: ask its TPM to confirm no open work, then close the workspace.

**L6. Report.** If the set of Blocked-on-user issues changed, update `docs/implementation/status.md` on a `task/<issue>-status-<YYYY-MM-DD>` branch in a worktree under the standing "Status report" issue, open a PR, and ask a team TPM to have its tester and tech lead review and merge it through the queue. Tell the user only what needs the user: credentials, purchases, hosting, product scope, and review disagreements past their bounds. If every issue is Done or Blocked on the user, say so and stop.

## Team loop

`team-N-tpm` repeats this for each issue `lead-tpm` assigns.

**1. Reconcile.** Re-apply the team's Herdr names. Read the assigned issue, its open PR, failed checks and latest comments. If a PR is mid-review, resume at the step it is in.

**2. Readiness.** If the issue is Backlog, draft the readiness refinement on the issue: actual entry points, settled signatures, named tests, runnable commands, the team's port and database block, and the own list. Ask `team-N-lead` for the one-line "ready" confirmation with amendments. Send the final own list to `lead-tpm` and wait for "own-list approved". Then move the issue to Ready.

**3. Reset and dispatch.** From the main checkout, run `scripts/task_worktree.sh <issue>-<slug> --team N --pane <dev-pane-id>` to create or reuse the task branch, provision its Codex config and skills link, and print the developer start command and the team's environment block. Identical config is left unchanged; inspect any differing config before using `--force`. Send `/exit` to `team-N-dev`, confirm with `herdr pane get <dev-pane-id>` that the pane is back at the shell, then run the printed start command. Send `/clear` to `team-N-test` and `/new` to `team-N-lead`, wait until each is idle, then re-apply the team's names. Post the dispatch comment on the issue, recording the base SHA for a new branch or the existing base and head for resumed work. Move it to Active, set Agent = `team-N-dev`. Prompt `team-N-dev` with the issue URL and the dispatch comment. Brief `team-N-test` and `team-N-lead` with the issue URL, the team names, and their environment blocks.

**4. Implement (developer).** The branch and worktree already exist; the developer owns the worktree after provisioning. Before coding, run `codex mcp get elixir-lsp --json` from the task worktree and verify that `cwd` is its absolute path. Open a draft PR. Write the failing integration test for the acceptance scenario first, then make it pass. Push cohesive commits. After each push, send `team-N-test` the SHA and PR URL over Herdr.

**5. Review commits (tester).** For each SHA: read the commit in a read-only worktree at that SHA, run the relevant checks with the tester's environment block, post the per-commit verdict on the PR, reply to the developer with the verdict. The developer repairs P0 immediately and P1 in the next commit. After three rounds on one finding, tell `team-N-lead`; the developer does root-cause analysis before trying again. Browser evidence is the CI `checks` run on the SHA; do not install a browser.

**6. Review PR (tech lead).** When every commit has a tester verdict with no open P0/P1, the developer marks the PR ready for review, resolves the review threads its fix commits addressed, and reports the PR complete to `team-N-tpm` and `team-N-lead`. The team TPM moves the issue to In review. The tech lead reads the whole diff against the current base in a read-only worktree at the head SHA. Challenge the design with a concrete alternative and tradeoff. If rejected, the team TPM moves the issue back to Active, the developer reworks on the same branch, and the loop returns to step 5. After two rejections, root-cause analysis is recorded on the issue before a third round. If accepted: post the review record, set `tips/independent-review` on the head SHA linking the record, then ask `lead-tpm` for a merge slot. With the slot: update the branch from `main`, wait for green checks, merge with a merge commit, run integrated checks on `main`, record the merge SHA on the issue, tell `lead-tpm`.

**7. Close.** The team TPM moves the issue to Done, clears Agent, removes the task worktree, deletes the merged local branch, asks the tester and tech lead to remove their review worktrees and drop their test databases, and reports to `lead-tpm`: issue, merge SHA, open blockers. Then wait for the next assignment.

## Escalation

A team TPM stops its loop and messages `lead-tpm` for:

- provider credentials, accounts, hosting or domain decisions;
- purchases;
- product scope changes;
- a review disagreement still unresolved after the rejection bounds above;
- an own-list conflict, a shared-file change, or a merged change from another team that breaks its branch.

Everything else is decided by the responsible role with evidence. A blocked issue is marked Blocked with the prerequisite, role and next action, and the team asks `lead-tpm` for a new assignment.

**Permission dialogs.** When a team member is `blocked` on a tool-permission prompt, the team TPM inspects it. Approve file, test and git actions inside the repo or its worktrees. Anything touching credentials, purchases, network services beyond GitHub, or paths outside the repo: stop and send it to `lead-tpm`, who asks the user. When a team TPM is blocked, `lead-tpm` inspects it the same way.

## Engineering guidance

The following repeats the Software Design and Testing sections of `AGENTS.md` for convenience. `AGENTS.md` is authoritative and also holds the Problem Solving, Code Review, Writing and Responses rules, which every agent applies.

- Use Elixir and Phoenix Framework idioms, standards and conventions.
- Use proven architecture, standards and conventions from widely used software similar to Tips.
- Strive for simple, working, elegant solutions. Elegant solutions make complex things seem easy and obvious. Choose simplicity over elegance when they conflict.
- Build an MVP for fast iteration and product-market fit. No unnecessary enterprise complexity. No backwards compatibility.
- Only accept necessary complexity when it makes the user's experience simpler. Do not make the implementation look simple by pushing its complexity onto the user. Apply this across architecture, backend, data model and frontend.
- Perfection is achieved not when there is nothing more to add, but when there is nothing left to take away.
- Testing trophy, integration first. TDD means writing the failing ExUnit integration test for the acceptance scenario before the code. Unit tests only for pure logic with wide blast radius. End-to-end tests only at milestone gates.

## Accepted tradeoffs

- The tech lead reviews design at PR time, not before coding. A design rejection can discard tester-reviewed commits. One review surface per role.
- Merges are serialized through the lead TPM's queue. Each merge costs one branch update and one CI run for the merging team. This replaces a hosted merge queue, which the repository plan does not offer.
- Issues with overlapping files never run in parallel. Throughput is bounded by independent work, not by team count.
