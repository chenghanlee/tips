# Developing software revision: authoring checks and evaluations

Authoring notes for the [promoted revision](../../../agent/skills/developing-software/SKILL.md), assessed
against the supplied [Skill authoring best practices](https://platform.claude.com/docs/en/agents-and-tools/agent-skills/best-practices).
This plan is retained with the [archived brainstorm](README.md). Its evaluations
remain pending; archiving the design discussion does not mark them complete. This
file is not an instruction file to load during implementation.

## Contents

- [Authoring assessment](#authoring-assessment)
- [Comparison method](#comparison-method)
- [Shared-limit evaluation](#evaluation-1-a-shared-limit-with-no-performance-claim)
- [Authorization evaluation](#evaluation-2-authorization-changes-during-an-open-session)
- [Performance evaluation](#evaluation-3-end-to-end-performance-with-database-and-browser-costs)
- [Pending validation](#pending-validation)

## Authoring assessment

- Discovery: the gerund name and third-person description identify the
  capability, repository, triggers and review routing. The active skill uses real
  YAML frontmatter.
- Structure: the revised body is below 500 lines. Its one bundled reference is
  linked directly at the measurement decision and is below 100 lines, so it needs
  no table of contents. Keep authoring notes out of the installed skill.
- Freedom: design choices remain contextual; contracts, authorization, test
  selection and required checks retain explicit constraints. A mandatory sequential
  checklist would conflict with the agreed conditional workflow.
- Actionability: triggers and short counterexamples identify when to act. Evidence,
  repair and refinement sections provide feedback and stopping conditions without
  requiring a compliance report.
- Tools and maintenance: this Markdown-only skill ships no executable scripts
  or MCP calls. Profiling uses tools available in the installed environment. Metric
  thresholds and profiler capabilities have linked sources; recheck them when
  changing the reference, rather than adding date-based instructions.
- Evidence: Opus and Fable critique informed revisions. This is authoring feedback,
  not evidence of better implementations or lower total token use.

## Comparison method

Start with the existing [replay scenarios](../../../agent/skills/developing-software/evals.json):
three scenario definitions across two historical tasks (issue 78 and issue 62,
including replacement of the issue 244 probe). They pin base and first-review heads
and provide a manual replay/grading protocol; they are not an executable harness.
Reuse those definitions before building new fixtures. Leave the active eval file
unchanged; this document defines the revision comparison protocol.

For each replay, use its pinned base in an isolated worktree and recover the issue
brief and linked requirements as they stood before implementation. Withhold later
review comments, fixes and evaluator assertions from the developer. Record the
exact brief and instruction versions used; if historical requirements cannot be
recovered, report that limit rather than claiming an equivalent replay.

Use fresh sessions with the same task, checkout, tools and model settings in each arm:
(1) repository instructions without developing-software, (2) the previous skill at
`988e174`, and (3) the promoted revision, pinned to its exact commit when running.
Preserve design and test requirements in every arm: the first two retain their
AGENTS.md copies; the revised arm uses the skill as their owner. Keep all other
routing and instructions equivalent. Skill versions and evaluation-task base
revisions are separate inputs; record both.
Historical first-review heads are evidence of observed defects, not controlled
no-skill runs or substitutes for a fresh arm with matched tools and settings.

Evaluate each intended developer model, including the models used in this discussion
if they will implement tasks. Add Haiku or Sonnet only if they are intended targets;
reviewing prose with Opus or Fable does not count as an implementation run.

Use a grader who has not seen the skill or arm identity. Score required behavior
from code and tests; score process separately from traces or change notes. An absent
process record is unassessable, not failed, and a claim without matching evidence
scores nothing. Do not make a particular implementation strategy a grading criterion.

Record acceptance failures, repair work, unnecessary scope, reference reads, tool
calls and total task tokens through required verification and repair. Use reported
token usage, not word counts or hidden-reasoning estimates; disclose unavailable
usage. Compare quality first, then total cost among runs that meet the requirements.
Repeat inconsistent results before attributing them to the skill. Observe whether
the agent discovers the skill and reads the performance reference when needed.

## Evaluation 1: a shared limit with no performance claim

**Developer request:** “Raise the contribution text limit from 500 to 800 characters.
Keep validation and helper text consistent. Preserve other behavior.”

**Status:** defined scenario only; no real fixture or pinned task yet. The proposed
fixture has a changeset limit, database constraint in an applied migration, UI helper
text, client maxlength and existing boundary tests. Prefer a matching real task;
build a synthetic fixture only if this gap warrants the additional evaluation cost.

**Expected outcomes:** 800 characters are accepted and 801 rejected through the
public flow; affected representations agree; the applied migration is preserved and
the schema change uses a new migration. Existing tests are reused where adequate.
No unrelated consolidation, browser audit or benchmark is justified by this task.

## Evaluation 2: authorization changes during an open session

**Replay source:** [issue 110](https://github.com/chenghanlee/tips/issues/110),
[PR 384](https://github.com/chenghanlee/tips/pull/384).
Base: `04462e318e5e807085987e8bd0d7016d883572be`.
First-review head: `b460b23dd43f13b1a4a619d28439ea3ef1a9ee94`.
Use the issue body and linked requirements as of 2026-10-07 as the developer request,
not the later repair instructions below. Historical brief recovery and replay setup
remain pending. The [pair workflow at that head](https://github.com/chenghanlee/tips/blob/b460b23dd43f13b1a4a619d28439ea3ef1a9ee94/agent/teams/README.md#2-developer-implement-and-hand-off)
required loading developing-software. Actual loading has not been verified from the
session trace, so do not classify that head as a controlled active-skill or no-skill
run.

**Evaluator context:** the issue requires a full ban to remove contribution actions
while own-content deletion remains available, and confirmed updates must not reorder
the list. Delayed-search cases operationalize those requirements; they are not
literal steps in the issue. The PR's [stale read repair](https://github.com/chenghanlee/tips/commit/3a4477c603f98ac11ce486d1ff26228c9491c156)
and [scope refresh repair](https://github.com/chenghanlee/tips/commit/f7a44a07cc89845d34d4d6c1b4a969a12d70f00a)
document the observed failures. Keep that evidence out of the developer prompt.

**Expected outcomes:** a vote refused for a full ban writes no vote; contribution
actions disappear in place without reranking; own-content Delete remains available.
A search begun before refusal cannot restore those actions, and later reads use
the post-refusal permissions. Grade the issue's remaining acceptance criteria too;
these focused checks do not replace the full task. Allow any design satisfying the
contract, without requiring request tags, reloads or another mechanism.

**Process evidence:** assess whether the regression test reached the claimed
transition and failed for the expected reason before the repair from recorded runs,
not from the final code alone. Also record unnecessary cleanup and repair work.

## Evaluation 3: end-to-end performance with database and browser costs

**Developer request:** “Opening a contribution list and applying its filter feels
slow with 1,000 contributions. Identify and reduce the bottlenecks while preserving
results and pagination. Report comparable before-and-after evidence. There is no
real-user telemetry.”

**Status:** defined scenario only; no real fixture or pinned task yet. The proposed
fixture has representative data, a per-row database lookup, a serial browser request
before results appear and a fast loading indicator. Prefer a real performance task;
otherwise weigh fixture cost against the untested measurement/reference-navigation
behavior. Fix tool, device, network and cache conditions before any comparison.

**Expected outcomes:** the agent reads the measurement reference, measures query
count/timing and the browser request/rendering path, and selects changes from that
evidence. Query plans are inspected if the chosen strategy depends on them. The
comparison measures the completed visible result, preserves correctness, and labels
results as lab measurements. Suite duration and indicator appearance do not support
a speed claim. No production percentile or product-usefulness claim is inferred.

## Pending validation

No revised-skill replay, model comparison or real-task observation has occurred in this
iteration. Historical implementations are not revision validation.
After these comparisons, observe real implementation tasks and revise only for
demonstrated failures or wasted work. Structural checks and reviewer consensus alone
do not establish the quality-per-token improvement this revision aims to achieve.
