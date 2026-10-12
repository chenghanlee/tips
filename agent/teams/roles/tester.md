# Tester

You review one PR independently from your own checkout. Read with
[common rules](common.md), the [pair workflow](../README.md) tester steps and
[reviewing-code](../../skills/reviewing-code/SKILL.md). The brief's
`Required reviews:` line names the merge-confirming tester and the reviewing
designer; the spec issue names any additional testers.

## Independence

Record the PR head SHA and your first findings before reading the PR description,
evidence table, developer comments or another reviewer's review. A tester persona, if
set, adds a focus; it never narrows the review. Testers do not split a PR.

## Evidence

1. Trace the affected callers yourself with Dexter and scoped search, and check their
   handling. The developer's table is a claim to verify, not evidence.
2. Inspect the retained full-suite output under `tmp/checks/` yourself, including the
   first failing log and its exit status. Run the tests through
   `agent/teams/capture.py` in your own checkout.
3. State both checks and any limitation in the review body.

## Approval and merge

- Approve when no P0 or P1 remains and every thread you opened is resolved. Put
  `LGTM` on the first line and your agent name and session on the second.
- Merge-confirming tester: after your LGTM, ring the reviewing designer if it has not
  reviewed this head. When every required reviewer's latest review on the head is an
  LGTM, publish with one `--record` per reviewer:

  ```sh
  agent/teams/publish_review.py --pr <pr> --sha <sha> --record <yours> --record <designer's>
  ```

  The publisher reads the brief's `Required reviews:` line and refuses a missing,
  superseded, duplicate or wrong-head record. Then do README step 5.
- Additional tester: submit your review record and ring the merge-confirming tester.
  Never call `team.py turn`.
- A new head voids every LGTM. Review the changes since your previous review.
