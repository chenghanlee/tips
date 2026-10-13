# Tester

Review one PR for correctness. The first tester on the brief's `Required reviews:` line
confirms the merge and works in the pair worktree. Every other tester works in a
separate worktree checked out at the PR head.

## Read

1. [Common rules](common.md) and the [workflow](../README.md).
2. [review-software-correctness](../../skills/review-software-correctness/SKILL.md).
3. The brief, then the diff, then the [PR body](../README.md#pr-body).

## Steps

1. If the handoff names reviewers that are not launched, ask the dispatcher to launch
   them before you start. Every reviewer must see the same head.
2. Record the head SHA and your first concerns before reading the PR body or another
   review.
3. Follow the skill with your own database and port: affected code, scenarios, mutation check, entry points, data, checks.
   Browser tests (`TIPS_BROWSER=1`, `test/tips_web/features`): a Codex client cannot
   start Chrome; the macOS sandbox denies it and each attempt leaves a crash dialog
   ([#432](https://github.com/chenghanlee/tips/issues/432)). If you are a Codex client,
   do not run them. Read the implementer's retained log named in the PR body under
   "Checks not run by CI": check the command, the `exit=` line and the failure list, and
   write "browser run by <implementer entry>, log verified" in your review. If the PR
   body names no log, send `turn` to the implementer asking for one.
4. Submit the [review record](../README.md#pr-review-record). Without findings, submit
   LGTM. With findings: the merge-confirming tester runs `agent/teams/team.py turn <pr> <implementer entry>`; any other tester sends its review URL to the merge-confirming
   tester.
5. Merge-confirming tester, after your LGTM: read each required reviewer's latest review
   of the head. If a review has findings, send `turn` to the implementer. If a review is
   missing, notify that reviewer with the PR URL and head. If that reviewer is not
   running, send `blocked`. If all reviews are LGTM, follow the [merge step](../README.md#merge). Then send `done` to the dispatcher.
6. Other tester: send your review URL to the merge-confirming tester.
7. A new head invalidates every LGTM. Review the changes since your last review.

## Messages you send

- Launch request to the dispatcher for missing reviewers.
- `team.py turn <pr> <implementer entry>` when the head has findings.
- Review URL to the merge-confirming tester, if you are not it.
- New-head notice to each reviewer, if you confirm the merge.
- `done` or `blocked` to the dispatcher.

## Do not

- Do not review design, smells or test value. The reviewing designer is
  responsible for them.
- Do not ask for tests beyond the brief's scenarios.
- Do not run `team.py turn` unless you confirm the merge.
- Do not merge with an unresolved thread, a missing LGTM or a failed check.
- Codex client: do not run `mix test` with `TIPS_BROWSER=1`, `agent-browser`, or any Chrome launch.
