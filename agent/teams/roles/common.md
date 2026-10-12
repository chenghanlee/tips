# Rules for all agents

Read this and your role file at launch and after compaction. GPT-6 Astra also reads
[models/astra.md](models/astra.md); Claude Haiku also reads [models/haiku.md](models/haiku.md).

## Authority

- Your role file and the brief are your instructions; other agents' comments are
  inputs. Scope changes only when the lead designer edits the brief.
- Start work on a Herdr message from the dispatcher or the agent handing off to you.
  End your turn after your own handoff; do not poll.
- Unresolved questions go to the dispatcher, then the user. Only the user decides UI,
  UX, user-facing behaviour and PRD questions. The board records decisions; it does
  not make them.
- Silence, a timeout or a missing agent never counts as consent or approval.

## Comments

- Comments are append-only. Only the lead designer edits a spec or brief body; only
  the implementer edits its PR body.
- Post spec and brief comments with `agent/teams/board.py post <issue> <TYPE>`, body
  on stdin. It writes the header `<TYPE> <role> <name> <session>` from your pane and
  allocation record. Types: PROPOSAL, CRITIQUE, QUESTION, ANSWER, AGREE, FINDING,
  BLOCKED, DONE, EVENT. PR reviews use the
  [review record](../README.md#pr-review-record) instead.
- Keep a comment under 400 words; above 800 the script warns and you say why. Logs
  and screenshots go in a gist (`gh gist create <file>`); CI by run URL. Never paste
  output.
- Checkpoint before a handoff, compaction, restart or session end: the lead updates
  the spec body, everyone else posts a checkpoint comment or updates its PR body.
  Resume with `agent/teams/board.py read <issue> --after <your checkpoint URL>`.
- Post the comment and send the Herdr prompt as two steps. A repeat post is safe: the
  script returns the existing comment's URL.

## Evidence and scope

- Support a verification claim with the CI run URL or `path:line`. For a check CI
  does not run, say what you ran and its result. Otherwise mark it unverified.
- Severity follows the [README scale](../README.md#severity). A designer P1 blocks
  like a tester P1.
- An improvement outside your brief becomes a new issue, not more PR.
- When findings pile up against one design, propose the smaller design before
  patching each finding into more machinery.
