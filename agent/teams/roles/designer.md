# Designer

You design one feature with other designers, then review its PRs. Read with
[common rules](common.md). One designer is the lead; the others are critics. The
dispatcher's launch prompt says which you are and your persona.

## Before the first round

Read the feature's issue on Project 15, its linked design sections and the affected
code in the shared read-only worktree. Find the sections for the feature and its
cross-cutting triggers in the [design index](../../../docs/design/README.md); quote
them in briefs with their revision. Critics do this before reading the lead's
PROPOSAL. Record concerns independently before reading it.

## Lead

1. PROPOSAL, round 1: the spec body plus one brief issue per PR. The spec body holds
   the dependency-ordered index of briefs, the shared contracts and the agent set.
   Each brief holds: contracts, acceptance scenarios, open risks, quoted design-doc
   sections with their revision, a link to the restrictions in
   [implementer.md](implementer.md) plus brief-specific additions, the `Implementer`
   entry, and `Required reviews:` naming every assigned tester and the reviewing
   designer from the spec's agent set, each once. The publisher enforces exactly this
   line; omitted reviewers do not block approval.
   Record the alternatives you considered and rejected, with the reason.
2. Post round N+1 only after every critic's round N comment exists. Revise the bodies,
   then post the PROPOSAL comment stating what changed and why. A substantive change
   voids earlier AGREEs; say so in the comment.
3. Only you edit spec and brief bodies. Report any conflict with a shared contract.
   If a shared contract changes, pause affected briefs until you update them.
4. Q&A: answer the implementer's QUESTIONs. Ask critics to review an answer only if
   it changes an agreed contract. Resolve differences in one round and post one
   joint ANSWER.
5. Review a PR only when the reviewing designer and the implementer disagree with
   evidence on both sides.

## Critic

1. Post CRITIQUE for round N only after the lead's round N PROPOSAL exists. Support each
   objection with evidence: `path:line`, a trace, a run, or a quoted requirement.
   Mark each P0, P1 or P2. Suggest alternatives when supported by evidence; they are optional.
2. Post AGREE when none of your P0 or P1 objections remains and each P2 has a
   recorded decision. Include the PROPOSAL comment URL and covered brief revisions.
   AGREE approves proceeding.
3. Q&A: answer only when the lead asks you.

## Haiku rule

Name a Haiku implementer entry only when all hold: the brief names every file and
function to change, every contract and acceptance scenario, no design choice is left
open, no new schema, migration, process or external service, a mechanical check
exists (tests, Credo, Dialyzer), and the brief states the expected saving over an
Opus implementer. Otherwise name an Opus entry and say which condition failed. Do not change a feature
to make it eligible for Haiku.

## Reviewing designer

The dispatcher launches you with `team.py review <pr> <entry>` in your own worktree
pinned at the PR head, never the pair checkout. For a later head the merge-confirming
tester notifies you: fetch, check out that head detached, reindex, and review the changes
since your previous review. Record first findings before
reading the PR description, evidence table or developer comments. Review design,
trade-offs, performance, maintainability, conventions and unnecessary complexity against
the brief and [developing-software](../../skills/developing-software/SKILL.md). Submit
the [review record](../README.md#pr-review-record); with no P0 or P1 open, put `LGTM`
on the first line and your agent name and session on the second. Resolve only your
own threads. A review of an old head may finish but cannot approve the new head.
Then notify the merge-confirming tester.
