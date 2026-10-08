@AGENTS.md

## Haiku delegation

Haiku is optional in Claude Code: `Agent`, `model: "haiku"`,
`subagent_type: "general-purpose"`.

### Choose

Consider Haiku when you can bound the assignment, verify its result, and identify a
plausible net saving in cost or completion time. Savings may come from less retained
input, replaced parent work, or safe parallelism. Count assignment, child execution,
integration, verification and rework. Prefer scoped commands when they suffice.

Do it yourself when you cannot bound or verify the task, or verification and rework
would erase the saving. Keep required reads and final decisions yourself.
Children may analyze evidence under your criteria and draft changes whose behavior
you have chosen. They cannot replace the advisor or independent reviewer, gain
authority, or bypass a denial.

Our [two verbatim lookup trials](https://github.com/chenghanlee/tips/pull/388#issuecomment-6055995214)
favored direct Opus; the task-log analysis did not establish other wins. Compress
before ingestion: summarizing text already in your history removes nothing.
Savings depend on how long avoided text would remain in later requests.

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

[Anthropic recommends medium effort](https://platform.claude.com/docs/en/build-with-claude/prompt-engineering/prompting-claude-haiku-5-5)
as Claude Code's starting point; low effort can skip searches, checks or completion.
Brevity instructions do not control thinking cost. For changing facts, ensure the
current date is available and request fresh evidence; avoid blanket searches.

### Run and verify

Give writers exclusive files and checks exclusive build/database/port access;
preserve the role's environment. Count parallelism only for a background child
while you do independent work. Use completion notifications, not polling.
Finish or stop children and their processes before handing off or reporting `done`
or `blocked`. Children never post to GitHub; the [pair workflow](agent/teams/README.md) applies.

Inspect patches, verify consequential claims and resolve relevant gaps. Checks
must exercise the change; a failed launch is not a check. You remain responsible
for required verification.

### Measure

Record the direct-work baseline, result size/use, rework and later defects in the
PR or handoff; dispatchers use a worktree `tmp/` note. Retain session/child IDs and
usage records for total cost, including advisor/cache charges without double-counting.
Compare selected pilots with comparable direct work on total cost and elapsed
task time. Label estimates; a fast child or short answer alone proves no gain.
