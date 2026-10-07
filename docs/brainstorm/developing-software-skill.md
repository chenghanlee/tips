# Developing software skill candidate

Intermediate candidate for the
[developing-software skill](../../agent/skills/developing-software/SKILL.md).
This document does not replace the active skill or repository rules.

The objective is to maximize code quality, software architecture quality and
decision quality per total token spent on decision-making, design and implementation,
including investigation, tool output, testing and repairs. Judge additions by the
mistakes or repeated work they prevent, not prompt length alone. Required behavior
and checks remain constraints. Opus and Fable reviewed earlier iterations; predicted
benefits have not been behaviorally evaluated.

## Proposed promotion

When this candidate is approved for promotion:

- Move the complete Software design and Tests rules from AGENTS.md into the skill,
  preserving their requirements and removing the copies from AGENTS.md.
- Keep repository boundaries, navigation, checks, writing and collaboration
  procedures in AGENTS.md. Route implementation planning, code changes and testing
  to the skill.
- Update reviewing-code and the team review prompt to reference the skill's design
  and testing rules. Update the pair workflow's repair-section reference.
- Validate the skill, documentation links and affected harness code. Compare
  implementation behavior and total token cost on representative tasks before
  claiming an improvement.

The migration and behavioral evaluation have not been performed. The draft below
contains the proposed skill metadata and instructions. Its links resolve from this
brainstorm document; adjust them for the skill directory on promotion.

## Candidate

```yaml
---
name: developing-software
description: Design and implement features, fixes and refactors in this repository. Use when planning implementation, changing code or writing tests. Code reviews use reviewing-code, which references this skill's design and testing rules.
---
```

# Developing software

Establish the required behavior, choose the simplest suitable design, challenge
consequential assumptions, and revise the design when implementation reveals a
concrete improvement.

Use these sections as decision guidance, not sequential gates. Apply conditional
checks when their triggers occur. Investigate until remaining uncertainty would
not change the approach or required verification. Spend more where mistakes could
lose data, cause external effects or be expensive to undo.

Follow [AGENTS.md](../../AGENTS.md) for repository boundaries, navigation, checks
and collaboration. Apply the relevant language and framework skills.

Identify the acceptance scenarios and scope before investigating. Follow task links
and repository entry points to the authoritative requirements, affected contracts
and relevant decisions; read what resolves the current question. Resolve routine
choices from the task, existing decisions and repository conventions. When
alternatives satisfy the same requirements, choose the simplest without asking.
Ask through the existing workflow only when an unresolved ambiguity changes what
counts as correct behavior; continue independent work while awaiting the answer.
Do not add adjacent capabilities.

## Build the simplest working solution

Choose the simplest design that delivers the required behavior through the complete
affected flow. Include the failure handling the requirement needs. A shorter
implementation that leaves required behavior unfinished is not simpler to maintain.

Start with existing code and framework mechanisms. Add a new abstraction,
dependency, process, configuration option or stored state only when you can explain
what current requirement it serves and why the simpler approach is insufficient.

When several approaches meet the requirements, prefer the one with fewer interacting
parts, clearer ownership and less coordination. Prefer the option easier for the
product's users when reducing code would make their experience worse.

Do not build for hypothetical scale, reuse or compatibility. Check concrete growth
and resource limits where they could invalidate the approach; introduce additional
machinery when requirements or evidence justify it.

### Reuse existing mechanisms and follow conventions

Before building a custom mechanism, check built-in features, locked dependencies
and commonly used libraries or tools. Prefer stable, composable interfaces whose
relevant behavior you can inspect and verify. Build your own only when none meets
the requirements or reuse costs more to integrate and maintain, including workarounds,
verification and future fixes. Local code is not automatically cheaper. When you
build your own, say what you checked and why in the PR.

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

**When changing a shared rule or stored fact:** find its other representations.
Limits, patterns, enums, labels, messages and filters can appear in constraints,
migrations, helper text, documentation, fixtures and other runtimes. Copies of one
rule may look different.

Keep one authoritative source for each rule and fact. Derive other representations
where practical; when copies are necessary, define how they stay consistent. Update
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
path, transaction, lock, OS process, stored retry or delayed action.

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

Test acceptance scenarios and reported regressions. Do not add tests merely because
functions, branches or inputs changed.

Read existing tests first. Leave adequate coverage unchanged; update assertions for
changed requirements; extend an existing test when it can cover the missing scenario
with the same setup and action. Add a test only when none can. Make the smallest set
of changes that covers the required scenarios.

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
- **Before deleting or replacing tests:** map still-required scenarios to surviving
  coverage. Delete tests for obsolete requirements or those made unnecessary by the
  change; preserve coverage of every acceptance scenario and regression that still
  applies.

## Check performance claims and bounds

**Trigger:** adding or changing a query, preload, pagination strategy, transaction,
index, page loading, navigation, browser interactions, assets, client requests,
timeout, retry, queue, capacity or size limit, parallel work, or a design justified
by performance.

Identify the expected workload, what grows and the relevant time and resource
limits. Investigate costs that could change the design; a routine bounded lookup
does not require a benchmark.

For a performance claim or optimization, use a profiler or trace that observes the
suspected cost. Test-suite duration mixes setup, fixtures, scheduling and assertions;
it does not establish application performance. Tests may drive the workload, but
measure the operation and resource being investigated.

| Suspected cost | Evidence to use |
|---|---|
| Browser rendering or interaction | A [browser performance trace](https://developer.chrome.com/docs/devtools/performance) of the affected flow; inspect main-thread work, frames and paints. |
| Network or external-service delay | A request waterfall and request/server traces; separate round trips, server work and transfer time. |
| Database execution or contention | Query timings/counts, pool and lock statistics; [EXPLAIN ANALYZE with BUFFERS](https://www.postgresql.org/docs/current/using-explain.html) on representative disposable data when execution detail is needed. ANALYZE executes the query. |
| Application CPU or memory | A runtime profiler available in the installed toolchain, such as [mix profile.tprof](https://hexdocs.pm/mix/Mix.Tasks.Profile.Tprof.html); choose its mode for the suspected resource cost. |

Use the profile to locate the bottleneck, then compare the affected operation before
and after under the same workload and conditions. Account for profiler overhead;
a shorter suite run or one favorable sample is not sufficient evidence of a gain.

For database work:

- Check how query count and rows read or returned grow with the data. Look for
  queries inside loops, unnecessary preloads and unbounded result sets; small
  fixtures can hide those costs.
- Use filters, indexes and pagination that match the access pattern. When performance
  depends on an index or query strategy, inspect the query plan with representative
  data instead of assuming the database will use it.
- Keep transactions and lock lifetimes limited to the work that needs them. Account
  for contention and connection occupancy, especially when external calls or slow
  work occur inside a transaction.

For frontend work, select the metrics affected by the change rather than running a
full audit for every UI edit:

- **Visible content:** distinguish [First Paint (FP) from First Contentful Paint
  (FCP)](https://developer.mozilla.org/en-US/docs/Web/API/PerformancePaintTiming).
  First pixels may be only a background; FCP marks the first content. Use Largest
  Contentful Paint (LCP) for when the largest visible content element renders.
  Inspect the critical request and rendering path before adding loading machinery.
- **Interaction and rendering:** use [Interaction to Next Paint
  (INP)](https://web.dev/articles/inp) for responsiveness. For requests or LiveView
  updates, also measure action-to-visible-result time; a quick loading indicator
  does not establish a quick result. Inspect frame times and main-thread work when
  interactions or scrolling stall. [Total Blocking Time (TBT)](https://web.dev/articles/tbt) is a lab
  diagnostic, not a substitute for exercising interactions.
- **Visual stability:** use Cumulative Layout Shift (CLS) to find unexpected movement.
  Reserve space for images and async content when their arrival shifts the interface.
- **Network:** inspect request waterfalls, round trips, payload sizes and cache
  behavior. [Time to First Byte (TTFB)](https://web.dev/articles/ttfb) includes more
  than network latency; use [resource timings](https://developer.mozilla.org/en-US/docs/Web/API/Performance_API/Resource_timing)
  and server timings as needed to distinguish connection, server and transfer costs.
  Remove unnecessary serial requests and critical-path bytes before adding caches
  or prefetching.

Use the task's performance requirements. [Core Web Vitals](https://web.dev/articles/vitals)
reference values are LCP <= 2.5 s, INP <= 200 ms and CLS <= 0.1 at the 75th percentile
of real visits, assessed separately for mobile and desktop; these are reference
values, not additional acceptance gates.

Without real-user data, compare before and after under the same representative
device, network, cache and interaction conditions. Exercise the affected flow;
a fast localhost load or an aggregate Lighthouse score alone does not establish
user-perceived performance. Report these as lab results, not field percentiles.

Across the whole operation, account for sequential work, concurrency, queueing,
retries, cleanup, network round trips, browser rendering and work that outlives the
caller. A per-query or per-step bound does not bound the operation.

For work governed by a shared deadline, quota or concurrency limit, identify which
results stop new work and what happens to work already in progress.

Limit measurement claims to the workload actually tested.

## Reconsider the design

**When a result contradicts expectations, or a bug or review finding exposes a
defect:** identify the failed assumption before adding another condition. Check
other sites and transitions that depend on it, and repair those that share the
defect. Verify the whole affected contract, including behavior the reported failure
did not exercise.

**When implementation reveals unclear ownership, an awkward interface, conflicting
state or repeated special cases:** identify an alternative that removes the observed
problem. Prefer the smallest revision that addresses its cause.

Within the design this task needs, prioritize improvements that prevent costly or
recurring defects or remove a demonstrated bottleneck. Refactor or replace parts
when the gain justifies the change and verification cost. Preserve required behavior
and verify each increment. Effort already spent is not a reason to retain an
approach. Stop when no identified improvement justifies its cost.

**When a consequential invariant is repeatedly missed:** prefer an existing schema,
constraint, compiler check, linter or behavioral test over another prose reminder.
Add custom enforcement only when preventing recurrence justifies its execution and
maintenance cost. Check the invariant, not an incidental implementation shape, so
valid alternatives remain possible. Make failures identify the violation and the
correction needed.

## Finish

Required behavior and checks remain required; a named verification gap does not
satisfy a requirement.

Inspect the diff and affected callers for missed behavior. Remove additions whose
absence would not break a requirement or make the solution harder to understand,
change or operate. Update affected documentation and delete superseded code, files,
documentation and tests in the same PR.

Run the [required repository checks](../../AGENTS.md#checks). Follow the existing
blocker, [PR review](../../agent/teams/README.md#pr-review-record) and handoff procedures.

Keep durable contracts and decision reasons in the existing repository documentation
that owns them, with links from the relevant entry point. Update that source instead
of adding competing instructions. Record task-specific trade-offs, unresolved
assumptions and verification limits in the existing PR or handoff so later work
knows when to revisit them.
