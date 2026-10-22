---
name: design-software
description: Guides the lead architect and the critic architect of a tips feature. Covers reading, candidate designs, the choice, the spec and brief format, the required rules, the additional rules, the performance principles, the test budget, critique and the choice of implementer. Code reviews use review-software-design.
---

# Design software

For an unresolved consequential design choice, the lead owns the decision and a
critic challenges it from a different persona when that judgment is useful. The
[architect role](../../teams/roles/architect.md) defines turns, messages, the round limit
and the AGREE condition. Use this skill to write and assess the design.

Build Tips as a new MVP to test product demand. Learn through working software with
the simplest sufficient engineering. Let the user decide the product capabilities.
Settled bounded work uses the ordinary brief path, without a ceremonial design round.
The implementer applies [Design during delivery](../implement-software/SKILL.md#design-during-delivery);
architects integrate discoveries that change consequential technical commitments.

Scope limits:

- Classify performance and maintainability findings by the
  [severity table](../../teams/README.md#severity). A [Bounded work](#required-rules)
  violation is P1; other cost findings are P2 with a decision unless the table says
  otherwise.
- Prefer an objection that removes a part over one that adds a part.

## Step 1: Read

1. The feature's issue on Project 15.
2. The design sections the [design index](../../../docs/design/README.md) names.
3. The affected code and the mechanisms the repository already has for the same job:
   modules, Oban features, Ecto patterns, provider clients.
4. The contract and failure sections of
   [implement-software](../implement-software/SKILL.md#trace-the-affected-contract).
5. For a brief with `UX:`, the approved candidate under `design/<brief>/` at its SHA.
   Before the pair starts, UI and UX questions go to the
   [UX designer](../../teams/roles/ux-designer.md), with the user; after that, to the
   user through the dispatcher as `blocked`
   ([blocker route](../../teams/README.md#report-and-resolve-blockers)).

Write two lines before anything else: the product question this feature answers, and the
signal that would show the answer is wrong. Design the feature so that signal can be
observed.

## Step 2: Candidates

Consider alternatives before choosing a design. Do not select the first design that
works without comparing the required candidates.

Lead: post two or three candidates, each under 150 words: the mechanism, what it adds,
what it leaves out, which required rule it may violate and why. Include one candidate
that adds no new mechanism. One candidate is enough when settled requirements leave no
material design choice. Name the constraint.

Critic: before reading the lead's candidates, write one independent alternative or
concern from your persona, or say you have none. Then rank all candidates, one
reason per rank.

Assess every candidate using the questions for your persona. Keep separate question
lists for the two personas.

- Architecture: identify which module writes each fact. Locate validation and
  authorization checks. Identify other affected code. Find the simplest mechanism.
  Describe how a test proves the contract.
- Operations: identify failures and how to detect them. Identify concurrent operations
  that can conflict. Identify work that can grow without a limit. Identify migrations
  and their effect on existing rows. Consider attacker input.

## Step 3: Choice

Lead: rank the candidates. Name the choice and explain why you rejected the others.
Refine the chosen candidate in later PROPOSALs. Reopen the choice only for a required
rule violation or new evidence that changes feasibility, required behaviour or cost.
Explain your decision.

## Step 4: Spec

A shared spec is useful when several briefs depend on one contract. It is not required
solely to launch an architect for a question on a started brief. When needed, sections:

1. Product question and signal.
2. Briefs in dependency order, each with its agents.
3. Shared contracts that more than one brief depends on.
4. Decisions and deferrals table: decision; cheap or expensive to reverse; revisit
   trigger. Cheap: code, config, jobs, queries. Expensive: schema, stored data, public
   URLs, provider contracts, new dependencies.

Lead: edit the body. Other agents: use comments.

## Step 5: Briefs

One brief per PR. Keep it short; split only at contracts that can ship independently.
Start with the agreed outcome, genuine constraints, acceptance examples and roster:
`Implementer: <entry>` and `Required reviews: <entries>`, merge-confirming tester first.
A story that changes what the user sees also names `UX: <ux-designer entry>` and
`Graphic designers: <entry>, ...` ([UX design team](../../teams/README.md#ux-design-team)).
The default is one independent tester covering correctness and design. Add reviewers
only for an identified contribution.

The implementer inspects source and maintains the technical detail after launch:
affected contracts and links, relevant state/failure/ownership facts, proposed checks,
and decisions or deferrals with their reasons and revisit triggers. Reference a shared
decision instead of copying it. Initial file/function placement is guidance, not frozen
scope. Explicit restrictions and agreed contracts remain binding.

Number acceptance scenarios with input, action and observable result. Mark `Masking
risk:` where a test could pass with its intended defect, and name that defect. Explain
expected test additions/replacements when useful, and update the budget as evidence
changes; a source-informed contract check does not require advance architect permission.
Link relevant design sections and their revision rather than copying whole documents.

## Required rules

Critics and reviewers: classify a violation as P1. Use the examples to identify
violations.

1. **One owner per fact.** Assign one module to write each rule, counter or state.
   Define each in one place. Problem example: the same predicate in two queries; two
   modules that update `cleanup_at`.
2. **Explicit state and transitions.** Name state values and list transitions in a
   table. Make illegal transitions unrepresentable or reject them in one guard. Problem
   example: boolean flags that combine into states nobody listed.
3. **Named failure paths.** For every call that can fail, describe what happens on
   timeout, duplicate and crash between steps. Explain what makes the retry safe.
   Problem example: handling success while leaving error handling for later.
4. **Bounded work.** Set a size, time or page limit for every loop, scan, queue and job.
   State how work continues after that limit. Problem example: process all rows.
5. **Failure reporting.** Log the available identifiers and the reason for every rescue,
   retry and fallback. Do not hide an error or return a default that hides a failure.
   Problem example: `_ -> :ok`.

## Additional rules

Classify a violation as P2 and record a decision.

- **Checks where they belong, reuse of existing code, readable at the call site.** Apply
  the implementation skill's [code rules](../implement-software/SKILL.md#code-rules).
- **Simplest mechanism.** Choose the simplest mechanism that meets the contract's
  lifetime, durability and consistency needs. Use existing facilities first. State the
  present benefit that justifies each new mechanism. Problem example: a scheduler or
  cache whose lifetime or complexity has no present benefit. One caller does not
  by itself make a structural abstraction unnecessary.
- **Code that supports tests.** Put side effects behind a function a test can replace.
  Pass time and randomness as inputs. Problem example: tests that need sleeps or a real
  provider.
- **Change stays local.** Keep repairs within the affected flow, including necessary
  modules, callers and tests. Respect concurrent ownership and explicit restrictions;
  do not broaden a delivery into unrelated cleanup.

Follow the language and framework conventions in the stack skills listed in AGENTS.md.

## Performance principles

Apply these to each operation a feature adds or changes, at the expected MVP
workload. A finding names the operation, the workload, the consequence and the
change. Severity follows the [severity table](../../teams/README.md#severity).

1. **Know what cost grows with.** Name what time, memory, storage and waiting grow
   with: input size, users, content, request rate, concurrency. Include fixed costs
   and device and network conditions.
2. **Count the whole operation.** Count through to the required result: work done,
   data transferred, calls to other systems, repeated work, waits. A limit on output
   is not a limit on work.
3. **Do less work.** Fetch, compute, render and send only what helps produce the
   required result.
4. **Choose where work runs.** Compare the processing, transfer and waiting cost of
   each place it could run. Keep access rules and required behaviour.
5. **Keep the user's wait short.** Defer work the result does not need now. Keep
   completion and failure handling.
6. **Bound what grows.** Apply the Bounded work rule, including work moved to a
   background job.
7. **Choose for the operations you have.** Pick algorithms, data structures, storage
   layouts and indexes for the required reads and writes at the expected workload,
   not for an empty database or a general case.
8. **A copy has a cost.** Compare the time a cache, denormalized value or precomputed
   result saves with the memory, storage and update work it needs, including the
   work to keep it correct. Keep existing data and transaction contracts.
9. **Evidence fits the decision.** The brief records the limits and assumptions that
   affect the design. Measure only for a stated limit or a cost that could change
   the design, with the
   [measurement reference](../implement-software/references/performance-measurement.md).
   Say whether a number is an estimate or a measurement.

## Test budget

Use the brief to determine test additions.

- The scenarios and contracts are the test list. One to two tests per scenario.
- Tests banned by default are listed in the implementation skill's
  [Tests](../implement-software/SKILL.md#tests).
- Verification without a prior brief line follows the implementation skill's
  [Tests](../implement-software/SKILL.md#tests): explain the affected contract and gap.
- When a feature replaces behaviour, the brief names the tests to delete. Delete a test
  only when surviving tests cover its distinct required cases.
- Critic: name the uncovered contract when adding a scenario. The brief's writer
  updates the budget; unsettled contracts go to their decision owner.

## Step 6: Critique

Critic, for each PROPOSAL:

1. Write your concerns before reading the PROPOSAL.
2. Give one objection per `path:line`, trace, run or quoted requirement. State its
   severity.
3. Use P1 only for a required rule violation or a severity-table condition. Classify
   everything else as P2 with a proposed decision.
4. A P2 does not block. The lead records a decision in the table or a note to the
   implementer.
5. Check each scenario for a masking risk. For a scenario that has one but no mark,
   propose the mark and its distinguishing defect.

Lead, after each round:

1. A substantive change alters a contract, a scenario, an mechanism or the decisions
   table. It invalidates earlier AGREEs. Say so in the PROPOSAL.
2. If a shared contract changes, pause the briefs that depend on it until the spec is
   updated.
3. Post BLOCKED when both sides have evidence and still disagree, or when a product or
   scope question is open. Silence is not agreement.

## Step 7: Choose the implementer

Name a Haiku implementer only when all hold:

- The brief names every file and function to change, every contract and scenario.
- No design choice is open.
- No schema, migration, process or external service is added.
- A mechanical check proves the result.

Otherwise name an Opus entry and say which condition failed. The dispatcher applies
this to the available task evidence for an ordinary brief. Do not manufacture a larger
design artifact to qualify a task for a model. Count implementation, advisor, review
and repair work when assessing the choice.
