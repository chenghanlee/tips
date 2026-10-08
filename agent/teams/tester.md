# Tester

Read the [shared workflow](README.md) and this procedure from the current worktree.
Determine whose turn it is before acting.

## Review the pushed head

1. Record the PR head SHA. Read [reviewing-code](../skills/reviewing-code/SKILL.md)
   from this worktree to establish scope and review that head against the shared
   design and testing standard. Run the tests. For UI tasks, also check acceptance
   scenarios through [manual browser review](browser-review.md).
2. If required review work stays blocked, follow the
   [blocker procedure](README.md#report-and-resolve-blockers).
3. Confirm the worktree is clean and HEAD matches the reviewed SHA. Report every P0
   and P1 in the first review. With findings: submit the review and run
   `agent/teams/team.py turn <pr> dev`. Without: continue to approval.

For fixes, check each repair and the scenarios it affects, and apply the skill to new
behaviour or design.

Follow the [shared repair exchange](README.md#address-findings) for subsequent passes.
Before a review conclusion, check the applicable [Finish obligations](../skills/developing-software/references/finish.md).

## Approve and confirm the merge

Approve when no P0 or P1 remains and every thread is resolved. Submit and publish
the [PR review record](pr-review-record.md) without waiting for CI. Keep the turn.

Auto-merge requires `checks`, `release`, `tips/independent-review` and resolved
threads. A merge closes the issue, sets the Project item to Done and deletes the
remote branch.

Run this watch command once each time the turn reaches this step:

```sh
timeout "$TIPS_CHECK_TIMEOUT_SECONDS" gh pr checks <pr> --watch --required
```

Whether it passes, fails or times out, then run:

```sh
gh pr view <pr> --json state,mergedAt,mergeStateStatus,autoMergeRequest
```

Use the first matching outcome:

| Outcome | Action |
|---|---|
| PR merged | Notify the dispatcher with `done`. |
| PR not merged and a required check failed | Run `agent/teams/team.py turn <pr> dev`. |
| Checks passed, PR open, auto-merge enabled, merge state neither `BLOCKED` nor `DIRTY` | Run the bounded merge wait below. |
| Any other outcome | Report `blocked` to the dispatcher with the pending check or merge blocker. |

GitHub may take several minutes to merge after checks pass. Run this once; it
rechecks every 15 seconds and uses the existing check timeout as its ceiling:

```sh
timeout "$TIPS_CHECK_TIMEOUT_SECONDS" sh -c '
  while :; do
    result=$(gh pr view "$1" --json state,mergeStateStatus,autoMergeRequest \
      --jq "[.state, .mergeStateStatus, (.autoMergeRequest != null)] | join(\" \")") || exit 1
    case "$result" in
      "MERGED "*) exit 0 ;;
      "OPEN BLOCKED "*|"OPEN DIRTY "*) echo "$result"; exit 1 ;;
      "OPEN "*" true") sleep 15 ;;
      *) echo "Merge wait stopped: $result"; exit 1 ;;
    esac
  done
' sh <pr>
```

After the wait exits or times out, read the PR state again. If merged, notify the
dispatcher with `done`. Otherwise, return to the developer if a required check
failed; report `blocked` for any other outcome, including an API error. Include
the current merge state or exact error. Do not repeat either wait in this turn.
