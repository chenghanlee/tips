# Dispatcher: design tier

Extends the [pair workflow](../README.md) dispatcher. Read with [common rules](common.md).

## What the trial tests

The user's experience suggests that implementers accept the first working design
and miss its effects elsewhere in Tips. The trial tests whether design review
improves correctness and design quality enough to justify its time and tokens.
The pilot traces do not establish this claim.

Save the lead's PROPOSAL before critique. Count changes to contracts, failure
handling or simplicity supported by the critic's evidence. No such changes, or
repeated failures under an agreed design, weaken the case for design rounds.

## Open a feature

1. Create the spec issue in the tips repo and add it to the swarm project:
   `gh project item-add <board.project> --owner <board.owner> --url <issue URL>`; set
   Kind, Feature and Phase there. Briefs are added the same way. Write the
   agent set in the body: designer names and the lead, tester names and the
   merge-confirming tester, the reviewing designer. Each is an `[agents.<entry>]`
   entry in `config.toml`. The lead copies the set into each brief: `Implementer:`
   and `Required reviews:`, testers first, the merge-confirming tester first of all.
2. Prepare the designers' worktree by hand: `git worktree add --detach
   .worktrees/design-<spec issue> origin/main`, install deps, build, start Dexter per
   the [LSP guide](../../lsp/README.md). You own it and remove it when the feature
   is done. Designers read and run Dexter there; they do not edit tracked files or
   run checks. Scratch goes in its `tmp/`. A designer that needs to run a check asks
   you for a pinned reviewer worktree with its own database suffix and port, as the
   reviewing designer gets for PR review.
3. Launch each designer by hand through Herdr with its role file, persona, the spec
   issue and whether it is lead or critic. Record each launch on the spec issue:
   `agent/teams/board.py post <spec> EVENT --as designer <name> <session id>` with the
   body `launched <client> by hand`. Record a replacement the same way with the body
   `took over for <name>`.
4. Personas: architecture (data integrity, contract boundaries, consistency with the
   existing architecture, simplicity, testability, effects on other code) and operations
   (failure and recovery paths, concurrency, security and authorization,
   performance, migrations and rollout, user-visible behaviour on existing data). One
   designer covers both; with three or more, divide the focus areas without overlap.

## Release a brief to implementation

Move a brief to Q&A only when all hold:

- Every assigned critic has a current AGREE naming the latest PROPOSAL URL and the
  brief revisions it covers.
- No P0 or P1 objection is open; every P2 has a recorded decision.
- No product decision is unresolved.
- The brief has an `Implementer` entry, acceptance scenarios, contracts and quoted
  design-doc sections with their revision, and a `Required reviews:` line that names
  every assigned tester and the reviewing designer from the spec's agent set, each
  once. Check the line against the spec yourself; the publisher reads only the brief.

With one designer and no critic, review the PROPOSAL against this list yourself and
accept it or send it back once.

Then run `agent/teams/team.py start <brief>`. The handoff names the accepted
PROPOSAL URL and brief revision. `start` launches the implementer and the
merge-confirming tester. When the merge-confirming tester asks you to launch the
other reviewers, run `agent/teams/team.py review <pr> <entry>` for each. `review` and
the tester's handoff read the brief's current `Required reviews:` line, so an added
reviewer only needs its `review` command. A changed implementer or merge-confirming
tester cannot be replaced before the brief's work is merged.

## Rounds and liveness

- After assigning a round, record a deadline 30 minutes later on the spec issue.
  Do not reset it when a wait returns early. Until the trial confirms that a
  background `herdr agent wait <name> --timeout <ms>` can resume your turn, the user
  must notify you at the deadline if no round record or blocker arrives. If you use
  this wait, set its timeout to the remaining time. If it returns without a round
  record, wait again only for the remaining time.
- At the deadline, check message delivery and agent state. Give a live agent at
  most one extension and record why. Before replacing a stopped session, confirm
  its work has stopped and read its records. The replacement reviews the same
  PROPOSAL and open objections, then posts EVENT "took over". If the next deadline
  passes without a result, ask the user. A timeout is not approval.
- Design rounds: default one CRITIQUE plus one repair pass. A third round needs your
  written reason; cap five, then BLOCKED and escalate.
- Q&A: cap three rounds, then BLOCKED and escalate.

## Measurement

Record this table on the spec issue when the feature is done. Report raw values;
do not combine them into a ratio until three features are complete. The first
feature tests whether the workflow works, not whether it caused an improvement.
Use #327 and #65 to identify repeated failures, not as a control group.

| Measure | Source |
|---|---|
| Feature start to verified, wall clock | First EVENT to merge of the last brief |
| Per-agent elapsed and checkout-holding time | `agent/teams/board.py usage <spec> <brief>...` from the EVENTs; waiting is elapsed minus holding, known only for pair agents |
| Human minutes and interventions | Your log; disclose each |
| Tokens per agent by model, advisors and restarts included; cached input once | The same `usage` table, from `~/.claude/projects` JSONL and `~/.codex/sessions` joined on the session id in each launch EVENT |
| Acceptance scenarios passing | Tester review records |
| Findings by severity from review; escaped defects until the next feature's review | PR reviews, later issues |
| Design changes supported by critique; rework caused by design changes | Saved PROPOSAL versus accepted brief |

Before launch, record the user's maximum added delay. Remove design rounds if
the trial produces no correction supported by evidence or exceeds that delay.
