# Implementing Tips with agents

This is the operating agreement for the agents that build Tips. Product requirements remain in the technical designs. Engineering guidance is in `AGENTS.md`. Runtime wiring for the current run (names, workspaces, steps, event messages, communication files) is in [goal-prompt.md](goal-prompt.md). [GitHub issues](https://github.com/chenghanlee/tips/issues) hold current task requirements and evidence; the [Tips project](https://github.com/users/chenghanlee/projects/15) holds scheduling state. Refine current issues in GitHub. When a contract changes, the tech lead that changed it links that decision from every affected Backlog issue so readiness refinement sees it.

## Roles

One lead TPM oversees up to five teams. Each team has four members.

| Role | Agent | Owns |
|---|---|---|
| Lead TPM (`lead-tpm`) | Claude | Issue assignment to teams, own-list overlap checks and shared-file reservations, the merge queue, team creation and retirement, Blocked-on-user tracking, `status.md`, all communication with the user. |
| Team TPM (`team-N-tpm`) | Claude | The team steps for one issue at a time: readiness refinement, dispatch, Project Status and Agent fields, handoffs, communication with `lead-tpm` and other team TPMs. |
| Tech lead (`team-N-lead`) | Codex | Technical contracts, readiness amendments and path narrowing, whole-PR adversarial design review, the `tips/independent-review` status, the merge in its granted slot, integrated checks on `main`. |
| Developer (`team-N-dev`) | Codex | Implementation of one issue with integration-first TDD, its branch, worktree and PR. |
| Tester (`team-N-test`) | Claude | Adversarial per-commit correctness review of pushed commits, running the tests and checks itself, browser evidence from CI. |

The user decides material product changes, purchases, provider credentials, hosting and public launch. Agents handle routine implementation choices and handoffs themselves.

Within a team, work is serial: one issue in implementation at a time. The developer may keep working on the same issue while the tester reviews an earlier commit. The developer does not start the next issue until the current PR is merged. Across teams, work is parallel: up to five issues at once, never two with overlapping files. Nobody reviews or merges their own change. Reviewers work from the issue, code and evidence, not from the implementer's conversation.

## Task readiness

The lead TPM assigns issues on the critical path (P0, then P1, then P2, and so on) whose prerequisites are Done, preferring the package the team last worked in. It never infers that a closed issue's dependent gate passed without its evidence. Before assigning, the lead TPM reconciles open PRs, failed checks, Active and Blocked issues and their latest handoffs in GitHub, and prioritizes repairs and reviews that unblock integration.

Packages are parent issues, not coding assignments. Each coding issue is one bounded change that a fresh agent can understand, implement, test and repair in one session. A user story may need several such issues; internal contracts and operational checks need not pretend to be user stories.

The team TPM drafts the readiness refinement. The team tech lead confirms it with a one-line "ready" comment on the issue, with amendments where needed. The team TPM then sends the own list to the lead TPM; after "own-list approved" it moves the issue from Backlog to Ready. All of these must be true:

- Prerequisites are integrated and their required checks passed. A contract or probe result resolves any open technical choice needed by this task.
- The issue states one outcome, explicit exclusions, exact owning design sections, acceptance scenarios and relevant failure and race cases.
- Code exists for any referenced entry points. The tech lead has narrowed anticipated module areas to actual files, signatures, fixtures and runnable verification commands. Agents must not guess paths during dispatch.
- The own list names every file the task may change. It does not overlap any active issue's own list. Shared files carry a one-line reservation approved by the lead TPM.
- The scope fits a fresh session, including reading, testing and repair headroom. Split discovery from implementation when uncertainty dominates. Split by behavior or invariant, never by line count.
- Required test environment or provider access is available, or the issue explicitly delivers only a local contract and its real-provider gate is a separate Blocked issue.

Do not make the developer reread all design and review history. Supply the task's owning sections and a short list of cross-cutting invariants (admission, visibility, lock order, transactional effects) that actually apply.

A team TPM may create child issues when a task must be split, and tells the lead TPM. The goal covers every issue in the project, including children created during the run.

## Issue and project state

Use one Project Status field: **Backlog → Ready → Active → In review → Done**, with **Blocked** available from any unfinished state. Failed review returns to Active for repair. Blocked issues name the missing prerequisite, the responsible role and the next concrete action. Waiting on a dependency in Backlog is normal, not an incident. Issue comments record dispatch, handoff, review and evidence. The Project Agent field holds the Herdr agent name of the current owner (`team-N-dev` while Active). GitHub assignees identify accountable humans, never fabricated agent accounts.

An issue closes only after its required result is integrated and verified. Closing a parent requires all mandatory children and package acceptance evidence. A milestone gate closes only against one integrated revision with its E2E evidence; sums of isolated task reports do not pass a gate. Failed or unavailable checks are failures or blockers, never passes. The team TPM updates issue and project state at dispatch, at handoff, when the PR enters whole-PR review (In review), when whole-PR review rejects it (back to Active), and at merge.

## Git

Use protected `main`, short-lived `task/<issue>-<slug>` branches and one worktree per active coding issue under `.worktrees/`. Nobody switches branches, commits or edits files in the main checkout; every commit happens in a worktree. At dispatch, the team TPM runs `scripts/task_worktree.sh <issue>-<slug> --team N --pane <dev-pane-id>` from the main checkout to create the branch and provision the worktree from fetched `origin/main`, then records its base SHA. An existing task worktree is reused without resetting its branch. The team TPM restarts Codex in that worktree as described in [goal-prompt.md](goal-prompt.md). The developer owns the worktree from then on and verifies its MCP workspace before coding. Open a draft PR early and one PR per bounded change. The developer marks it ready for review when every commit has a tester verdict with no open P0/P1. The developer resolves a review thread only after the fix commit has its tester verdict; the reviewer reopens it if the fix is wrong. Link its issue with `Closes #number` only when that PR completes the issue. Partial work uses `Refs #number`.

The developer owns its worktree. The tester and tech lead read the PR head in their own read-only worktrees. Nobody edits another agent's worktree. Shared files (dependency manifests, router, supervision and config, CI, test helper and support, seeds, design docs) change only under a reservation in the own list that the lead TPM approved; a task can own a small shared-file change.

Commit cohesive changes and run the relevant checks before pushing. Unreviewed local commits may be reorganized before first push. Once pushed, a SHA is fixed: never rewrite a published commit, never force-push, never push implementation directly to `main`. Every pushed commit receives a verdict, so do not push disposable WIP commits. Merge PRs with merge commits; squash and rebase merging are disabled. Bring new `main` changes into the task branch with an ordinary merge, and only in the granted merge slot or when the lead TPM asks; that merge and its conflict resolution are reviewed like any other commit. Any new head invalidates prior final approval.

## Review and merge

**The tester reviews each pushed commit.** The developer sends the tester the SHA over Herdr after each push. The tester inspects the commit in file context, checks local correctness, then affected callers, features and tests, then end-to-end behavior. It maps acceptance scenarios to named tests, trusts CI only for commands CI actually ran, and runs relevant verification CI omitted, using the team's port and database block. It posts a per-commit verdict on the PR using the review template and replies to the developer over Herdr. Fix commits name the finding they address. An interim P0 pauses new work on that branch until repaired; P1 repairs may be batched into the next commit.

The tester and developer may run at most three repair rounds on one finding. If a fourth would be needed, the tester tells the tech lead and the developer performs root-cause analysis before any further attempt. Bounds trigger analysis, never a pass.

**The tech lead reviews the whole PR before merge.** It reads every commit's tester verdict, then the complete diff against the current base, and challenges the chosen implementation, design choices, tradeoffs and assumptions. This is not a stricter pass over defects the tester already covers. A challenge states a concrete alternative and its tradeoff. The developer answers with evidence. The tech lead decides technical disagreements with evidence and escalates product scope changes through the team TPM to the lead TPM. It may reject the PR design at most twice; a third rejection requires root-cause analysis recorded on the issue first. A rejected design means new commits, which the tester reviews again.

Severity:

- **P0:** stop-ship critical exposure, irreversible data loss or fundamental inability to operate.
- **P1:** broken required behavior, authorization or consistency defect, or missing evidence that makes the change unsafe to integrate.
- **P2/P3:** lower-impact defects or improvements. Record them; link follow-up issues when deferred. A failed required acceptance criterion blocks completion regardless of label. Cosmetic preference alone is not P1.

No PR merges with an unresolved P0 or P1, an unsatisfied acceptance criterion, or failing relevant tests. Do not downgrade findings to pass.

**Gate.** All agents share one GitHub identity, so GitHub cannot verify reviewer independence. The main ruleset therefore requires a PR, resolved conversations, an up-to-date branch, the `checks`, `release` and `tips/independent-review` contexts. After its whole-PR verdict, the tech lead posts the review record on the PR, then sets `tips/independent-review` on the exact reviewed head SHA with the record's URL as the target. The status applies only to that head; a new head needs a new review and a new status. A branch update from `main` in the merge slot is a new head: the tech lead reviews the merge commit's conflict resolution, if any, and sets the status again. This is a process interlock, not cryptographic isolation between agents sharing credentials.

**Merge queue.** The lead TPM keeps a first-in-first-out queue of accepted PRs and grants one merge slot at a time. In its slot the tech lead updates the branch from `main`, waits for green checks on the new head, sets the status, merges with a merge commit and no extra edits, runs integrated checks on `main`, records the merge SHA on the issue, and reports to its team TPM, which reports to the lead TPM, who grants the next slot. If integrated checks on `main` fail, the queue stops; the team that merged reproduces and repairs or reverts through a reviewed PR before any other merge. Never label flaky failures green.

## Context and handoff

The developer, tester and tech lead start every issue with fresh context. The team TPM resets them before dispatch. The issue plus dispatch comment must therefore be self-sufficient.

If an agent nears context exhaustion mid-task, it keeps the same issue and branch open and hands off to a fresh session. The handoff records base and head SHAs, clean or dirty working-tree state, committed and uncommitted work, unresolved findings, failing commands, evidence, owned files and the next concrete action. Preserve user changes; never reset or stash blindly. The incoming session re-applies its Herdr name, reads the handoff, issue and relevant diff, verifies repository state, sets the Agent field and continues. Session recovery is not task completion.

For a lost or unresponsive agent, the team TPM inspects branch and worktree evidence before reassignment, then explicitly transfers ownership. For a lost or unresponsive team TPM, the lead TPM does the same. Never run two writers because an agent looks idle. Never put credentials in issues, logs or handoffs.

## Comment templates

Dispatch comment (team TPM):

> Team: N; owner: team-N-dev; reviewers: team-N-test, team-N-lead; base SHA: …; branch/worktree: …
> Outcome and exclusions: …
> Read: exact sections and actual entry points …
> Own: files/migration reservation (approved by lead-tpm) …; coordinate: …
> Prerequisites/evidence: …; test DB/port block: …
> Acceptance and commands: …
> Stop/handoff if: context headroom or prerequisite assumptions fail …

Return or handoff comment (developer):

> Head SHA and working-tree state: …; PR: …
> Behavior/contracts changed: …
> Commands and results (including failures/unexecuted checks): …
> Acceptance evidence and provider cleanup: …
> Unresolved findings/blockers and next action: …
> Ownership transfer: …

Review comment (tester per commit, tech lead per PR):

> Reviewer: …; implementer: team-N-dev
> Base SHA: …; head SHA: …
> Each commit SHA → verdict/findings: …
> Whole PR → local/downstream/end-to-end verdict: … (tech lead only)
> Tests/evidence inspected or independently run: …
> Unresolved P0/P1: …; lower-priority follow-ups: …

Merge record (tech lead):

> Merge SHA: …; PR: …; reviewed head: …; base: …
> Review record: …; integrated checks on main: run URL …
> Follow-ups carried to: …

## Milestones and external prerequisites

M0 proves reproducible startup, release and test plumbing. M1 proves all five risky boundaries on one revision. M2 proves the complete product. M3 rehearses operations on the intended topology. M4 records trial readiness and the owner's public-launch decision. Each gate issue owns E2E scenarios, environment and revision, evidence and unresolved blockers. Feature tests run earlier; milestones are not the first testing opportunity. Each task records acceptance-to-test mappings as it lands; P14 audits that coverage rather than creating it at the end.

The lead TPM maintains explicit access and setup issues for hosting, domain, providers, operator identity, vocabulary, founder content and recruitment. When a task needs a credential, account or hosting decision, the team TPM marks it Blocked and tells the lead TPM, who asks the user; the user obtains it. Agents propose defaults and use synthetic fixtures for tests; they do not fabricate firsthand production content. Secrets use the execution environment's secret mechanism. No budget has been fixed; absence of a ceiling does not authorize purchases.

Before launch, the intended single VPS serves as the preproduction environment. Run real-provider tests only through explicitly authorized invocations with scoped secrets, never automatically on arbitrary PR code. Record authorization in the dispatch comment or alongside the explicitly invoked CI workflow run URL. Ordinary PR CI needs no production secrets.

References: [Git worktrees](https://git-scm.com/docs/git-worktree), [GitHub rulesets](https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/managing-rulesets/available-rules-for-rulesets), [sub-issues](https://docs.github.com/en/rest/issues/sub-issues), [issue dependencies](https://docs.github.com/en/rest/issues/issue-dependencies).
