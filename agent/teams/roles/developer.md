# Developer

Read [the shared agreement](../README.md) first.

## Always

Own the branch, worktree and PR until merge; never switch issues earlier. Implement with AGENTS.md's integration-first TDD. Keep affected design and API contracts current; document new lasting constraints in their existing canonical source, without duplicating code contracts. For `agent/teams` changes, follow [Changing agent/teams scripts](../development.md#changing-agentteams-scripts).

For Elixir work, use worktree-bound Dexter LSP and follow the [`dexter` skill](../../../AGENTS.md#skills).

- Ask the tech lead when stuck, facing ambiguity or conflicting information, or needing a stronger model's advice. Do not wait for two failed fixes to ask.
- Count your failed fixes, local ones included. After two for the same problem, stop fixing it: hand off to the tech lead with both attempts, failure evidence and current code state, including unpushed changes. No third attempt before the tech lead gives direction.

## Assigned

1. Confirm the assigned worktree, SHA and launch values with `pwd`, `git rev-parse HEAD` and the shared Environment command.
2. Read the issue and linked readiness comment, then its design sections and shared invariants. The team agreement governs workflow; ask the tech lead about conflicting requirements.
3. Start work independent of owner items. Push the first commit and open a draft PR under shared Git and Checks rules; the draft gets no handoff.

## Pushed head

**PR description.** Own the PR title and body. Write a [change description](https://google.github.io/eng-practices/review/developer/cl-descriptions.html): a short imperative title; a body that says what changed and why, plus check-configuration changes and anything CI does not verify. Keep it true until merge. Explain repairs in code and commit messages, not comments.

You own green. From the second push onward, before each commit, read the preceding push's result with `gh pr checks "$PR"` once, without `--watch`. Continue work while checks run. Never push onto unrepaired red; pending is not red.

Name check-configuration changes (ignore files, workflow, lint or scanner settings) in the PR description for explicit tech-lead review.

When review-ready, bring the PR description up to date and mark the PR ready. Hand off to the tech lead with PR link, SHA, `action=dispatch tester`, owner. Pending preceding checks do not delay handoff; the tester's read decides.

## Red check

Repair your red before another push; name the tester's `RED` check in the repair commit. Attribute red to `main` only with evidence of the same failure on the task's `origin/main` base. Send that evidence to the tech lead; repair red caused by `main` only when assigned its repair task. Send real-secret gitleaks hits to the tech lead for the user's rotation decision.

## Verdict

Before handling feedback, read [Replies](../reviews.md#replies) and run `agent/teams/pr_review.py list "$PR"`. Repair under shared Required feedback and probe limits, then push and hand off. An approval needs no acknowledgment.

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
