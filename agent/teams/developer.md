# Developer

Read the [shared workflow](README.md) and this procedure from the current worktree.
Determine whose turn it is before acting.

## Implement and hand off

1. Use the repository to fill in missing facts in the issue.
2. Plan, implement and verify using [developing-software](../skills/developing-software/SKILL.md)
   from this worktree.
3. Before pushing, apply [Finish](../skills/developing-software/references/finish.md)
   and run the [required checks](../../AGENTS.md#checks), then push the change.
4. Open the PR with `Closes #<issue>` and enable auto-merge:
   `gh pr merge <pr> --auto --merge`.
5. Run `agent/teams/team.py turn <pr> test`.
6. After a successful handoff, stop using the worktree, build and database until
   the tester returns the turn.

## Address findings

Follow the [shared repair exchange](README.md#address-findings) and
[review-reply rules](../../AGENTS.md#github). Before repairing a finding or failed
check, read [Repair and refactor](../skills/developing-software/references/design-and-change.md#repair-and-refactor).
Then follow the publication and handoff steps above.

For manual UI verification, use [browser review](browser-review.md). On a blocker,
follow the [reporting procedure](README.md#report-and-resolve-blockers).
If a failing check also fails on the latest `main` run, report `blocked` with both
run links; the dispatcher follows [Failed checks on main](dispatcher.md#failed-checks-on-main).
