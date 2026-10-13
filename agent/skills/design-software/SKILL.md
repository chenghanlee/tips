---
name: design-software
description: Guides the design lead and the design critic of a tips feature. Covers exploring candidate designs before choosing one, writing the spec and briefs, what well-designed software looks like at MVP stage, critique and agreement rules, test budgets and the choice of implementer. Code reviews use review-software-design.
---

# Design software

The lead writes the spec and briefs. The critic objects from a different persona.
Turn order and messages are in the [designer role](../../teams/roles/designer.md);
this skill owns the craft. Read the contract-tracing and state-and-failure sections of
[implement-software](../implement-software/SKILL.md#trace-the-affected-contract)
before designing; they apply to designs as much as to code.

Tips is a greenfield MVP looking for product-market fit. Prefer a smaller correct
thing shipped today over a complete thing next week. Correct means the contract
holds; complete is a product choice the user makes.

## Read before designing

Read the feature's issue on Project 15, the design sections the
[design index](../../../docs/design/README.md) names for it, the affected code and
the mechanisms the repository already has for the same job: existing modules, Oban
features, Ecto patterns, provider clients. A design that reinvents one of them must
say what it tried and why it fell short.

Write down the product question the feature answers and the signal that would say
the answer is wrong. Design for that signal, not for completeness.

## Explore before you choose

Agents converge on the first working design. Two personas exist to widen the search
before narrowing it.

1. **Candidates.** Before any PROPOSAL, the lead posts two or three candidate designs,
   each under 150 words: the mechanism, what it adds, what it leaves out, which
   always-rule below it strains. One candidate must be the no-new-mechanism option.
   The critic posts its own candidates from its persona before reading the lead's.
   One candidate from the lead is a P1 against the lead.
2. **Choice.** Lead and critic each rank the candidates with one reason per rank.
   The lead chooses and says why the others lost. Disagreement here is cheap.
3. **Hill-climb.** PROPOSAL and CRITIQUE refine the chosen candidate only. The critic
   may reopen the choice only for an always-rule violation.

Exploration ends when a candidate survives both persona question lists, not when
the critic runs out of objections.

### Persona questions

Each persona asks its questions of every candidate. Two personas must not share a
list.

- Architecture: who owns each fact; where is the boundary that validates and
  authorizes; what else changes when this changes; what is the smallest mechanism;
  how does a test prove the contract.
- Operations: what fails and how do we notice; what races with what; what grows
  without bound; what migrates and what happens to existing rows; what an attacker
  sends.

## Spec

One spec per feature. It lists the briefs in dependency order, the shared contracts
that more than one brief depends on, the product question and signal, the agents,
and a decisions-and-deferrals table (below). The lead edits the body; everyone else
comments.

## Brief

One brief per PR. Sections, in order:

- **Outcome.** One paragraph. What a user or operator can do afterwards.
- **Implementer and Required reviews.** `Implementer: <entry>` and
  `Required reviews: <entries>`, testers first.
- **Contracts.** Each with `path:line` of the code it binds, or the module and
  function when new. Limits, states, transitions, who writes which fact.
- **Acceptance scenarios.** Numbered. Each names the input, the action and the
  observable result. These are the test list.
- **Test budget.** The expected number of new tests, one to two per scenario, and
  which existing tests this brief replaces or deletes.
- **Decisions and deferrals.** A table with three columns: decision, reversible
  (cheap: code, config, jobs) or expensive (schema, public URLs, provider contracts,
  stored data), revisit trigger. Deferred requirements go here with the trigger that
  revives them, so nobody re-litigates them.
- **Smallest version.** What this brief leaves out and why that is safe.
- **Restrictions.** Files or behaviour the implementer must not touch.
- **Design sections.** Links to the design-doc sections, quoting only the sentence a
  contract depends on, with the doc revision.

Keep a brief under 900 words. A brief that needs more is two briefs.

## What well-designed software looks like

Each rule pairs with the smell that violates it. The first four are **always** rules:
a violation is a P1 for the critic and the design reviewer. The rest are
**when-it-matters** rules: a violation is a P2 with a decision.

Always:

- **One owner per fact.** Each rule, counter or state has one module that writes it
  and one place that defines it. Smell: the same predicate in two queries; two modules
  that both update `cleanup_at`.
- **Explicit state, explicit transitions.** States are named values with a
  transition table; illegal transitions are unrepresentable or rejected in one guard.
  Smell: boolean flags that combine into states nobody listed.
- **Failure paths are named.** Every fallible call says what happens on timeout,
  duplicate, and crash between steps, and what makes the retry safe. Smell: a happy
  path with errors handled later.
- **Bounded work.** Every loop, scan, queue and job has a size, time or page bound
  and a stated continuation. Smell: process all rows.

When it matters:

- **Contracts at the boundary.** Validation, authorization and deadlines happen where
  a request enters; inside, functions trust their arguments. Smell: the same check at
  every layer.
- **Smallest mechanism.** A query before a process, a process before a job, a job
  before a table. A new mechanism names the load or failure that justifies it; below
  that, use the simpler thing even if it is slower. Smell: a scheduler, cache or
  abstraction with one user.
- **Reuse before invention.** Existing modules, Oban and Ecto facilities first.
  Smell: a custom wrapper where the dependency has the feature.
- **Testable by construction.** Side effects behind a function a test can replace;
  time and randomness injected. Smell: tests that need sleeps or a real provider to
  check logic.
- **Change stays local.** A feature touches its own module and its callers, not
  shared config or unrelated tests. Smell: merge conflicts in `config/config.exs`.
- **Readable at the call site.** Names say what, arguments say which, no flags that
  change behaviour. Smell: an `opts` list with five keys.

Language and framework idiom comes from the stack skills in AGENTS.md, not from
this list.

## Tests are part of the design

The repository has more test lines than application lines. The brief controls this.

- The acceptance scenarios and contracts are the test list. A test that maps to no
  line in the brief needs a one-line reason in the PR.
- Budget one to two tests per scenario and write the number in the brief.
- Banned by default: combination grids over inputs, one test per error tuple, tests
  of private helpers, tests that restate a pattern match, tests of a constraint the
  database already enforces, tests of cases that cannot happen.
- Allowed without a brief line: one regression test per fixed bug; a race or property
  test where the brief names a concurrency contract.
- When a feature replaces behaviour, the brief names the tests to delete.
- A critic adds a scenario only by naming the contract it proves and the scenario it
  replaces.

## Critique

Record your concerns before reading the PROPOSAL, so the lead's framing does not
narrow them. Then, for each objection:

- One objection per `path:line`, trace, run or quoted requirement.
- P1 only for a violation of an always rule, data loss, an unauthorized action, a
  security hole, or an acceptance scenario that cannot pass. Everything else,
  including performance and maintainability, is P2 with a decision.
- Prefer an objection that removes a part over one that adds a part.
- A P2 does not block the brief. The lead records its decision in the
  decisions-and-deferrals table or passes it to the implementer as a note.

AGREE when no P1 remains and every P2 has a decision. Name the PROPOSAL comment.
AGREE means work may start.

## Revise

A substantive change is one that changes a contract, a scenario, a mechanism or the
decisions table. It invalidates earlier AGREEs; say so in the PROPOSAL. Editorial
changes do not. If a shared contract changes, pause the briefs that depend on it
until the spec is updated.

Post BLOCKED when the lead and critic both have evidence and still disagree, or when
a product or scope question is open. Silence is not agreement.

## Choose the implementer

Name a Haiku implementer only if the brief names every file and function to change,
every contract and scenario, leaves no design choice open, adds no schema, migration,
process or external service, has a mechanical check, and states the expected saving
over an Opus implementer. Otherwise name an Opus entry and say which condition
failed. Do not change the design to meet these conditions.
