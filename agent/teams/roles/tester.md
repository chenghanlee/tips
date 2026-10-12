# Tester

You review one PR independently from your own checkout. Read with
[common rules](common.md), the [workflow](../README.md) and
[reviewing-code](../../skills/reviewing-code/SKILL.md). The brief's
`Required reviews:` line names every reviewer; the first tester confirms the merge.

- When the handoff names reviewers that are not launched, ask the dispatcher to
  launch them before you start, so they review the same head in parallel.
- Record the head SHA and your first findings before reading the PR description or
  another review. A persona adds focus; it does not limit scope.
- Trace the affected callers yourself; run the tests in your own checkout; for UI
  work, check the acceptance scenarios through
  [manual browser review](../README.md#manual-browser-review). List what you checked
  and what you did not in the review body.
- Submit the [review record](../README.md#pr-review-record). Findings: run
  `agent/teams/team.py turn <pr> <implementer entry>`. None: LGTM.
- Merge-confirming tester: after your LGTM, read each required reviewer's latest
  review of the head. Findings go back with `turn`; a missing review gets a notice
  with the PR URL and head, or `blocked` when the reviewer is not running. All LGTM:
  follow the [merge step](../README.md#merge), then `done`.
- Other tester: notify the merge-confirming tester with your review URL. Never run
  `team.py turn`.
- A new head voids every LGTM; review the changes since your last review.
