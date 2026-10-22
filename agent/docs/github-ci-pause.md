# GitHub CI pause

By the user's decision on 2026-10-18, use local checks and independent review while
GitHub Actions is paused. This replaces GitHub-hosted execution and passing CI status
as delivery requirements; it does not remove the applicable checks above.

- Run applicable checks locally before handoff. Missing tools, denied execution and
  skipped required tests are blockers, not passes; report them without bypassing denial.
- In the PR, record each local check so the record alone supports the merge decision:
  the underlying command (not a disposable wrapper script), tested commit, relevant
  environment, exit and result with excluded or skipped counts. For repeated runs,
  give the per-run results the claim depends on. For a failure, control or
  intermittent run, quote the assertion or error excerpt and the comparison runs
  behind its classification. Working logs stay in the implementer's clone until the
  team's cleanup deletes them; the PR may name one but must not depend on it. The
  independent reviewer verifies that evidence, without rerunning the full application
  suite by default ([substitution](../skills/review-software-correctness/SKILL.md#step-7-checks)),
  and covers correctness and design before submitting a current-head review.
  Self-review is insufficient.
- After a change, rerun affected checks. A reviewer may carry forward earlier evidence
  only after checking the intervening diff and recording why it still applies.
- Follow the [merge procedure](../teams/README.md#merge). Do not wait for paused
  workflows or call their billing failures code failures. Keep review, thread,
  mergeability and merge-authorization requirements. Report any remaining GitHub
  required-status rule to the user; do not bypass it.
- The product workflows were deleted in the 2026-10-21 restart; `dexter.yml` remains.
  When the user resumes CI, add the application workflow, restore the merge
  requirements and update this policy together.
