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
2. [review-software-correctness](../../skills/review-software-correctness/SKILL.md) and
   [review-software-design](../../skills/review-software-design/SKILL.md). Reuse one
   source investigation and review record for both concerns. Assess responsibility,
   dependencies and state ownership as well as behavior; a generic design sentence
   does not substitute for evidence in the diff and affected callers.
3. The brief, then the diff, then the [PR body](../README.md#pr-body).

## Steps

1. The implementer's handoff notified every required reviewer of the same head and asked
   the dispatcher to launch any that were missing. Do not notify or launch reviewers.
2. Before your first review, run the [manual browser review](../README.md#manual-browser-review)
   session sequence (`open about:blank`, `get url`, `close`) once in your own runtime. If
   it fails, report `blocked` with the exact error. It shows only that your runtime can
   open a browser; it replaces no later check.
3. Record the head SHA and your first concerns before reading the PR body or another
   review.
4. Follow both skills with your own database and port: affected code, design,
   scenarios and their controls, mutation check, entry points, data, checks.
   Wallaby browser tests (`TIPS_BROWSER=1`, `test/tips_web/features`): a Codex client
   cannot run them; the macOS sandbox kills chromedriver's Chrome and each attempt
   leaves a crash dialog ([#432](https://github.com/chenghanlee/tips/issues/432)). If
   you are a Codex client, do not run them. Read the implementer's retained log named
   in the PR body under "Checks not run by CI": check the command, the `exit=` line and
   the failure list, and write "browser run by <implementer entry>, log verified" in
   your review. If the PR body names no log, record that in your review; the
   merge-confirming tester then runs `agent/teams/team.py turn <pr> <implementer entry>`
   to request it, and any other tester sends its review URL to the merge-confirming
   tester. For manual checks follow [manual browser review](../README.md#manual-browser-review), including its Codex setup, launch form and failure steps.
5. Submit the [review record](../README.md#pr-review-record). Without findings, submit
   LGTM. Other tester: send your review URL to the merge-confirming tester.
6. Merge-confirming tester: when your review or any required reviewer's latest review of
   the head has findings, send `turn` to the implementer. Do not wait for the other
   reviews. When `agent/teams/pr_review.py observe <pr>` reports ready, follow the
   [merge step](../README.md#merge). Then send `done` to the dispatcher.
7. A new head invalidates every LGTM. Follow the [review record](../README.md#pr-review-record)
   for first-review coverage and later changes.

## Questions and changed decisions

You may answer bounded source or verification questions before a PR, using evidence
from your own clone and an ANSWER on the brief. This is optional help. A consequential
decision needing independent technical judgment goes to the appropriate designer;
checking conformity with your own answer is not independent validation of that decision.

For a changed binding decision, follow [Changed binding decisions](../README.md#changed-binding-decisions).

## Messages you send

- `team.py turn <pr> <implementer entry>` when the head has findings.
- Review URL to the merge-confirming tester, if you are not it.
- `done` or `blocked` to the dispatcher.

## Do not

- Do not turn an affected-code review into an audit of unrelated smells. Ask for
  verification when an affected contract's relevant evidence is missing.
- Do not run `team.py turn` unless you confirm the merge.
- Do not merge with an unresolved thread, a missing LGTM or a failed check.
- Codex client: do not run `mix test` with `TIPS_BROWSER=1`. Use `agent-browser` for manual checks.
