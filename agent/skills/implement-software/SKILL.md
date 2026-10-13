---
name: implement-software
description: Guides implementing a tips brief in the Phoenix/Elixir repository. Covers the MVP scope, code rules, state and failure, data changes, tests and the test budget, deferrals and when to stop. Code reviews use review-software-correctness and review-software-design, which link to this skill's contract and failure sections.
---

# Implement software

Implement one brief in one PR. Use its acceptance scenarios to determine completion.
[AGENTS.md](../../../AGENTS.md) defines repository boundaries, navigation, stack skills
and checks. [design-software](../design-software/SKILL.md#required-rules) defines the
architecture rules. Follow this skill to write code and tests.

## MVP scope

Build Tips as a new MVP to test product demand. Ship the smallest change that makes
every scenario in the brief pass. Implement the scope agreed in the brief. Ask the lead
about a missing requirement. Do not add scope.

Classify each choice before you make it:

- Cheap to reverse: code, config, queries, jobs, module layout. Make the choice and
  implement it. Explain it in the PR if a reviewer could ask why.
- Expensive to reverse: schema, stored data, public URLs, provider contracts, new hex
  dependencies. Follow the brief. If the brief does not cover it, post a blocker. Do not
  guess.

## Scope

Read these sources in order. Then stop:

1. The brief: outcome, contracts, scenarios, test budget, decisions table, restrictions.
2. The stack skills AGENTS.md names for the files you will change.
3. Each `path:line` the brief names and its callers, found with the [navigation rules](../../../AGENTS.md#elixir-navigation).
4. The existing tests for the changed modules.

State a one-line reason for reading beyond this list. If the brief is missing something
you need, post the question through the pair workflow and continue with the parts that
do not depend on it.

The brief's decisions table is binding. Do not reopen a decision in code. Do not add
capabilities the brief does not name.

## Code rules

Apply these rules in every change. Use the examples to identify violations.

- Pattern-match on the expected data format. Let an unexpected format fail at the
  boundary. Problem example: `nil` checks on every step of a function.
- Use one set of error results per context: `{:ok, value}` and `{:error, reason}` with a
  fixed set of reasons. Use `with` for operations with several steps that can fail.
  Problem example: a function that returns `nil`, `false` and `{:error, _}` for
  different failures.
- Parse untrusted input at the entry point (LiveView event, controller action, channel
  handler, job args) with existing parsers or changesets. Check caller admission and
  enforce domain rules in context operations on each call, as required by the [Admission contract](../../../docs/design/backend-design.md#admission-locking-and-returned-data).
  For writes, recheck eligibility under the required locks and keep it valid through
  commit. Keep authentication and access checks at web entry points. Do not use UI
  feedback as authorization. Keep query filters, database constraints and guarded
  writes. Add a repeated check only for a distinct trust boundary or state that may have
  changed. Problem example: the same check in the LiveView, the context and the query
  with no reason.
- Call context functions from LiveViews and controllers. Do not call `Repo` from them.
  Problem example: a query inside a `handle_event`.
- Assign one module to write each fact. Find the other copies of a rule, limit, enum or
  label before changing it: constraints, migrations, helper text, fixtures, docs. Update
  each one. Problem example: two modules that update the same column.
- Name a function for its operation and side effects. Use arguments to identify the
  inputs. Do not add options that change behaviour. Problem example: an `opts` list with
  five keys.
- Keep each function within one screen. A module has one reason to change. Problem
  example: a context module with thirty public functions.
- Use existing modules, Ecto, Oban and Phoenix features before creating your own. State
  in the PR which workload or failure requires a new process, cache, GenServer,
  scheduler or abstraction. Problem example: a wrapper with one user.
- Use Ecto's query, changeset and migration DSLs. Use raw SQL or `fragment` only for
  what they cannot express. Bind runtime values as parameters.
- When you rely on a dependency's behaviour, check it at the installed version and link
  the source in the PR. A similar name does not prove the same behaviour.

Use Credo, Dialyzer and the formatter for style checks. Follow the stack skills for
language and framework conventions.

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
correct return value does not prove a correct outcome.

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

The brief's scenarios and contracts are the test list. The brief's test budget is the
expected net test change; explain any difference in the PR body.

Order of work:

1. Read the existing tests for the changed modules.
2. Delete tests for behaviour this brief replaces. The brief names them.
3. For each scenario, find an existing test that can cover it with the same setup and
   action. Extend it. Add a new test only when none can.
4. Write the scenario test before the implementation. Run it. Confirm it fails for the
   reason the scenario describes.
5. Implement until it passes. Stop.

Rules:

- One to two tests per scenario. A test that maps to no scenario or contract line needs
  a one-line reason in the PR.
- Banned by default: combination grids over inputs, one test per error tuple, tests of
  private helpers, tests that restate a pattern match, tests that only assert the
  database raises, tests of cases that cannot happen. A test of how the application
  handles a constraint error, or of an invariant under concurrent writes, is allowed
  when a scenario names it.
- Allowed without a brief line: one regression test per fixed bug; one race or property
  test where the brief names a concurrency contract.
- Delete a test only when surviving tests cover its distinct required cases. Name them
  in the PR body.
- Test through public entry points: the context function, the LiveView, the job. Add a
  unit test only for pure logic a scenario test cannot reach. Add a browser test only
  for an interaction lower-level tests cannot check.
- Derive the expected result from the brief, not from the code. Code and tests can agree
  and both be wrong.
- A test proves a scenario only if its setup reached the condition and its assertion
  would fail for a plausible defect. Inspect the setup and expectation when a test
  passes unexpectedly.
- A double may replace an external call. The production code responsible for the claim
  must still run.
- Wait for the event or observable state with a time limit. A sleep is not proof. A
  timeout is not a pass.
- When code and tests disagree, use the brief to determine which is wrong. Do not change
  a fixture to make wrong behaviour pass.

## Performance

Trigger: the brief states a limit, or the change adds work that grows with data: a query
in a loop, a new preload, a result set with no limit, a transaction around an external
call, work that outlives the caller.

Name what grows and with what workload. Fix it with a filter, index, page or limit.
Measure only when the brief states a limit or the cost could change the design. Before
measuring, read [performance measurement](references/performance-measurement.md). Do not
measure when there is no stated limit and no growth.

## Deferrals

When the work reveals a problem the brief's budget does not cover:

- Do not fix it.
- Put it in one follow-up issue for this PR: the problem, the `path:line`, the trigger
  that makes it worth fixing. Link the issue from the PR body.
- If it breaks a scenario or a required rule, post a blocker instead.

## Bug fixes

When a result contradicts the brief, or a review finding shows a defect: find the failed
assumption before adding a condition. Check the other sites that share the assumption
and fix them in the same PR. Verify the whole contract, not only the reported case.

Refactor only when the brief requires it, or when the current code blocks a scenario or
its test. Name the blocking problem in the PR. Keep the refactor inside the affected
flow. Stop when the problem is resolved.

## Finish

Finish only when every scenario has a test. Confirm the tests and the [required checks](../../../AGENTS.md#checks) pass.

- Inspect the diff. Remove anything whose absence would not fail a scenario or make the
  code harder to read.
- Delete superseded code, tests and docs in the same PR.
- Update the docs the brief names. Do not add docs the brief did not ask for.
- Fill the [PR body](../../teams/README.md#pr-body): outcome, scenario table, affected
  code, tests without a scenario line, decisions, follow-up issue, checks not run by CI.
- Hand off through the [pair workflow](../../teams/README.md).
