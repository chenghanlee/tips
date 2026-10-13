---
name: design-software
description: Guides the design lead and the design critic of a tips feature. Covers reading, candidate designs, the choice, the spec and brief format, the always-rules and the when-it-matters rules, test budgets, critique, agreement and the choice of implementer. Code reviews use review-software-design.
---

# Design software

The lead writes the spec and briefs. The critic objects from a different persona.
The [designer role](../../teams/roles/designer.md) owns turns and messages. This
skill owns what to write and how to judge it.

Tips is a greenfield MVP looking for product-market fit. Design the smallest correct
thing that can ship today. Correct means the contract holds. Complete is a product
choice the user makes.

Scope limits:

- Three critique rounds after `Choice`. Then AGREE with the open P2s recorded as
  decisions, or BLOCKED.
- P1 only as the [severity table](../../teams/README.md#severity) defines it.
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

Agents converge on the first design that works. The candidates step widens the
search before the critique narrows it.

Lead:

1. Post two or three candidates, each under 150 words: the mechanism, what it adds,
   what it leaves out, which always-rule it strains.
2. One candidate must add no new mechanism.
3. Posting one candidate is a P1 against the lead.

Critic:

1. Post your own candidates from your persona before reading the lead's.
2. Rank all candidates, one reason per rank.

Each persona asks its own questions of every candidate. Two personas never share a
list.

- Architecture: who owns each fact; where the boundary validates and authorizes; what
  else changes when this changes; what the smallest mechanism is; how a test proves
  the contract.
- Operations: what fails and how we notice; what races with what; what grows without
  bound; what migrates and what happens to existing rows; what an attacker sends.

## Step 3: Choice

The lead ranks the candidates, names the choice and says why each other candidate
lost. Later PROPOSALs refine the chosen candidate only. The critic reopens the choice
only for an always-rule violation.

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

One brief per PR, under 900 words. A longer brief is two briefs. Sections, in order:

1. **Outcome.** One paragraph: what a user or operator can do afterwards.
2. **Implementer and Required reviews.** `Implementer: <entry>` and
   `Required reviews: <entries>`, testers first.
3. **Contracts.** Each with the `path:line` it binds, or the module and function when
   new. Limits, states, transitions, who writes which fact.
4. **Acceptance scenarios.** Numbered. Each names the input, the action and the
   observable result. These are the test list.
5. **Test budget.** New tests expected, one to two per scenario. Existing tests this
   brief replaces or deletes, by name.
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
5. **Breaks visible.** Every rescue, retry and fallback logs the record id and the
   reason. No swallowed error, no default that hides a failure. Smell: `_ -> :ok`.

## When-it-matters rules

A violation is a P2 with a decision.

- **Contracts at the boundary.** Validate, authorize and set deadlines where a
  request enters. Inside, functions trust their arguments. Smell: the same check at
  every layer.
- **Smallest mechanism.** A query before a process, a process before a job, a job
  before a table. A new mechanism names the load or failure that justifies it. Smell:
  a scheduler, cache or abstraction with one user.
- **Reuse before invention.** Existing modules, Oban and Ecto first. Smell: a wrapper
  where the dependency has the feature.
- **Testable by construction.** Side effects behind a function a test can replace.
  Time and randomness injected. Smell: tests that need sleeps or a real provider.
- **Change stays local.** A feature touches its module and its callers, not shared
  config or unrelated tests. Smell: merge conflicts in `config/config.exs`.
- **Readable at the call site.** Names say what, arguments say which, no flags that
  change behaviour. Smell: an `opts` list with five keys.

Language and framework idiom comes from the stack skills in AGENTS.md.

## Test budget

The repository has more test lines than application lines. The brief controls this.

- The scenarios and contracts are the test list. One to two tests per scenario.
- Banned by default: combination grids over inputs, one test per error tuple, tests
  of private helpers, tests that restate a pattern match, tests of a constraint the
  database enforces, tests of cases that cannot happen.
- Allowed without a brief line: one regression test per fixed bug; one race or
  property test where the brief names a concurrency contract.
- When a feature replaces behaviour, the brief names the tests to delete.
- A critic adds a scenario only by naming the contract it proves and the scenario it
  replaces.

## Step 6: Critique

Critic, for each PROPOSAL:

1. Write your concerns before reading the PROPOSAL.
2. One objection per `path:line`, trace, run or quoted requirement, with severity.
3. P1 only for an always-rule violation or a [severity table](../../teams/README.md#severity)
   condition. Everything else is P2 with a proposed decision.
4. A P2 does not block. The lead records a decision in the table or a note to the
   implementer.
5. AGREE when no P1 remains and every P2 has a decision. Name the PROPOSAL URL.

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
- The brief states the expected saving over an Opus implementer.

Otherwise name an Opus entry and say which condition failed. Do not change the design
to meet these conditions.
