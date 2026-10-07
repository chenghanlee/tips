---
name: reviewing-code
description: Reviews tips PRs, diffs and commits for defects, test gaps, unnecessary complexity and misuse of stack conventions. Applies to assigned code reviews and review requests, not routine implementation or plan discussions.
---

# Reviewing code

Review required behaviour independently of the code and its tests. Follow
[AGENTS.md](../../../AGENTS.md), including the required language and framework skills.
Repository rules take precedence over general skill advice. Read repository files
from the current worktree.

## Establish scope

Establish the reviewed commit or diff and its requirements. Read the relevant tests,
linked design sections and prior findings. In a pair, follow
[step 3](../../teams/README.md#3-tester-review-the-pushed-head) for review execution.

## Review

Consider every applicable rule below; list order does not indicate priority. Examples
illustrate the rules, not their limits. Trace execution and data through unchanged
callers and code that uses the results. For each suspected defect, identify the exact
line and the input, state or sequence that triggers it.

- Behaviour: Check observable results, user interactions and recovery against the
  requirements, acceptance scenarios, regressions and PR claims. For example, check
  feedback in loading, empty and error states; recovery from stale or conflicting
  updates; and UI copy, focus, keyboard access and docs against the glossary.
- State and data: Check that state stays consistent and effects preserve required
  invariants through concurrency, interruptions and recovery. Compare submitted,
  stored, retried and displayed values; identify authority, committed effects and
  resource ownership. For example, trace duplicate or out-of-order updates across
  reconnects; cancellation or restart after a write; and
  migrations on existing rows. Check transactions, constraints and external cleanup.
  For durable jobs, check serialized or stale inputs, repeated effects and whether
  the business write and job insertion must commit together. A lost reply does not
  prove rollback.
- Contracts: Check each side of a boundary against its contract for inputs, results,
  failures, timing, resource ownership and lifecycle. Verify dependencies against
  source or docs for the locked versions and configuration in use. For example, check
  callback mount, update and teardown; exceptions, exits, timeouts or partial provider
  responses; and command exit status, release configuration, migrations and readiness.
  Include boundaries such as browser storage, media parsers and uploads.
- Inputs: Check accepted and rejected values against domain rules at every entry point,
  including previously stored data and boundary values. For example, try nil, empty,
  whitespace or malformed values; encoded identifiers and character versus byte limits;
  and duplicates, ordering and values just below, at and above limits.
- Complexity and performance: Check how work and resource use grow with input size,
  history, user count and arrival rate, and whether they meet required limits. Include
  execution time, query count, memory, payload size and queues. For example, check N+1
  queries, repeated work per render or event, and unbounded loads or retention. Include
  work on records the user never sees and blocking work against required budgets.
- Trust: Identify trust boundaries and trace untrusted data into decisions and effects.
  Check identity, authorization, validation and sensitive-data handling at each boundary.
  For example, substitute an id or replay an operation after permissions change;
  trace untrusted content into HTML, URLs, provider destinations or commands; and check
  disclosure through output or logs. Include reads and effects in jobs, sockets and
  browser storage.
- Tests: Check that changed and existing tests detect violations of requirements and
  regressions, run reliably, and do not enforce incidental implementation choices.
  For example, check doubles against real contracts, isolation of shared state, waits
  for asynchronous work and browser elements retained across navigation. Find missing
  or redundant coverage and tests of frameworks or private implementation details.
  Prefer extending an existing test; preserve required order, timing and representation.
- Simplicity: Look for unnecessary parts or user steps that can be removed while
  preserving required behaviour, failure isolation and testability, without moving
  costs elsewhere. For example, check duplicate state or paths, compatibility code
  without a current requirement, and dead code or unused documentation.
- Idiom: Check code against the idioms, conventions, standards and documented best
  practices of its language and framework. Include control flow, data handling and
  programming model. Check whether custom code duplicates a built-in, locked
  dependency or established tool. For example, compare queries and forms with the
  framework's DSL and validation facilities; stateful processes with plain functions;
  and custom lifecycle or job handling with LiveView, OTP or Oban. Compare custom
  serializers, browser integrations and test helpers with standard facilities. Respect
  documented error contracts; Elixir's `with`, for example, does not catch exceptions.

## Verify and report

Try to reproduce suspected defects. Say which results came from executed checks and
which from reading code. Cite the contract supporting each finding.

Use the [severity table](../../teams/README.md#severity). For a PR, follow the
[PR review record](../../teams/README.md#pr-review-record). For a local review, return
the findings in the requested output. This skill does not authorize publishing a
review or merging.

Report one finding per defect. Start with the severity and the requested change,
followed by the requirement, consequence and evidence.

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
  justification and cite the guidance and consequence. For a repository-rule
  violation, cite the rule.

Report what you reviewed and what remains unfinished or blocked. "No findings" is
valid. Do not aim for a finding count or list choices you approve of.
