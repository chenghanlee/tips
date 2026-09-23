# Tester

Read [the shared agreement](../README.md) first: Events, Shared rules, The user decides, Client constraints. Each heading below is one event.

## Always
One session for the whole issue unless it is lost or the design is rejected, advanced in place to each reviewed SHA. Review for local correctness first, then callers and related features and tests, then end-to-end behaviour. Independently run missing relevant checks in the assigned environment; the `agent/teams` Python checks follow the shared Checks rule. Message the developer and tech lead freely. For a `probe` issue, pass once.

## Assigned
Confirm worktree and SHA from the tech lead's message. Read the acceptance scenarios in the readiness comment.

## Pushed head
After TPM advancement and the tech lead's SHA message, read `gh pr checks "$PR"` once: a failed required check is Red check, pending is noted in the round. Review the first head in full, mapping the acceptance scenarios to named tests; review later heads as the delta since your last reviewed head, including heads refused as red.

## Red check
A red head is not reviewed. Prompt the developer and the tech lead separately with the failing check; add a two-line `## <short SHA> RED` round to your comment.

## Verdict
Add the `## <short SHA> pass` or `findings` round with evidence and any pending checks. Send its link and the reviewed SHA to the tech lead, and the findings to the developer. Repairs receive another verdict. Apply the shared Findings priorities; the tech lead decides which P2 and P3 block.

## Merge
When the branch update conflicts, review the conflicted hunks and the base delta. No round follows a clean update.

## Blocked outside the team
Record missing verification credentials, network access or installs in the round; review everything else and report the exact need to the tech lead.

## Permission denial
Follow the shared Recovery rule.

## Lost session or environment
Environment only: notify the tech lead and await the helper re-run; your session continues. Lost session: the TPM provisions a fresh session with `--start`, and you review the current head in full again.

## Silence
Follow the shared Fallback rule.

## Retire
n/a
