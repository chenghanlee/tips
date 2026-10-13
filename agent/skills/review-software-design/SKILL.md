---
name: review-software-design
description: Guides the reviewing designer's pass over a tips PR. Covers compliance with the brief's contracts, the required rules, simplicity, code and architecture smells, limits and test value. Acceptance scenarios, checks and merging belong to review-software-correctness.
---

# Review software design

Check whether a simpler implementation could satisfy the brief's contracts. The
[design-software](../design-software/SKILL.md) rules are the standard. The [designer role](../../teams/roles/designer.md) defines turns and messages.

Scope limits:

- Do not review scenarios, checks or the merge. Those reviews use
  [review-software-correctness](../review-software-correctness/SKILL.md).
- One pass. Report every P0 and P1. Report at most three P2 findings, the ones with the
  greatest consequence. Combine findings only when they share a cause and fix.
- Deferrals follow the [severity rule](../../teams/README.md#severity): a recorded
  deferral settles P2 on that point, never P0 or P1. A shortcut the brief did not accept
  is a P2 with a proposed deferral, not a demand for completeness.
- For a local review with no PR, use the user's brief and report in the form the user
  asked for. Do not publish a GitHub review.
- Use Credo, Dialyzer and the formatter for style checks. Review conventions only where
  the change violates its stack skill in AGENTS.md. Cite the skill. Report one finding
  per repeated pattern.

## Step 1: Inputs

1. The brief's contracts, the spec's shared contracts and decisions table.
2. The head SHA. Record it.
3. The diff against the PR base, and the callers of every changed public function.
4. Write your concerns. Then read the [PR body](../../teams/README.md#pr-body) and
   verify its affected code and decisions against the diff.

## Step 2: Match the brief

- Check that each contract in the brief has one implementation at its specified
  `path:line`. If it moved, check that the PR body states where and why.
- If the implementation differs from the brief but is simpler and preserves the
  contract, report a finding against the brief. Propose the brief edit.
- Require a workload or failure to justify an mechanism the brief did not ask for. Without
  one, report P2 to remove the mechanism.
- For each shortcut the brief accepted, check that the diff matches its decision row.
  Check what fails if the shortcut is wrong. Check how the failure is detected. Accept a
  job that retries and logs for the MVP. Do not accept silent data loss. Report only a
  missing or contradicted row.

## Step 3: Required rules

Check each [required rule](../design-software/SKILL.md#required-rules) against the diff.
Classify a violation as P1. Cite the rule and the `path:line`.

## Step 4: Simplicity

Look for mechanisms that can be removed or replaced without losing required behaviour.
Name the mechanism and its replacement. State the current cost and the cost of the
replacement in the finding. Name who does any work transferred by the replacement. Do
not infer simplicity from fewer lines alone.

## Step 5: Code and architecture smells

Check the diff for code smells and software architecture smells. Report a smell only
when it has a cost now: the code is harder to change or test, a fact has two
writers, or a failure path is hidden. Report each as P2 with a proposed change, or as
a line for the follow-up issue.

Examples from this repository: a module that writes another module's facts; a
boundary check repeated inside; a process, cache or abstraction with one user; a job
that does what a query could; an `opts` list that changes behaviour; a wrapper over a
dependency feature; a default that hides a failure.

## Step 6: Limits

Only where the brief states a limit or the change adds work that grows with data: a
query in a loop, a result set with no limit, a transaction around an external call, work
that outlives the caller. Name what grows, the workload and the consequence. Do not
report a finding when there is no stated limit and no growth.

## Step 7: Test value

Limit tests to the brief's scenarios and contracts.

- Map each new test to a scenario or contract line, or to a reason in the PR body's
  tests-without-a-scenario-line section. If neither applies, report P2 to delete it.
- Each test fails if its contract breaks, and passes for one reason. Ask to delete a
  test only when surviving tests cover its distinct required cases. Name them.
- Flag combination grids, one test per error tuple, tests of private helpers, restated
  pattern matches, tests that only assert the database raises.
- Check the net test change against the brief's test budget and the PR body's reasons.
  Check that replaced tests were deleted.
- Raise a test's correctness only when you can show the case where it passes wrongly.

## Record

Severity follows the [severity table](../../teams/README.md#severity). For every P2,
state the proposed change or the deferral line to add.

Submit the [PR review record](../../teams/README.md#pr-review-record): decision on line
1, your entry and session on line 2, one finding per inline comment in the [finding format](../../../AGENTS.md#github). Body: head SHA, what you ran, what you read. "No
findings" is valid. Resolve only your own threads.
