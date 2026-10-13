---
name: design-software
description: Guides the design lead and the design critic of a tips feature. Covers reading, candidate designs, the choice, the spec and brief format, the required rules, the additional rules, the performance principles, the test budget, critique and the choice of implementer. Code reviews use review-software-design.
---

# Design software

Lead: write the spec and briefs. Critic: assess them from a different persona. The
[designer role](../../teams/roles/designer.md) defines turns, messages, the round limit
and the AGREE condition. Use this skill to write and assess the design.

Build Tips as a new MVP to test product demand. Design the smallest change that
satisfies the contracts. Let the user decide which product capabilities are required.

Scope limits:

- Use the [severity table](../../teams/README.md#severity). Classify performance and
  maintainability findings as P2 with a decision.
- Prefer an objection that removes a part over one that adds a part.

## Step 1: Read

1. The feature's issue on Project 15.
2. The design sections the [design index](../../../docs/design/README.md) names.
3. The affected code and the mechanisms the repository already has for the same job:
   modules, Oban features, Ecto patterns, provider clients.
4. The contract and failure sections of
   [implement-software](../implement-software/SKILL.md#trace-the-affected-contract).

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

One spec per feature. Sections:

1. Product question and signal.
2. Briefs in dependency order, each with its agents.
3. Shared contracts that more than one brief depends on.
4. Decisions and deferrals table: decision; cheap or expensive to reverse; revisit
   trigger. Cheap: code, config, jobs, queries. Expensive: schema, stored data, public
   URLs, provider contracts, new dependencies.

Lead: edit the body. Other agents: use comments.

## Step 5: Briefs

One brief per PR. Aim for 900 words. Split only at contracts that can ship
independently. Sections, in order:

1. **Outcome.** One paragraph: what a user or operator can do afterwards.
2. **Implementer and Required reviews.** `Implementer: <entry>` and `Required reviews: <entries>`, testers first.
3. **Contracts.** Give the `path:line` each contract applies to. For new code, name the
   module and function. List limits, states and transitions. Name which module writes
   each fact.
   State required performance limits and workload assumptions that affect the design,
   and link any existing contract that defines them.
4. **Acceptance scenarios.** Numbered. Each names the input, the action and the
   observable result. These are the test list.
5. **Test budget.** The expected net test change: tests added, one to two per scenario,
   and existing tests deleted or replaced, by name, each with a reason.
6. **Decisions and deferrals.** The rows of the spec table that apply to this brief.
7. **Smallest version.** What this brief leaves out and why that is safe.
8. **Restrictions.** Files or behaviour the implementer must not touch.
9. **Design sections.** Links, quoting only the sentence a contract depends on, with the
   doc revision.

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

- **Checks where they belong.** Parse input at entry points with existing parsers or
  changesets. Check caller admission and enforce domain rules in context operations on
  each call, as required by the [Admission contract](../../../docs/design/backend-design.md#admission-locking-and-returned-data).
  For writes, recheck eligibility under the required locks and keep it valid through
  commit. Keep query filters, database constraints and guarded writes. Repeat a check
  only for a distinct trust boundary or state that may have changed. Problem example:
  the same check in the LiveView, the context and the query with no reason.
- **Simplest mechanism.** Choose the simplest mechanism that meets the contract's
  lifetime, durability and consistency needs. Use existing facilities first. State the
  workload or failure that justifies each new mechanism. Problem example: a scheduler,
  cache or abstraction with one user.
- **Reuse existing code.** Use existing modules, Oban and Ecto first. Problem example: a
  wrapper where the dependency has the feature.
- **Code that supports tests.** Put side effects behind a function a test can replace.
  Pass time and randomness as inputs. Problem example: tests that need sleeps or a real
  provider.
- **Change stays local.** Keep a feature's changes in its module and its callers. Do not
  change shared config or unrelated tests. Problem example: merge conflicts in
  `config/config.exs`.
- **Readable at the call site.** Name a function for its operation and side effects. Use
  arguments to identify the inputs. Do not add flags that change behaviour. Problem
  example: an `opts` list with five keys.

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
- Banned by default: combination grids over inputs, one test per error tuple, tests of
  private helpers, tests that restate a pattern match, tests that only assert the
  database raises, tests of cases that cannot happen. A test of how the application
  handles a constraint error, or of an invariant under concurrent writes, is allowed
  when a scenario names it.
- Allowed without a brief line: one regression test per fixed bug; one race or property
  test where the brief names a concurrency contract.
- When a feature replaces behaviour, the brief names the tests to delete. Delete a test
  only when surviving tests cover its distinct required cases.
- Critic: name the uncovered contract when adding a scenario. The budget must reflect
  the added scenario.

## Step 6: Critique

Critic, for each PROPOSAL:

1. Write your concerns before reading the PROPOSAL.
2. Give one objection per `path:line`, trace, run or quoted requirement. State its
   severity.
3. Use P1 only for a required rule violation or a severity-table condition. Classify
   everything else as P2 with a proposed decision.
4. A P2 does not block. The lead records a decision in the table or a note to the
   implementer.

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

Otherwise name an Opus entry and say which condition failed. Do not change the design to
meet these conditions.
