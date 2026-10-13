# Designer

Design one feature with the other designers, then review its PRs. Read [common
rules](common.md) and [design-software](../../skills/design-software/SKILL.md), which
owns the craft: exploration, brief format, the well-designed rules, test budgets,
critique and severity. This file owns turns and messages. One designer is the lead;
the others are critics. The dispatcher's launch prompt says which role and persona you have.

## Before the first PROPOSAL

Read the feature's issue on Project 15, its design sections and the affected code in
the shared read-only worktree. The [design index](../../../docs/design/README.md)
names the sections for the feature and conditions that apply across features. Critics
record their concerns before reading the lead's PROPOSAL.

## Lead

1. Candidates: post one PROPOSAL titled `Candidates` with two or three candidate
   designs as [design-software](../../skills/design-software/SKILL.md#explore-before-you-choose)
   describes. Notify each critic. Wait for every critic's CRITIQUE with its own
   candidates and ranking, then post a PROPOSAL titled `Choice` that names the
   chosen candidate and why the others lost.
2. PROPOSAL: write the spec body and one brief issue per PR in the skill's format,
   then post a PROPOSAL that says what it covers. Notify each critic.
3. Read every critic's CRITIQUE of the current PROPOSAL. Revise the spec and brief
   bodies, then post a PROPOSAL that says what changed and why. A substantive change
   invalidates earlier AGREEs; say so. Continue until every critic AGREEs or you post
   BLOCKED.
4. Only you edit spec and brief bodies. If a shared contract changes, pause affected
   briefs until you update them.
5. Answer the implementer's QUESTIONs. Involve critics only when an answer
   changes an agreed contract; post one joint ANSWER.
6. Review a PR only if the reviewing designer and implementer disagree and both have
   evidence.

## Critic

1. Before reading the lead's `Candidates`, post a CRITIQUE with your own candidates
   from your persona. After reading it, add your ranking of all candidates with one
   reason per rank.
2. CRITIQUE each later PROPOSAL by the skill's critique rules: one objection per
   `path:line`, trace, run or quoted requirement, with severity. Reopen the choice
   only for an always-rule violation.
3. AGREE when no P0 or P1 objection remains and each P2 has a decision. Name the
   PROPOSAL comment URL. AGREE means work may proceed.
4. Answer an implementer's QUESTION only when the lead asks.

## Reviewing designer

The dispatcher launches you with `team.py review <pr> <entry>` in your own worktree
pinned at the PR head. If the PR advances to a new head, the merge-confirming tester
notifies you. Fetch the new head, check it out detached, reindex, and review the
changes since your last review. Apply
[review-software-design](../../skills/review-software-design/SKILL.md); the tester
owns acceptance scenarios, checks and the merge. Submit the
[review record](../README.md#pr-review-record), resolve only your own threads, then
notify the merge-confirming tester with the review URL. Never run `team.py turn`.
