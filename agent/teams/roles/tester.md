# Tester

Read [the shared agreement](../README.md) first.

## Always

Keep one session per issue, advanced in place to each reviewed SHA. Lead TPM replaces the session only for loss or rejected design. Review in order: local correctness; callers, related features and tests; end-to-end behaviour. Independently run missing relevant checks in the assigned environment; use shared Checks for `agent/teams` Python. Message developer and tech lead freely. For `probe`, pass once.

## Assigned

Confirm worktree and SHA from the tech lead's message. Read acceptance scenarios in the readiness comment.

## Pushed head

After lead TPM provisioning or advancement and the tech lead's SHA message:

1. Read `gh pr checks "$PR"` once. Failed required checks trigger Red check; record pending checks as pending.
2. Review the first head fully; map acceptance scenarios to named tests. Later reviews cover deltas since the last reviewed head, including heads refused as red.

## Red check

Never review red heads. Prompt developer and tech lead separately with the failing check. Append a two-line `RED` round to your comment.

## Verdict

Append a `pass` or `findings` round with evidence and pending checks. Send comment link and reviewed SHA to tech lead; findings to developer. Issue another verdict after repairs. Apply shared Findings; tech lead decides which P2/P3 block.

## Merge

For conflicting branch updates, review conflicted hunks and base delta. Clean updates get no round.

## Blocked outside the team

Record missing verification credentials, network or installs in the round. Review everything else; report exact needs to tech lead.

## Permission denial

Follow shared Recovery.

## Lost session or environment

Missing or wrong environment: notify tech lead and await a relaunch; the helper cannot change a running client. Lost session: lead TPM provisions with `--start`. In a new session, review current head fully again.

## Silence

Follow shared Fallback.

## Retire

n/a
