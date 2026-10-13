---
name: implement-software
description: Guides implementing a tips brief in the Phoenix/Elixir repository. Covers scope, the MVP posture, code rules, state and failure, data changes, tests and the test budget, deferrals and when to stop. Code reviews use review-software-correctness and review-software-design, which link to this skill's contract and failure sections.
---

# Implement software

You implement one brief in one PR. The brief's acceptance scenarios define done.
[AGENTS.md](../../../AGENTS.md) owns repository boundaries, navigation, stack skills
and checks. [design-software](../design-software/SKILL.md#what-well-designed-software-looks-like)
owns the architecture rules. This skill owns how to write the code and the tests.

## MVP posture

Tips is a greenfield MVP looking for product-market fit. Ship the smallest change
that makes every scenario in the brief pass. Correct means the contract holds.
Complete is a product choice the brief makes, not you.

Classify each choice before you make it:

- Cheap to reverse: code, config, queries, jobs, module layout. Decide, ship, note it
  in the PR if a reviewer could ask why.
- Expensive to reverse: schema, stored data, public URLs, provider contracts, new hex
  dependencies. Follow the brief. If the brief does not cover it, post a blocker.
  Do not guess.

## Scope

Read, in this order, then stop:

1. The brief: outcome, contracts, scenarios, test budget, decisions table,
   restrictions.
2. Each `path:line` the brief names and its callers, found with the
   [navigation rules](../../../AGENTS.md#elixir-navigation).
3. The stack skills AGENTS.md names for the files you will change.
4. The existing tests for the changed modules.

Reading beyond this list needs a reason you can state in one line. If the brief is
missing something you need, post the question through the pair workflow and
continue with the parts that do not depend on it.

The brief's decisions table is binding. Do not reopen a decision in code. Do not add
capabilities the brief does not name.

## Code rules

Apply these in every change. Each has the smell that breaks it.

- Pattern-match on the shape you expect. Let an unexpected shape fail at the
  boundary. Smell: `nil` checks on every step of a function.
- One error vocabulary per context: `{:ok, value}` and `{:error, reason}` with a
  fixed set of reasons. Use `with` for multi-step fallible flows. Smell: a function
  that returns `nil`, `false` and `{:error, _}` for different failures.
- Validate and authorize where the request enters: the LiveView event, controller
  action, channel handler or job. Inside, functions trust their arguments.
  Authorize the action where it is received, even if mount already checked.
  Smell: the same check at every layer.
- LiveViews and controllers call context functions. They do not call `Repo`.
  Smell: a query inside a `handle_event`.
- One module writes each fact. Find the other copies of a rule, limit, enum or
  label before changing it: constraints, migrations, helper text, fixtures, docs.
  Update each one. Smell: two modules that update the same column.
- Names say what the function does, including side effects. Arguments say which.
  No option that changes behaviour. Smell: an `opts` list with five keys.
- Functions fit on one screen. A module has one reason to change. Smell: a context
  module with thirty public functions.
- Reuse before invention: existing modules, Ecto, Oban and Phoenix features first.
  A new process, cache, GenServer, scheduler or abstraction needs the load or
  failure it answers, stated in the PR. Smell: a wrapper with one user.
- Use Ecto's query, changeset and migration DSLs. Use raw SQL or `fragment` only
  for what they cannot express. Bind runtime values as parameters.
- When you rely on a dependency's behaviour, check it at the installed version and
  link the source in the PR. A similar name does not prove the same behaviour.

Credo, Dialyzer and the formatter own style. The stack skills own idiom.

## Make breaks visible

Moving fast is safe only if we notice breaks. This is the always-rule for
implementation. A violation is a P1 in review.

- Every `rescue`, `catch`, retry and fallback logs the record id and the reason at
  `warning` or above.
- No `_ -> :ok`, no `rescue _ -> nil`, no default value that hides a failure.
- A job that fails raises or returns `{:error, reason}` so Oban retries and records
  it. Do not swallow the error and return `:ok`.
- Do not report "not found", "invalid input" or "success" unless the contract allows
  it for that case.

## Trace the affected contract

When you change behaviour or a return shape: find every caller with Dexter
`references` and scoped `rg`, and check the result through to the final state and
side effects. A correct return value does not prove a correct outcome.

When you refactor: keep observable behaviour the same except where the brief says
otherwise. If existing behaviour conflicts with the brief, say so in the PR. Do not
change the contract silently.

## State and failure

### Delayed and concurrent work

Trigger: a job, process, async callback, mount or reconnect path, transaction, lock,
retry, timeout, deadline, quota or limit.

- Name who owns each resource, who releases it and what survives the caller's exit.
- Do not release capacity while the work it bounds still runs. A cancel request does
  not mean the work stopped.
- Before applying a result, check it still belongs to the current operation. A read
  started before reconnect must not overwrite newer input.
- Revalidate a delayed or retried action: its inputs or permissions may have changed.
- Record completion only when the work is done. Cleanup running is not success.
- Bound the whole operation, not each step. Add up sequential work, retries,
  queueing and cleanup.
- For a shared deadline, quota or concurrency limit, say which results stop new work
  and what happens to work in progress.

### Fallible boundaries

Trigger: a database, HTTP, provider, storage, parser or OS call, or its result
handling.

- Check returns, exceptions, exits, timeouts, partial effects and required response
  fields.
- Handle each failure at the layer that can recover from it. Add a branch only when
  it changes the response or the recovery. Otherwise let the existing error boundary
  handle it, after checking that it does.
- Every caller handles or propagates a new result shape. An unmatched error is a
  crash or a wrong response.
- Before a retry or rollback, establish what may already have committed. No response
  does not prove failure. A local rollback does not undo an external effect.

## Data changes

Schema and stored data are expensive to reverse.

- Migrations are additive. A destructive migration (drop, rename, narrow) goes in a
  later PR after the code that stopped using the column has shipped.
- Backfills are bounded and resumable: batches, a cursor, a stated page size.
- Nothing is deleted from storage without a scenario in the brief that says so.
- A new column or table needs the contract in the brief that writes it.

## Tests

The brief's scenarios and contracts are the test list. The brief's test budget is
the limit. The repository has more test lines than application lines; do not add
to the ratio without a reason.

Order of work:

1. Read the existing tests for the changed modules.
2. Delete tests for behaviour this brief replaces. The brief names them.
3. For each scenario, find an existing test that can cover it with the same setup
   and action. Extend it. Add a new test only when none can.
4. Write the scenario test before the implementation. Run it. It must fail for the
   reason the scenario describes.
5. Implement until it passes. Stop.

Rules:

- One to two tests per scenario. A test that maps to no scenario or contract line
  needs a one-line reason in the PR.
- Banned by default: combination grids over inputs, one test per error tuple, tests
  of private helpers, tests that restate a pattern match, tests of a constraint the
  database enforces, tests of cases that cannot happen.
- Allowed without a brief line: one regression test per fixed bug; one race or
  property test where the brief names a concurrency contract.
- Two tests that fail for the same bug: keep one.
- Test through public entry points: the context function, the LiveView, the job.
  Add a unit test only for pure logic a scenario test cannot reach. Add a browser
  test only for an interaction lower-level tests cannot check.
- Derive the expected result from the brief, not from the code. Code and tests can
  agree and both be wrong.
- A test proves a scenario only if its setup reached the condition and its assertion
  would fail for a plausible defect. An unexpectedly passing test is a cue to inspect
  setup and expectation.
- A double may replace an external call. The production code responsible for the
  claim must still run.
- Wait for the event or observable state with a time limit. A sleep is not proof.
  A timeout is not a pass.
- When code and tests disagree, the brief decides which is wrong. Do not change a
  fixture to make wrong behaviour pass.

## Performance

Trigger: the brief states a bound, or the change adds work that grows with data: a
query in a loop, a new preload, an unbounded result set, a transaction around an
external call, work that outlives the caller.

Name what grows and with what workload. Fix it with a filter, index, page or bound.
Measure only when the brief states a bound or the cost could change the design;
then read [performance measurement](references/performance-measurement.md) first.
No stated bound and no growth: no measurement.

## Deferrals

When the work reveals a problem the brief's budget does not cover:

- Do not fix it.
- Add one line to the PR under `Deferrals`: the problem, the `path:line`, the
  trigger that makes it worth fixing.
- If it breaks a scenario or an always-rule, post a blocker instead.

## Bug fixes

When a result contradicts the brief, or a review finding shows a defect: find the
failed assumption before adding a condition. Check the other sites that share the
assumption and fix them in the same PR. Verify the whole contract, not only the
reported case.

Refactor only when the brief requires it, or when the current shape blocks a
scenario or its test. Name the blocking problem in the PR. Keep the refactor inside
the affected flow. Stop when the problem is resolved.

## Finish

Done means: every scenario has its test, the tests pass, the
[required checks](../../../AGENTS.md#checks) pass.

- Inspect the diff. Remove anything whose absence would not fail a scenario or make
  the code harder to read.
- Delete superseded code, tests and docs in the same PR.
- Update the docs the brief names. Do not add docs the brief did not ask for.
- PR description: what you built, deferrals, decisions a reviewer could question,
  checks that failed or were not run.
- Hand off through the [pair workflow](../../teams/README.md).
