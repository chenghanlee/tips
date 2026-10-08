@AGENTS.md

## Haiku subagents

Delegation is optional. In Claude Code, use `Agent` with `model: "haiku"`
and `subagent_type: "general-purpose"`.

Our [two verbatim lookup trials](https://github.com/chenghanlee/tips/pull/388#issuecomment-6055995214)
favored direct Opus. The experiments and task logs establish neither a net Haiku
gain nor a latency benefit from smaller context alone. Treat new uses as pilots.

### Decide

Consider bounded, verifiable work when less retained input, replaced parent work,
or safe parallelism could outweigh child, assignment, integration, verification and
rework costs. Prefer scoped commands when they suffice. Skip delegation without a
plausible net benefit; a cheaper model or an external wait alone is insufficient.

Keep required reads and final requirements, design, authorization and acceptance
decisions yourself. A child may select relevant evidence, analyze it and draft
changes under criteria you set. It does not replace the advisor or independent
reviewer, gain permissions, or bypass a denial.

Send minimal sufficient context. Compress before ingestion; an appended summary
does not remove earlier text. Input savings depend on retention through later
requests, advisor calls and cache rewrites.

### Assign

Keep the prompt short. [Anthropic's Haiku guide](https://platform.claude.com/docs/en/build-with-claude/prompt-engineering/prompting-claude-haiku-5-5)
recommends medium effort as the Claude Code starting point; low effort can skip
searches, checks or completion. Asking for brevity does not control thinking cost.
When facts may have changed, ensure today's date is available and request current
evidence; avoid blanket search instructions.

```text
Task: <bounded outcome and acceptance criteria>
Scope: <sources/revision, necessary context, constraints to preserve verbatim>
Access: read-only unless <exclusive files and permitted checks> are assigned.
Return: <artifact and size bound>; source locations or URLs; gaps and uncertainties.
Finish: complete the scope and permitted checks, then stop. No scope expansion.
        Report blockers, unfinished work, and check results or why checks did not run.
```

A check must exercise the change; syntax alone or a failed launch is insufficient.
Verify consequential claims, inspect patches and resolve relevant gaps before use.
You remain responsible for required checks.

### Run within your turn

Assign disjoint files and exclusive use of any build, database and port needed for
checks; otherwise run checks yourself. Preserve the role's environment and tool
paths. Children never post to GitHub.

Count overlap only when the child runs in the
[background](https://code.claude.com/docs/en/sub-agents#run-subagents-in-foreground-or-background)
and you have independent work. Foreground calls block. Use completion notifications,
not polling. Finish or stop children and their processes before handing off or
reporting `done` or `blocked`; the [pair workflow](agent/teams/README.md) still applies.

### Evaluate pilots

In the PR or handoff, record the proposed direct-work baseline, returned size,
usefulness, rework and later defects; dispatchers use a worktree `tmp/` note.
Retain session/child IDs and usage records, including advisor charges and cache
lifetimes; avoid double-counting. Compare selected pilots' total cost and elapsed
task time with comparable direct work. Label estimates; a child's speed or token
count alone is not a gain.
