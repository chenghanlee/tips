# Implementing Tips with agents

This is the operating agreement for the four agents that build Tips. Product requirements remain in the technical designs. Engineering guidance is in `AGENTS.md`. Runtime wiring for the current run (pane names, loop, communication files) is in [goal-prompt.md](goal-prompt.md). [GitHub issues](https://github.com/chenghanlee/tips/issues) hold current task requirements and evidence; the [Tips project](https://github.com/users/chenghanlee/projects/15) holds scheduling state. Refine current issues in GitHub. When a contract changes, Fable-Tech-Lead links that decision from every affected Backlog issue so readiness refinement sees it.

## Roles

| Role | Agent | Owns |
|---|---|---|
| Fable-TPM | Claude | Task selection, readiness refinement, dispatch, Project status and Agent field, blocker tracking, milestone evidence, status reporting to the user. |
| Astra | Codex | Implementation of one task at a time with integration-first TDD, its branch, worktree and PR. |
| Opus | Claude | Adversarial per-commit correctness review of Astra's pushed commits. |
| Fable-Tech-Lead | Claude | Technical contracts, shared-file reservations, path narrowing during readiness, whole-PR adversarial design review, the `tips/independent-review` status, merges, visual-design direction. |

The user decides material product changes, purchases, provider credentials, hosting and public launch. Agents handle routine implementation choices and handoffs themselves.

Work is strictly serial: one task in implementation at a time, N = 1. Astra may keep working on the same task while Opus reviews an earlier commit. Astra does not start the next task until the current PR is merged. Nobody reviews or merges their own change. Reviewers work from the issue, code and evidence, not from the implementer's conversation.

## Task readiness

At the start of each iteration, Fable-TPM reads this workflow and the milestone table, then inspects open PRs, failed checks, Active and Blocked issues and their latest handoffs in GitHub. It reconciles actual branch, head and ownership before dispatch, prioritizes repairs and reviews that unblock integration, then selects the next task on the critical path (P0, then P1, then P2, and so on). It never infers that a closed issue's dependent gate passed without its evidence.

Packages are parent issues, not coding assignments. Each coding issue is one bounded change that a fresh agent can understand, implement, test and repair in one session. A user story may need several such issues; internal contracts and operational checks need not pretend to be user stories.

Fable-TPM drafts the readiness refinement. Fable-Tech-Lead confirms it with a one-line "ready" comment on the issue. Fable-TPM then moves the issue from Backlog to Ready. All of these must be true:

- Prerequisites are integrated and their required checks passed. A contract or probe result resolves any open technical choice needed by this task.
- The issue states one outcome, explicit exclusions, exact owning design sections, acceptance scenarios and relevant failure and race cases.
- Code exists for any referenced entry points. Fable-Tech-Lead has narrowed anticipated module areas to actual files, signatures, fixtures and runnable verification commands. Agents must not guess paths during dispatch.
- The scope fits a fresh session, including reading, testing and repair headroom. Split discovery from implementation when uncertainty dominates. Split by behavior or invariant, never by line count.
- Required test environment or provider access is available, or the issue explicitly delivers only a local contract and its real-provider gate is a separate Blocked issue.

Do not make Astra reread all design and review history. Supply the task's owning sections and a short list of cross-cutting invariants (admission, visibility, lock order, transactional effects) that actually apply.

Fable-TPM may create child issues when a task must be split. The goal covers every issue in the project, including children created during the run.

## Issue and project state

Use one Project Status field: **Backlog → Ready → Active → In review → Done**, with **Blocked** available from any unfinished state. Failed review returns to Active for repair. Blocked issues name the missing prerequisite, the responsible role and the next concrete action. Waiting on a dependency in Backlog is normal, not an incident. Issue comments record dispatch, handoff, review and evidence. The Project Agent field holds the Herdr agent name of the current owner. GitHub assignees identify accountable humans, never fabricated agent accounts.

An issue closes only after its required result is integrated and verified. Closing a parent requires all mandatory children and package acceptance evidence. A milestone gate closes only against one integrated revision with its E2E evidence; sums of isolated task reports do not pass a gate. Failed or unavailable checks are failures or blockers, never passes. Fable-TPM updates issue and project state at dispatch, at handoff, when the PR enters whole-PR review (In review), when whole-PR review rejects it (back to Active), and at merge.

## Git

Use protected `main`, short-lived `task/<issue>-<slug>` branches and one worktree per active coding issue under `.worktrees/`. At dispatch, Fable-TPM runs `scripts/task_worktree.sh <issue>-<slug>` from the main checkout to create the branch and provision the worktree from fetched `origin/main`, then records its base SHA. An existing task worktree is reused without resetting its branch. Fable-TPM restarts Codex in that worktree as described in [goal-prompt.md](goal-prompt.md). Astra owns the worktree from then on and verifies its MCP workspace before coding. Open a draft PR early and one PR per bounded change. Astra marks it ready for review when every commit has an Opus verdict with no open P0/P1. Astra resolves a review thread only after the fix commit has its Opus verdict; the reviewer reopens it if the fix is wrong. Link its issue with `Closes #number` only when that PR completes the issue. Partial work uses `Refs #number`.

Astra owns its worktree. Opus and Fable-Tech-Lead read the PR head in their own read-only worktrees. Nobody edits another agent's worktree. Fable-Tech-Lead reserves changes to shared files (dependency manifests, router, supervision and config, CI, migrations) in the dispatch comment; a task can own a small shared-file change.

Commit cohesive changes and run the relevant checks before pushing. Unreviewed local commits may be reorganized before first push. Once pushed, a SHA is fixed: never rewrite a published commit, never force-push, never push implementation directly to `main`. Every pushed commit receives a verdict, so do not push disposable WIP commits. Merge PRs with merge commits; squash and rebase merging are disabled. Bring new `main` changes into the task branch with an ordinary merge; that merge and its conflict resolution are reviewed like any other commit. Any new head invalidates prior final approval.

## Review and merge

**Opus reviews each pushed commit.** Astra sends Opus the SHA over Herdr after each push. Opus inspects the commit in file context, checks local correctness, then affected callers, features and tests, then end-to-end behavior. It maps acceptance scenarios to named tests, trusts CI only for commands CI actually ran, and runs relevant verification CI omitted. It posts a per-commit verdict on the PR using the review template and replies to Astra over Herdr. Fix commits name the finding they address. An interim P0 pauses new work on that branch until repaired; P1 repairs may be batched into the next commit.

Opus and Astra may run at most three repair rounds on one finding. If a fourth would be needed, Opus tells Fable-Tech-Lead and Astra performs root-cause analysis before any further attempt. Bounds trigger analysis, never a pass.

**Fable-Tech-Lead reviews the whole PR before merge.** It reads every commit's Opus verdict, then the complete diff against the current base, and challenges the chosen implementation, design choices, tradeoffs and assumptions. This is not a stricter pass over defects Opus already covers. A challenge states a concrete alternative and its tradeoff. Astra answers with evidence. Fable-Tech-Lead decides technical disagreements with evidence and escalates product scope changes to the user. It may reject the PR design at most twice; a third rejection requires root-cause analysis recorded on the issue first. A rejected design means new commits, which Opus reviews again.

Severity:

- **P0:** stop-ship critical exposure, irreversible data loss or fundamental inability to operate.
- **P1:** broken required behavior, authorization or consistency defect, or missing evidence that makes the change unsafe to integrate.
- **P2/P3:** lower-impact defects or improvements. Record them; link follow-up issues when deferred. A failed required acceptance criterion blocks completion regardless of label. Cosmetic preference alone is not P1.

No PR merges with an unresolved P0 or P1, an unsatisfied acceptance criterion, or failing relevant tests. Do not downgrade findings to pass.

**Gate.** All agents share one GitHub identity, so GitHub cannot verify reviewer independence. The main ruleset therefore requires a PR, resolved conversations, an up-to-date branch, the `checks` CI context and the `tips/independent-review` commit status. After its whole-PR verdict, Fable-Tech-Lead posts the review record on the PR, then sets `tips/independent-review` on the exact reviewed head SHA with the record's URL as the target. The status applies only to that head; a new head needs a new review and a new status. This is a process interlock, not cryptographic isolation between agents sharing credentials.

**Merge.** Fable-Tech-Lead merges only after `checks` and `tips/independent-review` pass on the current head and base and conversations are resolved. The merge commit has no extra edits. After merge, Fable-Tech-Lead runs integrated checks on `main` and records the merge SHA on the issue. Fable-TPM then moves the issue to Done. If integration fails, stop dispatch, reproduce, and repair or revert through a reviewed PR. Never label flaky failures green.

## Context and handoff

Astra, Opus and Fable-Tech-Lead start every task with fresh context. Fable-TPM resets them before dispatch. The issue plus dispatch comment must therefore be self-sufficient.

If an agent nears context exhaustion mid-task, it keeps the same issue and branch open and hands off to a fresh session. The handoff records base and head SHAs, clean or dirty working-tree state, committed and uncommitted work, unresolved findings, failing commands, evidence, owned files and the next concrete action. Preserve user changes; never reset or stash blindly. The incoming session re-applies its Herdr name, reads the handoff, issue and relevant diff, verifies repository state, sets the Agent field and continues. Session recovery is not task completion.

For a lost or unresponsive agent, inspect branch and worktree evidence before reassignment, then explicitly transfer ownership. Never run two writers because an agent looks idle. Never put credentials in issues, logs or handoffs.

## Comment templates

Dispatch comment (Fable-TPM):

> Owner: astra; reviewers: opus, fable-tech-lead; base SHA: …; branch/worktree: …
> Outcome and exclusions: …
> Read: exact sections and actual entry points …
> Own: files/migration reservation …; coordinate: …
> Prerequisites/evidence: …; test DB/port/provider namespace: …
> Acceptance and commands: …
> Stop/handoff if: context headroom or prerequisite assumptions fail …

Return or handoff comment (Astra):

> Head SHA and working-tree state: …; PR: …
> Behavior/contracts changed: …
> Commands and results (including failures/unexecuted checks): …
> Acceptance evidence and provider cleanup: …
> Unresolved findings/blockers and next action: …
> Ownership transfer: …

Review comment (Opus per commit, Fable-Tech-Lead per PR):

> Reviewer: …; implementer: astra
> Base SHA: …; head SHA: …
> Each commit SHA → verdict/findings: …
> Whole PR → local/downstream/end-to-end verdict: … (Fable-Tech-Lead only)
> Tests/evidence inspected or independently run: …
> Unresolved P0/P1: …; lower-priority follow-ups: …

## Milestones and external prerequisites

M0 proves reproducible startup, release and test plumbing. M1 proves all five risky boundaries on one revision. M2 proves the complete product. M3 rehearses operations on the intended topology. M4 records trial readiness and the owner's public-launch decision. Each gate issue owns E2E scenarios, environment and revision, evidence and unresolved blockers. Feature tests run earlier; milestones are not the first testing opportunity. Each task records acceptance-to-test mappings as it lands; P14 audits that coverage rather than creating it at the end.

Fable-TPM maintains explicit access and setup issues for hosting, domain, providers, operator identity, vocabulary, founder content and recruitment. When a task needs a credential, account or hosting decision, Fable-TPM marks it Blocked and asks the user; the user obtains it. Agents propose defaults and use synthetic fixtures for tests; they do not fabricate firsthand production content. Secrets use the execution environment's secret mechanism. No budget has been fixed; absence of a ceiling does not authorize purchases.

Before launch, the intended single VPS serves as the preproduction environment. Run real-provider tests only through explicitly authorized invocations with scoped secrets, never automatically on arbitrary PR code. Record authorization in the dispatch comment or alongside the explicitly invoked CI workflow run URL. Ordinary PR CI needs no production secrets.

References: [Git worktrees](https://git-scm.com/docs/git-worktree), [GitHub rulesets](https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/managing-rulesets/available-rules-for-rulesets), [sub-issues](https://docs.github.com/en/rest/issues/sub-issues), [issue dependencies](https://docs.github.com/en/rest/issues/issue-dependencies).
