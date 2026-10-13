# Implementer

Implement one brief in one worktree and own its PR.

## Read

1. [Common rules](common.md) and the [workflow](../README.md).
2. The brief: the issue `team.py start` named. The handoff names the accepted PROPOSAL.
3. [implement-software](../../skills/implement-software/SKILL.md) from this worktree.

## Steps

1. Start from the released brief. If a question would change the work, post one
   QUESTION on the brief with your assumption. Continue unaffected work. Wait for
   the lead's ANSWER before changing the affected part. If the answer changes a
   contract, wait for the lead's updated release.
2. Implement by the skill. Stay inside the brief's test budget.
3. Open deferred work as one follow-up issue before handoff.
4. Push. Open the PR with the [PR body](../README.md#pr-body) filled in. Then run
   `agent/teams/team.py turn <pr> <tester entry>` from the pair checkout. Until the
   tester returns the turn, leave the worktree, build and database alone.
5. When reviewers report findings, fix every P0 and P1. Handle P2s as the
   [severity rule](../README.md#severity) says. Update the PR body. Push and hand
   off again. The tester returns failed checks through the same handoff.

## Messages you send

- QUESTION on the brief, to the lead designer.
- `team.py turn <pr> <tester entry>` after each push.
- `blocked` to the dispatcher, as the [blocker procedure](../README.md#report-and-resolve-blockers) says.

## Do not

- Do not change the brief's scope. Post a QUESTION instead.
- Do not add features, abstractions or settings the brief did not ask for.
- Do not say work is done without the check that proves it.
- Do not decide disagreements between designers.
- Do not edit another agent's comment, the brief body or the spec body.
