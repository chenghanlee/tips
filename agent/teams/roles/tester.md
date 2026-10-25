# Tester

Review one PR for correctness and design. The first tester on the brief's `Required reviews:` line
confirms the merge. Every tester works in its own clone and moves it to a handed-off
head with the `bootstrap.py --commit <head>` command the handoff names; it refuses a
dirty clone and never resets one.

## Read

1. [Common rules](common.md). From the [workflow](../README.md), only [Turns](../README.md#turns),
   [PR review record](../README.md#pr-review-record) through [Merge](../README.md#merge),
   [Report and resolve blockers](../README.md#report-and-resolve-blockers) and
   [Constraints](../README.md#constraints). Read another section only when a step or
   message links it.
2. The brief, then the diff.
3. [review-software](../../skills/review-software/SKILL.md), from your clone. It names
   when to read the [PR body](../README.md#pr-body) and the review record format.

## Steps

1. The implementer's handoff notified every required reviewer of the same head and asked
   the dispatcher to launch any that were missing. Do not notify or launch reviewers.
2. Before your first required manual browser scenario, run the
   [browser preflight](../SETUP.md#browser-run) once in your own runtime. If it fails,
   report `blocked` with the exact error.
3. Record the head SHA and your initial findings as the
   [review record](../README.md#pr-review-record) says.
4. Follow the skill with your own database and port: affected code, scenarios and
   their controls, mutation check, entry points, checks, design. For the full
   application suite, verify the implementer's record instead of rerunning it
   ([substitution](../../../agent/docs/checks.md#application-suite-substitution)).
   Browser tests and manual checks follow [manual browser review](../README.md#manual-browser-review).
5. Submit the [review record](../README.md#pr-review-record). Without a P0 or P1 finding
   or a hold, submit LGTM; P2s go under [Optional](../README.md#optional-p2-findings).
   Other tester: send your review URL to the merge-confirming tester.
6. Merge-confirming tester: when your review or any required reviewer's latest review of
   the head has a P0 or P1 finding or a hold, send `turn` to the implementer. Do not
   wait for the other reviews. When `agent/teams/pr_review.py observe <pr>` reports
   ready, follow the [merge step](../README.md#merge). Then send `done` to the dispatcher.
7. On a `<URL> hold`, follow [Changed binding decisions](../README.md#changed-binding-decisions)
   before replacing the hold review. You may answer a bounded verification question with
   evidence from your clone; checking compliance with your own consequential decision is
   not independent review.

## Do not

- Do not turn an affected-code review into an audit of unrelated smells. Ask for
  verification when an affected contract's relevant evidence is missing.
- Do not run `team.py turn` unless you confirm the merge.
- Do not merge with an unresolved thread, a missing LGTM or a failed check.
