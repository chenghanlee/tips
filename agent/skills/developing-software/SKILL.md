---
name: developing-software
description: Guides the design and implementation of features, fixes and refactors in any language or project. Checks dependency claims before custom mechanisms, shared rules before copies, lifecycle and authority invariants, failure categories, cost bounds and whether tests can detect the likely fault. Applies to implementation work; excludes code reviews and standalone planning discussions.
---

# Developing software

Follow the project's rules and its language and framework guidance; they take
precedence. Apply only the sections whose trigger matches the change. Record evidence
in existing tests and change notes; do not produce a checklist report. Evidence is a source, an execution result or a
reproducible scenario. A statement that a check was done is not evidence.

## 1. Behaviour and scope

Trigger: changed behaviour. For a refactor, check that behaviour is preserved.

- Trace the reachable success, rejection and interruption paths through the affected
  callers, including recovery after a failed or lost reply. Map each distinct required
  outcome to the scenario that checks it. State any outcome left unchecked and why.
- Add behaviour or extension points only for a current requirement, including required
  compatibility or deployment sequencing. Remove speculative paths this change does not
  need (YAGNI). When recovery retries stored inputs, check whether changes since the first
  attempt can make them permanently invalid; refresh or reject them instead of offering
  a retry that cannot succeed.

## 2. Existing mechanisms

Trigger: a new or replaced mechanism: client, parser, validator, pool, lock, retry,
cache, wait, state machine, protocol, serializer, wrapper.

- Check built-ins, dependencies, existing code and established tools first. Verify the
  candidate's behaviour and limits against the version and configuration in use; link
  the source or documentation that supports the claim that determines the choice.
- Idiomatic code uses the language's and framework's supported constructs and
  contracts. Prefer an existing mechanism when it meets the requirement at lower
  integration and maintenance cost. For custom code, show the unmet requirement or the
  concrete cost that justifies it. A claim about the alternative that you did not
  verify is a defect. A repository rule can require a construct on its own.
- When replacing a working integration or experiment, establish a passing control
  before relying on new measurements. If the control fails, isolate the cause before
  drawing the conclusion the experiment was meant to support.

## 3. Shared rules

Trigger: a rule, limit, lookup, label or query that may already exist.

- Find its definitions and the callers they affect. Reuse the owner, or consolidate
  when the drift removed outweighs the coupling and maintenance added. Check copies in tests,
  docs and other runtimes.
- When one policy needs several implementations (another runtime, language or trust
  boundary), name the single source of truth and how the copies stay aligned, for example
  generation or shared contract cases that exercise every implementation. Keep validation at each
  trust boundary.

## 4. State, resources and authority

Trigger: asynchronous work, late results, cancellation, retries, reconnects,
concurrent writers, child processes, locks, capacity, sessions, untrusted input,
authorization that can change during the operation.

- Name the invariant and the transitions that can break it. Trace the late, duplicate,
  cancelled and concurrent operations, including recovery after interruption, to the
  resulting state and effects, not only the handler's return value. Use a small table
  when it clarifies the sequence.
- For each resource, name who owns it, who releases it and what survives the caller's
  exit. Do not release capacity while the work it bounds still runs. Distinguish
  cancellation requested from termination confirmed, and mark effects that cannot be
  undone.
- Define a consistent validity check for each affected operation: does this result
  still belong to the current operation? Apply it before stale work can change state
  or produce effects. Reuse framework
  guarantees where they suffice. Remove redundant state that can disagree (make
  illegal states unrepresentable); keep independent facts in separate fields.
- Distinguish caller-selected data from trusted authority. Validate requested changes
  and resource ids; do not let caller input change the acting identity without the
  required authorization. Define when authorization must hold. If it must remain valid
  through the effect, use an atomic check or a protocol that handles changes during
  the operation (TOCTOU).

## 5. Failures

Trigger: new or changed handling of a call that can fail: I/O, dependency, parser,
database, provider, child process.

- Check the dependency's returns, exceptions, exits, timeouts and partial effects. Map
  them to the outcomes the application needs for recovery, preserving every
  distinction that changes what happens next.
- Keep each failure's recovery category until the responsible layer handles it. Do not
  report absence, invalid input or success unless the operation's contract supports
  that result. Retain enough safe diagnostic context to distinguish input rejection
  from infrastructure failure, even when the user message is coarse.
- State which effect is uncertain and what evidence resolves it. A failed lookup does
  not prove that an earlier write failed; a local rollback does not undo an external
  effect; receiving no response does not establish whether the effect committed.
- Record completion only when the required work is complete, not because cleanup ran.
  Where production already decides success, reuse the result production uses for
  success counts and stop decisions instead of implementing a second classifier; check the
  response fields that contract requires.
- For budgeted external work, define which results stop starting new work and how
  in-flight work and cleanup are handled. Verify that every relevant failure, including
  follow-up reads, reaches that decision.

## 6. Complexity and performance

Trigger: work that grows with input size or load; chained limits; queues; cleanup.

- State the workload, the cost and the required bound. Check repeated I/O (for example N+1
  queries) and loading data the caller does not need. Distinguish measured costs from estimates; measure
  when the design depends on a performance claim. Synchronous work alone is not a
  defect.
- Compose the end-to-end bound across sequential work, parallel work, queueing,
  retries and cleanup. Where a total deadline applies, steps must not reset it (deadline
  propagation).
  Account separately for memory, waiting work and cleanup that outlives the caller.

## 7. Simplicity

Trigger: adding a mechanism or considering a refactor.

- Simpler means fewer unnecessary parts or user steps for the same required
  behaviour, without moving costs elsewhere. Show what can be removed without losing
  required behaviour, failure isolation or testability. Include user effort and
  maintenance in the cost comparison. Fewer lines or modules alone do not prove
  simplicity.

## 8. Tests

Trigger: verifying changed behaviour, repairing coverage, or running an experiment.

- Compare changed and existing tests for the same requirement. For the targeted fault,
  name the plausible wrong behaviour and check that coverage distinguishes it. Test
  required observations and ordering, not incidental representation. Prefer extending an
  existing scenario when it covers the requirement without obscuring distinct
  behaviour.
- The contract is the test oracle: derive expectations from it, not from the code's
  current output. When a test and the code disagree, the contract decides which is
  wrong.
- Place doubles so the production code responsible for the claimed property still
  runs. Check setup assumptions against production and state what the test cannot
  establish. Exercise the real wiring when the claim depends on it.
- Synchronize on the required event or observable state with a supported wait
  primitive where it fits. Bound the wait and report the last observation on
  expiry. Elapsed sleep is not proof of completion; expiry is not success.
- Test the application's use of a platform guarantee, not the guarantee alone. Keep
  timing controls local; do not shorten global timeouts to speed up a few tests.
- For an enforcement or boundary experiment, establish the control and check that the
  observed failure came from the condition under test. An unrelated failure leaves the
  claim unproven.

## 9. Repairing a finding

Trigger: a confirmed defect.

- Name the broken invariant and inspect the sibling sites or transitions that share
  it. Repair the affected cases and reuse or extend their coverage. State which cases
  the repair addresses and any remaining gap. When a fix applies to a copy, find every
  copy.
- If the repair adds another flag, copy or special case for the same invariant, check
  whether an existing owner or transition can handle it. Remove superseded paths and
  verify the resulting flow as a whole.

## 10. Finish

Trigger: changed responsibilities or removed code, before handoff.

- Check what the change made unreachable, unused or false, including comments and
  configuration. Before deleting or replacing tests or probes, map each still-required
  scenario to surviving executable coverage; a historical report is not a regression
  test. Confirm callers before removing externally reachable code.
- After related repairs, read the affected flow together. Give distinct
  responsibilities distinct names; remove names that misdescribe the final behaviour or
  are ambiguous with framework APIs.
