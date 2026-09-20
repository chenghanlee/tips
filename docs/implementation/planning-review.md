# Backlog and workflow review

Date: 2026-09-20. Codex acted as engineering manager/tech lead; Fable acted as TPM and independent reviewer through Herdr pane `wJ:p1`, session `16fe80a4-c785-435f-a965-e84b69ffea11`. The owner confirmed the workflow decisions before backlog publication. No application was implemented by this planning change.

## Round 1

Fable challenged delayed external prerequisites, the combined database/SaladUI probe, overlapping shared-component ownership, late backups, bundled operations tasks and the potential cost of parallel review. Codex separated provider-specific evidence, database-image work, SaladUI compatibility, backups, counter repair, error reporting, job retries and moderator bootstrap. Access tracking can start immediately. The generator works in a temporary directory so it cannot overwrite the existing project or wait on an unattended overwrite prompt.

The workflow specifies handoff without making an exhausted agent wait, fresh-session review, current-base verification, explicit owner/session fields and live GitHub state. The documentation PR provides the initial required `checks` workflow; P0.04 later adds actual application/browser/secret checks. No application result is inferred from planning CI.

## Round 2

Fable accepted three disputed choices:

- Retain strict current-base checks because disjoint files can conflict semantically. Use one named final integration slot, with no speculative syncing of all open branches. Final-review latency limits throughput.
- Permit implementation to continue during review of a pushed-SHA checkpoint. Fixes name findings; an interim P0 pauses new work on that branch. Only the current final head/base receives a passing review status.
- Publish the full backlog now, with later issues in Backlog. Ready refinement resolves actual interfaces, paths, commands and evidence. The original JSON publication snapshots were later removed; GitHub owns subsequent changes.

Fable found unnecessary full-auth/provider dependencies on fixture and contract tasks, missing limiter/shared-component dependencies, a moderator-bootstrap timing gap, and several oversized tasks. Those were split or given precise prerequisite leaves. Provider probes need only their own credentials; real integrated gates still require the configured runtime. Pure context operations can proceed before broad UI expansion when their contracts and ownership are ready.

Both agents checked exact design-section references, task identity, dependency cycles, milestone ordering and coverage. Coverage means requirements have owners; it does not mean their tests have passed. Required task acceptance must be mapped to actual tests/evidence as implementation lands. Later operational evidence does not create an implicit dependency cycle back into M2.

## Round 3

Fable verified all 116 tasks: unique identities, valid reading sections, acyclic dependencies, milestone ordering, and complete gate ancestry. Remaining corrections gave moderator bootstrap one accountable Accounts owner and kept the media gate independent of real mail/Turnstile access while M1 still requires the full auth gate. The publication index must exist and CI must pass before exact-SHA review. P0.01 remains a readiness sizing checkpoint; split it further if discovery exceeds a fresh session.

## Bootstrap evidence and final review

Fable independently inspected root commit `0ea089f` with `git cat-file`, `git ls-tree` and `git show --stat`. Verdict: PASS. It has no parent and the canonical empty tree `4b825dc642cb6eb9a060e54bf8d69288fbee4904`; it contains no files. It was reviewed before the first push.

All substantive files are submitted through the planning PR. Its exact commit-by-commit and complete-PR review record, CI results and merge evidence are recorded on GitHub and linked from P0.00. This document records review decisions; it does not substitute for those exact-SHA verdicts.

The active main ruleset requires a PR, resolved review conversations, up-to-date `checks` and `tips/independent-review`, with no configured bypass actors, force pushes or deletion. Repository merge settings preserve commits through merge commits. The independent-review status is a process interlock; shared GitHub credentials do not establish isolated reviewer identities.
