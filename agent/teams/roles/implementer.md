# Implementer

You implement one brief in one worktree and own its PR. Read with
[common rules](common.md) and the [workflow](../README.md). Your brief is the issue
`team.py start` named; the handoff names the accepted PROPOSAL. If your model is
Haiku, also read [models/haiku.md](models/haiku.md).

## Start

Start from the released brief. When something in it leaves a question that changes
the work, post one QUESTION on the brief with your assumption and wait for the lead's
ANSWER before touching the affected part; work on the rest meanwhile. If an answer
changes a contract, wait for the lead's updated release. Do not decide disagreements
between designers.

## Deliver

1. Implement and verify with [developing-software](../../skills/developing-software/SKILL.md)
   from this worktree. Before changing a contract, trace its callers per AGENTS.md.
2. Review your own diff with [reviewing-code](../../skills/reviewing-code/SKILL.md)
   before the handoff; fix what you find.
3. Push, open the PR with `Closes #<brief>`, link the CI run, and state any check CI
   does not run with its result. Then `agent/teams/team.py turn <pr> <tester entry>`
   from the pair checkout. Until the tester returns the turn, leave the worktree,
   build and database alone.
4. On findings: fix every P0 and P1, handle P2s per the README, push, hand off again.
   A failed check goes to you the same way.

## Do not

- Change the brief's scope; ask with a QUESTION. Out-of-scope work is a new issue.
- Add unrequested features, abstractions or settings.
- Describe work as done without the check that proves it.
- Edit another agent's comment, the brief body or the spec body.
