---
name: developing-software
description: Guides implementation planning, features, fixes, refactors and tests in the tips Phoenix/Elixir repository. Applies when designing a code change, implementing required behavior or choosing tests. Code reviews use reviewing-code, which references this skill's design and testing rules.
---

# Developing software

Follow [AGENTS.md](../../../AGENTS.md) for repository boundaries, navigation,
skills and collaboration. Read this map and its references from the current worktree.

Organize the work around the required outcome, relevant contract and code, applicable
guidance, evidence, and next action. Read what can resolve uncertainty that changes
the approach or verification, including constraints on later work. Keep current
conclusions distinct from abandoned approaches. This is reading guidance, not a
report to write before each tool call.

## When to read

Select rows for the decision you are making now. These are decision cues, not
sequential gates. Required guidance must be available
before the decision it constrains. Read the relevant sections, not every reference
by default. Reuse applicable current text already in context; reload it after context
loss, a source change or a newly relevant trigger. Report an unavailable required
reference before the work that needs it.

| Decision | Read before deciding |
|---|---|
| Scope or implementation approach | [Design and change](references/design-and-change.md), through Trace the affected contract |
| Contradictory result, defect, review finding or proposed refactor | [Repair and refactor](references/design-and-change.md#repair-and-refactor) |
| An incoming-action, state/resource or fallible-boundary trigger below applies | The matching section of [State and failure](references/state-and-failure.md) before the affected design or code decision |
| Choosing verification or relying on a result, including deciding existing tests suffice | [Establish useful evidence and testing](references/evidence.md#establish-useful-evidence) |
| A performance trigger below applies | [Performance claims and bounds](references/evidence.md#check-performance-claims-and-bounds) before the affected design, claim or assessment |
| Profiling or measuring | The relevant part of [Performance measurement](references/performance-measurement.md) |
| Publication, completion or a review conclusion | [Finish](references/finish.md) |

Reviewers select applicable guidance independently from the requirements and reviewed
flow, not the developer's claims. Use general guidance throughout the task; apply
checks marked **Trigger** or **When** when their conditions occur. State and performance
guidance can be needed during planning.

## Applicability

### Incoming actions

**Trigger:** adding or changing a LiveView event handler, controller action, channel
message handler or other entry point that receives input from a user or external
system.

### State, resources and delayed work

**Trigger:** adding or changing an async callback, process, job, mount or reconnect
path, transaction, lock, OS process, retry, delayed action, timeout, deadline, quota
or resource limit.

### Fallible boundaries

**Trigger:** adding or changing a database, HTTP, provider, browser-storage, parser
or OS call, or its result handling.

### Performance

**Trigger:** any of the following:

- A performance claim or observed regression.
- A change to how work grows with data: a query inside a loop, a new preload, an
  unbounded result set, a transaction wrapping an external call, parallel work or
  work that outlives the caller.
- A change to what the browser must load or do before content is visible or an
  interaction completes: a new or reordered request, a critical-path asset or font,
  payload size, client-side work on interaction or async content that moves the layout.
