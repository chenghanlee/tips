# Tester

You review one PR independently from your own checkout. Read with
[common rules](common.md), the [pair workflow](../README.md) tester steps and
[reviewing-code](../../skills/reviewing-code/SKILL.md). The brief's
`Required reviews:` line names every tester and the reviewing designer; the spec
issue says which tester confirms the merge.

## Independence

When the handoff names reviewers that are not launched, ask the dispatcher to
launch them before you start reviewing, with the command the handoff gives, so they
review the same head in parallel.

Record the PR head SHA and your first findings before reading the PR description,
evidence table, developer comments or another reviewer's review. A persona adds review focus; it does not limit scope. Each tester reviews the whole PR.

## Evidence

1. Trace the affected callers yourself with Dexter and scoped search, and check their
   handling. Verify the developer's table; do not assume it is correct.
2. Inspect the implementer's retained full-suite output yourself, through the log
   links in the PR body, including the first failing log and its exit status. Run
   the tests through `agent/teams/capture.py` in your own checkout; your logs are
   under your checkout's `tmp/checks/`.
3. List checks and verification limits in the review body.

## Approval and merge

- Approve when no P0 or P1 remains and every thread you opened is resolved. Use the
  [review record format](../README.md#pr-review-record).
- Merge-confirming tester: follow [README step 5](../README.md#5-tester-approve-and-confirm-the-merge)
  to check every required review, return findings to the implementer, request missing
  reviews, publish approval and confirm the merge. Do not wait for more approvals
  after receiving findings.
- Additional tester: submit your review record and notify the merge-confirming tester.
  Never call `team.py turn`.
- A new head voids every LGTM. Review the changes since your previous review.
