---
name: implement-software
description: Guides implementing a brief for the Tips application and its agent harness (agent/teams). Covers design during delivery, code rules, state and failure, data changes, tests, deferrals and when to stop. Code reviews use review-software, which links to this skill's contract and failure sections.
---

# Implement software

Implement one brief in one PR. Deliver its required behavior with coherent affected
structure and evidence proportionate to the contracts and uncertainty.
[AGENTS.md](../../../AGENTS.md) defines repository boundaries, navigation, stack skills
and checks. [design-software](../design-software/SKILL.md#required-rules) defines the
architecture rules. Follow this skill to write code and tests.

## Design during delivery

Build Tips and its harness as an MVP: ship the simplest sufficient working change. Read
the brief, the stack skills AGENTS.md names for the files you change, the affected
source and its callers ([navigation rules](../../../agent/docs/elixir-navigation.md)),
and the existing tests. Fill source-derived gaps without adding product scope; product
questions go to the user through the dispatcher.

Make reversible internal choices yourself (code, config, queries, jobs, module layout),
including structural repairs in the affected flow when their present benefit to
understanding, change or verification justifies the work; a failing test or a second
caller is not required, and neither is a cosmetic extraction. Keep observable behaviour
and verify that it is preserved. Internal placement may change; public or shared
contracts, persistent or recovery meaning, authority boundaries and active ownership
remain binding. Follow settled decisions for expensive changes (schema, stored data,
public URLs, provider contracts, dependencies); route only an unresolved consequential
decision through the
[architect route](../../teams/roles/dispatcher.md#decisions-during-implementation), and
continue unaffected work while it is pending. Record consequential choices in the PR
body's Decisions, not in a separate design inventory. Deferrals follow the
[severity rule](../../teams/README.md#severity).

## Code rules

The stack skills carry the language and framework conventions. These are project
policy:

- Parse untrusted input at the entry point with existing parsers or changesets. Check
  caller admission and enforce domain rules in context operations on each call; for a
  write, recheck eligibility under the required locks through commit. Authentication
  and access checks stay at web entry points; UI feedback is not authorization. Add a
  repeated check only for a distinct trust boundary or state that may have changed.
- Call context functions from LiveViews and controllers, not `Repo`.
- One module writes each fact. Before changing a rule, limit, enum or label, find and
  update every copy: constraints, migrations, helper text, fixtures, docs.
- Use Ecto's query, changeset and migration DSLs; raw SQL or `fragment` only for what
  they cannot express, with runtime values bound as parameters. Do not add options that
  change behaviour.
- Use existing modules, Ecto, Oban and Phoenix features before creating your own. State
  in the PR the present benefit of a new process, cache, GenServer, scheduler or
  abstraction; a wrapper that repeats a dependency's API has none.
- When you rely on a dependency's behaviour, check it at the installed version and link
  the source in the PR.

Use Credo and the formatter for style; Dialyzer runs as
[checks](../../docs/checks.md#dialyzer) says.

## Report failures

Make failures detectable when working quickly. Follow the fifth [required rule](../design-software/SKILL.md#required-rules). Classify a violation as P1.

- Log the available identifiers (record, job, request) and the reason for every
  `rescue`, `catch`, retry and fallback. Choose the log level by consequence.
- Do not use `_ -> :ok` or `rescue _ -> nil`. Do not return a default value that hides a
  failure.
- Raise or return `{:error, reason}` when a job fails so Oban retries and records it. Do
  not hide the error by returning `:ok`.
- Do not report "not found", "invalid input" or "success" unless the contract allows it
  for that case.

## Trace the affected contract

When you change behaviour or a return format: find every caller with Dexter `references`
and scoped `rg`, and check the result through to the final state and side effects. A
correct return value does not prove a correct outcome. For evidence across several
files, follow the [Lookup subagents](../../docs/lookup-subagents.md) rule; you
remain responsible for tracing and verifying the affected contract.

When you add, cache, move or remove a fact (a stored value, a derived flag, or a timer
that keeps it current): find every path that constructs, updates, reads, resets or
removes it, and every late callback (timer, async result, message) that can arrive
after it changed. List them under the PR body's `Affected code`. Prefer removing the
redundant copy, or giving the fact one writer, to patching each path. Keep any trigger
that re-evaluates a time-dependent fact, and start it on every path that creates the
fact.

When you refactor: keep observable behaviour the same except where the brief says
otherwise. If existing behaviour conflicts with the brief, say so in the PR. Do not
change the contract silently.

## State and failure

### Delayed and concurrent work

Trigger: a job, process, async callback, mount or reconnect path, transaction, lock,
retry, timeout, deadline, quota or limit.

- Name who manages each resource. State who releases it and what survives the caller's
  exit.
- Do not release capacity while the work it limits still runs. A cancel request does not
  mean the work stopped.
- Before applying a result, check it still belongs to the current operation. A read
  started before reconnect must not overwrite newer input.
- Revalidate a delayed or retried action: its inputs or permissions may have changed.
- Record completion only when the work is done. Do not treat cleanup running as
  completion.
- Limit the whole operation, not each step. Add up sequential work, retries, queueing
  and cleanup.
- For a shared deadline, quota or concurrency limit, say which results stop new work and
  what happens to work in progress.

### Calls that can fail

Trigger: a database, HTTP, provider, storage, parser or OS call, or its result handling.

- Check returns, exceptions, exits, timeouts, partial effects and required response
  fields.
- Handle each failure at the layer that can recover from it. Add a branch only when it
  changes the response or the recovery. Otherwise let the existing error boundary handle
  it, after checking that it does.
- Handle or propagate a new result format in every caller. An unmatched error causes a
  crash or a wrong response.
- Before a retry or rollback, establish what may already have committed. Do not infer
  failure from a missing response. Do not assume a local rollback undoes an external
  effect.

## Data changes

Schema and stored data are expensive to reverse.

- Use additive migrations. Put a destructive migration (drop, rename, narrow) in a later
  PR after shipping the code that stopped using the column.
- Limit the work in each backfill batch and make the backfill resumable. Use batches, a
  cursor and a stated page size.
- Delete from storage only when a scenario in the brief requires it.
- Name the contract that writes each new column or table in the brief.

## Tests

The brief's scenarios and contracts are the test list.

Order of work:

1. Read the existing tests for the changed modules.
2. Delete tests for behaviour this brief replaces. The brief names them.
3. For each scenario, find an existing test that can cover it with the same setup and
   action. Extend it. Add a new test only when none can. Write the test before or after
   the code, as you choose; the control below is what proves it can fail.
4. Make the scenario work. Then use the implementation to identify plausible mistakes
   its test could miss. For each masking risk you find, repair the setup, the input or
   the missing observation so the test distinguishes the mistake. Correct an existing
   expectation only from the brief or an established affected contract, and explain the
   correction in the PR body. Run the distinguishing control and record it in the PR
   body as for a marked `Masking risk:` row.
5. Inspect the affected design under [Design during delivery](#design-during-delivery).
   Repair a justified problem or record the consequential tradeoff. Stop when the
   working change is coherent and verified.

Rules:

- Prefer extending an existing test. Add or retain another only for a distinct required
  case the surviving tests do not prove. A test that maps to no scenario or contract line
  gets its own row in the PR body's scenario table with a one-line reason.
- Banned by default: combination grids over inputs, one test per error tuple, tests of
  private helpers, tests that restate a pattern match, tests that only assert the
  database raises, tests of cases that cannot happen. A test of how the application
  handles a constraint error, or of an invariant under concurrent writes, is allowed
  when a scenario names it.
- Allowed without a prior brief line: a regression test for a fixed bug, or relevant
  verification of an existing affected contract, including preservation during a
  refactor. Explain the uncovered case; extend an existing test where possible. Test
  gaps do not require a new architect approval unless the contract itself is unsettled.
- Delete a test only when surviving tests cover its distinct required cases. Name them
  in the PR body.
- Test through public entry points: the context function, the LiveView, the job. Add a
  unit test only for pure logic a scenario test cannot reach. Add a browser test only
  for an interaction lower-level tests cannot check.
- Derive the expected result from the brief, not from the code. Code and tests can agree
  and both be wrong.
- Choose inputs that separate the intended behaviour from the named mistake, and keep
  the other preconditions valid so another guard cannot hide it. Problem examples: four
  identical streams into a feature that orders four streams, so a swap changes nothing;
  an identity check tested with a record that differs in every field, so an `or`
  written for an `and` still rejects it.
- A test proves a scenario only if its setup reached the condition and its assertion
  would fail for a plausible defect. Inspect the setup and expectation when a test
  passes unexpectedly.
- For a scenario the brief marks `Masking risk:`, supply a control: a small change to
  production code, or to a stub the test controls, that introduces the named defect.
  Keep the assertion fixed during the control run. Run the test with the control,
  confirm the test fails at the assertion that detects that defect, then revert. Put the
  control and the failing assertion in the PR body. One control serves several scenarios
  only when it shows each one's distinguishing defect.
- A double may replace an external call. The production code responsible for the claim
  must still run.
- Wait for the event or observable state with a time limit. A sleep is not proof. A
  timeout is not a pass.
- When code and tests disagree, use the brief to determine which is wrong. Do not change
  a fixture to make wrong behaviour pass.

## Performance

When the change adds or alters work, waiting, memory or storage, apply the
[performance principles](../design-software/SKILL.md#performance-principles) at the
expected workload. Measure when a stated limit, or a cost that could change the design,
needs evidence ([how](references/performance-measurement.md)); label estimates as such.
Record consequential findings in the PR body and route a change to a binding decision
through the architect route.

## Deferrals

Put unrelated or unjustified work in one linked follow-up issue: the problem, the
`path:line`, the trigger that makes it worth fixing. This does not defer a P0 or P1 and
does not exclude a justified repair in the affected flow.

## Bug fixes

Find the failed assumption and fix every affected site that shares it. Verify the whole
contract, not only the reported case; for changed state, follow
[Trace the affected contract](#trace-the-affected-contract).

## Finish

Prove the required scenarios and pass the [required checks](../../../agent/docs/checks.md).
Remove superseded code, tests and docs; update affected contract and usage docs; keep
only changes whose benefit justifies their cost. Fill the
[PR body](../../teams/README.md#pr-body) and hand off through the
[pair workflow](../../teams/README.md).
