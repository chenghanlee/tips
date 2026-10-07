---
name: reviewing-code
description: Reviews tips PRs, diffs and commits for defects, test gaps, unnecessary complexity and misuse of stack conventions. Applies to assigned code reviews and review requests, not routine implementation or plan discussions.
---

# Reviewing code

Review required behaviour independently of the code and its tests. Follow AGENTS.md,
including the required language and framework skills. Repository rules take precedence
over general skill advice. Read repository files from the current worktree.

Establish the reviewed commit or diff and its requirements. Read the relevant tests,
linked design sections and prior findings. In a pair, follow
[step 3](../../teams/README.md#3-tester-review-the-pushed-head) for review execution.
Consider every applicable question below; list order does not indicate priority. Trace
execution and data through unchanged callers and code that uses the results. For each
suspected defect, identify the exact line and the input, state or sequence that
triggers it.

- Behaviour: Check acceptance scenarios, regressions and PR claims. Check the required
  feedback and recovery for each reachable loading, empty, error, stale or conflict
  state. Check affected UI text, focus, keyboard access, labels and docs against the
  requirements and the glossary.
- State and data: Compare submitted, stored, retried and displayed values. After
  concurrent writes or tab activity, reconnect, duplicate or out-of-order results,
  cancellation, timeout or restart, which state is authoritative and which effects have
  committed? A lost reply does not prove rollback. Check transactions, constraints,
  recovery from durable state, cleanup of external effects and migrations on existing
  rows. For Oban, check serialized arguments, stale jobs, repeated effects and whether
  the business write and job insertion must commit together.
- Contracts: Verify that dependency source versions match the lockfiles at the reviewed
  commit. Does each caller handle the dependency's return values, exceptions, process
  exits, timeout conditions and lifecycle behaviour? Where relevant, check LiveView and
  hook mount, update and teardown; IndexedDB failures; provider responses and total
  timeout budgets; media file ownership, parser limits and uncertain upload outcomes;
  command exit statuses, release packaging, configuration, migration failures and
  readiness.
- Inputs: Check empty, nil, whitespace, malformed and previously stored values;
  identifier encodings; Unicode character counts versus byte counts; duplicates;
  ordering; and values at and around limits.
- Complexity and performance: How do execution time, query count, memory use, payload
  size and queue length grow with input size, history size, user count or arrival rate?
  Check N+1 queries, repeated work per render or event, unbounded loads or retention,
  work that grows with records the user never sees, and blocking calls against the
  required latency and resource budgets. State what grows or which budget applies, the
  workload, the consequence and a fix that preserves required behaviour. Distinguish
  measurements from estimates. A scan or synchronous call alone is not a defect.
- Trust: Try substituting an id and replaying an operation after permissions change.
  Check authorization for reads and effects, including jobs, sockets and browser
  storage. Follow untrusted content into HTML, URLs, provider destinations and
  commands. Check for unauthorized disclosure through output or logs.
- Tests: Compare changed and existing tests with the requirements, not the
  implementation. Do they check required behaviour or assert that incorrect behaviour is
  correct? Check shared-state isolation, waits for asynchronous work, browser elements
  retained across navigation and test doubles against real contracts. Distinguish
  required order, timing and representation from incidental details. Find missing
  coverage, redundant tests and tests of frameworks or private implementation details.
  Prefer extending an existing test. To remove or combine tests, name the remaining test
  or smaller replacement that covers every scenario.
- Simplicity: Simpler means fewer unnecessary parts or user steps for the same required
  behaviour, without moving costs elsewhere. Can you remove a part, state, duplicate
  path, compatibility code, dead code or unused documentation without losing required
  behaviour, failure isolation or testability? Show the current cost and proposed
  replacement, including user effort and maintenance. Fewer lines or modules alone do
  not prove simplicity.
- Idiom: Does custom code duplicate a documented feature of a built-in, locked
  dependency or established tool? Compare custom code with the Ecto DSL, changesets and
  forms; LiveView lifecycle and uploads; OTP supervision; Oban for durable work; and
  standard serializers, browser APIs and test helpers. Check whether plain functions can
  replace processes. Report a custom protocol, format, state machine, wrapper or
  convention when a standard meets the requirement at lower integration and
  maintenance cost, or an explicit repository rule requires it. Name the standard, show
  that it meets the requirement, and explain how the custom code differs, what it costs
  and what should replace it. For a repository-rule violation, cite the rule. Respect
  documented error contracts; `with` does not catch exceptions.

## Report

Try to reproduce suspected defects. Say which results came from executed checks and
which from reading code. Cite the contract supporting each finding.

Use the [severity table](../../teams/README.md#severity). For a PR, follow the
[PR review record](../../teams/README.md#pr-review-record). For a local review, return
the findings in the requested output. This skill does not authorize publishing a
review or merging.

Report one finding per defect. Start with the severity and the requested change,
followed by the requirement, consequence and evidence. For behaviour, give the input
and the actual and expected results. For simplicity or idiom, give the cost and
replacement. Report what you reviewed and what remains unfinished or blocked. "No
findings" is valid. Do not aim for a finding count or list choices you approve of.
