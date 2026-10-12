---
name: reviewing-code
description: Reviews tips PRs, diffs and commits for defects, test gaps, unnecessary complexity and misuse of stack conventions. Applies to assigned code reviews and review requests, not routine implementation or plan discussions.
---

# Reviewing code

Review required behaviour independently of the code and its tests. Follow
[AGENTS.md](../../../AGENTS.md), including the required language and framework skills.
Repository rules take precedence over general language and framework skill advice.
Read [developing-software](../developing-software/SKILL.md) as the shared design and
testing standard; this skill adds review methods and probes, not a second rule set.
Read repository files and skill references from the current worktree.

## Establish scope

Establish the reviewed commit or diff. Read the issue and acceptance scenarios, PR
body, diff, changed files and their callers, existing tests, linked design sections
and prior review threads. For a local review, use the user brief in place of absent
issue or PR records. In a pair, the [tester role](../../teams/roles/tester.md)
owns turn-taking and handoff; this section owns what to inspect.

## Review

Consider every applicable rule below; list order does not indicate priority. Examples
illustrate the rules, not their limits. Trace execution and data through unchanged
callers and code that uses the results. For each suspected defect, identify the exact
line and the input, state or sequence that triggers it.

- Behaviour: Check observable results, user interactions and recovery against the
  requirements, acceptance scenarios, regressions and PR claims. Check required
  feedback and recovery for each reachable state. For example, cover loading, empty,
  error, stale and conflict states, and check UI copy, focus, keyboard access and docs
  against the requirements and glossary.
- State and data: Probe the [state and resource rules](../developing-software/SKILL.md#state-resources-and-delayed-work)
  through duplicate or out-of-order updates across tabs, reconnects and timeouts;
  cancellation or restart after a write; and migrations on existing rows. Compare
  submitted, stored, retried and displayed values. For durable jobs, inspect serialized
  or stale inputs, repeated effects under retry, and whether the business write and
  job insertion must commit together.
- Contracts: Trace both sides of [affected contracts](../developing-software/SKILL.md#trace-the-affected-contract)
  and [fallible boundaries](../developing-software/SKILL.md#fallible-boundaries).
  For example, inspect callback mount, update and teardown; partial provider responses;
  command exit status, release configuration, migrations and readiness. Include
  browser storage, media parsers and uploads.
- Inputs: Check accepted and rejected values against domain rules at every entry point,
  including previously stored data and boundary values. For example, try nil, empty,
  whitespace or malformed values; encoded identifiers and character versus byte limits;
  and duplicates, ordering and values just below, at and above limits.
- Complexity and performance: Assess claims and costs against the
  [performance guidance](../developing-software/SKILL.md#check-performance-claims-and-bounds).
  Vary input size, history, user count and arrival rate when they affect the claim.
  Look for work on records the user never sees, repeated work per render or event,
  and unbounded retention; use measurements when the conclusion depends on them.
- Trust: Identify trust boundaries and trace untrusted data into decisions and effects.
  Check identity, authorization, validation and sensitive-data handling at each boundary.
  Try substituting an id and replaying an operation after permissions change. For
  example, trace untrusted content into HTML, URLs, provider destinations or commands,
  and check disclosure through output or logs. Include reads and effects in jobs,
  sockets and browser storage.
- Tests: Apply the [test selection and evidence rules](../developing-software/SKILL.md#choose-and-maintain-tests)
  to changed and existing coverage. Identify which acceptance scenario a missing or
  redundant test affects. Probe isolation of shared state and browser elements retained
  across navigation. Check that assertions cover required order, timing and representation.
- Simplicity: Apply [the simplest complete solution](../developing-software/SKILL.md#build-the-simplest-working-solution)
  criterion. Compare the proposed removal or replacement against user effort, failure
  isolation and testability; check whether it merely moves costs elsewhere.
- Idiom: Apply [reuse and conventions](../developing-software/SKILL.md#reuse-existing-mechanisms-and-follow-conventions)
  and the applicable language/framework skills. Compare queries and forms with the
  framework's DSL and validation facilities; stateful processes with plain functions;
  and lifecycle or job handling with LiveView, OTP or Oban. Check custom serializers,
  browser integrations and test helpers against available facilities. Verify claims
  about error handling; Elixir's `with`, for example, does not catch exceptions.

## Verify and report

Try to reproduce suspected defects. Say which results came from executed checks and
which from reading code. Cite the contract supporting each finding.

Use the [severity table](../../teams/README.md#severity). For a PR, follow the
[PR review record](../../teams/README.md#pr-review-record). For a local review, return
the findings in the requested output. This skill does not authorize publishing a
review or merging.

Use the finding format in [AGENTS.md](../../../AGENTS.md#github). Support each finding
with the evidence appropriate to its type:

- Behaviour: Give the input and the actual and expected results.
- Complexity and performance: State what grows or which budget applies, the workload,
  the consequence and a fix that preserves required behaviour. Distinguish measurements
  from estimates. A scan or synchronous call alone is not a defect.
- Tests: To remove or combine tests, name the remaining test or smaller replacement
  that covers every still-required scenario.
- Simplicity: Show the current cost and proposed replacement, including user effort
  and maintenance. Fewer lines or modules alone do not prove simplicity.
- Idiom: Report a custom protocol, format, state machine, wrapper or convention when
  a standard meets the requirement at lower integration and maintenance cost, or an
  explicit repository rule requires it. Name the standard, show that it meets the
  requirement, and explain how the custom code differs, what it costs and what should
  replace it. For deviations from language or framework guidance, assess the stated
  justification and cite the guidance and consequence. If no explanation is given,
  cite the [deviation rule](../developing-software/SKILL.md#reuse-existing-mechanisms-and-follow-conventions).
  For a repository-rule violation, cite its owning document.

Report what you reviewed and what remains unfinished or blocked. "No findings" is
valid. Do not aim for a finding count or list choices you approve of.
