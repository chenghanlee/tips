# Tester

Review one PR for correctness and design. The first tester on the brief's `Required reviews:` line
confirms the merge. Every tester works in its own clone and moves it to a handed-off
head with the `bootstrap.py --commit <head>` command the handoff names; it refuses a
dirty clone and never resets one.

## Read

1. [Common rules](common.md). From the [workflow](../README.md), only [Turns](../README.md#turns),
   [Severity](../README.md#severity),
   [Report and resolve blockers](../README.md#report-and-resolve-blockers) and
   [Constraints](../README.md#constraints). Read the review record, PR body, browser and
   merge sections when a step links them; `agent/teams/read.py section <file> <heading>`
   prints one.
2. The brief, then the diff against the base your handoff names, then the tests of the
   changed modules. Your handoff withholds the PR until the `handoff` step below.
3. [review-software](../../skills/review-software/SKILL.md), from your clone. Its Step 1
   is the concerns file and the `handoff` command that prints the
   [PR body](../README.md#pr-body); it also gives the review record format.

## Steps

1. The implementer's handoff notified every required reviewer of the same head and asked
   the dispatcher to launch any that were missing. Do not notify or launch reviewers.
2. Write the head SHA and your initial concerns to `tmp/concerns.md`; on a later head,
   append the new head and the delta's concerns to it. Then run the
   `pr_review.py handoff <head> tmp/concerns.md` command your handoff names. It prints
   the PR, its body and prior reviews; `turn` and `observe` take the PR it prints.
   The [review record](../README.md#pr-review-record) repeats the concerns.
3. Follow the skill with your own database and port: affected code, scenarios and
   their controls, mutation check, entry points, checks, design. For the full
   application suite, verify the implementer's record instead of rerunning it
   ([substitution](../../../agent/docs/checks.md#application-suite-substitution)).
   Browser tests and manual checks follow [manual browser review](../README.md#manual-browser-review).
4. Submit the [review record](../README.md#pr-review-record). Without a P0 or P1 finding
   or a hold, submit LGTM; P2s go under [Optional](../README.md#optional-p2-findings).
   Other tester: send your review URL to the merge-confirming tester.
5. Merge-confirming tester: when your review or any required reviewer's latest review of
   the head has a P0 or P1 finding, send `turn` to the implementer. Do not
   wait for the other reviews. When `python3 <harness>/pr_review.py observe <pr>` reports
   ready, follow the [merge step](../README.md#merge). Then send `done` to the dispatcher.
6. On a `<URL> hold`, follow [Changed binding decisions](../README.md#changed-binding-decisions)
   before replacing the hold review. You may answer a bounded verification question with
   evidence from your clone; checking compliance with your own consequential decision is
   not independent review.

## Do not

- Do not turn an affected-code review into an audit of unrelated smells. Ask for
  verification when an affected contract's relevant evidence is missing.
- Do not run `team.py turn` unless you confirm the merge.
- Do not merge with an unresolved thread, a missing LGTM or a failed check.
