# Dispatcher: design tier

Extends the [pair workflow](../README.md) dispatcher. Read with [common rules](common.md).

## Hypothesis under test

From the user's experience, not from the pilot traces: implementers lock onto the
first working design and miss first- and second-order effects on the rest of Tips, so
a design round before implementation raises correctness and design quality per unit
of time and tokens. Falsifier: the lead's PROPOSAL is saved before critique; count
the critic's evidenced changes to contracts, failure handling or simplicity. None
across the trial weakens the case. Recurring application failures under an agreed
design count against the claim that the tier fixes them.

## Open a feature

1. Create the spec issue in the tips repo and add it to the swarm project. Write the
   agent set in the body: designer names and the lead, tester names and the
   merge-confirming tester, the reviewing designer. Each is an entry in
   `config.toml`.
2. Prepare one shared read-only worktree at `main` HEAD with compiled deps and
   Dexter for the designers.
3. Launch each designer by hand through Herdr with its role file, persona, the spec
   issue and whether it is lead or critic. Record each launch as an EVENT comment on
   the spec issue with the agent name and session id.
4. Personas: architecture (data integrity, contract boundaries, consistency with the
   existing architecture, simplicity, testability, blast radius) and operations
   (failure and recovery paths, concurrency, security and authorization,
   performance, migrations and rollout, user-visible behaviour on existing data). One
   designer carries both; three or more split them so no two share a persona.

## Release a brief to implementation

Move a brief to Q&A only when all hold:

- Every assigned critic has a current AGREE naming the latest PROPOSAL URL and the
  brief revisions it covers.
- No P0 or P1 objection is open; every P2 has a recorded disposition.
- No product decision is unresolved.
- The brief has an `Implementer` entry, acceptance scenarios, contracts and quoted
  design-doc sections with their revision, and a `Required reviews:` line that names
  every assigned tester and the reviewing designer from the spec's agent set, each
  once. Check the line against the spec yourself; the publisher reads only the brief.

With one designer and no critic, review the PROPOSAL against this list yourself and
accept it or send it back once.

Then run `agent/teams/team.py start <brief>`. The handoff names the accepted
PROPOSAL URL and brief revision.

## Rounds and liveness

- After delivering a round assignment, record the due time 30 minutes out on the
  spec issue (a trial setting). The due time never moves. Until the trial shows that
  a background `herdr agent wait <name> --timeout <ms>` returning wakes you, this is
  an operator checkpoint: the user wakes you at the due time if no round record or
  blocker arrived. If you use the wait, give it the remaining time to the due time,
  and an early return without the round record only re-arms it for the remainder.
- At the checkpoint, inspect delivery and agent state. A live agent gets one
  reasoned extension. Replace a dead session only after its activity stopped and its
  records are read; the replacement reviews the same PROPOSAL and inherited
  objections and posts EVENT "took over". A second unresolved checkpoint goes to the
  user. No approval by timeout.
- Design rounds: default one CRITIQUE plus one repair pass. A third round needs your
  written reason; cap five, then BLOCKED and escalate.
- Q&A: cap three rounds, then BLOCKED and escalate.

## Measurement

Record this table on the spec issue when the feature is done. Raw numbers only; no
collapsed ratio until three features. The first feature is a feasibility test, not a
causal comparison; #327 and #65 are recurrence evidence, not a control group.

| Measure | Source |
|---|---|
| Feature start to verified, wall clock | First EVENT to merge of the last brief |
| Per-agent working and waiting time | EVENT and comment timestamps |
| Human minutes and interventions | Your log; disclose each |
| Tokens per agent by model, advisors and restarts included; cached input once | `~/.claude/projects` JSONL, `~/.codex/sessions`, joined on session id |
| Acceptance scenarios passing | Tester review records |
| Findings by severity from review; escaped defects until the next feature's review | PR reviews, later issues |
| Evidenced design changes from critique; rework caused by design changes | Saved PROPOSAL versus accepted brief |

Pre-registered removal criterion for the design round: no evidenced correction in
the trial, or added delay above a number the user sets before launch.
