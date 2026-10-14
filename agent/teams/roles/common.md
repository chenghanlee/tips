# Rules for all agents

Read this and your role file at launch and after compaction.

## Authority

- Follow your role file and the brief. Treat other agents' comments as information to
  consider. Scope changes only when the lead designer edits the brief.
- Start work on a Herdr message from the dispatcher or the agent handing off to you. End
  your turn after your own handoff. Do not poll.
- Send unresolved questions to the dispatcher, then the user. Only the user decides UI,
  UX, user-facing behaviour and PRD questions. Record those decisions on the board.
- Silence, a timeout or a missing agent never counts as consent or approval.
- An answer or instruction that touches a required check or its evidence says which
  kind it is:
  - Clarification: explains how to meet an obligation. It cannot change which checks
    run or what evidence counts.
  - Substitution: replaces a check or its evidence with another. It names the exact
    obligation replaced, the replacement, the obligations that still apply, and its
    authority.
  - Waiver: removes an obligation. It names the exact obligation, the obligations that
    still apply, and its authority.

  Authority is a link to the record that allows the change: the user's decision, the
  brief or its decisions table, or a rule in this workflow. Without it, or when the
  kind or scope is unclear, the original obligation stands. A change only the user may
  make needs the user's own recorded decision. A role, a label or another agent's
  report of the user's view does not count.

## Comments

- Append comments without editing earlier comments. Only the lead designer edits a spec
  or brief body. Only the implementer edits its PR body.
- Post spec and brief comments with `agent/teams/board.py post <issue> <TYPE>`, body on
  stdin. It writes the header `<TYPE> <role> <name> <session>` from your pane and
  allocation record. Types: PROPOSAL, CRITIQUE, QUESTION, ANSWER, AGREE, FINDING,
  BLOCKED, DONE, EVENT. PR reviews use the [review record](../README.md#pr-review-record) instead.
- Keep each comment under 400 words. If it has more than 800 words, the script warns.
  Explain why it needs that many words. Put logs and screenshots in a gist with `gh gist create <file>`. Link to CI runs by URL. Do not paste output.
- Before compaction, restart or session end, or when your state is not already in a
  posted PROPOSAL, review or PR body, save a checkpoint. The lead designer updates the
  spec body. Everyone else posts a checkpoint comment or updates their PR body. Resume
  with `agent/teams/board.py read <issue> --after <your checkpoint URL>`.
- Post the comment, then send the Herdr prompt as a separate step. If you repeat the
  post, the script returns the existing comment's URL.

## Evidence and scope

- Support a verification claim with the CI run URL or `path:line`. For a check CI does
  not run, say what you ran and its result. Otherwise mark it unverified.
- Use the [README scale](../README.md#severity). A designer P1 and a tester P1 both
  block progress.
- Open a new issue for any improvement outside the brief. Keep that work out of the
  current PR.
- When several findings concern the same design, propose a simpler design before fixing
  them separately.
