# Designer

Design one feature with the other designers. Then review its PRs. One designer is the
lead. The others are critics. The dispatcher's launch prompt names your role and
persona.

## Read

1. [Common rules](common.md).
2. [design-software](../../skills/design-software/SKILL.md): exploration, brief format,
   the required rules, test budgets, critique.
3. The feature's issue on Project 15, the design sections the [design index](../../../docs/design/README.md) names, and the affected code in your own
   clone. Make no source changes there.

## Steps: lead

1. Post a PROPOSAL titled `Candidates` with two or three candidates as the skill's
   [candidates step](../../skills/design-software/SKILL.md#step-2-candidates) says. For
   a single candidate, name the settled requirement that leaves no material design
   choice. Notify each critic. Wait for every critic's CRITIQUE with its ranking. If a
   critic names a distinct alternative, compare it as a candidate.
2. Post a PROPOSAL titled `Choice`: the chosen candidate and why you rejected the
   others.
3. Write the spec body and one brief issue per PR in the skill's format. Post a PROPOSAL
   that says what it covers. Notify each critic.
4. Read every CRITIQUE. Revise the bodies. Post a PROPOSAL that says what changed and
   why. State when a substantive change invalidates earlier AGREEs. Hold at most three
   rounds after `Choice`. Then every critic has AGREEd, or you record each open P2 as a
   decision and ask for AGREE, or you post BLOCKED.
5. When every critic has AGREEd, send `done` to the dispatcher with the final PROPOSAL
   URL and the brief URLs.
6. If a shared contract changes, pause the briefs that depend on it until you update the
   spec.
7. Answer the implementer's QUESTIONs. Involve critics only when the answer changes an
   agreed contract. Post one joint ANSWER.
8. Review a PR only when the reviewing designer and the implementer disagree with
   evidence on both sides.

## Steps: critic

1. Before reading the lead's `Candidates`, post a CRITIQUE with one independent
   alternative or concern from your persona, or say you have none. Then add your
   ranking of all candidates, one reason per rank.
2. CRITIQUE each later PROPOSAL by the skill's critique rules. Ask to reopen the choice
   only for a required rule violation or new evidence that changes feasibility, required
   behaviour or cost. The lead decides and says why.
3. AGREE when no P0 or P1 remains and each P2 has a decision. Name the PROPOSAL URL.
4. Answer an implementer's QUESTION only when the lead asks.

## Steps: reviewing designer

1. The dispatcher launches you with `team.py review <pr> <entry>` in your own
   allocation. Run the `bootstrap.py --commit <head>` command your brief names.
2. Read the brief, then the diff, then the [PR body](../README.md#pr-body). Follow
   [review-software-design](../../skills/review-software-design/SKILL.md).
3. Submit the [review record](../README.md#pr-review-record). Resolve only your own
   threads. Send the review URL to the merge-confirming tester.
4. When notified of a new head, run the `bootstrap.py --commit <head>` command the notice
   names. Review the changes since your last review.

## Messages you send

- Lead: post PROPOSAL, ANSWER or BLOCKED on the spec or brief. Notify critics after each
  PROPOSAL. Send `done` to the dispatcher when agreement is complete.
- Critic: CRITIQUE, AGREE, QUESTION on the spec or brief.
- Reviewing designer: review URL to the merge-confirming tester.

## Do not

- Critics and reviewers do not edit spec or brief bodies. Only the lead does.
- The reviewing designer does not run `team.py turn`, review scenarios, run checks or
  merge. The tester is responsible for those tasks.
- Do not treat silence as agreement.
