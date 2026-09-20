# Implementing Tips with parallel agents

This is the operating agreement for Codex (engineering manager/tech lead), Fable (TPM and visual-design owner), implementers and independent reviewers. Product requirements remain in the technical designs. [GitHub issues](https://github.com/chenghanlee/tips/issues) hold current task requirements and evidence; the [Tips project](https://github.com/users/chenghanlee/projects/15) holds scheduling state. Local task JSON files are the initial publication snapshot, not a second live tracker. Freeze them after publication; refine current issues in GitHub. When a contract changes, Codex links that decision from every affected Backlog issue so readiness refinement sees it.

## Responsibilities and capacity

Codex resolves technical contracts, reserves shared files/migrations, checks downstream effects and merges. Fable maintains dependencies, readiness, scope coverage, blockers and milestone evidence. The user decides material product changes, purchases and public launch. Agents handle routine implementation choices and handoffs themselves.

N is the maximum simultaneous implementation workers, including Fable when designing or writing code. Reviewers and coordinators also consume the environment's actual agent capacity. Never exceed either cap. With one available session, implement, stop, then review in an independent session. A coordinator who authored a change cannot independently approve it. Reviewers receive the issue, code and evidence, not the implementer's conversation as their source of truth.

Before dispatch, Fable selects ready work on the critical path and Codex confirms disjoint ownership. Use spare capacity for ready supporting work or review; do not manufacture new services or speculative changes to occupy workers. Keep at most one active coding issue per implementation worker. When review backlog blocks integration, prioritize reviewers over new starts.

## Task readiness

For a fresh TPM session: read this workflow and the milestone table, then inspect open PRs, failed checks, active/blocked issues and their latest handoffs in GitHub. Reconcile actual branch/head and ownership before dispatch. Confirm configured N and available sessions, prioritize repairs/reviews that unblock integration, then choose ready disjoint work. Report the current milestone, blockers needing owner action and the next dispatch; do not ask the user to reconstruct project history. Never infer that a closed issue's dependent gate passed without its evidence.

Packages are parent issues, not coding assignments. Each coding issue is one bounded change that a fresh agent can understand, implement, test and repair in a session. This is a sizing target, not a guarantee about unknown defects. A user story may need several such issues; internal contracts and operational checks need not pretend to be user stories.

Fable moves an issue from Backlog to Ready only when all these are true:

- Prerequisites are integrated and their required checks passed. A contract/probe result resolves any open technical choice needed by this task.
- The issue states one outcome, explicit exclusions, exact owning design sections, acceptance scenarios and relevant failure/race cases.
- Code now exists for any referenced entry points. Codex has narrowed anticipated module areas to actual files, signatures, fixtures and runnable verification commands. Future issues may have anticipated paths while in Backlog; agents must not guess them during dispatch.
- The scope fits a fresh session, including reading, testing and repair headroom. Split discovery from implementation when uncertainty dominates. Split by behavior or invariant, never an arbitrary line count.
- Required test environment/provider access is available, or the issue explicitly delivers only a local contract and its real-provider gate is a separate blocked issue.
- There is one named owner, an available slot and no overlapping mutable files, fixtures, migration reservation or real-provider asset namespace.

Do not make every worker reread all design/review history. Supply the task's owning sections and a short list of cross-cutting invariants (admission, visibility, lock order and transactional effects) that actually apply. Start with generous context headroom; calibrate after the first few issues using observed context occupancy and repair needs. Do not use cumulative billed tokens as a context meter or invent a fixed universal token limit.

## Issue and project state

Use one Project Status field: **Backlog → Ready → Active → In review → Done**, with **Blocked** available from any unfinished state. Failed review returns to Active for repair. Blocked issues name the missing prerequisite, responsible role and next concrete action; dependency waiting in Backlog is normal, not an incident. Issue comments record dispatch, handoff, review and evidence. The project Agent field identifies the tool, session ID/link and dispatch date; GitHub assignees identify accountable humans, not fabricated agent accounts.

An issue closes only after its required result is integrated and verified. Closing a parent requires all mandatory children and package acceptance evidence. A milestone gate closes only against one integrated revision, with its E2E evidence; sums of isolated task reports do not pass a gate. Failed or unavailable checks are failures or blockers, never passes. The acting coordinator updates issue/project state when merging or handing off; Fable reconciles the queue each dispatch cycle, without requiring a separate session for each transition.

## Git and shared ownership

Use protected `main`, short-lived `task/<issue>-<slug>` branches and a separate worktree per active coding issue. Start from a fetched, known `origin/main` SHA. Use a draft PR early and one PR per bounded change. Link its issue with `Closes #number` only when that PR completes the issue. Partial work uses `Refs #number`.

Codex serializes changes to shared files (dependency manifests, router, supervision/config, CI and migrations) through explicit reservations in dispatch comments. A task can own a small shared-file change; coordination does not require Codex to write every edit. Do not edit another agent's worktree. Each worktree has its own development port, test database and build output where isolation requires it. Record these in dispatch. Provider tests get unique prefixes/assets and explicit cleanup. Never run reset/drop against another worker's database.

Commit cohesive changes and run appropriate checks. Unreviewed local commits may be organized before first push; never rewrite an already reviewed commit. Every commit submitted for integration receives a verdict, so avoid publishing disposable WIP commits. Preserve reviewed commit identities: use merge commits for PRs; disable squash/rebase merging. Do not rewrite published or already reviewed commits. Once pushed, a SHA is fixed even before a checkpoint review is requested. Bring new main changes into the task branch with an ordinary merge; independently review that merge and conflict resolution, then rerun affected checks. An update invalidates final PR approval. No force pushes, direct implementation pushes to main, or routine admin bypasses.

The empty repository needs a root commit before GitHub can accept a PR. Independently review that content-free initialization commit before its first push; all substantive documents and implementation then go through a PR. Record bootstrap evidence in P0.00. The documentation PR supplies `.github/workflows/checks.yml`, which reports `checks` on pull requests; enable the main ruleset before merging that substantive PR. This is repository initialization, not a standing bypass policy.

## Independent review and merge

The implementer may continue while review is pending. Review an explicit pushed-SHA checkpoint while work proceeds; only a final review of the latest stable head and current base can pass the required status. Do not start dependent work on another owner's unmerged branch. A worker taking a different ready issue must hand off or park their previous issue explicitly. Before merge, a separate agent session must examine **each commit** introduced by the PR, and then the **complete PR diff against the current base**. A batch session may review several commits individually. Fix commits name the finding/comment they address. An interim P0 pauses new work on that branch until repaired; P1 repairs may be batched into the next checkpoint. Fix commits and branch-sync merges are included. Review local correctness, affected callers/features/tests, then end-to-end behavior.

The review record contains reviewer identity and session, exact base and head SHAs, an explicit verdict for each commit SHA, complete-PR verdict, findings with severity, and verification evidence. Do not infer commit review from a generic PR approval. The reviewer inspects the head in file context, maps acceptance to named tests, trusts CI only for commands it actually ran, and runs relevant verification omitted by CI when the environment permits. Missing required verification remains a blocker. The linked review comment is authoritative; the PR template is an index to it. A reviewer can request repair but must not approve their own repair implementation; use another independent reviewer if they become an author.

- **P0:** stop-ship critical exposure, irreversible data loss or fundamental inability to operate.
- **P1:** broken required behavior, authorization/consistency defect or missing evidence that makes this change unsafe to integrate.
- **P2/P3:** lower-impact defects or improvements. Record them; link follow-up issues when deferred. A failed required acceptance criterion still blocks completion regardless of its label. Cosmetic preference alone is not P1.

Repair and review until there are no unresolved P0/P1 findings, required acceptance criteria are satisfied, and relevant tests pass. Do not silently downgrade findings to pass. Codex resolves technical disagreement with evidence; escalate product scope changes to the user.

When agents share a GitHub identity, GitHub cannot supply independent human self-approval. Use an independently authored review record and a required `tips/independent-review` commit status posted by the reviewer after recording evidence. Link the status to that review comment. Require the `checks` CI context and an up-to-date branch. The status applies only to the reviewed head; the record names the current base. Codex verifies actor/session independence, coverage and base freshness immediately before merge. Use one named integration slot; other PRs do not sync speculatively. Serialize final integration slots: finish one branch's current-base review and merge before preparing the next. Interim commit reviews may run concurrently and their verdicts remain evidence. Final review includes the sync commit, complete current-base diff and semantic effects of intervening main changes on callers/callees. N workers does not promise N merges per cycle; final-review latency limits throughput. File-disjoint changes can still conflict semantically; they do not waive current-base checks. This is an agent process control, not cryptographic isolation between agents sharing credentials. Do not claim it prevents a malicious credential holder from forging a status. A distinct authorized reviewer identity can add native PR approval later without changing the review obligation.

Codex merges only after checks and independent review pass on the current head/base and conversations are resolved. The mechanical merge commit must have no extra edits; inspect its tree against the reviewed head, run integrated checks and record the merge SHA before closing delivery evidence. If integration fails, stop dependent dispatch, reproduce and repair or revert through a reviewed PR. Do not label unrelated flaky failures green; identify their impact and track the blocker.

## Context recovery and stalled work

Stop before context exhaustion when possible. Keep the **same issue and branch** open; transfer to a fresh repair session. Record base/head, clean/dirty working-tree state, committed and uncommitted work, exact unresolved review findings, failing commands, evidence, owned files, environment identifiers and the next concrete action. Preserve user changes and never reset or stash blindly. The outgoing session posts the handoff, clears its Agent entry and stops; it need not wait while running out of context. Fable keeps the paths reserved for that issue. Ownership transfers when the incoming session acknowledges and sets its Agent entry. The incoming session owns that field update; TPM reconciliation must not silently overwrite an active claim. Session recovery is not task completion.

The next agent reads the compact handoff, issue and relevant diff, verifies repository state and continues tests/repair. It need not inherit the old transcript. If the scope itself is oversized, Codex/Fable split additional independent behavior into linked issues; required repairs remain blocking and the original issue stays open. Repeated repair loops trigger root-cause analysis or a technical spike, not endless retries of the same approach. There is no arbitrary review-count limit that overrides the no-P0/P1 rule.

For a lost or unresponsive worker, inspect branch/worktree evidence before reassignment, then explicitly transfer ownership. Do not run two writers because an agent appears idle. Blocker reports state impact and next action; only ask the user for decisions or access agents cannot obtain themselves. Never put credentials in issues, logs or handoffs.

## Dispatch and return templates

Dispatch comment:

> Owner/session: …; reviewer: …; base SHA: …; branch/worktree: …; N/occupied slots: …
> Outcome and exclusions: …
> Read: exact sections and actual entry points …
> Own: files/migration reservation …; coordinate: …
> Prerequisites/evidence: …; test DB/port/provider namespace: …
> Acceptance and commands: …
> Stop/handoff if: context headroom or prerequisite assumptions fail …

Return/handoff comment:

> Head SHA and working-tree state: …; PR: …
> Behavior/contracts changed: …
> Commands and results (including failures/unexecuted checks): …
> Acceptance evidence and provider cleanup: …
> Unresolved findings/blockers and next action: …
> Ownership transfer: …

Independent review comment:

> Reviewer/session: …; implementer/session: …
> Base SHA: …; head SHA: …
> Each commit SHA → verdict/findings: …
> Whole PR → local/downstream/end-to-end verdict: …
> Tests/evidence inspected or independently run: …
> Unresolved P0/P1: …; lower-priority follow-ups: …

## Milestones and external prerequisites

M0 proves reproducible startup/release and test plumbing. M1 proves all five risky boundaries on one revision. M2 proves the complete product. M3 rehearses operations on intended topology. M4 records trial readiness and the owner's public-launch decision. Each gate issue owns E2E scenarios, environment/revision, evidence and unresolved blockers. Feature tests run earlier; milestones are not the first testing opportunity. Each task records acceptance-to-test/evidence mappings as it lands; P14 audits that existing coverage, rather than creating it at the end.

Fable maintains explicit access/setup issues for hosting/domain/providers, operator identity, vocabulary, founder content and recruitment. Agents propose defaults and use synthetic fixtures for tests; they do not fabricate firsthand production content. Secrets use the execution environment's secret mechanism. No budget has been fixed; absence of a ceiling does not authorize arbitrary purchases.

References: [Git worktrees](https://git-scm.com/docs/git-worktree), [GitHub rulesets](https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/managing-rulesets/available-rules-for-rulesets), [sub-issues](https://docs.github.com/en/rest/issues/sub-issues), and [issue dependencies](https://docs.github.com/en/rest/issues/issue-dependencies). These support ordinary Git/GitHub workflows; this project does not need a new scheduling service.

Before launch, the intended single VPS serves as the preproduction environment. Earlier real-provider tests may run from isolated worktrees or CI with distinct asset namespaces. This does not add a permanent staging fleet. Run real-provider tests only through explicitly authorized/tagged invocations with scoped secrets, never automatically on arbitrary PR code. Record authorization in the dispatch comment for a worktree run, or alongside the explicitly invoked CI workflow run URL. Ordinary PR CI needs no production secrets.
