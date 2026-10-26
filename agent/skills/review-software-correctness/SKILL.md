---
name: review-software-correctness
description: Guides the correctness part of a tips PR review. The combined tester also applies review-software-design in the same investigation and review record.
---

# Review software correctness

Verify that the change meets the brief on every affected path. Provide evidence for that
conclusion.

Scope limits:

- Also apply [review-software-design](../review-software-design/SKILL.md). Reuse the
  same affected-code investigation and review record; correctness does not replace
  assessment of responsibility, dependencies, state ownership or test value.
- Ask for a test only for a scenario, or for an existing contract the affected code
  reaches that no surviving test proves (step 5).
- Deferrals follow the [severity rule](../../teams/README.md#severity).
- One pass. Report every P0 and P1. Report at most three P2 findings, the ones with the
  greatest consequence. Combine findings only when they share a cause and fix. Put P2s
  where [Optional P2 findings](../../teams/README.md#optional-p2-findings) says.

The [tester role](../../teams/roles/tester.md) defines turns, handoff and the merge.
[implement-software](../implement-software/SKILL.md) is the standard for contracts,
state and failure. Follow this skill to inspect the code and run checks.

## Step 1: Inputs

Collect, in this order:

1. The brief: contracts, acceptance scenarios, decisions table.
2. The head SHA you review. Record it.
3. The diff against the PR base.
4. The existing tests for each changed module.

Record your concerns as the [review record](../../teams/README.md#pr-review-record)
says, then read the [PR body](../../teams/README.md#pr-body) and prior review threads.
Verify the PR body's scenario table and affected code in steps 2
and 3. Do not copy these claims as results. For a local review with no PR, use the
user's brief and the working tree.

## Step 2: Affected code

Find everything the change can affect, not only the changed lines.

1. List each changed public function, schema, changeset, query, migration, config key,
   PubSub topic, Oban queue or worker, shared test fixture and shared component.
2. For each item, find its users with Dexter `references` and scoped `rg`, as the
   [navigation rules](../../../agent/docs/elixir-navigation.md) say. Investigate every user
   that only one of them found. For evidence across several files, follow the
   [Lookup subagents](../../docs/lookup-subagents.md) rule; you remain responsible
   for tracing and verifying the affected contract.
3. Follow each user in turn. Stop at an entry point, or at a caller whose handling of
   the change you have read and that still satisfies its own contract. Do not stop just
   because a signature is unchanged. Keep a list of visited functions. Do not revisit a
   function.
4. Collect the entry points reached: LiveViews, controllers, channels, jobs, other
   contexts.

Include indirect effects:

- A changeset change affects every form and context that uses it.
- A migration affects every existing row.
- A shared fixture or factory change affects every test that uses it.
- A config change affects every environment that reads it.
- A changed error tuple affects every caller that matches on it.
- An added, cached, moved or removed fact affects each path that constructs, updates,
  reads, resets or removes it, and each late callback
  ([implement-software](../implement-software/SKILL.md#trace-the-affected-contract)).
  Find them yourself before comparing with the PR body's list.

Then verify the PR body's `Affected code` list at the reviewed head. In the review body
report only what you add, correct or dispute, and any material coverage limit; link the
verified list instead of copying it.

## Step 3: Scenarios

Check the brief's scenarios in order. Fill one row per scenario:

| Scenario | Proof | Status |
|---|---|---|
| number and title | test name, or the command you ran | proven, unproven or wrong |

Rules:

- Derive the expected result from the brief, not from the code or the test. Code and
  tests can agree and both be wrong.
- Run the test. Read its assertion. For each row, identify how the setup reaches the
  claimed condition, the brief line or established affected contract that supplies the
  expected result, and the assertion that would fail for the named defect. For
  asynchronous work, the test waits for the event or observable state with a time limit
  before asserting; a sleep is not proof and a timeout is not a pass.
- The input must separate the intended behaviour from the named defect, with the other
  preconditions valid ([implement-software](../implement-software/SKILL.md#tests)).
- For a row the brief marks `Masking risk:`, and for a control the PR body records from
  the implementation, reproduce the implementer's control: apply it, run the test,
  confirm it fails at the named assertion, then revert. The row is unproven if the
  control is missing or not run, the test still passes, or it fails for another reason,
  such as setup, compilation or an unrelated crash.
- A double may replace an external call. The production code responsible for the claim
  must still run.
- Prove a scenario that names a user interaction in the browser. Follow [manual browser review](../../teams/README.md#manual-browser-review). Otherwise, mark it unproven.
- Ask for another test only for a distinct required case no surviving test proves
  ([implement-software](../implement-software/SKILL.md#tests)).

Classify unproven or wrong scenarios as P1.

## Step 4: Mutation check

Skip when the PR changes only docs. Otherwise choose a realistic defect in the scenario
with the highest cost if wrong: data loss, money, access, or an external effect. Say in
the record why that scenario costs most. Then inspect where the change joins the
existing flow: callers, ordering, release and cleanup. Add a second control when that
join exposes a distinct consequential risk the first control does not cover.

Before each run, name the plausible mistake, the behaviour it changes and the assertion
expected to fail. Choose a mistake the PR body's controls do not already cover;
reproducing a control is Step 3, not this check. A new or existing test counts when it exercises the responsible
production path and detects that behaviour; neither the test's age nor whether the
mutant deletes a line decides validity.

For each control:

1. Run its test unchanged. Confirm it passes.
2. Apply the defect: invert a condition, drop a write, return early, reorder two steps.
   If it causes a compile error or an unrelated crash, pick another defect. Neither
   proves the test detects the intended defect.
3. Run the test. Confirm the named assertion fails.
4. Revert the change. Rerun the test. Confirm the working tree is clean.

Report P1 if the test still passes in step 3. It does not prove the scenario. Record each
mutation and its result in the review body.

## Step 5: Entry points

For each entry point in the affected code:

1. Run its existing tests.
2. Pick the probes below that the changed contract makes relevant. Name them in the
   review body. Do not require a fixed number of probes.
3. Trace one input from the entry point through the changed code to the final state and
   side effects.
4. If the path reaches an existing contract that no surviving test proves for the
   changed case, file P1 "missing coverage for affected contract `path:line`" with the
   uncovered case. The implementer records the case and supplies the missing evidence;
   only an unsettled contract needs an architect decision. Prefer extending an existing test.

Probes, by change type:

- Behaviour: check the observable result for each reachable state: loading, empty,
  error, stale, conflict.
- State: check duplicate or out-of-order updates across tabs, reconnects and timeouts.
  Check cancellation or restart after a write. Compare stored, retried and displayed
  values.
- Data: when stored readers or writers change, exercise pre-change records through the
  new code; for a migration, also run it on existing rows, run the rollback, and check
  that any backfill is bounded and resumable.
- Boundaries: both sides of each [affected contract](../implement-software/SKILL.md#trace-the-affected-contract) and [call that can fail](../implement-software/SKILL.md#calls-that-can-fail); partial provider
  responses; exit status.
- Inputs: nil, empty, malformed, encoded identifiers, character versus byte limits,
  duplicates, values at and past limits, stored data from before the change.
- Trust: an id substituted for another user's; an action replayed after permissions
  changed; untrusted content into HTML, URLs, providers or commands; sensitive data in
  output or logs.
- Failure reporting: a `rescue`, `catch`, retry or fallback on an affected path that
  hides the error, returns a default, or logs without the identifiers it has.

## Step 6: Checks

Run the [required checks](../../../agent/docs/checks.md) for the kinds of files the PR
changed, in your own database and port. For the full application suite, follow the
[substitution](../../../agent/docs/checks.md#application-suite-substitution); for local
evidence during the CI pause, follow the [policy](../../../agent/docs/github-ci-pause.md).
Run any further check your investigation needs.

Report each applicable check once: run by you, verified from the implementer's record,
or missing with its reason or an authorized waiver. Quote only the failing lines. For a
failing or flaky test, follow the
[failed-check procedure](../../teams/README.md#report-and-resolve-blockers). Do not
report a skipped CI check as passed.

## Proof standard

A P1 defect claim needs one of:

- A reproduction: the command, the input and the output.
- A trace: `path:line` from the input through the code to the wrong result.

Without one, file it as a P2 marked `suspected`, with what you tried. A missing check,
an unproven scenario or missing coverage is a P1 on the evidence of the gap; it needs no
defect reproduction.

Say for every finding whether it came from a run or from reading.

## Severity

Use the [severity table](../../teams/README.md#severity). A scenario that passes for the
wrong reason is unproven. State the requested change for every P2.

## Review record

Submit the [PR review record](../../teams/README.md#pr-review-record), with findings in
the [finding format](../../../AGENTS.md#github).

Review body, in this order:

1. Head SHA.
2. `Affected code`: what you add to, correct or dispute in the PR body's list, or "none".
3. `Scenarios`: the table from step 3.
4. `Mutation`: what you broke and whether the test failed, and each control you
   reproduced.
5. `Checks`: each applicable check as run, verified from the record, or missing with its
   reason or [waiver](../../teams/roles/common.md#authority); limitations that qualify
   a proof. Omit inapplicable categories.
6. Design assessment and consequential tradeoffs from the shared investigation; no
   generic declaration is needed.
7. Findings outside the diff, each with `path:line`, and `Optional` P2 findings. Omit
   either heading when it has none.

"No findings" is valid when every scenario is proven and every step above is recorded.

After a full review of a PR, a review of a later head may use a compact record: the
head, the complete delta, the new evidence you inspected or ran, the reason each retained
result still applies, findings and unresolved checks. Recheck the obligations, code,
tests, fixtures and inputs the delta changes; repeat a control when the change
invalidates its evidence. A change to one claim does not require repeating unaffected
evidence. An unchanged head does not remove the need to assess new evidence, such as a
new check record.

## Merge

Merge only as the [merge rule](../../teams/README.md#merge) allows: every required
review is an LGTM on the head, every thread is resolved, the required checks pass. This
skill does not authorize a review or a merge on its own.
