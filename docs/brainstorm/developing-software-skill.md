# Developing software skill draft

Intermediate base for rethinking the
[developing-software skill](../../agent/skills/developing-software/SKILL.md).
The aim is to guide engineering judgment during implementation: maintainable
software, proportionate attention to scale and reliability, and fast delivery
suited to an MVP. This draft does not replace the active skill or repository rules.

## Direction

A short workflow gives the agent orientation. Concrete decision rules provide
the useful guidance. Each rule should help the agent notice a consequential
situation, investigate it, and choose its next action.

Generic instructions such as "understand the requirements" and "keep it simple"
mostly repeat knowledge the agent already has. The skill earns its place when
it changes a decision the agent might otherwise get wrong. Optimize for better
decisions per instruction token.

The skill can direct attention and activate existing knowledge. Whether it
improves engineering judgment must be evaluated through implementation results.

## Engineering perspective

Build the smallest complete behavior that meets the current requirement. Spend
care according to consequence and reversibility. A disposable screen and a
data model that accumulates records deserve different levels of deliberation.

Understand the affected flow beyond the changed lines. Keep modifications within
the assignment. Prefer clear ownership, explicit contracts, familiar mechanisms
and few interacting parts. Consider scale through concrete workload and growth
assumptions; introduce additional machinery when a requirement or evidence
justifies its cost.

We do not yet have user behavior or feedback. Technical decisions can use source
code, dependency documentation, existing tests, local logs and traces, database
inspection, and focused experiments. Measurements with synthetic inputs support
claims about those inputs, not production demand or product usefulness.

## Proposed workflow

Follow [AGENTS.md](../../AGENTS.md), the applicable language and framework skills,
and the [pair workflow](../../agent/teams/README.md) when paired. The steps below
guide implementation decisions; they do not add reporting or approval gates.

Understand → Resolve uncertainty → Change → Refine the design → Verify → Finish.

### Understand

Read the requirement, relevant code and existing tests. Separate required behavior
from a suggested implementation. Identify the observable outcome, the invariants
that must remain true, and where the affected rules currently belong.

Proceed when you can explain what must change and what must remain true.

### Resolve uncertainty

Identify assumptions that could change the implementation. Inspect available
evidence first. When it cannot settle a consequential question, use the smallest
test, trace, measurement or experiment that can distinguish the plausible answers.
Verify the specific dependency guarantees the design relies on.

Proceed when the evidence is sufficient to choose an approach. Distinguish
observations, inferences and untested assumptions. Escalate unresolved requirement
or scope decisions through the existing workflow.

### Change

Extend the appropriate owner using existing mechanisms when they meet the
requirement. Read existing tests, add or update coverage for new behavior or a
regression, and observe the expected failure before changing the implementation.
Work in increments small enough to verify.

When new evidence contradicts the approach, revisit the decision it affects.
Repeated flags, special cases and duplicated decisions are reasons to inspect
the model and ownership before adding more code.

Proceed when the required behavior works through the affected flow.

### Refine the design

Treat the first working implementation as evidence about the design. With what
you now know, would you choose the same ownership, state representation and
interfaces? Identify complexity caused by assumptions the implementation disproved.

Refactor or replace the affected parts when a concrete alternative makes the
required behavior easier to understand, change or operate. Prefer the smallest
revision that removes the cause. "Throw one away" means being willing to discard
an approach despite the effort already spent; it does not require a second
implementation for every task. For a difficult uncertainty, a disposable experiment
may resolve the design before the first complete implementation.

Preserve required observable behavior and use relevant tests to check each
refactoring increment. Remove superseded paths and update affected documentation.
Keep refinement within the assignment; raise broader redesigns through the existing
scope process. Do not add abstractions for hypothetical future requirements.

Proceed when no identified design problem justifies further change for this task.
Keeping the first design is a valid result. Return to this step earlier whenever
implementation evidence warrants it.

### Verify

Check the likely wrong behavior through public entry points. Run the relevant
tests and required repository checks. Inspect the diff and affected callers for
missed behavior, unnecessary complexity and obsolete code or documentation.

Proceed when required scenarios are covered and required checks pass. A named
verification gap does not waive a requirement. Report blockers under the existing
workflow.

### Finish

Report the resulting behavior, consequential trade-offs and material verification
limits. Follow the existing PR and handoff requirements. Do not narrate compliance
with every instruction.

## Decision rules to refine

These are the substance to develop and evaluate. The workflow alone is not enough.

| Situation | Question and action |
|---|---|
| A requirement suggests a mechanism | Identify which observable behavior requires it. Verify whether an existing mechanism already satisfies that behavior. |
| Another flag or special case seems necessary | Check whether the current representation permits invalid states or puts a decision in the wrong owner. Change the model when that removes the cause. |
| Similar code appears in several places | Establish whether it represents the same rule and should change together. Share it when the drift removed justifies the coupling introduced. Preserve validation at each trust boundary. |
| A design depends on a library guarantee | Verify that specific guarantee against the installed version and configuration. Similar names or examples do not establish equivalent behavior. |
| Work can finish late, repeat or outlive its caller | Identify the authoritative state and resource owner. Trace relevant interruption and recovery paths. Before applying a result, establish that it still belongs to the current operation. Cancellation requested does not mean work has stopped. |
| A fallible operation may have external effects | Establish what may already have committed and what evidence can settle an uncertain outcome before retrying. Preserve failure distinctions that change recovery. |
| Inputs or actions cross a trust boundary | Check validation and authorization at that boundary, including delayed work when permissions may have changed. |
| A design depends on performance | Identify the expected workload, what grows and the relevant resource limit. Measure the suspected dominant cost before optimizing it. Include retries and work that outlives the caller in bounds. |
| A test claims to protect behavior | Identify the plausible wrong behavior it would catch. Ensure doubles leave the production code responsible for the claimed property running. |
| A bug or review finding needs repair | Identify the broken invariant and inspect sibling sites that share it. Repair affected cases within scope and remove superseded paths. |

## Instruction design

- Give each rule one home. Reference existing repository and language instructions.
- Keep the common path short. Add supporting files only when conditional detail
  warrants another read.
- Make each rule connect a recognizable situation to a decision and an action.
- Keep concrete safeguards such as "a timeout does not prove the write failed."
  Generic summaries lose useful guidance.
- Bound investigation by affected contracts and uncertainties that could change
  the design or required verification.
- Require evidence for consequential claims, without requiring a written artifact
  for every reasoning step.
- Add examples only when they clarify a distinction the instruction cannot convey
  economically on its own.

## Next iteration

Review the active skill against this draft before proposing its replacement.
Preserve useful safeguards, remove duplication and reconsider broad obligations
that cause work without improving a decision.

Evaluate the candidate on a routine change, a stateful feature and a bug repair.
Inspect the resulting code and decisions: appropriate scope, justified ownership,
effective verification, and complexity avoided. Also check for unnecessary
investigation, reporting and token use. These evaluations have not yet been run.

Open questions:

- Which rules change behavior beyond the workflow and repository instructions?
- Which safeguards need examples, and which are already precise enough?
- Does the agent recognize when it has sufficient evidence to proceed?
- Does refinement remove demonstrated complexity without causing compulsory
  rewrites or speculative redesign?
- Can the common path stay short while retaining the active skill's useful detail?
