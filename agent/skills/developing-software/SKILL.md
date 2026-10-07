---
name: developing-software
description: Guides implementation planning, features, fixes, refactors and tests in the tips Phoenix/Elixir repository. Applies when designing a code change, implementing required behavior or choosing tests. Code reviews use reviewing-code, which references this skill's design and testing rules.
---

# Developing software

Use general guidance throughout the task; apply checks marked **Trigger** or **When**
when their conditions occur. These are decision cues, not sequential gates. Follow
[AGENTS.md](../../../AGENTS.md) for repository boundaries, navigation, skill routing,
checks and collaboration.

## Scope the task

Investigate until remaining uncertainty would not change the approach or required
verification. Spend more where mistakes could lose data, cause external effects or
be expensive to undo.

Identify the acceptance scenarios and scope before investigating. Follow task links
and repository entry points to the authoritative requirements, affected contracts
and relevant decisions; read what resolves the current question. Resolve routine
choices from the task, existing decisions and repository conventions. When
alternatives satisfy the same requirements, choose the simplest without asking.
Ask through the existing workflow only when an unresolved ambiguity changes what
counts as correct behavior; continue independent work while awaiting the answer
when that workflow permits it.
Do not add adjacent capabilities.

## Build the simplest working solution

Build the simplest design that delivers the required behavior through the complete
affected flow, including required failure handling. A shorter implementation that
leaves required behavior unfinished is not simpler to maintain. Among complete
solutions, prefer fewer interacting parts, clearer ownership and less coordination;
prefer the user's experience over reducing code.

Add an abstraction, dependency, process, configuration option or stored state only
when you can name the current requirement it serves and why the simpler approach
is insufficient. Do not build for hypothetical scale, reuse or compatibility.

## Reuse existing mechanisms and follow conventions

Before building a custom mechanism, check existing code, built-in features, locked
dependencies and commonly used libraries or tools. Prefer stable interfaces with
behavior you can establish from documentation, source or a focused probe. Include verification,
workarounds and future fixes in the integration and maintenance cost. Build your own
only when none meets the requirements or that total cost exceeds building and
maintaining your own. When you build your own, say what you checked and why in the PR.

Before copying a nearby pattern, check it against the current contract and
conventions. Repetition in the repository does not establish that a pattern is
correct.

When the design depends on a dependency's behavior, verify the specific guarantee
at the installed version and configuration. Link the supporting source in the PR.
Similar names or examples do not establish equivalent behavior.

Follow applicable standards and language and framework idioms. Explain deviations
in the PR. Use Ecto's query, changeset and migration DSLs; use raw SQL or `fragment`
only for what they cannot express, and bind runtime values as parameters.

## Trace the affected contract

**When changing behavior or a function's return shape:** identify the required
outcome and what must remain true. Find affected callers using the repository's
navigation rules, and check the consequences through to the final state and effects.
A correct handler result alone does not establish a correct outcome.

**When adding a dependency between modules or domains:** respect documented
ownership and dependency boundaries while choosing the simplest local
implementation. A new feature alone does not justify a new layer or framework.

**When changing a shared rule, stored fact or runtime state representation:** find
its other representations.
Limits, patterns, enums, labels, messages and filters can appear in constraints,
migrations, helper text, documentation, fixtures and other runtimes. Copies of one
rule may look different.

For that rule or fact, keep one authoritative source. Derive duplicate state rather
than storing copies that can disagree; keep independent facts separate. When stored
copies are necessary, define how they stay consistent. Update
each representation affected by the requirement. Consolidate only when it simplifies
this task or removes a concrete inconsistency, and that gain justifies the coupling
and verification cost. Historical migrations are evidence to inspect, not
automatically files to rewrite.

**When refactoring:** preserve existing observable behavior except for changes the
task explicitly requires. If that behavior conflicts with a requirement, make the
conflict explicit rather than silently changing the contract.

## Handle state and failure

### Incoming actions

**Trigger:** adding or changing a LiveView event handler, controller action, channel
message handler or other entry point that receives input from a user or external
system.

Parse and validate untrusted input into a defined internal representation at the
receiving boundary; reuse schema or SDK guarantees where they establish the needed
contract. Do not spread guesses about data shapes through downstream code.
Authorize the action where it is received, even if mount, an earlier step or another
layer already checked. Earlier checks may be stale when the action runs.

### State, resources and delayed work

**Trigger:** adding or changing an async callback, process, job, mount or reconnect
path, transaction, lock, OS process, retry, delayed action, timeout, deadline, quota
or resource limit.

Identify where the affected state can change and which transitions could break the
requirement. Establish who owns each resource, who releases it and what survives
the caller's exit.

- Do not release capacity while the work it bounds still runs. Cancellation
  requested does not mean work has stopped.
- Before applying a result, establish that it still belongs to the current operation.
  A read started before reconnect must not overwrite newer input.
- Revalidate delayed or retried actions when their inputs or permissions may have
  changed. Refresh or reject permanently invalid inputs rather than offering a
  retry that cannot succeed.
- Record completion only when the required work is done. Reuse production's success
  decision; cleanup running is not evidence of success.
- When adding or changing a timeout, retry, deadline, quota or resource limit: bound
  the whole operation. Add up sequential work, retries, queueing, cleanup and work
  that outlives the caller; a per-step timeout does not bound the operation.
- For a shared deadline, quota or concurrency limit, define which results stop new
  work and what happens to work already in progress.

### Fallible boundaries

**Trigger:** adding or changing a database, HTTP, provider, browser-storage, parser
or OS call, or its result handling.

Check relevant returns, exceptions, exits, timeouts, partial effects and required
response fields. Handle each failure at the layer responsible for its recovery,
preserving the distinctions that change recovery. Add a branch only when it changes
the required response or recovery; otherwise let the existing error boundary handle
it, after confirming it gives the needed behavior. Do not disguise an unexpected
failure as a default value.

Every affected caller must handle or propagate a new result shape. An unmatched
error can become a crash or the wrong response. Do not report "not found", "invalid
input" or "success" unless the contract permits it.

Before retrying or rolling back, establish what may already have committed and what
evidence can settle an uncertain outcome. No response does not prove failure; a
local rollback does not undo an external effect.

## Establish useful evidence

When relying on a test or measurement, check that its setup reached the condition
being claimed and that the observation distinguishes the required behavior from a
plausible defect. An unexpectedly passing regression test is a cue to inspect both
setup and expectation. Use the existing before/after result when it establishes the
claim; add inspection, a reproduction, a control or a temporary mutation only to
resolve a specific remaining doubt. Choose the cheapest adequate method.

### Choose and maintain tests

Derive expected behavior from the requirement independently of the implementation.
Code and tests can agree while both violate the requirement. Tests should allow
another implementation that satisfies the same contract.

Cover acceptance scenarios and reported regressions with the smallest set of test
changes. Do not add tests merely because functions, branches or inputs changed.
Read existing tests first. Leave adequate coverage unchanged; update assertions for
changed requirements; extend an existing test when it can cover the missing scenario
with the same setup and action. Add a test only when none can cover the required
scenario.

For new behavior or a regression, write or update the test before changing the
implementation. Confirm that it fails for the expected reason.

Use integration tests through public entry points. Add a unit test only for a
pure-logic boundary case that integration tests do not cover. Add a browser test
only for a user interaction that lower-level tests cannot check.

Test application behavior, including its use of dependencies. Do not test the
framework itself, private functions or code structure.

Before adding or changing tests, weigh the relevant
[Test Desiderata](https://testdesiderata.com/): isolated, composable, deterministic,
fast, writable, readable, behavioral, structure-insensitive, automated, specific,
predictive and inspiring.

### Check the evidence produced by tests

- **When using doubles:** keep the production code responsible for the claimed
  property running. Otherwise, the test may verify only the substitute.
- **When waiting for async behavior:** wait for the required event or observable
  state with a time limit. A sleep does not prove completion; a timeout is not a pass.
- **When code and tests disagree:** let the contract decide which is wrong. Do not
  change fixtures merely to make incorrect behavior pass.
- **When deleting or replacing tests:** first map still-required scenarios to
  surviving coverage. Delete tests for obsolete requirements or those made unnecessary by the
  change; preserve coverage of every acceptance scenario and regression that still
  applies.

## Check performance claims and bounds

**Trigger:** any of the following:

- A performance claim or observed regression.
- A change to how work grows with data: a query inside a loop, a new preload, an
  unbounded result set, a transaction wrapping an external call, parallel work or
  work that outlives the caller.
- A change to what the browser must load or do before content is visible or an
  interaction completes: a new or reordered request, a critical-path asset or font,
  payload size, client-side work on interaction or async content that moves the layout.

The trigger selects the risk to assess, not a measurement of every changed asset.
A performance claim or an uncertain cost that could change the design requires
profiling; an ordinary bounded change with neither needs no measurement.

Name the property at risk and the workload. Profile the suspected cost, not test-suite
elapsed time. Before measuring, read the relevant part of
[performance measurement](references/performance-measurement.md).

For database work, check how query count and rows read or returned grow with data.
Match filters, indexes and pagination to the access pattern. Keep transaction and
lock lifetimes limited to the work that needs them, accounting for contention and
connection occupancy.

## Repair and refactor

**When a result contradicts expectations, or a bug or review finding exposes a
defect:** identify the failed assumption before adding another condition. Check
other sites and transitions that depend on it, and repair those that share the
defect. Verify the whole affected contract, including behavior the reported failure
did not exercise.

**When this task reveals repeated violations of one consequential invariant:** use
an existing enforcement point where it covers the affected paths, fix the remaining
violations and keep checks at each trust boundary. Add custom enforcement only
within the task's scope and when preventing recurrence justifies its execution and
maintenance cost; check the invariant itself and make failures name the rule and
the correction.

**When considering a refactor:** proceed only if the task requires it or the current
implementation reveals an ownership, interface or state problem that materially
complicates the required behavior or its verification. Name that problem and keep
the revision within the affected flow. Inconsistency elsewhere or hypothetical reuse does not justify
expanding the task. Preserve required behavior and verify each increment. Effort
already spent is not a reason to retain an approach. Stop when the named problem is
resolved and required verification passes.

## Finish

Required behavior and checks remain required; a named verification gap does not
satisfy a requirement.

Inspect the diff and affected callers for missed behavior. Remove additions whose
absence would not break a requirement or make the solution harder to understand,
change or operate. Update affected documentation and delete superseded code, files,
documentation and tests in the same PR.

Run the [required repository checks](../../../AGENTS.md#checks). Follow the existing
blocker, [PR review](../../teams/README.md#pr-review-record) and handoff procedures.

Record durable contracts and decision reasons in the repository documentation that
owns them, linked from the relevant entry point; update it rather than creating
competing instructions. Record task-specific trade-offs, open assumptions and
verification limits in the PR or handoff so later work knows when to revisit them.
