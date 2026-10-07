---
name: developing-software
description: Guides code changes in any language or project. Checks what a dependency really does before custom code, one owner per shared rule, state and authority invariants, failure categories, cost bounds, and whether tests can catch the likely fault. Use when implementing a feature, fix or refactor, designing a module, choosing between a library and custom code, handling failures, or writing tests. Not for code reviews or planning discussions.
---

# Developing software

Project rules and language or framework guidance come first. Apply only the sections
whose trigger matches your change. Put evidence in tests and change notes, not in a
checklist. Evidence is a source, a run result or a scenario someone can reproduce.
Saying you checked is not evidence.

## Workflow

1. Before code: sections 1 to 3.
2. While coding: sections 4 to 7 when their triggers match.
3. Before pushing: section 8. Then reread the diff against each triggered section.
   Fix what fails. Repeat until nothing fails.
4. After a finding, and before handoff: sections 9 and 10.

[evals.json](evals.json) holds three scenarios that compare this skill against a
baseline without it.

## 1. Behaviour and scope

Trigger: changed behaviour. For a refactor, check that behaviour is unchanged.

- Trace every success, rejection and interruption path through the affected callers,
  including recovery after a failed or lost reply. Map each required outcome to the
  test that checks it. Name any outcome without a test and say why.
- Add behaviour or extension points only for a current requirement, including required
  compatibility or deployment order. Remove paths this change does not need (YAGNI).
- If recovery retries stored inputs, check whether changes since the first attempt can
  make them invalid for good. Refresh or reject them. Do not offer a retry that cannot
  succeed.

## 2. Existing mechanisms

Trigger: a new or replaced client, parser, validator, pool, lock, retry, cache, wait,
state machine, protocol, serializer or wrapper.

- Check built-ins, dependencies, existing code and common tools first. Verify what the
  candidate does and its limits at the version and configuration in use. Link the
  source or docs that support the claim your choice rests on.
- Idiomatic code uses the constructs and contracts the language and framework support.
  Prefer an existing mechanism when it meets the requirement at lower integration and
  maintenance cost. For custom code, name the unmet requirement or the concrete cost.
  An unverified claim about the alternative is a defect. A repository rule can require a
  construct on its own.
- When replacing a working integration or experiment, get a passing control before
  trusting new measurements. If the control fails, find the cause before drawing the
  conclusion the experiment was for.

## 3. Shared rules

Trigger: a rule, limit, lookup, label or query that may already exist.

- Find its definitions and their callers. Reuse the owner, or consolidate when the
  drift removed outweighs the coupling and maintenance added. Check copies in tests,
  docs and other runtimes.
- When one policy needs several implementations (another runtime, language or trust
  boundary), name the single source of truth and how copies stay aligned, for example
  generation or shared contract cases that run against every implementation. Keep
  validation at each trust boundary.

## 4. State, resources and authority

Trigger: async work, late results, cancellation, retries, reconnects, concurrent
writers, child processes, locks, capacity, sessions, untrusted input, or authorization
that can change during the operation.

- Name the invariant and the transitions that can break it. Trace late, duplicate,
  cancelled and concurrent operations, and recovery after interruption, to the final
  state and effects, not just the handler's return value. A small table helps when the
  sequence is unclear.
- For each resource, name who owns it, who releases it and what survives the caller's
  exit. Do not release capacity while the work it bounds still runs. Separate
  "cancellation requested" from "termination confirmed". Mark effects that cannot be
  undone.
- For each operation, define one check: does this result still belong to the current
  operation? Apply it before stale work changes state or produces effects. Reuse
  framework guarantees where they are enough. Remove redundant state that can disagree
  (make illegal states unrepresentable). Keep independent facts in separate fields.
- Separate caller-selected data from trusted authority. Validate requested changes and
  resource ids. Caller input must not change the acting identity without authorization.
  Define when authorization must hold. If it must hold through the effect, use an atomic
  check or a protocol that handles changes mid-operation (TOCTOU).

## 5. Failures

Trigger: new or changed handling of a call that can fail: I/O, dependency, parser,
database, provider, child process.

- Check the dependency's returns, exceptions, exits, timeouts and partial effects. Map
  them to the outcomes the application needs for recovery. Keep every distinction that
  changes what happens next.
- Keep each failure's recovery category until the layer that handles it. Do not report
  absence, invalid input or success unless the contract allows that result. Keep enough
  safe diagnostic context to tell input rejection from infrastructure failure, even
  when the user sees a short message.
- Say which effect is uncertain and what evidence settles it. A failed lookup does not
  prove an earlier write failed. A local rollback does not undo an external effect. No
  response does not show whether the effect committed.
- Record completion only when the required work is done, not because cleanup ran. Where
  production already decides success, reuse that result for success counts and stop
  decisions; do not write a second classifier. Check the response fields the contract
  requires.
- For budgeted external work, define which results stop new work and what happens to
  in-flight work and cleanup. Verify every relevant failure, including follow-up reads,
  reaches that decision.

## 6. Complexity and performance

Trigger: work that grows with input or load; chained limits; queues; cleanup.

- State the workload, the cost and the required bound. Check repeated I/O (for example
  N+1 queries) and loading data the caller does not need. Separate measured costs from
  estimates. Measure when the design rests on a performance claim. Synchronous work
  alone is not a defect.
- Compose the end-to-end bound across sequential work, parallel work, queueing, retries
  and cleanup. Where a total deadline applies, steps must not reset it (deadline
  propagation). Account separately for memory, waiting work and cleanup that outlives
  the caller.

## 7. Simplicity

Trigger: adding a mechanism or considering a refactor.

- Simpler means fewer unnecessary parts or user steps for the same required behaviour,
  without moving costs elsewhere. Show what can be removed without losing required
  behaviour, failure isolation or testability. Count user effort and maintenance in
  the comparison. Fewer lines or modules alone do not prove simplicity.

## 8. Tests

Trigger: verifying changed behaviour, repairing coverage, or running an experiment.

- Compare changed and existing tests for the same requirement. Name the plausible wrong
  behaviour and check that the tests would catch it. Test required observations and
  order, not incidental representation. Extend an existing scenario when it covers the
  requirement without hiding distinct behaviour.
- The contract is the test oracle. Derive expectations from it, not from the code's
  current output. When a test and the code disagree, the contract decides which is
  wrong.
- Place doubles so the production code responsible for the claimed property still
  runs. Check setup assumptions against production. Say what the test cannot show.
  Run the real wiring when the claim depends on it.
- Wait on the required event or observable state, with a supported wait primitive
  where one fits. Bound the wait. On expiry, report the last observation. A sleep is
  not proof of completion. Expiry is not success.
- Test the application's use of a platform guarantee, not the guarantee alone. Keep
  timing controls local. Do not shorten global timeouts to speed up a few tests.
- For an enforcement or boundary experiment, run a control and check that the observed
  failure came from the condition under test. An unrelated failure proves nothing.

## 9. Repairing a finding

Trigger: a confirmed defect.

- Name the broken invariant. Inspect the sibling sites or transitions that share it.
  Repair the affected cases and reuse or extend their coverage. Say which cases the
  repair covers and what gap remains. When a fix applies to a copy, find every copy.
- If the repair adds another flag, copy or special case for the same invariant, check
  whether an existing owner or transition can handle it. Remove superseded paths. Verify
  the whole flow.

## 10. Finish

Trigger: changed responsibilities or removed code, before handoff.

- Check what the change made unreachable, unused or false, including comments and
  configuration. Before deleting or replacing tests or probes, map each still-required
  scenario to a surviving test. A historical report is not a regression test. Confirm
  callers before removing externally reachable code.
- After related repairs, read the affected flow as a whole. Give distinct
  responsibilities distinct names. Remove names that misdescribe the final behaviour
  or clash with framework APIs.
