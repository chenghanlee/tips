---
name: implement-software
description: Guides implementing a brief for the Tips application and its agent harness (agent/teams). Covers the MVP scope, code rules, state and failure, data changes, tests and the test budget, deferrals and when to stop. Code reviews use review-software-correctness and review-software-design, which link to this skill's contract and failure sections.
---

# Implement software

Implement one brief in one PR. Deliver its required behavior with coherent affected
structure and evidence proportionate to the contracts and uncertainty.
[AGENTS.md](../../../AGENTS.md) defines repository boundaries, navigation, stack skills
and checks. [design-software](../design-software/SKILL.md#required-rules) defines the
architecture rules. Follow this skill to write code and tests.

## MVP scope

Build the Tips application and its agent harness (`agent/teams`) as an MVP to test
product demand. Ship the simplest sufficient working change. Preserve the agreed outcome and constraints; missing product requirements go
to the user through the dispatcher. Maintain the brief's source-derived technical
detail without inventing scope.

Classify each choice before you make it:

- Cheap to reverse: code, config, queries, jobs, module layout. Make the choice and
  implement it. Explain it in the PR if a reviewer could ask why.
- Expensive to reverse: schema, stored data, public URLs, provider contracts, new hex
  dependencies. Follow the agreed contract. An unresolved consequential choice goes
  through the [architect route](../../teams/roles/dispatcher.md#decisions-during-implementation).
  Continue unaffected work; do not guess at the missing decision.

## Design during delivery

The implementer owns the coherent working change. Repair a structural problem in the
affected flow when its explainable present benefit to understanding, maintenance,
change, extension, reuse or verification justifies the work. Include necessary modules,
callers and tests. A failing scenario, prewritten refactor instruction, second caller
or smaller diff is not required. A cosmetic extraction is not required either.

Choose clear responsibilities, dependencies and ownership of state. Use small coherent
steps and prompt feedback; keep structural and behavioral effects distinguishable.
Separate commits or PRs when the review or verification benefit justifies the extra
coordination, not automatically. Keep observable behavior unless an authorized decision
changes it. Close the relevant evidence gap before trusting a preservation claim.

Internal placement is not frozen scope. Shared/public contracts, persistent or recovery
meaning, authority boundaries, expensive commitments and active ownership still bind.
When new facts invalidate one, raise the specific decision and evidence through the
workflow; only dependent work waits. Reversible exploration can establish missing facts.
Use existing PR Decisions/Affected code for consequential choices, not a smell inventory.

## Scope

Start with these sources, then follow the affected flow as needed:

1. The brief: outcome, contracts, scenarios, test budget, decisions table, restrictions.
2. The stack skills AGENTS.md names for the files you will change.
3. Each `path:line` the brief names and its callers, found with the [navigation rules](../../../AGENTS.md#elixir-navigation).
4. The existing tests for the changed modules.

Inspect necessary callers and existing mechanisms rather than treating the initial path
list as complete. Fill source-derived gaps in the brief; route unresolved requirements
or consequential decisions through the workflow and continue independent work.

Binding decisions change through their decision owner, not silently in code. Deferrals
follow the [severity rule](../../teams/README.md#severity). Do not add unagreed product
capabilities.

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
  enforce domain rules in context operations on each call, following the admission
  contract when the design docs define one.
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
- Keep responsibilities and dependencies understandable at the call site. Split a
  function or module when that improves the affected design, not to meet a line count.
- Use existing modules, Ecto, Oban and Phoenix features before creating your own. State
  in the PR what present benefit justifies a new process, cache, GenServer,
  scheduler or abstraction. A present structural benefit can justify a helper with one
  caller; a wrapper that merely repeats a dependency's API does not establish a benefit.
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
correct return value does not prove a correct outcome. For evidence across several
files, follow the [Lookup subagents](../../docs/subagents.md#lookup-subagents) rule; you
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

The brief's scenarios and contracts are the test list. The brief's test budget is the
expected net test change; explain any difference in the PR body.

Order of work:

1. Read the existing tests for the changed modules.
2. Delete tests for behaviour this brief replaces. The brief names them.
3. For each scenario, find an existing test that can cover it with the same setup and
   action. Extend it. Add a new test only when none can.
4. Write the scenario test before the implementation. Run it. Confirm it fails for the
   reason the scenario describes.
5. Make the scenario work, then inspect the affected design under
   [Design during delivery](#design-during-delivery). Repair a justified problem or
   record the consequential tradeoff. Stop when the working change is coherent and verified.

Rules:

- One to two tests per scenario. A test that maps to no scenario or contract line needs
  a one-line reason in the PR.
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
- A test proves a scenario only if its setup reached the condition and its assertion
  would fail for a plausible defect. Inspect the setup and expectation when a test
  passes unexpectedly.
- For a scenario the brief marks `Masking risk:`, supply a control: a small change to
  production code, or to a stub the test controls, that introduces the named defect.
  Never change the assertion. Run the test with the control, confirm the test fails at
  the assertion that detects that defect, then revert. Put the control
  and the failing assertion in the PR body. One control serves several scenarios only
  when it shows each one's distinguishing defect.
- A double may replace an external call. The production code responsible for the claim
  must still run.
- Wait for the event or observable state with a time limit. A sleep is not proof. A
  timeout is not a pass.
- When code and tests disagree, use the brief to determine which is wrong. Do not change
  a fixture to make wrong behaviour pass.

## Performance

Trigger: the change adds or alters work, waiting, memory or storage, including an
existing operation.

Apply the [performance principles](../design-software/SKILL.md#performance-principles)
at the expected MVP workload. Link the brief's relevant limits and assumptions.
Record new evidence and any implementation trade-off or discovery that affects the
design in the PR body. If it changes an agreed contract, obtain the decision through
the architect route and incorporate the linked answer before resuming affected work.

Measure only when a limit is stated or the cost could change the design. Before
measuring, read [performance measurement](references/performance-measurement.md).
Support a performance claim with the operation, the workload and the code, contract
or measurement evidence. Say whether a number is an estimate or a measurement.

## Deferrals

For unrelated improvements or wider work whose cost is not justified in this delivery:

- Keep it out of the current PR. Bounded repairs in the affected flow follow
  [Design during delivery](#design-during-delivery), not this exclusion.
- Put it in one follow-up issue for this PR: the problem, the `path:line`, the trigger
  that makes it worth fixing. Link the issue from the PR body.
- If it breaks a scenario or a required rule, post a blocker instead.

## Bug fixes

When a result contradicts the brief, or a review finding shows a defect: find the failed
assumption before adding a condition. Check the other sites that share the assumption
and fix them in the same PR. When the fix changes how a fact is stored, list its paths
as [Trace the affected contract](#trace-the-affected-contract) says. Verify the whole
contract, not only the reported case.

Structural repairs follow [Design during delivery](#design-during-delivery); a passing
scenario does not rule out a worthwhile repair. Stop when the affected problem is resolved.

## Finish

Finish only when every scenario has a test. Confirm the tests and the [required checks](../../../AGENTS.md#checks) pass.

- Inspect the diff for required behavior and coherent structure. Remove additions
  whose benefit does not justify their cost; retain justified repairs even when the
  scenarios passed before them.
- Delete superseded code, tests and docs in the same PR.
- Update affected contract and usage docs so they describe the resulting behavior.
- Fill the [PR body](../../teams/README.md#pr-body): outcome, scenario table, affected
  code, tests without a scenario line, decisions, follow-up issue, checks not run by CI.
- Hand off through the [pair workflow](../../teams/README.md).
