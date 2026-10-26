---
name: review-software
description: Guides a tips PR review: correctness against the brief on every affected path, and the design of the change. The tester applies all of it. An additional reviewing architect applies Steps 1 and 2, the Design section and the record.
---

# Review software

Verify that the change meets the brief on every affected path and that its design is
the simplest that satisfies the contracts. Provide evidence for both conclusions.

Scope limits:

- Ask for a test only for a scenario, or for an existing contract the affected code
  reaches that no surviving test proves (Step 5).
- One pass. Report every P0 and P1. Report at most three P2 findings, the ones with the
  greatest consequence. Combine findings only when they share a cause and fix. Put P2s
  where [Optional P2 findings](../../teams/README.md#optional-p2-findings) says.
  Deferrals follow the [severity rule](../../teams/README.md#severity); a shortcut the
  brief did not accept is a P2 with a proposed deferral, not a demand for completeness.
- For a local review with no PR, use the user's brief and the working tree, and report
  in the form the user asked for. Do not publish a GitHub review.
- Leave style to Credo and the formatter, and to Dialyzer on its
  [schedule](../../docs/checks.md#dialyzer). Review conventions only where the change
  violates its stack skill in AGENTS.md. Cite the skill. One finding per repeated pattern.

The [tester role](../../teams/roles/tester.md) defines turns, handoff and the merge; the
[architect role](../../teams/roles/architect.md) does for an additional reviewing
architect. [implement-software](../implement-software/SKILL.md) is the standard for
contracts, state and failure.

## Step 1: Inputs

Your handoff names the head and its base, not the PR. Read, in this order:

1. The brief: contracts, acceptance scenarios, decisions table; the spec's shared
   contracts when the brief links one. If the brief is missing or incomplete, report
   `blocked`; the PR body is not a substitute.
2. The diff: `git diff origin/<base>...HEAD` in your clone at the head.
3. The existing tests for each changed module.

Write `tmp/concerns.md`: the head SHA, then the plausible mistakes this change could
make and the check that would tell each one apart, with the brief line or contract that
gives the expected result. "No specific concern" is valid. These are hypotheses to revise,
not a test plan. Then run `python3 <harness>/pr_review.py handoff <head> tmp/concerns.md`;
it refuses until the file names the head, and then prints the PR, its
[body](../../teams/README.md#pr-body) and prior review threads. Verify the body's
scenario table, affected code and decisions in steps 2 and 3. Do not copy its claims as
results.

## Step 2: Affected code

Independently trace changed contracts, shared fixtures and config through their callers
to entry points, or to a caller whose handling of the change you have read and that
still satisfies its own contract. Find users with Dexter `references` and scoped `rg`
([navigation rules](../../../agent/docs/elixir-navigation.md)); investigate every use
that only one lookup found. An unchanged signature is not a stopping point. For each entry
point reached, check the resulting state and side effects. Do not revisit a checked
path. For evidence across several files, follow the
[Lookup subagents](../../docs/lookup-subagents.md) rule; you remain responsible for
tracing and verifying the affected contract.

An added, cached, moved or removed fact affects each path that constructs, updates,
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
| number and title | each required case: test name or command and its assertion; then the required cases not exercised, or `none` | proven only when no required case is unexercised or unproven; otherwise unproven or wrong |

A required case is a path, recipient or ordering the brief's scenario or an affected
contract from Step 2 names: read and write, first and later, each named recipient.
Evidence for part of a scenario is unproven, not "proven for" the part.

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
- Prove a scenario that names a user interaction in the browser. Follow
  [manual browser review](../../teams/README.md#manual-browser-review). Otherwise, mark
  it unproven.
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
reproducing a control is Step 3, not this check. A new or existing test counts when it
exercises the responsible production path and detects that behaviour; neither the
test's age nor whether the mutant deletes a line decides validity.

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
evidence during the CI pause, follow the [policy](../../../agent/docs/checks.md#github-ci-pause).
Run any further check your investigation needs.

Report each applicable check once: run by you, verified from the implementer's record,
or missing with its reason or an authorized waiver. Quote only the failing lines. For a
failing or flaky test, follow the
[failed-check procedure](../../teams/README.md#report-and-resolve-blockers). Do not
report a skipped CI check as passed.

## Design

Check the affected design against the brief's contracts and accepted decisions: each
contract has one implementation at its stated place, or the PR body says where it moved
and why; each accepted shortcut matches its decision row, and its failure is detected.
Assess responsibility, dependencies and state ownership. Apply design-software's
[required rules](../design-software/SKILL.md#required-rules); a violation is P1 with the
rule and `path:line`. Internal layout may change under
[Design during delivery](../implement-software/SKILL.md#design-during-delivery); check
the stated benefit and the preserved contracts, and do not demand a new design approval
for a bounded repair. Propose a simpler mechanism only with its present benefit and
costs, including who takes on displaced work; do not infer simplicity from fewer lines.
Report a code or architecture smell only when it costs now: harder to change or test, a
fact with two writers, or a hidden failure path. Preserve required behaviour and
justified distinct test coverage; an added test with no scenario, affected contract or
justified regression is P2. Apply the
[performance principles](../design-software/SKILL.md#performance-principles) when the
change adds or alters work, waiting, memory or storage; a finding names the operation,
the workload, the consequence and the change. Other design findings use the
[severity table](../../teams/README.md#severity), within the combined P2 limit.

For changed pages, forms or components, apply
[web-design-guidelines](../web-design-guidelines/SKILL.md) to the affected templates,
CSS and JS within this review. Pin the rules: resolve the commit with
`gh api repos/vercel-labs/web-interface-guidelines/commits/main --jq .sha`, fetch
`https://raw.githubusercontent.com/vercel-labs/web-interface-guidelines/<sha>/command.md`
(`curl` on a Codex client) and record the SHA in the review. This replaces the vendored
skill's fetch from `main`, its file prompt and its output format. When the brief names
an approved candidate (`design/<brief>/` at the approved SHA), compare the implemented
states with its images at the viewports and states `candidate.md` names, with the
authoritative copy and the disclosed differences: hierarchy, grouping, copy, controls
and agreed behaviour. P0 where the table requires it; P1 when an approved constraint
fails or is unproven, or the change significantly harms the user's experience; other
differences are P2.

An additional reviewing architect applies Steps 1 and 2, this section and the record;
the tester remains responsible for scenarios, checks and the merge. Reuse shared
evidence, not duplicate passes.

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
2. `Concerns`: your `tmp/concerns.md` as written before `handoff`, and what became of each.
3. `Affected code`: what you add to, correct or dispute in the PR body's list, or "none".
4. `Scenarios`: the table from step 3.
5. `Mutation`: what you broke and whether the test failed, and each control you
   reproduced.
6. `Checks`: each applicable check as run, verified from the record, or missing with its
   reason or [waiver](../../teams/roles/common.md#authority); limitations that qualify
   a proof. Omit inapplicable categories.
7. Design assessment and consequential tradeoffs from the shared investigation; no
   generic declaration is needed.
8. Findings outside the diff, each with `path:line`, and `Optional` P2 findings. Omit
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
