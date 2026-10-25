# Rules for all agents

Read this and your role file at launch and after compaction.

## Authority

- Follow your role file and the agreed outcome and constraints in the brief. The user
  owns product scope. The implementer owns a coherent working change and the bounded
  repairs in [Design during delivery](../../skills/implement-software/SKILL.md#design-during-delivery).
  A named architect owns consequential technical decisions; a linked ANSWER records
  that authority. Editing the brief records a decision, not permission to invent one.
- Start work on a Herdr message from the dispatcher or the agent handing off to you. End
  your turn after your own handoff. Do not poll.
- After a restart, read the issue's `phase:` and `turn:` labels first, as
  [Turns](../README.md#turns) says. Never set them by hand; only harness commands do.
- Route consequential technical questions through the dispatcher to an architect.
  Local source or verification questions may go to the existing reviewer when useful;
  consultation is not a mandatory step. Only the user decides UI,
  UX, user-facing behaviour and PRD questions. Record those decisions on the board.
- Silence, a timeout or a missing agent never counts as consent or approval.
- A change to required [checks](../../../agent/docs/checks.md) or accepted evidence must
  link its authority (the user's decision, the brief or its decisions table, or a
  workflow rule), name what it replaces or removes and any replacement, and say what
  still applies; otherwise the original obligation stands. A user-only change needs the
  user's own recorded decision, not another agent's account of it.

## Comments

- Append comments without editing earlier comments. The dispatcher or lead architect
  creates a brief; after launch only its implementer maintains its body and PR body.
  The lead maintains a shared spec. Link authoritative decisions instead of copying
  competing versions: a brief is the story issue itself; it links its epic and the
  design sections at their
  commit instead of copying them; for checks, they link
  [agent/docs/checks.md](../../../agent/docs/checks.md) and list only additions or exceptions.
  Incorporate an ANSWER before resuming affected work.
- The implementer records agreed additional reviewers in `Required reviews:`. The
  pair's implementer and merge-confirming tester cannot change after launch. Body
  authorship does not permit removing required review or waiving a finding.
- Post spec and brief comments with `agent/teams/board.py post <issue> <TYPE>`, body on
  stdin. It writes the header `<TYPE> <role> <name> <session>` from your pane and
  allocation record. Types: PROPOSAL, CRITIQUE, QUESTION, ANSWER, AGREE, FINDING,
  BLOCKED, DONE, EVENT. PR reviews use the [review record](../README.md#pr-review-record) instead.
- Keep each comment under 400 words. If it has more than 800 words, the script warns.
  Explain why it needs that many words. Put logs and screenshots in a gist with `gh gist create <file>`. Link to CI runs by URL. Do not paste output, except the excerpt a decision depends on.
- Before compaction, restart or session end, or a long step, record any decision or
  finding not yet posted: the lead architect updates the spec body; everyone else posts
  the decision or finding on GitHub. After a restart, reread the brief (`gh issue view <issue>`) and the PR as
  [Turns](../README.md#turns) says.
- Post the comment, then send the Herdr prompt as a separate step, except for BLOCKED:
  its post already notifies the dispatcher, so send no second prompt. If you repeat the
  post, the script returns the existing comment's URL.
