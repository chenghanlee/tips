# Developing software candidate: authoring checks and evaluations

Authoring notes for the [brainstorm candidate](developing-software-skill.md), assessed
against the supplied [Skill authoring best practices](https://platform.claude.com/docs/en/agents-and-tools/agent-skills/best-practices).
This file is for evaluating the skill, not an instruction file to load during implementation.

## Contents

- [Authoring assessment](#authoring-assessment)
- [Comparison method](#comparison-method)
- [Shared-limit evaluation](#evaluation-1-a-shared-limit-with-no-performance-claim)
- [Authorization evaluation](#evaluation-2-authorization-changes-during-an-open-session)
- [Performance evaluation](#evaluation-3-end-to-end-performance-with-database-and-browser-costs)
- [Pending validation](#pending-validation)

## Authoring assessment

- Discovery: the proposed gerund name and third-person description identify the
  capability, repository, triggers and review routing. The metadata is shown in a
  code block because this is a brainstorm; promotion must produce real frontmatter.
- Structure: the candidate body is below 500 lines. Its one bundled reference is
  linked directly at the measurement decision and is below 100 lines, so it needs
  no table of contents. Keep authoring notes out of the installed skill.
- Freedom: design choices remain contextual; contracts, authorization, test
  selection and required checks retain explicit constraints. A mandatory sequential
  checklist would conflict with the agreed conditional workflow.
- Actionability: triggers and short counterexamples identify when to act. Evidence,
  repair and refinement sections provide feedback and stopping conditions without
  requiring a compliance report.
- Tools and maintenance: this Markdown-only candidate ships no executable scripts
  or MCP calls. Profiling uses tools available in the installed environment. Metric
  thresholds and profiler capabilities have linked sources; recheck them when
  changing the reference or promoting it, rather than adding date-based instructions.
- Evidence: Opus and Fable critique informed revisions. This is authoring feedback,
  not evidence of better implementations or lower total token use.

## Comparison method

The three evaluations below define tasks and observable outcomes. Fixtures and runs
are pending. Prepare isolated, reproducible fixtures from a fixed repository revision
before running them; keep the evaluator's assertions and seeded defects out of the
developer prompt. Do not modify the active skill to run a comparison.

Use fresh sessions with the same task, checkout, tools and model settings in each arm:
(1) repository instructions without developing-software, (2) the active skill, and
(3) the candidate. Preserve design and test requirements in every arm; for the
candidate, remove their AGENTS.md copies in the disposable fixture to represent the
proposed ownership change. Keep all other routing and instructions equivalent.

Evaluate each intended developer model, including the models used in this discussion
if they will implement tasks. Add Haiku or Sonnet only if they are intended targets;
reviewing prose with Opus or Fable does not count as an implementation run.

Record acceptance failures, repair work, unnecessary scope, reference reads, tool
calls and total task tokens through required verification and repair. Use reported
token usage, not word counts or hidden-reasoning estimates; disclose unavailable
usage. Compare quality first, then total cost among runs that meet the requirements.
Repeat inconsistent results before attributing them to the skill. Observe whether
the agent discovers the skill and reads the performance reference when needed.

## Evaluation 1: a shared limit with no performance claim

**Developer request:** “Raise the contribution text limit from 500 to 800 characters.
Keep validation and helper text consistent. Preserve other behavior.”

**Fixture:** a changeset limit, database constraint in an applied migration, UI helper
text, client maxlength and existing boundary tests. Include an unrelated duplicate
helper to detect unnecessary cleanup. Use disposable data and the normal migration path.

**Expected outcomes:** 800 characters are accepted and 801 rejected through the
public flow; affected representations agree; the applied migration is preserved and
the schema change uses a new migration. Existing tests are reused where adequate.
No unrelated consolidation, browser audit or benchmark is justified by this task.

## Evaluation 2: authorization changes during an open session

**Developer request:** “A user who becomes ineligible after opening the page can
still vote. Reject that vote, remove contribution actions and show the existing
eligibility message. Preserve existing votes and unrelated page behavior.”

**Fixture:** a LiveView mounted while eligible, eligibility changed before the event,
and a context function also called by another entry point. Include a delayed read
that can return stale action availability after refusal. Existing fixtures include
an initially ineligible user, which cannot reproduce the reported transition.

**Expected outcomes:** the regression test reaches the eligible-to-ineligible
transition and fails before the repair for the expected reason. No vote is written;
the final UI remains consistent after the delayed reply. A changed result shape is
handled or propagated by affected callers. No default fallback hides failure, and
no unrelated error-tuple normalization enters the diff. Allow any design satisfying
these outcomes; do not require request tags or another particular mechanism.

## Evaluation 3: end-to-end performance with database and browser costs

**Developer request:** “Opening a contribution list and applying its filter feels
slow with 1,000 contributions. Identify and reduce the bottlenecks while preserving
results and pagination. Report comparable before-and-after evidence. There is no
real-user telemetry.”

**Fixture:** representative seeded data, a per-row database lookup, a serial browser
request before results appear, and a fast loading indicator. Provide the repository's
installed profiling tools and fixed device, network and cache conditions.

**Expected outcomes:** the agent reads the measurement reference, measures query
count/timing and the browser request/rendering path, and selects changes from that
evidence. Query plans are inspected if the chosen strategy depends on them. The
comparison measures the completed visible result, preserves correctness, and labels
results as lab measurements. Suite duration and indicator appearance do not support
a speed claim. No production percentile or product-usefulness claim is inferred.

## Pending validation

No fixture execution, model comparison or real-task observation has occurred.
After these comparisons, observe real implementation tasks and revise only for
demonstrated failures or wasted work. Structural checks and reviewer consensus alone
do not establish the quality-per-token improvement this candidate aims to achieve.
