# Tester

Read [the shared agreement](../README.md) first.

## Always

Keep one session per issue, advanced in place to each dispatched SHA. Lead TPM replaces the session only for loss, a wrong launch environment or a rejected implementation design. Review in order: local correctness; callers, related features and tests; end-to-end behaviour. Independently run missing relevant checks in the assigned environment; for `agent/teams` Python follow [Changing agent/teams scripts](../development.md#changing-agentteams-scripts). Message developer and tech lead freely. For `probe`, pass once.

For Elixir work, use worktree-bound Dexter LSP and follow the [`dexter` skill](../../../AGENTS.md#skills).

- Ask the tech lead when stuck, facing ambiguity or conflicting information, or needing a stronger model's advice.
- Apply shared Required feedback's two-failed-repair stop; hand off to the tech lead, not the developer.
- Report failed local verification even when CI is green: head, command, environment and failure evidence. Ask the tech lead when the cause is unclear; an unchanged test does not establish an inherited defect.

## Assigned

Prepare before `grill-me`: confirm worktree and base SHA, read the issue and acceptance scenarios in the contract, then notify the tech lead that you are ready. On the skill invocation, independently challenge the assignment under [Brief consensus](../README.md#brief-consensus), especially acceptance scenarios and verification. Interview the tech lead through Herdr: send the full numbered questions and recommendations directly to the lead. After answers, explicitly report more questions or no more questions and shared understanding. A changed contract decision reopens affected agreement. Acknowledge the final revision on the issue, then await release, checkout advancement and review-head dispatch. Contract consensus does not preapprove code or tests.

## Pushed head

After lead TPM provisioning or advancement and its forwarded tech-lead-authorized handoff, confirm your pane, worktree and `git rev-parse HEAD` match the assignment before reviewing:

1. Read `gh pr checks "$PR"` once. Failed required checks trigger Red check; record pending checks as pending.
2. At the first head you actually review, re-read the acknowledged contract and independently derive expected acceptance behavior from its linked design sections. Review the full PR against `origin/main`, not the agreed base: a reused branch can already hold implementation commits. An incorrect or incomplete contract is a normal required review finding: report the gap with evidence and let the tech lead handle reopening. Never use Q&A answers as verdict evidence. Verify the tests exercise each acceptance scenario, are correct and fail when the code breaks. Apply AGENTS.md's test-value review. Later reviews cover all changes since your last reviewed head, including heads refused as red and relevant base changes.

For an intermittent-failure repair, check that it addresses the supported cause. When useful, rerun the prior failing workload within an explicit runtime budget; do not retry until green.

## Red check

Never review red heads. Refuse explicitly: prompt developer and tech lead separately with the failing check. A refusal does not move your last reviewed head.

## Verdict

Before your first review, read [Reviews and replies](../reviews.md#reviews). Submit one review: feedback, or `LGTM` naming any pending checks. Withhold approval when required local verification fails, even if CI is green. Send review link and SHA to tech lead, and to developer when it has feedback. After repairs, resolve the threads you opened that are fixed and review again.

## Merge

For conflicting branch updates, review conflicted hunks and base delta. Clean updates get no review.

## Blocked outside the team

Record missing verification credentials, network or installs in the review. Review everything else; report exact needs to tech lead.

## Permission denial

Follow shared Recovery.

## Lost session or environment

Missing or wrong environment: notify tech lead and await a relaunch; the helper cannot change a running client. Lost session: lead TPM provisions with `--start`. In a new session, complete Assigned and Brief consensus at the current head first, then review that head fully again. Contract changes reopen affected questions with the developer.

## Silence

Follow shared Fallback.

## Retire

n/a
