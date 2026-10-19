# Rules for all agents

Read this and your role file at launch and after compaction.

## Authority

- Follow your role file and the agreed outcome and constraints in the brief. The user
  owns product scope. The implementer owns a coherent working change and the bounded
  repairs in [Design during delivery](../../skills/implement-software/SKILL.md#design-during-delivery).
  A named designer owns consequential technical decisions; a linked ANSWER records
  that authority. Editing the brief records a decision, not permission to invent one.
- Start work on a Herdr message from the dispatcher or the agent handing off to you. End
  your turn after your own handoff. Do not poll.
- Route consequential technical questions through the dispatcher to a designer.
  Local source or verification questions may go to the existing reviewer when useful;
  consultation is not a mandatory step. Only the user decides UI,
  UX, user-facing behaviour and PRD questions. Record those decisions on the board.
- Silence, a timeout or a missing agent never counts as consent or approval.
- An answer or instruction that touches a required check or its evidence says whether
  it is a clarification (how to meet an obligation; it cannot change which checks run
  or what evidence counts), a substitution (replaces a check or its evidence) or a
  waiver (removes an obligation). A substitution or waiver names the obligations that
  still apply, the exact obligation it replaces or removes, any replacement, and its
  authority: a link to the record that allows the change, such as the user's decision,
  the brief or its decisions table, or a rule in this workflow. Without it, or when the
  kind or scope is unclear, the original obligation stands. A change only the user may
  make needs the user's own recorded decision. A role, a label or another agent's
  report of the user's view does not count.

## Comments

- Append comments without editing earlier comments. The dispatcher or design lead
  creates a brief; after launch only its implementer maintains its body and PR body.
  The lead maintains a shared spec. Link authoritative decisions instead of copying
  competing versions: briefs link the source issue and the design sections at their
  commit instead of copying them; for checks, they link
  [AGENTS.md#checks](../../../AGENTS.md#checks) and list only additions or exceptions.
  Incorporate an ANSWER before resuming affected work.
- The implementer records agreed additional reviewers in `Required reviews:`. The
  pair's implementer and merge-confirming tester cannot change after launch. Body
  authorship does not permit removing required review or waiving a finding.
- Post spec and brief comments with `agent/teams/board.py post <issue> <TYPE>`, body on
  stdin. It writes the header `<TYPE> <role> <name> <session>` from your pane and
  allocation record. Types: PROPOSAL, CRITIQUE, QUESTION, ANSWER, AGREE, FINDING,
  BLOCKED, DONE, EVENT. PR reviews use the [review record](../README.md#pr-review-record) instead.
- Keep each comment under 400 words. If it has more than 800 words, the script warns.
  Explain why it needs that many words. Put logs and screenshots in a gist with `gh gist create <file>`. Link to CI runs by URL. Do not paste output.
- Before compaction or a long step, record on GitHub any decision or finding not yet
  posted. After a restart, reread the brief (`gh issue view <issue>`) and the PR as
  [Turns](../README.md#turns) says.
- Post the comment, then send the Herdr prompt as a separate step. If you repeat the
  post, the script returns the existing comment's URL.

## Evidence and scope

- Support a source claim with `path:line` at its commit. For execution evidence use the
  CI run URL, or during the [CI pause](../../../AGENTS.md#github-ci-pause), the local
  command, tested SHA, result, environment and log path. Otherwise mark it unverified.
- Use the [README scale](../README.md#severity). A designer P1 and a tester P1 both
  block progress.
- Open a new issue for any improvement outside the brief. Keep that work out of the
  current PR.
- When several findings concern the same design, propose a simpler design before fixing
  them separately.
