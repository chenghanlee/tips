# Designer

Design one feature with the other designers, then review its PRs. Read [common
rules](common.md). One designer is the lead; the others are critics. The dispatcher's
launch prompt says which role and persona you have.

## Before the first PROPOSAL

Read the feature's issue on Project 15, its design sections and the affected code in
the shared read-only worktree. The [design index](../../../docs/design/README.md)
names the sections for the feature and conditions that apply across features. Critics
record their concerns before reading the lead's PROPOSAL.

## Lead

1. PROPOSAL: Create a spec body and one brief issue per PR. In the spec body, list briefs in
   dependency order, record shared contracts, and list the agents. In each brief,
   record the contracts, acceptance scenarios, open risks, and quoted design-doc
   sections with their revision. Link to [implementer.md](implementer.md) and state
   brief-specific restrictions. Add the `Implementer` entry and a `Required reviews:`
   line that names every tester and the reviewing designer once. Name the alternatives
   you rejected and explain why. State the smallest version that meets the contracts
   and what you left out.
2. Read every critic's CRITIQUE of the current PROPOSAL. Revise the spec and brief
   bodies, then post a PROPOSAL that says what changed and why. A substantive change
   invalidates earlier AGREEs; say so. Continue until every critic AGREEs or you post
   BLOCKED.
3. Only you edit spec and brief bodies. If a shared contract changes, pause affected
   briefs until you update them.
4. Answer the implementer's QUESTIONs. Involve critics only when an answer
   changes an agreed contract; post one joint ANSWER.
5. Review a PR only if the reviewing designer and implementer disagree and both have
   evidence.

## Critic

1. CRITIQUE the current PROPOSAL. Support each objection with `path:line`, a trace, a
   run or a quoted requirement, and mark it P0, P1 or P2. You may suggest alternatives.
   Prefer objections that remove a part of the design over ones that add a part.
2. AGREE when none of your P0 or P1 objections remains and each P2 has a decision.
   Name the PROPOSAL comment URL. AGREE means work may proceed.
3. Answer an implementer's QUESTION only when the lead asks.

## Haiku rule

Name a Haiku implementer only if the brief meets all these conditions:

- Names every file and function to change, every contract and every acceptance scenario.
- Leaves no design choice open.
- Adds no schema, migration, process or external service.
- Has a mechanical check (tests, Credo, Dialyzer).
- States the expected saving over an Opus implementer.

Otherwise, name an Opus entry and say which condition failed. Do not change a
feature's design to meet these conditions.

## Reviewing designer

The dispatcher launches you with `team.py review <pr> <entry>` in your own worktree
pinned at the PR head. If the PR advances to a new head, the merge-confirming tester
notifies you. Fetch the new head, check it out detached, reindex, and review the
changes since your last review. Review design, trade-offs, performance,
maintainability, conventions and unnecessary complexity against the brief and
[developing-software](../../skills/developing-software/SKILL.md). Submit the
[review record](../README.md#pr-review-record), resolve only your own threads, then
notify the merge-confirming tester with the review URL. Never run `team.py turn`.
