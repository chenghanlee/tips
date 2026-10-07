---
name: developing-software
description: Guides code changes in this repository. Each section has a trigger you can see in the diff: behaviour paths, dependency claims, shared literals, state and resources, failures, cost bounds, tests, and repairing a finding. Use when implementing a feature, fix or refactor, handling failures, or writing tests. Not for code reviews or planning discussions.
---

# Developing software

[AGENTS.md](../../../AGENTS.md) rules and the language and framework skills come first.
Each section starts with a trigger you can see in the diff. Apply only the sections
whose trigger matches. Evidence is a source, a run result or a scenario someone can
reproduce. "I checked" is not evidence.

## Workflow

1. Before code: sections 1 to 3.
2. While coding: sections 4 to 6 when their triggers match.
3. Before pushing: section 7. Reread the diff against each triggered section and fix
   what fails. You are done when a reread finds nothing to fix, every required
   scenario has a test, and each other risk from those sections has a test, a source
   link or a named gap.
4. In the PR description, link the source for each claim about a dependency. Under
   "Not verified by CI", list each triggered risk with no test and say why.
5. After a review finding: section 8.

## 1. Behaviour and scope

Trigger: the diff changes a return value, error, rendered output, stored row, job or
message. A refactor must leave these unchanged.

- Trace every success, rejection and interruption path through the affected callers.
  Include what happens after a failed or lost reply.
- If recovery retries stored inputs, check whether later changes can make them
  permanently invalid. Refresh or reject them. Do not offer a retry that cannot
  succeed.

## 2. Existing mechanisms

Trigger: the diff adds a dependency; adds code that parses, validates, retries, caches,
pools, locks, waits, serializes or wraps another API; or states how a dependency or
provider behaves, in code, docs or comments.

- Check what the candidate and the rejected alternative do, and their limits, at the
  version and configuration in use. Link the source or docs that back the claim your
  choice rests on.

## 3. Shared rules

Trigger: the diff adds or changes a literal limit, pattern, enum value, label, error
message or query filter.

- Find every copy: code, DB constraint and its migration, design doc, form helper
  text, fixtures and other runtimes (#320's limit lived in five places). Reuse the
  owner. Merge copies only when the drift you remove costs more than the coupling you
  add.
- When one policy needs several implementations (another runtime, language or trust
  boundary), name the single source of truth and how the copies stay in sync. Keep
  validation at each trust boundary.

## 4. State and resources

Trigger: the diff adds or changes an async callback or promise, process, job, mount or
reconnect path, transaction, lock, OS process or capacity limit.

- Name the invariant and the transitions that can break it. Trace late, duplicate,
  cancelled and concurrent operations, and recovery after an interruption, to the
  final state and effects, not just the handler's return value.
- For each resource, name who owns it, who releases it and what survives the caller's
  exit. Do not free capacity while the work it bounds still runs. "Cancel requested"
  is not "process exited". Mark effects that cannot be undone.
- Before a result changes state, check that it still belongs to the current operation.
  Example: a storage read started before a disconnect must not overwrite input typed
  after the reconnect. Use framework guarantees where they are enough.
- Remove duplicate state that can disagree. Keep independent facts in separate fields.

## 5. Failures

Trigger: the diff adds or changes a fallible call (Repo, HTTP, a provider, browser
storage, an OS command, a parser) or the handling of its result.

- List the dependency's returns, exceptions, exits, timeouts, partial effects and
  required response fields. Map each to the outcome recovery needs. Keep every
  distinction that changes what happens next.
- Pass each failure's kind up to the layer that handles it. Do not report "not found",
  "invalid input" or "success" unless the contract allows that result. Keep enough
  safe context to tell input rejection from infrastructure failure.
- Example: a new `{:error, reason}` needs a matching clause in every caller up to the
  one that builds the response. Otherwise it crashes or becomes the wrong error (#320).
- Say which effect is uncertain and what settles it. A failed lookup does not prove an
  earlier write failed. A local rollback does not undo an external effect. No response
  does not tell you whether the effect committed.
- Record completion only when the required work is done, not because cleanup ran.
  Where production already decides success, reuse that result. Do not write a second
  check.
- For budgeted external work, define which results stop new work and what happens to
  in-flight work and cleanup. Check that every relevant failure, including follow-up
  reads, reaches that decision.

## 6. Complexity and performance

Trigger: the diff adds a timeout, retry, queue, size limit or parallel work.

- State the workload, the total time bound and the resource ceiling. Add up the bound
  across sequential work, parallel work, queueing, retries and cleanup. A step must
  not reset the total deadline. Include memory and work that outlives the caller.
  Measure when the design rests on a performance claim.

## 7. Tests

Trigger: every change, before pushing.

- Name the likely wrong behaviour and check that the tests, changed or not, would
  catch it. Test what the contract requires, including order, not how the code
  happens to represent it.
- The contract decides what is correct. When a test and the code disagree, the
  contract says which is wrong. Do not change fixtures to fit the code.
- Place doubles so the production code responsible for the claimed property still
  runs. Run the real wiring when the claim depends on it. Check setup assumptions
  (keys, sizes, environment) against production. Say what the test cannot show.
- Wait for the required event or observable state, with a time limit. A sleep does not
  prove completion. A timeout is not a pass.
- Before trusting a measurement or enforcement result, run a passing control and
  confirm the failure came from the condition under test. If the control fails, find
  out why first.
- Before deleting or replacing a test or probe, map each still-required scenario to a
  surviving test. A past report is not a regression test.

## 8. Repairing a finding

Trigger: the commit repairs a review finding or a reported bug.

- Name the broken invariant. Check the sibling sites or transitions that share it.
  Repair every affected case and copy, and reuse or extend their coverage. Say which
  cases the repair covers and which it does not.
- If the repair adds another flag, copy or special case for the same invariant, check
  whether an existing owner or transition can handle it. Remove the paths it replaces.
  Check the whole flow.
