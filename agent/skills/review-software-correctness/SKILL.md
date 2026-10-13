---
name: review-software-correctness
description: Guides the tester's review of a tips PR for correctness against its brief. Covers the blast radius of the change, running the scenarios, a mutation check, data checks, the proof standard for findings, severity and the review record. Design quality, smells and test value belong to review-software-design.
---

# Review software correctness

You answer one question: does the change do what the brief says, on every path it
touches, and can we prove it.

Scope limits:

- Do not review design, smells, idiom or test value. That is
  [review-software-design](../review-software-design/SKILL.md).
- Ask for a test only for a scenario, or for an existing contract the blast radius
  reaches that no surviving test proves (step 5).
- Deferrals follow the [severity rule](../../teams/README.md#severity): a recorded
  deferral settles P2 on that point, never P0 or P1.
- One pass. Report every P0 and P1. Report at most three P2 findings, the ones with
  the greatest consequence. Combine findings only when they share a cause and fix.

The [tester role](../../teams/roles/tester.md) owns turns, handoff and the merge.
[implement-software](../implement-software/SKILL.md) is the standard for
contracts, state and failure. This skill owns what to inspect and what to run.

## Step 1: Inputs

Collect, in this order:

1. The brief: contracts, acceptance scenarios, test budget, decisions table.
2. The head SHA you review. Record it.
3. The diff against the PR base.
4. The existing tests for each changed module.

Write down your concerns. Then read the [PR body](../../teams/README.md#pr-body)
and prior review threads. The PR body's scenario table and blast radius are claims
to verify in steps 2 and 3, not results to copy. For a local review with no PR, use the user's brief and the
working tree.

## Step 2: Blast radius

Find everything the change can affect, not only the changed lines.

1. List each changed public function, schema, changeset, query, migration, config
   key, PubSub topic, Oban queue or worker, shared test fixture and shared
   component.
2. For each item, find its users with Dexter `references` and scoped `rg`, as the
   [navigation rules](../../../AGENTS.md#elixir-navigation) say. Investigate every
   user that only one of them found.
3. Follow each user in turn. Stop at an entry point, or at a caller whose handling
   of the change you have read and that still keeps its own contract. An unchanged
   signature alone is not a stop. Keep a visited list; do not revisit a function.
4. Collect the entry points reached: LiveViews, controllers, channels, jobs, other
   contexts.

Indirect reach counts:

- A changeset change reaches every form and context that uses it.
- A migration reaches every existing row.
- A shared fixture or factory change reaches every test that uses it.
- A config change reaches every environment that reads it.
- A changed error tuple reaches every caller that matches on it.

Write the list in the review body under `Blast radius`. An empty list is a claim;
state how you checked it.

## Step 3: Scenarios

Walk the brief's scenarios in order. Fill one row per scenario:

| Scenario | Proof | Status |
|---|---|---|
| number and title | test name, or the command you ran | proven, unproven or wrong |

Rules:

- Derive the expected result from the brief, not from the code or the test. Code
  and tests can agree and both be wrong.
- Run the test. Read its assertion. The test proves the scenario only if its setup
  reached the condition and its assertion fails for a plausible defect.
- A double may replace an external call. The production code responsible for the
  claim must still run.
- A sleep is not proof. A timeout is not a pass.
- A scenario that names a user interaction is proven in the browser, following
  [manual browser review](../../teams/README.md#manual-browser-review), or marked
  unproven.
- One test per scenario is enough. Do not ask for more.

Unproven and wrong are P1.

## Step 4: Mutation check

Skip when the PR changes only docs. Otherwise pick the scenario with the highest
cost if wrong: data loss, money, access, or an external effect.

1. Run its test unchanged. It must pass.
2. Break the production code for that scenario with one realistic defect: invert a
   condition, drop a write, return early. A compile error or an unrelated crash is
   not evidence; pick another defect.
3. Run the test. Its assertion must fail.
4. Revert the change. Rerun the test. Confirm the working tree is clean.

A test that still passes in step 3 is a P1: the test does not prove the scenario.
Record the mutation, the result and the time spent in the review body.

## Step 5: Affected paths

For each entry point in the blast radius:

1. Run its existing tests.
2. Pick the probes below that the changed contract makes relevant. Name them in the
   review body. No quota.
3. Trace one input from the entry point through the changed code to the final
   state and side effects.
4. If the path reaches an existing contract that no surviving test proves for the
   changed case, file P1 "missing coverage for affected contract `path:line`" with
   the uncovered case. The lead adds the scenario. Prefer extending an existing
   test.

Probes, by change type:

- Behaviour: each reachable state has an observable result: loading, empty, error,
  stale, conflict. UI copy matches the glossary.
- State: duplicate or out-of-order updates across tabs, reconnects and timeouts;
  cancel or restart after a write; stored, retried and displayed values compared.
- Jobs: stale inputs on retry; repeated effects on retry; the business write and
  the job insertion commit together.
- Boundaries: both sides of each
  [affected contract](../implement-software/SKILL.md#trace-the-affected-contract)
  and [fallible boundary](../implement-software/SKILL.md#fallible-boundaries);
  partial provider responses; exit status.
- Inputs: nil, empty, malformed, encoded identifiers, character versus byte
  limits, duplicates, values at and past limits, stored data from before the
  change.
- Trust: an id substituted for another user's; an action replayed after
  permissions changed; untrusted content into HTML, URLs, providers or commands;
  sensitive data in output or logs.
- Breaks visible: a `rescue`, `catch`, retry or fallback on an affected path that
  swallows the error, returns a default, or logs without the identifiers it has.

## Step 6: Data

When the PR has a migration:

1. Run it on a database with existing rows, not an empty one.
2. Run the rollback.
3. Check that a backfill is bounded and resumable.

When the PR changes how stored data is written or read, with or without a
migration: read rows written before the change through the new code.

A failure in any step is P1. Record "not applicable" for the branch the PR does not
take.

## Step 7: Checks

Run the [required checks](../../../AGENTS.md#checks) for the kinds of files the PR
changed, in your own database and port. When application code, tests or
behaviour-changing config changed, run the full application test suite once.

- Rerun a failing test once. If it passes the second time, report it as flaky with
  the test name. Do not hide it.
- Report: which checks passed, which failed with the failing lines only, which you
  did not run and why.
- For browser tests, real-provider tests, release smoke and migration rollback,
  record what you actually did: ran with result, or not run with the reason.
- A CI result that did not run is not a pass.

## Proof standard

A P1 defect claim needs one of:

- A reproduction: the command, the input and the output.
- A trace: `path:line` from the input through the code to the wrong result.

Without one, file it as a P2 marked `suspected`, with what you tried. A missing
check, an unproven scenario or missing coverage is a P1 on the evidence of the gap;
it needs no defect reproduction.

Say for every finding whether it came from a run or from reading.

## Severity

Use the [severity table](../../teams/README.md#severity). A scenario that passes
for the wrong reason is unproven. Every P2 carries the change you ask for.

## Review record

Submit the [PR review record](../../teams/README.md#pr-review-record): decision on
line 1, your entry and session on line 2, one finding per inline comment in the
[finding format](../../../AGENTS.md#github).

Review body, in this order:

1. Head SHA.
2. `Blast radius`: the list from step 2.
3. `Scenarios`: the table from step 3.
4. `Mutation`: what you broke and whether the test failed.
5. `Ran`: the commands and checks you ran, with results.
6. `Not run`: what you did not run and why, and any step marked not applicable.
7. Findings outside the diff, each with `path:line`.

"No findings" is valid when every scenario is proven and every step above is
recorded.

## Merge

Merge only as the [merge rule](../../teams/README.md#merge) allows: every required
review is an LGTM on the head, every thread is resolved, the required checks pass.
This skill does not authorize a review or a merge on its own.
