# Tester

Review one PR for correctness and design. The first tester on the brief's `Required reviews:` line
confirms the merge.

## Read

1. [Common rules](common.md). From the [workflow](../README.md), only [Turns](../README.md#turns),
   [Report and resolve blockers](../README.md#report-and-resolve-blockers) and
   [Constraints](../README.md#constraints). Read other sections when a step links them;
   `python3 <harness>/read.py section <file> <heading>` prints one.

## Steps

1. Apply [review-software](../../skills/review-software/SKILL.md), from your clone, to
   each review you are assigned, including one you resume after a relaunch. Do not
   notify or launch reviewers.
2. Other tester: send your review URL to the merge-confirming tester.
3. Merge-confirming tester: when your review or any required reviewer's latest review of
   the head has a P0 or P1 finding, send `turn` to the implementer. Do not wait for the
   other reviews. When `python3 <harness>/pr_review.py observe <pr>` reports ready,
   follow the [merge step](../README.md#merge). Then send `done` to the dispatcher.
4. On a `<URL> hold`, follow [Changed binding decisions](../README.md#changed-binding-decisions)
   before replacing the hold review. You may answer a bounded verification question with
   evidence from your clone; checking compliance with your own consequential decision is
   not independent review.
