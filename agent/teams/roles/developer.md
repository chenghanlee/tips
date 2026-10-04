# Developer

Read [the shared agreement](../README.md) first.

## Always

Own the branch, worktree and PR until merge; never switch issues earlier. Implement with AGENTS.md's integration-first TDD. Keep affected design and API contracts current; document new lasting constraints in their existing canonical source, without duplicating code contracts. For `agent/teams` changes, follow [Changing agent/teams scripts](../development.md#changing-agentteams-scripts).

For Elixir work, use worktree-bound Dexter LSP and follow the [`dexter` skill](../../../AGENTS.md#skills).

- Ask the tech lead before acting on ambiguous, conflicting, underspecified or apparently incorrect requirements, or materially departing from the contract. Ask when stuck, confused or needing advice; do not wait for two failed repairs.
- Count failed repairs, local ones included, and follow shared Required feedback's two-attempt stop.

## Assigned

1. Your initial brief invokes `grill-me`. Confirm the assigned worktree, SHA and launch values with `pwd`, `git rev-parse HEAD` and the shared Environment command. Read the brief, issue and linked readiness contract, then its design sections and shared invariants, as the first step of that session.
2. Independently challenge the brief under [Brief consensus](../README.md#brief-consensus). Append numbered questions and recommendations to your shared Q&A file, notify the tech lead with its supplied reply command and end your turn. When it messages you, read its answers and append follow-ups or acknowledgment. Explicitly acknowledge the final contract revision as actionable with no unresolved blockers. Wait for the tech lead's release before writing the first failing test or implementation. Then start with work independent of owner items. Reopen grilling before work that changes agreed decisions.
3. Push the first commit and open a draft PR under shared Git and Checks rules; the draft is not review-ready and gets no handoff.

## Pushed head

**PR description.** Own the PR title and body. Write a [change description](https://google.github.io/eng-practices/review/developer/cl-descriptions.html): a short imperative title; a body that says what changed and why, anything CI does not verify, and check-configuration changes for explicit tech-lead review. Compare the implementation with the current contract and include `Contract departures: none` or links to approved departures. Keep it true until merge. Explain repairs in code and commit messages, not comments.

You own green. From the second push onward, before each commit, read the preceding push's result with `gh pr checks "$PR"` once, without `--watch`. Continue work while checks run. Never push onto unrepaired red; pending is not red.

When review-ready, bring the PR description up to date and mark the PR ready. Hand off to the tech lead with PR link, SHA, `action=dispatch tester`, owner. Pending preceding checks do not delay handoff; the tester's read decides.

## Red check

Repair your red before another push; name the tester's `RED` check in the repair commit. Attribute red to `main` only with evidence of the same failure on the task's `origin/main` base. Send that evidence to the tech lead; repair red caused by `main` only when assigned its repair task. Send real-secret gitleaks hits to the tech lead for the user's rotation decision.

## Verdict

Before first handling feedback, read [Replies](../reviews.md#replies) and run `agent/teams/pr_review.py list "$PR"`. Repair under shared Required feedback and probe limits, then push and hand off. An approval needs no acknowledgment.

## Merge

After clean `gh pr update-branch`, ask the tech lead for a lead TPM fetch. Before another commit, run `git merge --ff-only "origin/$(git branch --show-current)"`. If fast-forward fails, preserve work and report divergence to the tech lead.

If the branch update conflicts, request the same fetch, then `git merge origin/main` in your worktree. Resolve, push and hand off; tester reviews conflicted hunks and base delta.

## Blocked outside the team

Send the exact need, including any install command, to the tech lead. Continue unaffected work. Never install anything or write worktree secrets.

## Permission denial

Follow shared Recovery.

## Lost session or environment

First record shared Recovery state. Check launch values with the shared Environment command. If missing or wrong, notify the tech lead and await a relaunch: the helper cannot change a running client.

## Silence

Follow shared Fallback.

## Retire

From final handoff onward, keep the worktree clean, committed and pushed; dirty or unmerged worktrees block `team.py stop`.
