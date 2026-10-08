@AGENTS.md

## Haiku subagents

Opus and Fable can launch Haiku subagents with the `Agent` tool, `model` "haiku", `subagent_type` "general-purpose". Haiku has your tools, runs in parallel with you, and is cheaper and faster per token. Whether to use it is your call. Nothing is routed through it, and a scoped command or script that answers the question is always an acceptable choice instead.

What this project's own sessions showed ([PR #388](https://github.com/chenghanlee/tips/pull/388), the closed mechanical explorer):

- A token kept in your context is paid again on every later request, on every advisor call while it is still in the request (advisor input was uncached in the observed calls), and for Fable on every cache rewrite after a hold longer than an hour. Money is saved by keeping text out of your context, not by moving the reading elsewhere.
- Those sessions showed no time saving from a smaller context alone. Time is saved only when Haiku works while you do something else, or when its one answer replaces several of your requests.
- Haiku's price advantage is largest for fresh input and output (Opus 5.5 to Haiku 5.5, prompts under 100K tokens), smaller for cached context, and much smaller above 100K tokens. It is not a total-job saving. A verbatim relay through Haiku saves nothing: you ingest it all anyway.

### Consider Haiku when all of these hold

1. The answer is much smaller than the reading it replaces, and a scoped command cannot already give that small answer.
2. The question can be stated once, with an answer you can check: scope searched, `path:line` on every row, constraints and decisions quoted verbatim, a "left out" list.
3. The work is reading, compressing, collecting, or a mechanical change against a contract you have already fixed.
4. Either you have independent work to do while it runs, or it replaces several of your requests. If you would wait for it with nothing else to do, do the work yourself.

Haiku may summarize and compress. Anything you must act on word for word, such as copy, error text, config values, authorization text and decisions, comes back verbatim or not at all.

### Do not use Haiku for

- A single known command, a function body you are about to edit, a small hunt, a passing check run. The call costs more than it saves.
- Waiting: CI, merge, a test suite, a provider call, the tester's turn, a user hold. Haiku watching a clock does not shorten it.
- Deciding: requirements, architecture, locking, authorization, transaction ordering, concurrency, test contracts, what a search hit means, severity, acceptance, blocker calls, what counts as done. A cheap implementation of a wrong contract costs a review round.
- Required reads: the issue and its linked design sections, the pair workflow, the skills, blocker comments, the diff you are reviewing, the advisor's reply. Rules and policy are read first-hand, including the rereads after compaction.
- Routing around a denied action or a permission prompt, real provider calls, secrets, anything that needs the user's authorization.
- A substitute for the advisor. The advisor reasons over your whole conversation; Haiku cannot.
- Forking your context. Keep each prompt small and self-contained; Haiku's cheap tier ends at 100K prompt tokens and it cannot reason over your history.
- Digesting text already in your context. That adds tokens and removes none. Compress before ingestion.
- Keeping caches warm. No polling, no keepalive calls, no `sleep`.

### Ownership and turns

- During your turn, a Haiku child that writes gets files you do not touch meanwhile, or returns a patch in the worktree's `tmp/` that you apply. You inspect every change and run the normal checks.
- Every child finishes or is stopped before you hand off with `team.py turn <pr> test`, and no child uses the worktree, the build or the database after that. The [pair workflow](agent/teams/README.md) rules apply to your children as to you.
- Haiku never runs `mix` against a shared database, never edits another agent's work and never posts to GitHub.

### Asking

```
Question: <one question>
Scope: <paths, or "lib test config">
Return: <table or list>, every row with path:line; quote <what> verbatim;
        end with "Left out:" and "Searched:".
Rules: read only; do not write files; Dexter is at .dexter/dexter.sh
       (export TIPS_DEXTER="$PWD/.dexter/dexter.sh"); use both Dexter and rg
       for uses of a function.
```

Launch independent calls together and keep working; results arrive on their own. Reject an answer with no scope, no locations or no "left out" list, and read the gap yourself.

### Record

No Haiku job here has a measured gain yet. Until one does, record in the PR description or the handoff, per call: the question, characters returned, whether you used it, what it got wrong, and what a scoped command would have returned instead. Per task: child token usage, your rework after a child's answer, elapsed time of the delegated step, and the session cost total from the client's cost counter. The dispatcher keeps the same record in its session notes. Without this record a pilot cannot be judged.
