---
name: design-software
description: Guides the design lead and the design critic of a tips feature. Covers reading, candidate designs, the choice, the spec and brief format, the always-rules and the when-it-matters rules, the test budget, critique and the choice of implementer. Code reviews use review-software-design.
---

# Design software

The lead writes the spec and briefs. The critic objects from a different persona.
The [designer role](../../teams/roles/designer.md) owns turns, messages, the round
limit and the AGREE condition. This skill owns what to write and how to judge it.

Tips is a greenfield MVP looking for product-market fit. Design the smallest change
that satisfies the contracts. Completeness is the user's product decision.

Scope limits:

- Severity follows the [severity table](../../teams/README.md#severity).
  Performance and maintainability are P2 with a decision.
- Prefer an objection that removes a part over one that adds a part.

## Step 1: Read

1. The feature's issue on Project 15.
2. The design sections the [design index](../../../docs/design/README.md) names.
3. The affected code and the mechanisms the repository already has for the same job:
   modules, Oban features, Ecto patterns, provider clients.
4. The contract and failure sections of
   [implement-software](../implement-software/SKILL.md#trace-the-affected-contract).

Write two lines before anything else: the product question this feature answers,
and the signal that would show the answer is wrong. Design for that signal.

## Step 2: Candidates

Agents converge on the first design that works. This step widens the search before
the critique narrows it.

Lead: post two or three candidates, each under 150 words: the mechanism, what it
adds, what it leaves out, which always-rule it may violate and why. One candidate
adds no new mechanism. One candidate is enough when settled requirements leave no
material design choice; name the constraint.

Critic: before reading the lead's candidates, write one independent alternative or
concern from your persona, or say you have none. Then rank all candidates, one
reason per rank.

Each persona asks its own questions of every candidate. Two personas never share a
list.

- Architecture: who owns each fact; where the boundary validates and authorizes; what
  else changes when this changes; what the smallest mechanism is; how a test proves
  the contract.
- Operations: what fails and how we notice; what races with what; what grows without
  bound; what migrates and what happens to existing rows; what an attacker sends.

## Step 3: Choice

The lead ranks the candidates, names the choice and says why each other candidate
lost. Later PROPOSALs refine the chosen candidate. The choice reopens only for an
always-rule violation or new evidence that changes feasibility, required behaviour
or cost. The lead decides and says why.

## Step 4: Spec

One spec per feature. Sections:

1. Product question and signal.
2. Briefs in dependency order, each with its agents.
3. Shared contracts that more than one brief depends on.
4. Decisions and deferrals table: decision; cheap or expensive to reverse; revisit
   trigger. Cheap: code, config, jobs, queries. Expensive: schema, stored data,
   public URLs, provider contracts, new dependencies.

The lead edits the body. Everyone else comments.

## Step 5: Briefs

One brief per PR. Aim for 900 words. Split only at contracts that can ship
independently. Sections, in order:

1. **Outcome.** One paragraph: what a user or operator can do afterwards.
2. **Implementer and Required reviews.** `Implementer: <entry>` and
   `Required reviews: <entries>`, testers first.
3. **Contracts.** Each with the `path:line` it binds, or the module and function when
   new. Limits, states, transitions, who writes which fact.
4. **Acceptance scenarios.** Numbered. Each names the input, the action and the
   observable result. These are the test list.
5. **Test budget.** The expected net test change: tests added, one to two per
   scenario, and existing tests deleted or replaced, by name, each with a reason.
6. **Decisions and deferrals.** The rows of the spec table that apply to this brief.
7. **Smallest version.** What this brief leaves out and why that is safe.
8. **Restrictions.** Files or behaviour the implementer must not touch.
9. **Design sections.** Links, quoting only the sentence a contract depends on, with
   the doc revision.

## Always-rules

A violation is a P1 for the critic and for every reviewer. Each rule has the smell
that breaks it.

1. **One owner per fact.** One module writes each rule, counter or state; one place
   defines it. Smell: the same predicate in two queries; two modules that update
   `cleanup_at`.
2. **Explicit state and transitions.** States are named values with a transition
   table. Illegal transitions are unrepresentable or rejected in one guard. Smell:
   boolean flags that combine into states nobody listed.
3. **Named failure paths.** Every fallible call says what happens on timeout,
   duplicate and crash between steps, and what makes the retry safe. Smell: a happy
   path with errors handled later.
4. **Bounded work.** Every loop, scan, queue and job has a size, time or page bound
   and a stated continuation. Smell: process all rows.
5. **Breaks visible.** Every rescue, retry and fallback logs the identifiers it has
   and the reason. No swallowed error, no default that hides a failure. Smell:
   `_ -> :ok`.

## When-it-matters rules

A violation is a P2 with a decision.

- **Checks where they belong.** Entry points parse input with existing parsers or
  changesets. Context operations admit callers freshly and enforce domain rules, per
  the [Admission contract](../../../docs/design/backend-design.md#admission-locking-and-returned-data).
  Writes recheck eligibility under the required locks through commit. Query filters,
  database constraints and guarded writes stay. A repeated check needs a distinct
  trust boundary or state that may have changed. Smell: the same check in the
  LiveView, the context and the query with no reason.
- **Smallest mechanism.** Choose the simplest mechanism that meets the contract's
  lifetime, durability and consistency needs, existing facilities first. A new
  mechanism names the load or failure that justifies it. Smell: a scheduler, cache or
  abstraction with one user.
- **Reuse before invention.** Existing modules, Oban and Ecto first. Smell: a wrapper
  where the dependency has the feature.
- **Testable by construction.** Side effects behind a function a test can replace.
  Time and randomness injected. Smell: tests that need sleeps or a real provider.
- **Change stays local.** A feature touches its module and its callers, not shared
  config or unrelated tests. Smell: merge conflicts in `config/config.exs`.
- **Readable at the call site.** Name a function for its operation and side effects.
  Arguments identify the inputs. No flag that changes behaviour. Smell: an `opts`
  list with five keys.

Language and framework idiom comes from the stack skills in AGENTS.md.

## Test budget

The brief controls test growth.

- The scenarios and contracts are the test list. One to two tests per scenario.
- Banned by default: combination grids over inputs, one test per error tuple, tests
  of private helpers, tests that restate a pattern match, tests that only assert the
  database raises, tests of cases that cannot happen. A test of how the application
  handles a constraint error, or of an invariant under concurrent writes, is allowed
  when a scenario names it.
- Allowed without a brief line: one regression test per fixed bug; one race or
  property test where the brief names a concurrency contract.
- When a feature replaces behaviour, the brief names the tests to delete. A test is
  deleted only when surviving tests cover its distinct required cases.
- A critic adds a scenario by naming the uncovered contract. The budget updates.

## Step 6: Critique

Critic, for each PROPOSAL:

1. Write your concerns before reading the PROPOSAL.
2. One objection per `path:line`, trace, run or quoted requirement, with severity.
3. P1 only for an always-rule violation or a severity-table condition. Everything
   else is P2 with a proposed decision.
4. A P2 does not block. The lead records a decision in the table or a note to the
   implementer.

Lead, after each round:

1. A substantive change alters a contract, a scenario, a mechanism or the decisions
   table. It invalidates earlier AGREEs. Say so in the PROPOSAL.
2. If a shared contract changes, pause the briefs that depend on it until the spec is
   updated.
3. Post BLOCKED when both sides have evidence and still disagree, or when a product
   or scope question is open. Silence is not agreement.

## Step 7: Choose the implementer

Name a Haiku implementer only when all hold:

- The brief names every file and function to change, every contract and scenario.
- No design choice is open.
- No schema, migration, process or external service is added.
- A mechanical check proves the result.

Otherwise name an Opus entry and say which condition failed. Do not change the design
to meet these conditions.
