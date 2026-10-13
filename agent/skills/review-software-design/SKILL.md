---
name: review-software-design
description: Guides the reviewing designer's pass over a tips PR. Covers conformance to the brief's contracts, the always-rules, simplicity, smells, bounds and test value. Acceptance scenarios, checks and merging belong to review-software-correctness.
---

# Review software design

You answer one question: is this the smallest correct shape for the brief's
contracts. The [design-software](../design-software/SKILL.md) rules are the
standard. The [designer role](../../teams/roles/designer.md) owns turns and
messages.

Scope limits:

- Do not review scenarios, checks or the merge. That is
  [review-software-correctness](../review-software-correctness/SKILL.md).
- One pass, at most five findings. More than five means the brief or the design was
  wrong; say that in one finding.
- A shortcut the brief accepted, or a deferral in a linked issue, is not a finding
  unless it breaks a scenario. A shortcut the brief did not accept is a P2 with a
  proposed deferral, not a demand for completeness.
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

## Step 3: Always-rules

Check each [always-rule](../design-software/SKILL.md#always-rules) against the diff.
A violation is a P1. Cite the rule and the `path:line`.

## Step 4: Simplicity

Ask: could this be half the code. Name the mechanism that could go and what replaces
it. A finding shows the current cost and the replacement, including who does the
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
- Each test fails if its contract breaks, and passes for one reason. Two tests that
  fail for the same bug: keep one.
- Flag combination grids, one test per error tuple, tests of private helpers,
  restated pattern matches, tests of constraints the database enforces.
- Check the net count against the brief's test budget. Check that replaced tests were
  deleted. More test lines than code lines in the PR: name it.
- Raise a test's correctness only when you can show the case where it passes wrongly.

## Step 8: Blast radius of shortcuts

For each accepted shortcut, state what breaks if it is wrong and how we would notice.
A job that retries and logs is fine at MVP. Silent data loss is not.

## Record

Severity follows the [severity table](../../teams/README.md#severity). Every P2
carries the change you propose or the deferral line to add.

Submit the [PR review record](../../teams/README.md#pr-review-record): decision on
line 1, your entry and session on line 2, one finding per inline comment in the
[finding format](../../../AGENTS.md#github). Body: head SHA, what you ran, what you
read. "No findings" is valid. Resolve only your own threads.
