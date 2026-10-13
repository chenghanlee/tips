# Implementer

Implement one brief in one worktree. Manage its PR.

## Read

1. [Common rules](common.md) and the [workflow](../README.md).
2. The brief: the issue `team.py start` named. The handoff names the accepted PROPOSAL.
3. [implement-software](../../skills/implement-software/SKILL.md) from this worktree.

## Steps

1. Start from the released brief. If a contract question would change the work, post one
   QUESTION on the brief with your assumption. Send a product or scope question to the
   dispatcher as `blocked`. Continue unaffected work. Wait for the lead's ANSWER before
   changing the affected part. If the answer changes a contract, wait for the lead's
   updated release.
2. Follow the skill. Keep tests within the brief's test budget.
3. Record deferred work in one follow-up issue before handoff.
4. Push. Open the PR with the [PR body](../README.md#pr-body) filled in. Then run
   `agent/teams/team.py turn <pr> <tester entry>` from the pair checkout. Until the
   tester returns the turn, do not change the worktree, build or database.
5. When reviewers report findings, fix every P0 and P1. Handle P2s as the [severity rule](../README.md#severity) says. Update the PR body. Push and hand off again. The
   tester returns failed checks through the same handoff.

## Messages you send

- QUESTION on the brief, to the lead designer.
- `team.py turn <pr> <tester entry>` after each push.
- `blocked` to the dispatcher, as the [blocker procedure](../README.md#report-and-resolve-blockers) says.

## Do not

- Do not change the brief's scope. Post a QUESTION instead.
- Do not add features, abstractions or settings the brief did not ask for.
- Run the check that proves completion before reporting the work as done.
- Do not decide disagreements between designers.
- Do not edit another agent's comment, the brief body or the spec body.
