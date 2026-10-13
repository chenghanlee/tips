---
name: review-software-design
description: Guides the reviewing designer's pass over a tips PR. Covers conformance to the brief's contracts, the always-rules, simplicity, smells, bounds and test value. Acceptance scenarios, checks and merging belong to review-software-correctness.
---

# Review software design

You answer one question: could a simpler implementation satisfy the brief's
contracts. The [design-software](../design-software/SKILL.md) rules are the
standard. The [designer role](../../teams/roles/designer.md) owns turns and
messages.

Scope limits:

- Do not review scenarios, checks or the merge. That is
  [review-software-correctness](../review-software-correctness/SKILL.md).
- One pass. Report every P0 and P1. Report at most three P2 findings, the ones with
  the greatest consequence. Combine findings only when they share a cause and fix.
- Deferrals follow the [severity rule](../../teams/README.md#severity): a recorded
  deferral settles P2 on that point, never P0 or P1. A shortcut the brief did not
  accept is a P2 with a proposed deferral, not a demand for completeness.
- For a local review with no PR, use the user's brief and report in the form the
  user asked for; do not publish a GitHub review.
- Credo, Dialyzer and the formatter own style. Review idiom only where the change
  uses the stack against its stack skill in AGENTS.md; cite the skill. One finding
  per repeated pattern.

## Step 1: Inputs

1. The brief's contracts, the spec's shared contracts and decisions table.
2. The head SHA. Record it.
3. The diff against the PR base, and the callers of every changed public function.
4. Write your concerns. Then read the [PR body](../../teams/README.md#pr-body) and
   verify its blast radius and decisions against the diff.

## Step 2: Conformance

- Each contract in the brief has one implementation at the `path:line` the brief
  named, or the PR body says where it moved and why.
- A deviation that is simpler and keeps the contract is a finding for the brief. Say
  so and propose the brief edit.
- A mechanism the brief did not ask for needs the load or failure it answers. Without
  one, P2 to remove.
- For each shortcut the brief accepted, check that the diff matches its decision
  row: what breaks if it is wrong and how we would notice. A job that retries and
  logs is fine at MVP. Silent data loss is not. Report only a missing or
  contradicted row.

## Step 3: Always-rules

Check each [always-rule](../design-software/SKILL.md#always-rules) against the diff.
A violation is a P1. Cite the rule and the `path:line`.

## Step 4: Simplicity

Look for mechanisms that can be removed or replaced without losing required
behaviour. Name the mechanism and what replaces it. A finding shows the current cost and the replacement, including who does the
extra work if the replacement moves it. Fewer lines alone do not prove simplicity.

## Step 5: Smells

Each is a P2 with a proposed change, or a line for the follow-up issue.

- Architecture: a module that writes another module's facts; a boundary check
  repeated inside; a process, cache, scheduler or abstraction with one user; a job
  that does what a query could; config or shared test files changed for one feature.
- Code: an `opts` list that changes behaviour; a name that hides a side effect; a
  wrapper over a dependency feature; a copied pattern the contract does not need; a
  default that disguises a failure.

## Step 6: Bounds

Only where the brief states a bound or the change adds work that grows with data: a
query in a loop, an unbounded result set, a transaction around an external call,
work that outlives the caller. Name what grows, the workload and the consequence.
No stated bound and no growth: no finding.

## Step 7: Test value

The tests are the brief's scenarios and contracts, and nothing more.

- Map each new test to a scenario or contract line, or to a reason in the PR body's
  tests-without-a-scenario-line section. Neither: P2 to delete.
- Each test fails if its contract breaks, and passes for one reason. Ask to delete a
  test only when surviving tests cover its distinct required cases; name them.
- Flag combination grids, one test per error tuple, tests of private helpers,
  restated pattern matches, tests that only assert the database raises.
- Check the net test change against the brief's test budget and the PR body's
  reasons. Check that replaced tests were deleted.
- Raise a test's correctness only when you can show the case where it passes wrongly.

## Record

Severity follows the [severity table](../../teams/README.md#severity). Every P2
carries the change you propose or the deferral line to add.

Submit the [PR review record](../../teams/README.md#pr-review-record): decision on
line 1, your entry and session on line 2, one finding per inline comment in the
[finding format](../../../AGENTS.md#github). Body: head SHA, what you ran, what you
read. "No findings" is valid. Resolve only your own threads.
