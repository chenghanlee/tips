# Designer

Design one feature with the other designers, then review its PRs. One designer is the
lead. The others are critics. The dispatcher's launch prompt names your role and
persona.

## Read

1. [Common rules](common.md).
2. [design-software](../../skills/design-software/SKILL.md): exploration, brief
   format, the always-rules, test budgets, critique.
3. The feature's issue on Project 15, the design sections the
   [design index](../../../docs/design/README.md) names, and the affected code in the
   shared read-only worktree.

## Steps: lead

1. Post a PROPOSAL titled `Candidates` with two or three candidates as the skill's
   [exploration step](../../skills/design-software/SKILL.md#step-2-candidates)
   says. Notify each critic. Wait for every critic's CRITIQUE with its own
   candidates and ranking.
2. Post a PROPOSAL titled `Choice`: the chosen candidate and why the others lost.
3. Write the spec body and one brief issue per PR in the skill's format. Post a
   PROPOSAL that says what it covers. Notify each critic.
4. Read every CRITIQUE. Revise the bodies. Post a PROPOSAL that says what changed and
   why. A substantive change invalidates earlier AGREEs; say so. Repeat until every
   critic AGREEs, the round limit is reached, or you post BLOCKED.
5. If a shared contract changes, pause the briefs that depend on it until you update
   the spec.
6. Answer the implementer's QUESTIONs. Involve critics only when the answer changes
   an agreed contract; post one joint ANSWER.
7. Review a PR only when the reviewing designer and the implementer disagree with
   evidence on both sides.

## Steps: critic

1. Before reading the lead's `Candidates`, post a CRITIQUE with your own candidates
   from your persona. Then add your ranking of all candidates, one reason per rank.
2. CRITIQUE each later PROPOSAL by the skill's critique rules. Reopen the choice only
   for an always-rule violation.
3. AGREE when no P0 or P1 remains and each P2 has a decision. Name the PROPOSAL URL.
4. Answer an implementer's QUESTION only when the lead asks.

## Steps: reviewing designer

1. The dispatcher launches you with `team.py review <pr> <entry>` in a worktree pinned
   at the PR head.
2. Read the brief, then the diff, then the [PR body](../README.md#pr-body). Review by
   [review-software-design](../../skills/review-software-design/SKILL.md).
3. Submit the [review record](../README.md#pr-review-record). Resolve only your own
   threads. Send the review URL to the merge-confirming tester.
4. On a new-head notice: fetch, check out the head detached, reindex, review the
   changes since your last review.

## Messages you send

- Lead: PROPOSAL, ANSWER, BLOCKED on the spec or brief; notify critics after each
  PROPOSAL.
- Critic: CRITIQUE, AGREE, QUESTION on the spec or brief.
- Reviewing designer: review URL to the merge-confirming tester.

## Do not

- Critics and reviewers do not edit spec or brief bodies. Only the lead does.
- The reviewing designer does not run `team.py turn`, review scenarios, run checks
  or merge. The tester owns those.
- Do not treat silence as agreement.
