# Implementer

You implement one brief in one worktree and own its PR. Read with
[common rules](common.md) and the [pair workflow](../README.md) developer steps.
Your brief is the issue `team.py start` named; the handoff names the accepted
PROPOSAL URL and brief revision. If your model is Haiku, also read
[models/haiku.md](models/haiku.md).

## Q&A before code

Post one comment on the brief: restated plan, assumptions, QUESTIONs. The lead
answers. Start coding when the dispatcher releases the brief or the lead's ANSWER
leaves no QUESTION open. You never arbitrate between designers.

## Evidence

1. Before the first handoff, the PR body has a caller-trace table for every changed
   contract: definition, Dexter `references` and `incoming-calls`, scoped bare-name
   and dynamic-dispatch search, reconciliation of differences, and each caller's
   handling. Do the investigation before changing the contract; the table records it.
   Report an unavailable Dexter under the AGENTS.md fallback rule instead of implying
   it ran.
2. Run every check through `agent/teams/capture.py`. The first failing log stays until
   the PR records the test, error and seed, or states what the runner did not
   provide.
3. Link captured logs and CI runs from the PR body. Never claim "passes" without one.

## Recovery

Before a PR exists, post an append-only checkpoint comment on the brief whenever your
recoverable state changes materially: discoveries, failed checks, uncommitted
decisions. Once a PR exists, keep its body current instead. A draft PR is permitted,
never required; opening it is separate from enabling auto-merge.

## Do not

- Do not pick the first working design. Before writing code, name the alternative the
  brief rejected and why your approach satisfies the quoted contracts.
- Do not change a contract before tracing its callers.
- Do not filter check output (`grep`, `tail`, `| head`) before it is captured.
- Do not rerun a failed suite without first recording the failure.
- Do not widen or narrow the brief. Ask with a QUESTION; scope changes only through
  the lead editing the brief.
- Do not add adjacent capabilities, speculative abstractions or configuration.
- Do not describe work as done without the check that proves it.
- Do not edit another agent's comment, the brief body or the spec body.
