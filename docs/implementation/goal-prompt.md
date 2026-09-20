# Goal: implement every issue in the Tips project

All four agents read this file. Process rules are in [agent-workflow.md](agent-workflow.md). Engineering guidance is in `AGENTS.md`. When this file and those files disagree, this file is wrong: fix it, do not improvise.

## Goal

Every issue in [GitHub Project 15](https://github.com/users/chenghanlee/projects/15) is **Done** or **Blocked on the user**. Child issues created during the run count. The loop stops when nothing else can move.

## Agents

| Herdr name | Pane | Role |
|---|---|---|
| `fable-tpm` | wJ:p1 | Technical program manager. Runs this loop. |
| `astra` | wJ:p2 | Implementer (Codex). |
| `opus` | wJ:p9 | Per-commit correctness reviewer. |
| `fable-tech-lead` | wJ:p8 | Design reviewer, gate owner, merger. |

Address agents by Herdr name. Pane IDs are used only in the rename block below and in Herdr commands that need them. Names are cleared when an agent exits or resets (`/clear` and `/new` both clear the name), so `fable-tpm` re-applies them at the start of every iteration and right after every reset in step 3. An agent that starts a fresh session mid-task re-applies its own name first:

```bash
herdr agent rename wJ:p1 fable-tpm
herdr agent rename wJ:p2 astra
herdr agent rename wJ:p9 opus
herdr agent rename wJ:p8 fable-tech-lead
```

## Communication

- **Short messages** go directly over Herdr: `herdr agent prompt <name> "<text>" --wait`.
- **Long exchanges** (design challenges, review feedback with code, brainstorms) go in a shared file: `docs/implementation/communication/<YYYY-MM-DD>-<agent_1>-<agent_2>-<issue>.md` in the main checkout. The folder is gitignored. Send the path over Herdr; the receiver reads the file.
- **Durable records** are GitHub comments on the issue or PR, in the templates from agent-workflow.md. Communication files are scratch. If it is not on GitHub, it did not happen.
- `fable-tpm` tracks progress from GitHub, not from pane output.

## Loop

`fable-tpm` repeats this until the goal is met.

**Step 0.** If the `main` checkout has uncommitted changes, land them first: `fable-tpm` opens an issue, commits them on a `task/<issue>-<slug>` branch, and the PR is reviewed and merged like any other (Opus per commit, Fable-Tech-Lead whole PR). Never start task work from a dirty base.

**1. Reconcile.** Re-apply Herdr names. Read open PRs, failed checks, Active and Blocked issues and their latest comments. Fix any state that disagrees with reality. If a PR is mid-review, resume at the step it is in.

**2. Select.** Pick the next issue on the critical path: P0, then P1, then P2, and so on, respecting issue dependencies. If it is Backlog, draft the readiness refinement on the issue, ask `fable-tech-lead` for the one-line "ready" confirmation, then move it to Ready. If nothing is Ready and nothing can be made Ready without the user, go to step 8.

**3. Reset and dispatch.** Send `/new` to `astra`, `/clear` to `opus` and `fable-tech-lead`; wait until each is idle, then re-apply the Herdr names. Post the dispatch comment on the issue. Move it to Active, set Agent = `astra`. Prompt `astra` with the issue URL and the dispatch comment.

**4. Implement (Astra).** Create `task/<issue>-<slug>` from fetched `origin/main` in a worktree under `.worktrees/`. Open a draft PR. Write the failing integration test for the acceptance scenario first, then make it pass. Push cohesive commits. After each push, send `opus` the SHA and PR URL over Herdr.

**5. Review commits (Opus).** For each SHA: read the commit in a read-only worktree at that SHA, run the relevant checks, post the per-commit verdict on the PR, reply to `astra` with the verdict. Astra repairs P0 immediately and P1 in the next commit. After three rounds on one finding, tell `fable-tech-lead`; Astra does root-cause analysis before trying again.

**6. Review PR (Fable-Tech-Lead).** When every commit has an Opus verdict with no open P0/P1, Astra marks the PR ready for review, resolves the review threads its fix commits addressed, and reports the PR complete to `fable-tpm` and `fable-tech-lead`. `fable-tpm` moves the issue to In review. Fable-Tech-Lead then reads the whole diff against the current base in a read-only worktree at the head SHA. Challenge the design with a concrete alternative and tradeoff. If rejected, `fable-tpm` moves the issue back to Active, Astra reworks on the same branch, and the loop returns to step 5. After two rejections, root-cause analysis is recorded on the issue before a third round. If accepted: post the review record, set `tips/independent-review` on the head SHA linking the record, merge with a merge commit, run integrated checks on `main`, record the merge SHA on the issue.

**7. Close.** `fable-tpm` moves the issue to Done, clears Agent, removes the worktree, and prints a one-paragraph summary in pane wJ:p1: issue, merge SHA, open blockers, next issue.

**8. Report and continue.** If the set of Blocked-on-user issues changed, update `docs/implementation/status.md` (this is the one file the user reads). `main` is protected, so `fable-tpm` commits it on a `task/<issue>-status-<YYYY-MM-DD>` branch under the standing "Status report" issue (create it on first use, not in Project 15), opens a PR, Opus reviews the commit, and Fable-Tech-Lead sets the status and merges. Return to step 1. If every issue is Done or Blocked on the user, stop and say so.

## Escalation to the user

Stop and ask the user only for:

- provider credentials, accounts, hosting or domain decisions;
- purchases;
- product scope changes;
- a review disagreement still unresolved after the rejection bounds above.

Everything else is decided by the responsible role with evidence. A blocked issue is marked Blocked with the prerequisite, role and next action, and the loop moves to the next unblocked issue.

**Permission dialogs.** When `astra`, `opus` or `fable-tech-lead` is `blocked` on a tool-permission prompt, `fable-tpm` inspects it. Approve file, test and git actions inside the repo or its worktrees. Anything touching credentials, purchases, network services beyond GitHub, or paths outside the repo: stop and ask the user.

## Engineering guidance

The following repeats the Software Design and Testing sections of `AGENTS.md` for convenience. `AGENTS.md` is authoritative and also holds the Problem Solving, Code Review, Writing and Responses rules, which every agent applies.

- Use Elixir and Phoenix Framework idioms, standards and conventions.
- Use proven architecture, standards and conventions from widely used software similar to Tips.
- Strive for simple, working, elegant solutions. Elegant solutions make complex things seem easy and obvious. Choose simplicity over elegance when they conflict.
- Build an MVP for fast iteration and product-market fit. No unnecessary enterprise complexity. No backwards compatibility.
- Accept necessary complexity when it makes the user's experience simpler. Do not make the implementation look simple by pushing its complexity onto the user. Apply this across architecture, backend, data model and frontend.
- Perfection is achieved not when there is nothing more to add, but when there is nothing left to take away.
- Testing trophy, integration first. TDD means writing the failing ExUnit integration test for the acceptance scenario before the code. Unit tests only for pure logic with wide blast radius. End-to-end tests only at milestone gates.

## Accepted tradeoff

Fable-Tech-Lead reviews design at PR time, not before coding. A design rejection can discard Opus-reviewed commits. This was chosen deliberately to keep one review surface per role.
