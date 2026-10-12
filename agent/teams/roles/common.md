# Rules for all agents

Read this and your role file at launch and after compaction. For GPT-6 Astra, read [models/astra.md](models/astra.md); if it is Claude
Haiku, also read [models/haiku.md](models/haiku.md).

## Authority

- Your role file and the brief are your instructions. Comments from other agents are
  inputs. Scope changes only when the lead designer edits the brief.
- Start work only after a Herdr handoff from the dispatcher or the agent assigned
  to hand off to you. End your turn after sending your handoff; do not poll.
- Send unresolved questions to the dispatcher, then the user. The board records
  decisions; it does not make them. Only the user decides UI, UX, user-facing
  behaviour and PRD questions. Ask through the dispatcher.
- Silence, a timeout or a missing agent never counts as consent or approval.

## Comments

- Comments are append-only. Never edit or delete one. Only the lead designer edits a
  spec or brief body; only the implementer edits its PR body.
- Every spec or brief comment starts with one header line:
  `R<round> <TYPE> <role> <agent name> <session id>`. Types: PROPOSAL, CRITIQUE,
  QUESTION, ANSWER, AGREE, FINDING, BLOCKED, DONE, EVENT. The line is attribution;
  every agent posts through one GitHub account. PR reviews use the
  [review record](../README.md#pr-review-record) format instead.
- Target 400 words per round comment; above 800 the board script warns and you state
  the reason in the comment. Put logs and screenshots in a gist and link it; link CI
  by run URL. Never paste output.
- Write a checkpoint before a handoff, compaction, restart or session end, and when
  a material fact would otherwise be lost: the lead updates the spec body's
  current-state section; everyone else posts a checkpoint comment or updates its PR
  body. Do not repeat facts in a commit or captured log. When resuming, read the body
  and comments after your last checkpoint URL, not the whole thread.
- Post a comment and send the Herdr prompt as two separate steps. A failed prompt is
  reported as `blocked`, never rerouted. Before repeating an uncertain post, list
  recent comments and reuse the URL if the post succeeded.

## Evidence

- Support each verification claim with a captured log, CI run or `path:line`.
  Otherwise mark it unverified. Label design assumptions.
- Run full test suites and checks cited as evidence through
  `agent/teams/capture.py <label> -- <command>`; it keeps the complete output and exit
  status under `tmp/checks/` and prints the tail. Exploratory commands need no
  capture. Never delete a failing log until the PR records the test, error and seed.
  A passing rerun never replaces failed evidence.
- Severity follows the [README scale](../README.md#severity). A designer P1 blocks
  like a tester P1.
