---
name: review-software-correctness
description: Guides the tester's review of a tips PR, diff or commit for correctness against the brief: acceptance scenarios, contracts, inputs, state, trust, and the required checks. Excludes design quality, smells and test value, which review-software-design owns.
---

# Review software correctness

You answer one question: does the change do what the brief says, and can we prove
it. Design quality, smells, idiom and test value belong to
[review-software-design](../review-software-design/SKILL.md); do not raise them
here. Read [implement-software](../implement-software/SKILL.md) as the shared
standard for contracts, state and failure; this skill adds review methods and
probes. In a pair, the [tester role](../../teams/roles/tester.md) owns turn-taking,
handoff and the merge; this skill owns what to inspect.

## Establish scope

Establish the reviewed head. Read the brief's acceptance scenarios and contracts,
the diff against the base, changed files and their callers, existing tests and
prior review threads. For a local review, use the user's brief in place of absent
records. Record your observations before reading the PR description or another
review.

## Acceptance scenarios

Walk the brief's scenarios in order. For each one, name the test or the run that
proves it, or mark it unproven. A scenario with no proof is a P1. Do not ask for
more tests than the scenarios need; a scenario proven by one test is proven.

Derive the expected result from the brief, not from the code or the test. Code and
tests can agree while both violate the requirement.

## Probes

Apply the probes the change makes relevant. Trace execution and data through
unchanged callers and code that uses the results. For each suspected defect,
identify the line and the input, state or sequence that triggers it.

- Behaviour: observable results, feedback and recovery for each reachable state,
  including loading, empty, error, stale and conflict states; UI copy against the
  glossary.
- State and data: duplicate or out-of-order updates across tabs, reconnects and
  timeouts; cancellation or restart after a write; migrations on existing rows;
  submitted, stored, retried and displayed values compared. For jobs: stale inputs,
  repeated effects under retry, and whether the business write and job insertion
  commit together.
- Contracts and boundaries: both sides of each
  [affected contract](../implement-software/SKILL.md#trace-the-affected-contract)
  and [fallible boundary](../implement-software/SKILL.md#fallible-boundaries),
  including partial provider responses, exit status, release configuration and
  readiness.
- Inputs: accepted and rejected values at every entry point, including stored data
  and boundary values: nil, empty, malformed, encoded identifiers, character versus
  byte limits, duplicates, values at and past limits.
- Trust: untrusted data traced into decisions and effects; identity, authorization
  and sensitive data at each boundary; an id substituted; an operation replayed
  after permissions change; untrusted content into HTML, URLs, providers or
  commands; disclosure through output or logs.

## Checks

Run the [required checks](../../../AGENTS.md#checks) for the changed files in
your own database and port. Report which passed, which failed with the failing
lines only, and which you did not run: browser tests, real-provider tests, release
smoke, migration rollback. CI results that did not run are not a pass.

A test proves a scenario only if its setup reached the condition and its assertion
distinguishes the required behaviour from a plausible defect. When a double is
used, the production code responsible for the claim must still run. A sleep does
not prove completion.

## Manual and browser review

When the brief names a user interaction, run it in the browser as the
[manual browser review](../../teams/README.md#manual-browser-review) describes.
Otherwise say that no UI flow was reviewed.

## Severity

Use the [severity table](../../teams/README.md#severity). A scenario that cannot
pass, a missing or failing required check, or lost or corrupted data is P1 or P0.
Everything else is P2 with the change you ask for.

## Review record

Try to reproduce each suspected defect. Say which results came from executed
checks and which from reading code. Cite the scenario or contract behind each
finding, in the [finding format](../../../AGENTS.md#github): for wrong behaviour,
the input, the actual result and the expected result.

Submit the [PR review record](../../teams/README.md#pr-review-record): decision on
line 1, your entry and session on line 2, one finding per inline comment. Report
what you reviewed and what remains unproven. "No findings" is valid. Do not aim
for a finding count.

## Merge

Merge only as the [merge rule](../../teams/README.md#merge) allows: every required
review is an LGTM on the head, every thread is resolved, the required checks pass.
This skill does not authorize publishing a review or merging on its own.
