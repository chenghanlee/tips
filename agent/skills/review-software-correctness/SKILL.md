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

1. The brief: contracts, acceptance scenarios, test budget, decisions table.
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
   [navigation rules](../../../AGENTS.md#elixir-navigation) say. Investigate every user
   that only one of them found.
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

Write the list in the review body under `Affected code`. For a changed fact, name the
paths you checked. If the list is empty, state how you checked that nothing else is
affected.

## Step 3: Scenarios

Check the brief's scenarios in order. Fill one row per scenario:

| Scenario | Proof | Status |
|---|---|---|
| number and title | test name, or the command you ran | proven, unproven or wrong |

Rules:

- Derive the expected result from the brief, not from the code or the test. Code and
  tests can agree and both be wrong.
- Run the test. Read its assertion. The test proves the scenario only if its setup
  reached the condition and its assertion fails for a plausible defect.
- For a row the brief marks `Masking risk:`, reproduce the implementer's control from
  the PR body: apply it, run the test, confirm it fails at the named assertion, then
  revert. The row is unproven if the control is missing, the test still passes, or it
  fails for another reason, such as setup, compilation or an unrelated crash.
- A double may replace an external call. The production code responsible for the claim
  must still run.
- Do not treat a sleep as proof or a timeout as a pass.
- Prove a scenario that names a user interaction in the browser. Follow [manual browser review](../../teams/README.md#manual-browser-review). Otherwise, mark it unproven.
- One test per scenario is enough. Do not ask for more.

Classify unproven or wrong scenarios as P1.

## Step 4: Mutation check

Skip when the PR changes only docs. Otherwise pick the scenario with the highest cost if
wrong: data loss, money, access, or an external effect.

1. Run its test unchanged. Confirm it passes.
2. Break the production code for that scenario with one realistic defect: invert a
   condition, drop a write, return early. If it causes a compile error or an unrelated
   crash, pick another defect. Neither proves the test detects the intended defect.
3. Run the test. Confirm its assertion fails.
4. Revert the change. Rerun the test. Confirm the working tree is clean.

Report P1 if the test still passes in step 3. It does not prove the scenario. Record the
mutation, the result and the time spent in the review body.

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
   only an unsettled contract needs a designer decision. Prefer extending an existing test.

Probes, by change type:

- Behaviour: check the observable result for each reachable state: loading, empty,
  error, stale, conflict. Check UI copy against the glossary.
- State: check duplicate or out-of-order updates across tabs, reconnects and timeouts.
  Check cancellation or restart after a write. Compare stored, retried and displayed
  values.
- Jobs: check stale inputs and repeated effects on retry. Check that the business write
  and the job insertion commit together.
- Boundaries: both sides of each [affected contract](../implement-software/SKILL.md#trace-the-affected-contract) and [call that can fail](../implement-software/SKILL.md#calls-that-can-fail); partial provider
  responses; exit status.
- Inputs: nil, empty, malformed, encoded identifiers, character versus byte limits,
  duplicates, values at and past limits, stored data from before the change.
- Trust: an id substituted for another user's; an action replayed after permissions
  changed; untrusted content into HTML, URLs, providers or commands; sensitive data in
  output or logs.
- Failure reporting: a `rescue`, `catch`, retry or fallback on an affected path that
  hides the error, returns a default, or logs without the identifiers it has.

## Step 6: Data

When the PR has a migration:

1. Run it on a database with existing rows, not an empty one.
2. Run the rollback.
3. Check that a backfill limits its work and can resume.

When the PR changes how stored data is written or read, with or without a migration:
read rows written before the change through the new code.

Classify a failure in any step as P1. Record "not applicable" for the branch that does
not apply to the PR.

## Step 7: Checks

Run the [required checks](../../../AGENTS.md#checks) for the kinds of files the PR
changed, in your own database and port, except the full application test suite.

For the full application suite, verify the implementer's record for the reviewed head
instead of running the suite again. This is a
[substitution](../../teams/roles/common.md#authority) by the user's decision of
2026-10-20 ([#515](https://github.com/chenghanlee/tips/issues/515)). It replaces the
default second run, including the plain `mix test` the changed-file-kind checks reach.
The record must cover that head completely: a CI run, or during the CI pause the record
the [policy](../../../AGENTS.md#github-ci-pause) requires. Missing, contradictory or
inapplicable evidence does not satisfy it: report the required check as missing, or run
the suite yourself. Also run the suite when your investigation needs it. Steps 3 to 6,
the other required checks, the browser delegation in the
[tester role](../../teams/roles/tester.md), the failed-check procedure and the rule for
carrying evidence across a later diff still apply. Harness Python checks are outside this rule.
Lost guarantee: a second unconditional application-suite run in another database, port
and runtime.

During the [CI pause](../../../AGENTS.md#github-ci-pause), verify the recorded local
commands, tested SHA, results and the excerpts the decision depends on. Record which
evidence you ran yourself and which you inspected. Apply the policy's rule for carrying
evidence across a later diff; an absent CI run is not a pass and does not replace local
verification.

- For a failing or flaky test, follow the [failed-check procedure](../../teams/README.md#report-and-resolve-blockers).
- Report: which checks passed, which failed with the failing lines only, which you did
  not run and why.
- For browser tests, real-provider tests, release smoke and migration rollback, record
  what you ran and its result. State what you did not run and why.
- Do not report a skipped CI check as passed.

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
2. `Affected code`: the list from step 2.
3. `Scenarios`: the table from step 3.
4. `Mutation`: what you broke and whether the test failed, and each control you
   reproduced.
5. `Ran`: the commands and checks you ran, with results.
6. `Not run`: what you did not run and why, and any step marked not applicable. For a
   required check, link the [substitution or waiver](../../teams/roles/common.md#authority)
   that removed it.
7. Design assessment and consequential tradeoffs from the shared investigation; no
   duplicate affected-code list or generic declaration is needed.
8. Findings outside the diff, each with `path:line`.
9. `Optional`: the P2 findings.

"No findings" is valid when every scenario is proven and every step above is recorded.

## Merge

Merge only as the [merge rule](../../teams/README.md#merge) allows: every required
review is an LGTM on the head, every thread is resolved, the required checks pass. This
skill does not authorize a review or a merge on its own.
