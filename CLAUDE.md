@AGENTS.md

## Haiku delegation

Haiku is optional in Claude Code: `Agent`, `model: "haiku"`, `subagent_type: "general-purpose"`. Same tools as you, runs in parallel, cheaper per fresh token. A scoped command or script that answers the question is always acceptable instead.

### Economics

- Every token in your context is billed again on each later request, on each advisor call while it is in the request, and for Fable on each cache rewrite after an hour-long hold. Haiku saves money only by keeping text out of your context, for as long as that text would have stayed there.
- A smaller context saved no time in this project's sessions. Haiku saves time only while you do independent work, or when one answer replaces several of your requests.
- Haiku's discount is large for fresh input and output under 100K prompt tokens, small for cached context, smaller above 100K. A verbatim relay saves nothing. Our [two verbatim lookup trials](https://github.com/chenghanlee/tips/pull/388#issuecomment-6055995214) favored direct Opus; the task-log analysis established no other win yet.

### Choose

Consider Haiku when all hold:

1. You can bound the assignment and verify its result.
2. The result is much smaller than the reading, or replaces several of your requests, or runs while you do independent work.
3. The net saving survives assignment, child execution, integration, verification and rework. Prefer a scoped command when it suffices.
4. The work is reading, summarizing, collecting, or drafting a change whose behaviour you already chose.

Never use Haiku for:

- Waiting: CI, merge, tests, providers, the tester, the user.
- Deciding: requirements, design, locking, authorization, ordering, concurrency, test contracts, relevance of a hit, severity, acceptance, blockers, done.
- Required reads: the issue and linked design, pair workflow, skills, blocker comments, the diff under review, the advisor's reply, post-compaction rereads.
- Replacing the advisor or the independent reviewer, gaining authority, bypassing a denial, real provider calls, secrets, anything needing user authorization.
- Forking your context into it, or digesting text already in your history. Compress before ingestion.
- Polling, keepalive calls, `sleep`.

### Assign

Send minimal sufficient context and a short contract:

```text
Task: <bounded outcome and acceptance criteria>
Scope: <sources/revision, essential context, constraints to preserve verbatim>
Permissions: read-only unless <writes/checks> are explicitly assigned.
Return: <artifact and size limit>; source references, omissions and uncertainties.
Finish: complete the scope and permitted checks, then stop; no extra work.
        Report check results, blockers and anything unfinished.
```

Keep the default medium effort; [low effort](https://platform.claude.com/docs/en/build-with-claude/prompt-engineering/prompting-claude-haiku-5-5) skips searches, checks or completion, and brevity instructions do not reduce thinking.

### Run and verify

- Writers get exclusive files; checks get exclusive build, database and port access; the role's environment is preserved.
- Use completion notifications, not polling. Count parallelism only for a background child while you do independent work.
- Finish or stop children and their processes before handing off or reporting `done` or `blocked`. Children never post to GitHub. The [pair workflow](agent/teams/README.md) applies to them.
- Inspect patches, verify consequential claims, read the gaps yourself. A check must exercise the change; a failed launch is not a check. Required verification stays yours.

### Measure

Record in the PR or handoff, or for the dispatcher in a root `tmp/` note: the direct-work baseline, result size and use, rework, later defects. Retain session and child IDs and usage records for total cost, including advisor and cache charges, without double-counting. Compare pilots with comparable direct work on total cost and elapsed task time. Label estimates. A fast child or a short answer alone proves no gain.
