---
name: review-software-design
description: Guides the design assessment of a tips PR, by the combined tester or an additional designer. Covers contracts, responsibility, dependencies, state ownership, simplicity, performance and test value.
---

# Review software design

Check whether a simpler implementation could satisfy the brief's contracts. The
[design-software](../design-software/SKILL.md) rules are the standard. The [designer role](../../teams/roles/designer.md) defines turns and messages.

Scope limits:

- The combined tester applies this and
  [review-software-correctness](../review-software-correctness/SKILL.md) in one source
  investigation and review record. An additional designer covers design; the tester
  remains responsible for scenarios, checks and merge. Reuse shared evidence, not
  duplicate passes or reports. Apply the P2 limit across the combined review.
- One pass. Report every P0 and P1. Report at most three P2 findings, the ones with the
  greatest consequence. Combine findings only when they share a cause and fix.
- Deferrals follow the [severity rule](../../teams/README.md#severity). A shortcut the
  brief did not accept is a P2 with a proposed deferral, not a demand for completeness.
- For a local review with no PR, use the user's brief and report in the form the user
  asked for. Do not publish a GitHub review.
- Leave style to Credo, Dialyzer and the formatter, which the tester runs. Review
  conventions only where the change violates its stack skill in AGENTS.md. Cite the
  skill. Report one finding per repeated pattern.

## Step 1: Inputs

1. The brief's contracts, the spec's shared contracts and decisions table.
2. The head SHA. Record it.
3. The diff against the PR base, and the callers of every changed public function.
4. Record your concerns as the [review record](../../teams/README.md#pr-review-record)
   says, then verify the [PR body](../../teams/README.md#pr-body)'s affected code and
   decisions against the diff.

## Step 2: Match the brief

- Check that each contract in the brief has one implementation at its specified
  `path:line`. If it moved, check that the PR body states where and why.
- Internal layout may evolve under
  [Design during delivery](../implement-software/SKILL.md#design-during-delivery).
  Check the benefit and preserved contracts; do not demand another design approval
  for a bounded repair. Keep the current contract record accurate where it matters.
- Require an explainable present benefit to justify an added mechanism, including
  structural understanding, changeability and verification as well as workload/failure.
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

When the change caches a derived fact or adds state that several paths must keep
current, check whether removing the copy or giving it one writer would satisfy the
contract. A replacement keeps the timer rule in
[Trace the affected contract](../implement-software/SKILL.md#trace-the-affected-contract).

## Step 5: Code and architecture smells

Check the diff for code smells and software architecture smells. Report a smell only
when it has a cost now: the code is harder to change or test, a fact has two
writers, or a failure path is hidden. Report each as P2 with a proposed change, or as
a line for the follow-up issue.

Examples from this repository: a module that writes another module's facts; a
boundary check repeated without a distinct obligation; a mechanism with no justified
present benefit; a job
that does what a query could; an `opts` list that changes behaviour; a wrapper over a
dependency feature; a default that hides a failure.

## Step 6: Performance

Apply the [performance principles](../design-software/SKILL.md#performance-principles)
to each operation the diff adds or changes. Check the brief's limits and workload
assumptions against the implementation. A finding names the operation, the workload,
the consequence and the proposed change. A missing index, page or measurement is not
a finding by itself. Use a representative plan or measurement when the conclusion
depends on it. Severity follows the [severity table](../../teams/README.md#severity).

## Step 7: Test value

Limit tests to the brief's scenarios and contracts.

- Map each new test to a scenario or affected contract, or to a reason in the PR body's
  tests-without-a-scenario-line section. If neither applies, report P2 to delete it.
- Each test fails if its contract breaks, and passes for one reason. Ask to delete a
  test only when surviving tests cover its distinct required cases. Name them.
- Flag tests that the implementation skill's [Tests](../implement-software/SKILL.md#tests)
  bans by default.
- Check the net test change against the brief's test budget and the PR body's reasons.
  Check that replaced tests were deleted.
- Raise a test's correctness only when you can show the case where it passes wrongly.

## Record

Severity follows the [severity table](../../teams/README.md#severity). For every P2,
state the proposed change or the deferral line to add.

Submit the [PR review record](../../teams/README.md#pr-review-record), with findings in
the [finding format](../../../AGENTS.md#github). Body: head SHA, what you ran, what you
read. "No findings" is valid.
