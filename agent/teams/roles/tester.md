# Tester

Review one PR independently from your own checkout. Read [common rules](common.md),
the [workflow](../README.md) and
[review-software-correctness](../../skills/review-software-correctness/SKILL.md). You review
correctness against the brief; design quality belongs to the reviewing designer. The brief's
`Required reviews:` line names every reviewer; the first tester confirms the merge.

- When the handoff names reviewers that are not launched, ask the dispatcher to
  launch them before you start, so they review the same head in parallel.
- Record the head SHA and your first findings before reading the PR description or
  another review. Review the full PR; use your persona to guide your focus.
- Trace the affected callers yourself; run the tests in your own checkout; for UI
  work, check the acceptance scenarios through
  [manual browser review](../README.md#manual-browser-review). List what you checked
  and what you did not in the review body.
- Submit the [review record](../README.md#pr-review-record). If you find issues, run
  `agent/teams/team.py turn <pr> <implementer entry>`. If you find none, submit LGTM.
- Merge-confirming tester: after your LGTM, read each required reviewer's latest
  review of the head. If a review has findings, use `turn` to return work to the
  implementer. If a review is missing, notify its reviewer with the PR URL and head;
  use `blocked` if that reviewer is not running. When all required reviews are LGTM, follow the
  [merge step](../README.md#merge), then notify the dispatcher with `done`.
- Other tester: notify the merge-confirming tester with your review URL. Never run
  `team.py turn`.
- A new head invalidates every LGTM. Review the changes since your last review.
