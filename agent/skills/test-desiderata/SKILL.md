---
name: test-desiderata
description: Write, change and review tests using Kent Beck's Test Desiderata and the repository's test-value rules. Load immediately before this work.
---

# Test desiderata

Use [Kent Beck's Test Desiderata](https://testdesiderata.com/) to weigh test value.
Balance the properties below; accept a loss only for a more valuable gain.
These are design questions, not twelve required report sections.

| Property | Ask |
|---|---|
| Isolated | Will this pass alone and in any execution order? |
| Composable | Can independent variations be checked separately without losing confidence in their combination? |
| Deterministic | With unchanged inputs and code, is the outcome stable? |
| Fast | Does the feedback arrive soon enough to be useful? |
| Writable | Is creating this test proportionate to the code's cost? |
| Readable | Can a reader see the scenario and why it matters? |
| Behavioral | Would a relevant behavior change make this fail? |
| Structure-insensitive | Would a behavior-preserving refactor leave this passing? |
| Automated | Can it run unattended? |
| Specific | Does failure identify what went wrong? |
| Predictive | Does passing provide evidence about production behavior? |
| Inspiring | Does this give confidence to change or ship the code? |

## Write tests

Start from the acceptance scenario or regression and inspect existing coverage.
Choose the smallest addition that provides missing confidence; do not add a test
just because code changed.

Repository policy: use the testing trophy, integration first. For application
TDD, write the failing ExUnit integration test before implementation and confirm
it fails for the intended reason. Unit tests are for pure logic with wide blast
radius. Add new end-to-end tests, including browser journeys, for milestone gates;
CI continues running existing coverage.

Assert observable behavior through the appropriate boundary. Avoid mirroring
implementation steps or building an expected result with the logic under test.
Keep fixtures and controlled dependencies as small as the scenario permits.
Run the relevant checks required by the repository; report failures and limits.

## Review tests

Default to no for each new or changed test. Identify the behavior it protects,
the defect it would catch and the confidence missing without it. Weigh that
against runtime, maintenance, duplication and fragility.

Require removal when value does not justify cost, and explain why. If removal
would lose required coverage, require repair or replacement instead. Check both
that broken behavior fails and that harmless refactoring remains possible.
Inspect assertions and setup; a passing run alone does not establish either.

Report actionable findings and material tradeoffs, not a property-by-property
scorecard. Keep the suite lean: fewer tests for the same confidence.
