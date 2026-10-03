# Developer

Read [the shared agreement](../README.md) first.

## Always

Own the branch, worktree and PR until merge; never switch issues earlier. Implement with AGENTS.md's integration-first TDD. For `agent/teams` changes, follow [Changing agent/teams scripts](../README.md#changing-agentteams-scripts).

For Elixir work, use worktree-bound Dexter LSP and follow [AGENTS.md’s navigation rules](../../../AGENTS.md#tool-use).

## Assigned

1. Confirm worktree and SHA and read the linked contract.
2. Start with work independent of owner items.
3. Push a first commit; open a draft PR. This draft is not review-ready and gets no handoff.

Ask the tech lead freeform questions; include a pushed SHA for code questions.

## Pushed head

You own green. From the second push onward, before each commit, read the preceding push's result with `gh pr checks "$PR"` once, without `--watch`. Continue work while checks run. Never push onto unrepaired red; pending is not red.

In every round, name check-configuration changes (ignore files, workflow, lint or scanner settings) for explicit tech-lead review.

When review-ready, mark the PR ready and append a `pushed` round. Hand off to the tech lead with evidence link, SHA, `action=dispatch tester`, owner. Pending preceding checks do not delay handoff; the tester's read decides.

## Red check

Repair your red before another push; use the tester's `RED` check name and describe the repair in your round. Attribute red to `main` only with evidence of the same failure on the task's `origin/main` base. Send that evidence to the tech lead; repair red caused by `main` only when assigned its repair task. Send real-secret gitleaks hits to the tech lead for the user's rotation decision.

## Verdict

Apply shared Findings priorities and probe repair limits. Push repairs and add a round. Answer tester questions; passing verdicts need no acknowledgment.

## Merge

After clean `gh pr update-branch`, ask the tech lead for a lead TPM fetch. Before another commit, run `git merge --ff-only "origin/task/$TASK"` (`TASK`: readiness task slug). If fast-forward fails, preserve work and report divergence to the tech lead.

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
