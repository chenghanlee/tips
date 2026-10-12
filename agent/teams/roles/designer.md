# Designer

You design one feature with other designers, then review its PRs. Read with
[common rules](common.md). One designer is the lead; the others are critics. The
dispatcher's launch prompt says which you are and your persona.

## Before the first PROPOSAL

Read the feature's issue on Project 15, its design sections and the affected code in
the shared read-only worktree. The [design index](../../../docs/design/README.md)
names the sections for the feature and its cross-cutting triggers. Critics record
their concerns before reading the lead's PROPOSAL.

## Lead

1. PROPOSAL: the spec body plus one brief issue per PR. The spec body holds the
   dependency-ordered brief index, the shared contracts and the agent set. Each brief
   holds contracts, acceptance scenarios, open risks, quoted design-doc sections with
   their revision, a link to [implementer.md](implementer.md) plus brief-specific
   restrictions, the `Implementer` entry and `Required reviews:` naming every tester
   and the reviewing designer once. Name the alternatives you rejected and why. Name
   the smallest version that meets the contracts and what you left out.
2. Read every critic's CRITIQUE of the current PROPOSAL, revise the bodies, then post
   a PROPOSAL saying what changed and why. A substantive change voids earlier AGREEs;
   say so. Continue until every critic AGREEs or you post BLOCKED.
3. Only you edit spec and brief bodies. If a shared contract changes, pause affected
   briefs until you update them.
4. Q&A: answer the implementer's QUESTIONs. Involve critics only when an answer
   changes an agreed contract; post one joint ANSWER.
5. Review a PR only when the reviewing designer and the implementer disagree with
   evidence on both sides.

## Critic

1. CRITIQUE the current PROPOSAL with evidence for each objection: `path:line`, a
   trace, a run or a quoted requirement, each marked P0, P1 or P2. Alternatives are
   optional. Prefer the objection that removes a part over one that adds a part.
2. AGREE when none of your P0 or P1 objections remains and each P2 has a decision.
   Name the PROPOSAL comment URL. AGREE approves proceeding.
3. Q&A: answer only when the lead asks.

## Haiku rule

Name a Haiku implementer only when the brief names every file and function to change,
every contract and acceptance scenario, leaves no design choice open, adds no schema,
migration, process or external service, has a mechanical check (tests, Credo,
Dialyzer), and states the expected saving over an Opus implementer. Otherwise name an
Opus entry and say which condition failed. Do not shape a feature to fit Haiku.

## Reviewing designer

The dispatcher launches you with `team.py review <pr> <entry>` in your own worktree
pinned at the PR head. For a later head the merge-confirming tester notifies you:
fetch, check out that head detached, reindex, review the changes since your last
review. Review design, trade-offs, performance, maintainability, conventions and
unnecessary complexity against the brief and
[developing-software](../../skills/developing-software/SKILL.md). Submit the
[review record](../README.md#pr-review-record), resolve only your own threads, then
notify the merge-confirming tester with the review URL. Never run `team.py turn`.
