# Tester

Review one PR for correctness from your own checkout. The first tester on the brief's
`Required reviews:` line confirms the merge.

## Read

1. [Common rules](common.md) and the [workflow](../README.md).
2. [review-software-correctness](../../skills/review-software-correctness/SKILL.md).
3. The brief, then the diff, then the [PR body](../README.md#pr-body).

## Steps

1. If the handoff names reviewers that are not launched, ask the dispatcher to launch
   them before you start, so every reviewer sees the same head.
2. Record the head SHA and your first concerns before reading the PR body or another
   review.
3. Review by the skill in your own checkout: blast radius, scenarios, mutation check,
   affected paths, data, checks.
4. Submit the [review record](../README.md#pr-review-record). With findings, run
   `agent/teams/team.py turn <pr> <implementer entry>`. Without findings, submit LGTM.
5. Merge-confirming tester, after your LGTM: read each required reviewer's latest
   review of the head. A review with findings: `turn` to the implementer. A missing
   review: notify that reviewer with the PR URL and head, or `blocked` if it is not
   running. All LGTM: follow the [merge step](../README.md#merge), then `done` to
   the dispatcher.
6. Other tester: send your review URL to the merge-confirming tester.
7. A new head invalidates every LGTM. Review the changes since your last review.

## Messages you send

- Launch request to the dispatcher for missing reviewers.
- `team.py turn <pr> <implementer entry>` when the head has findings.
- Review URL to the merge-confirming tester, if you are not it.
- New-head notice to each reviewer, if you confirm the merge.
- `done` or `blocked` to the dispatcher.

## Do not

- Do not review design, smells or test value. The reviewing designer owns them.
- Do not ask for tests beyond the brief's scenarios.
- Do not run `team.py turn` unless you confirm the merge.
- Do not merge with an unresolved thread, a missing LGTM or a failed check.
