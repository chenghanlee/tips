@AGENTS.md

## Haiku subagents

Haiku is available to Opus and Fable through the `Agent` tool with `model` "haiku" and `subagent_type` "general-purpose". It is about 40 times cheaper per token than Opus and faster, runs in parallel with your own work, and has the same tools you have. You decide when to use it. Nothing routes through it by force.

Facts that set the economics, measured on this project's sessions ([PR #388](https://github.com/chenghanlee/tips/pull/388)):

- Context size costs no time. A request takes about 3 seconds plus 8 seconds per 1K output tokens, whatever the context size. Delegation saves time only when Haiku works while you do something else, or when it replaces several of your requests.
- Every token you keep in context is paid again on each later request, on each advisor call (uncached, 50 times the cache-hit price) and, for Fable, on each cache rewrite after a hold longer than an hour. Delegation saves money when the answer Haiku returns is much smaller than what you would have read.
- Haiku's cheap tier ends at a 100K-token prompt. Do not fork your own context into it.

### Principles

1. Delegate reading, not deciding. Haiku may summarize and compress. You keep requirements, architecture, acceptance, authorization, locking and concurrency decisions, and every judgment about what counts.
2. Ask one question with a checkable answer: scope searched, `path:line` on every row, constraints and decisions quoted verbatim, and a "left out" list. Reject an answer that has none of these.
3. Delegate when the answer is much smaller than the reading, or when you have independent work to do meanwhile. Do not delegate one known command, a function body you are about to edit, a passing check run, or a wait.
4. Keep the required reads yourself: the issue and its linked design sections, the pair workflow, the skills, blocker comments, the diff under review.
5. Compress before ingestion. A digest of text already in your context removes nothing.
6. Launch Haiku calls in parallel and keep working; results arrive on their own. Do not poll or `sleep`.
7. Haiku never writes during another agent's turn, never touches files you did not assign to it, never runs `mix` against a shared database, and never routes around a denied action.

### Triggers

| Who | Scenario | Ask Haiku for | Expected gain |
|---|---|---|---|
| Fable | Board or issue-thread state across several issues | One row per item: number, state, blocker, who must act, last decision quoted with its URL | 15K fewer tokens kept all day; about $0.50 per use, more before a rewrite |
| Fable | Why something happened in an agent transcript or log | A short timeline with file, line and timestamp, uncertainties marked | Replaces 4-10 of your requests |
| Opus | Where a rule, limit or copy string is enforced, shown, tested and configured | A table grouped by role with exact value, unit and `path:line`, unresolved matches listed | Replaces noisy search sorting; about $0.25 per use |
| Opus | Which fixture, setup and cleanup to use before writing tests | Nearest existing test, fixture signatures and defaults verbatim, committed versus sandbox rows, cleanup pattern | Pays only when the hunt spans several files |
| Opus | A failed CI run or test suite with long output | The failing blocks with exact errors and exit status, one cause guess per failure, labelled as a guess | Replaces log paging; a parser first, Haiku when failures interlock |
| Opus | Before `done` on a task with scattered evidence | Each acceptance criterion with its evidence or "not established", never "covered" because a test exists | One avoided review round is 8-17 minutes |
| Opus | Supplementary design or prior-probe material beyond the required sections | Constraining paragraphs verbatim, the rest in a few lines, with ranges | Avoids reading a 40-60K overflow in full |
| Opus | A mechanical write bundle after you fixed the behaviour: moving duplicated helpers, wiring one designed component into several pages | A patch in the worktree's `tmp/` or edits to files you assigned, then you inspect and run the checks | Replaces your typing turns; about $0.10-0.20 per bundle |

### Prompt shape

```
Question: <one question>
Scope: <paths, or "lib test config">
Return: <table or list>, every row with path:line; quote <what> verbatim; end with "Left out:" and "Searched:".
Rules: read only; do not write files; Dexter is at .dexter/dexter.sh (export TIPS_DEXTER="$PWD/.dexter/dexter.sh"); use both Dexter and rg for uses of a function.
```

### Record what happened

Until a pilot shows a measured gain, list each Haiku call in the PR description or handoff: the question, characters returned, whether you used the answer, and what it got wrong. The dispatcher records the same in its session notes.
