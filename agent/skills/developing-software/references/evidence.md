# Evidence

Read the applicable sections at the retrieval points in the [engineering map](../SKILL.md#when-to-read).

## Establish useful evidence

When relying on a test or measurement, check that its setup reached the condition
being claimed and that the observation distinguishes the required behavior from a
plausible defect. An unexpectedly passing regression test is a cue to inspect both
setup and expectation. Use the existing before/after result when it establishes the
claim; add inspection, a reproduction, a control or a temporary mutation only to
resolve a specific remaining doubt. Choose the cheapest adequate method.

### Choose and maintain tests

Derive expected behavior from the requirement independently of the implementation.
Code and tests can agree while both violate the requirement. Tests should allow
another implementation that satisfies the same contract.

Cover acceptance scenarios and reported regressions with the smallest set of test
changes. Do not add tests merely because functions, branches or inputs changed.
Read existing tests first. Leave adequate coverage unchanged; update assertions for
changed requirements; extend an existing test when it can cover the missing scenario
with the same setup and action. Add a test only when none can cover the required
scenario.

For new behavior or a regression, write or update the test before changing the
implementation. Confirm that it fails for the expected reason.

Use integration tests through public entry points. Add a unit test only for a
pure-logic boundary case that integration tests do not cover. Add a browser test
only for a user interaction that lower-level tests cannot check.

Test application behavior, including its use of dependencies. Do not test the
framework itself, private functions or code structure.

Before adding or changing tests, weigh the relevant
[Test Desiderata](https://testdesiderata.com/): isolated, composable, deterministic,
fast, writable, readable, behavioral, structure-insensitive, automated, specific,
predictive and inspiring.

### Check the evidence produced by tests

- **When using doubles:** keep the production code responsible for the claimed
  property running. Otherwise, the test may verify only the substitute.
- **When waiting for async behavior:** wait for the required event or observable
  state with a time limit. A sleep does not prove completion; a timeout is not a pass.
- **When code and tests disagree:** let the contract decide which is wrong. Do not
  change fixtures merely to make incorrect behavior pass.
- **When deleting or replacing tests:** first map still-required scenarios to
  surviving coverage. Delete tests for obsolete requirements or those made unnecessary by the
  change; preserve coverage of every acceptance scenario and regression that still
  applies.

## Check performance claims and bounds

The trigger selects the risk to assess, not a measurement of every changed asset.
A performance claim or an uncertain cost that could change the design requires
profiling; an ordinary bounded change with neither needs no measurement.

Name the property at risk and the workload. Profile the suspected cost, not test-suite
elapsed time. Before measuring, read the relevant part of
[performance measurement](performance-measurement.md).

For database work, check how query count and rows read or returned grow with data.
Match filters, indexes and pagination to the access pattern. Keep transaction and
lock lifetimes limited to the work that needs them, accounting for contention and
connection occupancy.
