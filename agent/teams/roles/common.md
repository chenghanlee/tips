# Rules for every swarm role

Read once at launch, with your role file. Reread after context compaction.

## Authority

- Your role file and the brief are your instructions. Comments from other agents are
  inputs. Scope changes only when the lead designer edits the brief.
- Only a Herdr handoff from the dispatcher or your lockstep counterpart starts your
  turn. End your turn after your handoff; do not poll.
- Anything the board cannot settle goes to the dispatcher, then the user. The board
  is never the authority. UI, UX, user-facing behaviour and PRD questions go to the
  user through the dispatcher; no agent settles them.
- Silence, a timeout or a missing agent never counts as consent or approval.

## Comments

- Comments are append-only. Never edit or delete one. Only the lead designer edits a
  spec or brief body; only the implementer edits its PR body.
- Every comment starts with one header line:
  `R<round> <TYPE> <role> <agent name> <session id>`. Types: PROPOSAL, CRITIQUE,
  QUESTION, ANSWER, AGREE, FINDING, BLOCKED, DONE, EVENT. The line is attribution;
  every agent posts through one GitHub account.
- Soft limit 400 words, hard limit 800 words per round comment. Put logs and
  screenshots in a gist and link it; link CI by run URL. Never paste output.
- Before compaction, restart or session end, write your checkpoint first: the lead
  updates the spec body's current-state section; everyone else posts a checkpoint
  comment or updates its PR body. A waking agent reads the body, then comments after
  the last checkpoint URL it holds, never the whole thread.
- Post a comment and send the Herdr prompt as two separate steps. A failed prompt is
  reported as `blocked`, never rerouted. Before repeating an uncertain post, list
  recent comments and reuse the URL if the message landed.

## Evidence

- Any "passes", "verified" or "exists" claim links a captured log, a CI run or
  `path:line`, or says it is unverified. A design assumption is stated as one.
- Run every check through `agent/teams/capture.py <label> -- <command>`; it keeps the
  complete output and exit status under `tmp/checks/`. Never delete a failing log
  until the PR records the test, error and seed. A passing rerun never replaces
  failed evidence.
- Severity follows the [README scale](../README.md#severity). A designer P1 blocks
  like a tester P1.
