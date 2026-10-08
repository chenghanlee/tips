@AGENTS.md

## Haiku subagents

Opus and Fable may launch Haiku: `Agent` tool, `model` "haiku", `subagent_type` "general-purpose". Same tools as you, runs in parallel, cheaper per token. Optional. A scoped command or script that answers the question is always acceptable instead.

### Why it pays, or does not

- Every token in your context is billed again on each later request, each advisor call while it is in the request, and for Fable each cache rewrite after an hour-long hold. Haiku saves money only by keeping text out of your context.
- A smaller context did not save time in this project's sessions ([PR #388](https://github.com/chenghanlee/tips/pull/388)). Haiku saves time only when it works while you do something else, or one answer replaces several of your requests.
- Haiku's discount is large for fresh input and output under 100K prompt tokens, small for cached context, smaller above 100K. A verbatim relay saves nothing.

### Use Haiku only when all four hold

1. The answer is much smaller than the reading it replaces, and no scoped command gives that answer directly.
2. One question, one checkable answer: scope searched, `path:line` per row, verbatim quotes for anything you act on word for word, a "Left out" list.
3. The work is reading, summarizing, collecting, or a mechanical change against a contract you already fixed.
4. You have other work meanwhile, or it replaces several of your requests. If you would only wait, do it yourself.

### Never use Haiku for

| Not this | Because |
|---|---|
| One known command, a body you are about to edit, a small hunt, a passing check | Costs more than it saves |
| Waiting on CI, merge, tests, providers, the tester, the user | Does not shorten the wait |
| Deciding: requirements, design, locking, authorization, ordering, concurrency, test contracts, hit relevance, severity, acceptance, blockers, done | A wrong contract costs a review round |
| Required reads: issue and linked design, pair workflow, skills, blocker comments, the diff under review, the advisor's reply, post-compaction rereads | Policy is read first-hand |
| Routing around a denial or prompt, real provider calls, secrets, anything needing user authorization | Boundary |
| Replacing the advisor, or forking your context into it | Haiku cannot reason over your history; prompts over 100K tokens lose the discount |
| Digesting text already in your context | Adds tokens, removes none. Compress before ingestion |
| Polling, keepalive, `sleep` | Waste |

### Ownership and turns

- A child that writes gets files you do not touch meanwhile, or returns a patch in the worktree's `tmp/`. You inspect every change and run the checks.
- Every child is finished or stopped before `team.py turn <pr> test`. No child touches the worktree, build or database after handoff. The [pair workflow](agent/teams/README.md) binds your children as it binds you.
- A child never runs `mix` on a shared database, edits another agent's work, or posts to GitHub.

### Prompt

```
Question: <one question>
Scope: <paths>
Return: <table or list>; path:line per row; quote <what> verbatim;
        end with "Left out:" and "Searched:".
Rules: read only; no file writes; export TIPS_DEXTER="$PWD/.dexter/dexter.sh";
       Dexter and rg both for uses of a function.
```

Launch independent calls together. Keep working; results arrive on their own. Reject an answer missing scope, locations or "Left out", and read the gap yourself.

### Record

No Haiku job has a measured gain yet. Until one does, record per call in the PR description or handoff: question, characters returned, used or not, errors, what a scoped command would have returned. Per task: child tokens, your rework, elapsed time of the delegated step, session cost total from the client's cost counter. The dispatcher keeps the same record in its session notes.
