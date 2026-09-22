# Implementing Tips with agents

This is the operating agreement for building Tips. [AGENTS.md](../../AGENTS.md) governs engineering. [goal-prompt.md](goal-prompt.md) describes dispatch. GitHub issues and PRs hold requirements, decisions, review history and evidence. [agent-team.toml](../../config/agent-team.toml) owns agent settings; do not duplicate its defaults in commands or prose.

## Roles

One lead TPM assigns work to teams within the configured trial limit. Each team handles one issue at a time.

| Role | Owns |
|---|---|
| Lead TPM (`lead-tpm`) | Assign issues, start/retire teams, resolve cross-team dependencies, report blockers to the user. |
| Team TPM (`team-N-tpm`) | Assess readiness, provision/advance coding sessions, dispatch, update issue labels, route handoffs. |
| Developer (`team-N-dev`) | Implement the issue with integration-first TDD; own its branch, worktree and PR. |
| Tester (`team-N-test`) | Independently review each pushed commit and run relevant verification. |
| Tech lead (`team-N-lead`) | Confirm technical readiness; deeply review the whole PR's design; publish its review status and merge. |

TPMs handle coordination so technical leads can concentrate on code review. Reviewers use the issue, code and evidence, with fresh sessions at each dispatched revision. Nobody reviews or merges their own implementation. The common GitHub identity cannot mechanically prove reviewer independence.

The user decides material product changes, purchases, credentials, hosting and public launch. Routine technical choices belong to the responsible role. No budget has been fixed; absence of a ceiling does not authorize purchases.

## Task readiness

The lead TPM picks critical-path issues whose prerequisites are integrated and evidenced, preferring the team's current package. Package parent issues are not coding assignments. Split work into bounded changes a fresh agent can understand, implement, test and repair.

Before dispatch, the team TPM records one outcome, exclusions, exact design sections and real entry points, acceptance scenarios, runnable verification and available prerequisites. The tech lead confirms readiness on the issue, amending the technical contract when necessary. Discovery may be its own task. Do not require file ownership lists, reservations or overlap approval; coordinate concrete shared changes when they arise.

Each coding issue records acceptance-to-test mappings. Milestone gates require E2E evidence on one integrated revision; isolated task reports do not establish a gate. Closing a package requires its mandatory children and package acceptance evidence.

## Issue and project state

Use GitHub issues and PRs as the source of truth. Add `active` when assigned; add `blocked` when progress requires outside action, with the prerequisite, responsible role and next action in a comment. Remove stale labels as the situation changes. A waiting dependency is not automatically a user blocker. Do not mirror a workflow state machine into Project fields or maintain a separate status document.

An issue closes only when its required result is integrated and evidenced. Partial work uses `Refs #number`; a completing PR uses `Closes #number`. Child issues created during the run count toward the goal.

## Git

Use protected `main`, short-lived `task/<issue>-<slug>` branches and worktrees under `.worktrees/`. The main checkout is read-only for source changes: never switch its branch, edit, commit or run tests there. Repository administration such as fetch and worktree creation runs from main. Make every source change in a worktree, including documentation and operational scripts.

The TPM uses `scripts/task_worktree.py` to provision and start coding clients. Keep the existing task slug when an issue is renamed. The developer owns its task worktree; tester and tech lead have separate detached review worktrees. No agent edits another's checkout. The helper checks reviewer cleanliness even at the same SHA, checks selected-client configuration before changing HEAD, reuses a matching live session, and stops the old client and verifies descendant exit before advancing a reviewer. `/new`, `/clear` and `cd` inside an already-running client do not reroot its LSP.

Open a draft PR early. Commit cohesive changes and run relevant checks before pushing. Unpushed local commits may be reorganized; published commits are fixed. Never force-push or push implementation directly to main. Repository rules block force pushes on `task/**` while permitting deletion of merged branches. Merge with merge commits; keep strict up-to-date checks and automatic deletion of merged remote heads.

## Review and merge

**Tester:** Review every pushed commit in context, first for local correctness, then callers and related features/tests, then end-to-end behavior. Map acceptance to named tests; trust CI only for commands it ran. Independently run missing relevant checks using the assigned environment. Post the verdict and evidence on the PR and notify the developer. Repairs receive another verdict. Required acceptance failures block completion regardless of severity.

**Tech lead:** After tester findings are resolved, read the whole diff against the current base. Challenge implementation, architecture and assumptions with concrete alternatives and tradeoffs. Evaluate each proposed fix's downstream effects. Resolve technical disagreement using evidence; escalate material product changes through the TPM. A rejected design creates new commits that the tester reviews again.

P0 means critical exposure, irreversible loss or fundamental inability to operate. P1 means broken required behavior, authorization/consistency defects or missing evidence needed to integrate safely. P2/P3 are lower-impact defects or improvements; record follow-up issues when deferred. Do not downgrade findings merely to pass. Repeated failed repairs require root-cause analysis rather than more blind attempts.

The tech lead posts a review record with reviewer/implementer, base/head SHAs, commit verdicts, whole-PR findings, independently run checks, unresolved findings and follow-ups. Then it publishes `tips/independent-review` on that exact head, linking the record. Main requires a PR, resolved conversations, an up-to-date branch and the required `checks`, `release` and independent-review contexts. This is an interlock, not credential isolation.

Merge uses native GitHub CLI commands, without a TPM merge queue:

```bash
gh pr update-branch "$PR"
# If HEAD changed: dispatch the exact new SHA for review before continuing.
timeout "$TIPS_CHECK_TIMEOUT_SECONDS" gh pr checks "$PR" --watch
gh pr merge "$PR" --merge --match-head-commit "$REVIEWED_SHA"
```

Capture the new head after branch update. A new head needs a new status: the tech lead reviews the base delta and publishes a new status on that SHA; conflict resolution also goes through the tester. Resume the checks/merge sequence after those verdicts arrive. A base change during this sequence can make the strict gate reject the merge; inspect the new state and repeat the necessary review. A timeout, rate limit or failed required check is not success. Record the PR, reviewed head, merge SHA and review evidence on the issue, then notify the TPM. Do not synchronously watch main or automatically revert its changes.

## Context and handoff

Send one plain message containing the issue/PR link, relevant SHA, requested action and reply-to agent. Record durable evidence on GitHub. Wake the next responsible role with `herdr agent prompt`; then end the turn. No polling or waiting on agent replies. A single bounded foreground wait for known CI checks is allowed. The user detects otherwise silent stalls.

For context recovery, keep the issue/branch open and record base/head SHAs, working-tree cleanliness, committed/uncommitted work, unresolved findings, failed/unrun checks and the next action. Explicitly transfer ownership before starting another writer. Never reset or stash someone else's work to recover a session. Inspect Git and pane evidence before reassigning an unresponsive client. Never put credentials in logs, issues or handoffs.

## Environment and cleanup

The helper applies the selected role's configured model, effort, permissions, database suffix and test port in the actual target process. Only the selected client's generated configuration is written. Both clients invoke the canonical main checkout's LSP wrapper with the assigned absolute worktree root. Review revisions do not need to contain that wrapper. Keep installed patched bridge/Expert tools available independently of task worktrees.

Startup reports **client launched**, not index ready. Brief the agent once Herdr reports it ready. Expert can keep compiling in the background. Do not add a compile gate or launch a second LSP as a probe. Configuration/tooling changes require a disposable actual-client pilot checking both the client root and LSP root for each client. Five observed cold sessions do not establish capacity for every configured team to compile simultaneously; the team limit remains a trial.

TPMs run without the Elixir LSP. Coordinator launches use configured compaction; coding launches do not inherit that coordinator override. Codex approval policy does not change or guarantee its sandbox; it retains the user's sandbox configuration. Claude's permission mode comes from the same config.

`team.py stop N`, called from outside that team, gracefully stops owned clients and verifies owned descendants exited before cleanup. It refuses dirty or unmerged worktrees, drops only that team's test databases, removes worktrees and closes the workspace. Uncertainty or survivors fail the command and preserve remaining resources for inspection. It never broadly kills BEAM processes or deletes the shared engine cache. Do not run overlapping lifecycle calls; one TPM owns a team's transitions, with no lock or daemon.

The database connection limit is configured in [compose.yaml](../../compose.yaml), with `TIPS_DB_MAX_CONNECTIONS` as the standard Compose override. Apply it by recreating the database service only while no teams are running. Agent launch settings do not restart PostgreSQL or existing clients.

## Milestones and external prerequisites

M0 proves reproducible startup, release and testing; M1 proves risky boundaries on one revision; M2 proves the complete product; M3 rehearses operations; M4 records trial readiness and the user's public-launch decision. Each gate names its environment, revision, evidence and unresolved blockers.

The lead TPM tracks access/setup requirements for hosting, domain, providers, operator identity, vocabulary and content in GitHub issues. Agents propose defaults and use synthetic fixtures; they do not fabricate firsthand production content. Before launch, the intended VPS is the preproduction environment. Run real-provider tests only through explicitly authorized invocations with scoped secrets, never automatically on arbitrary PR code. Ordinary PR CI needs no production secrets.
