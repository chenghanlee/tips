---
name: review-software-design
description: Guides the reviewing designer's pass over a tips PR. Covers conformance to the brief's contracts, the well-designed-software rules, architecture and code smells, bounds, and whether the tests are worth having. Excludes acceptance scenarios, checks and merging, which review-software-correctness owns.
---

# Review software design

You review the shape of the change, not whether it passes its scenarios. The tester
owns acceptance scenarios, required checks and the merge through
[review-software-correctness](../review-software-correctness/SKILL.md). The
[design-software](../design-software/SKILL.md) rules are the standard; this skill
says how to apply them to a diff. Turn order and notification are in the
[designer role](../../teams/roles/designer.md).

Tips is an MVP. Prefer a smaller correct thing over a complete one. A shortcut the
brief accepted is not a finding; a shortcut the brief did not accept is a P2 with a
proposed deferral, not a demand for completeness.

## Establish scope

Read the brief's contracts, the spec's shared contracts and decisions table, the
diff against the PR base, and the callers of every changed public function. Record
your observations before reading the PR description or another review.

One pass, one review record, at most five findings. More than five means the brief
or the design was wrong; say that in one finding instead of listing symptoms.

## Conformance

Check contracts and boundaries, not whether every brief sentence is mirrored.

- Each contract in the brief has one implementation at the `path:line` the brief
  named, or the PR says where it moved and why.
- A deviation that is simpler and keeps the contract is a finding for the brief, not
  the code. Say so and propose the brief edit.
- A mechanism the brief did not ask for needs the justification the brief would have
  needed: the load or failure it answers. Without one, it is a P2 to remove.

## The always rules

A violation of any of these is a P1. Cite the rule and the `path:line`.

- One owner per fact: a rule, counter or state is written in one module and defined
  in one place.
- Explicit state and transitions: named states, one guard that rejects illegal
  transitions.
- Named failure paths: every fallible call says what happens on timeout, duplicate
  and crash between steps, and what makes the retry safe.
- Bounded work: every loop, scan, queue and job has a bound and a continuation.

## Simplicity

First question of the review: could this be half the code. Name the mechanism that
could go and what would replace it. A finding here shows the current cost and the
replacement, including who does the extra work if the replacement moves it; fewer
lines alone do not prove simplicity.

## Smells

Architecture: a module that writes another module's facts; a boundary check
repeated inside; a process, cache, scheduler or abstraction with one user; a job
that does what a query could; config or shared test files changed for one feature.

Code: an `opts` list that changes behaviour; a function whose name hides a side
effect; a wrapper over a dependency feature; a copied pattern that the current
contract does not need; a default that disguises a failure.

Each is a P2 with a proposed change, or a line in the deferral list if the brief's
budget does not cover it.

## Idiom

Credo, Dialyzer and the formatter own style. Review idiom only where the change uses
the stack against the way the stack skill in AGENTS.md says to use it, and cite the
skill. One finding for a repeated pattern, not one per occurrence.

## Bounds

Review performance only where the brief states a bound or the change adds work that
grows with data: a query in a loop, an unbounded result set, a transaction around an
external call, work that outlives the caller. Name what grows, the workload and the
consequence. No stated bound and no growth, no finding.

## Test value

The tests are the brief's scenarios and contracts, and nothing more.

- Map each new test to a scenario or contract line. A test with no line and no
  one-line reason in the PR is a P2 to delete.
- Each test would fail if its contract broke, and passes for one reason. Two tests
  that fail for the same bug: keep one.
- Flag combination grids, one test per error tuple, tests of private helpers,
  restated pattern matches, and tests of constraints the database enforces.
- Check the net count against the brief's test budget and that replaced tests were
  deleted. More than one test line per code line is a smell to name.
- Raise a test's correctness (it lies, it is flaky, it needs a real provider for a
  logic check) only when you can show the case where it passes wrongly.

## Blast radius

For each accepted shortcut, state what breaks if it is wrong and how we would
notice. A job that retries and logs is fine at MVP. Silent data loss is not.

## Severity and record

P1: an always-rule violation, data loss, an unauthorized action, a security hole.
P2: everything else, each with the change you propose or the deferral line to add.
P0 as the [severity table](../../teams/README.md#severity) defines it.

Submit the [PR review record](../../teams/README.md#pr-review-record): decision
on line 1, your entry and session on line 2, one finding per inline comment with
the finding format in [AGENTS.md](../../../AGENTS.md#github). Say what you ran and
what you read. "No findings" is valid. Resolve only your own threads.
