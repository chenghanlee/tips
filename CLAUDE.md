@AGENTS.md

## Haiku delegation

Use Haiku only to carry out steps and rules supplied by Opus or Fable.
Keep analysis and judgment with the parent. Delegation is optional: `Agent`, `model: "haiku"`,
`subagent_type: "general-purpose"`. Prefer a command or script when it suffices.

### Choose

Use Haiku only when all three hold:

1. You specify the sources, allowed actions, what to select or omit, what to change
   or preserve, the output format and when to stop. Haiku must not invent missing
   rules or decide what matters, what evidence means or which behavior is correct.
2. You can check the result for errors and missing information against the sources,
   stated requirements or a test.
3. You can name the work or input it would save, or independent work you can do
   meanwhile. The saving must plausibly exceed assignment, child execution,
   integration, checking and rework.

### When not to use Haiku

- The work needs analysis or judgment: interpreting requirements, weighing evidence,
  deciding what matters, diagnosing a cause or choosing behavior. Do that yourself;
  delegate only the steps left after those decisions.
- You cannot give clear instructions or check the result. Resolve the missing
  requirements or verification method first.
- You must repeat the work to trust it, or delegation adds more work than it saves.
  Handing off a wait does not shorten it.

Keep required reads, permission decisions, required verification and final decisions
about design, test requirements, severity, acceptance, blockers and completion.
A child cannot replace the advisor or independent reviewer, grant permission or
bypass a denial.

### Costs and evidence

- Less text in your context can reduce later input, advisor and cache-write costs.
  Count only requests that would retain it. A new summary does not erase old text.
- Replacing parent output or requests can save money. Compare total work at the
  applicable model and cache prices; cheaper tokens alone do not prove a saving.
- Replacing steps or overlapping independent work may save time. Our logs establish
  no time saving from smaller context alone; assume none without measurement.

Our [two lookup trials](https://github.com/chenghanlee/tips/pull/388#issuecomment-6055995214)
favored direct Opus. The task logs established no other win. Treat new uses as trials.

### Assign

Send only inputs needed for the assigned steps. Do not copy or fork your full
conversation history; the parent handles its interpretation. Haiku 5.5's
[prices](https://platform.claude.com/docs/en/about-claude/pricing) increase above 100K prompt tokens.
Use this contract:

```text
Task: <result and acceptance criteria>
Scope: <sources/revision, selection and change rules, text to preserve exactly>
Permissions: read-only unless <writes/checks> are assigned.
Return: <artifact and size limit>; sources, omissions and check results.
Stop: finish the assigned work and checks; add nothing else.
      If instructions are missing, ambiguous or conflict, report the gap; do not decide.
```

[Anthropic recommends medium effort](https://platform.claude.com/docs/en/build-with-claude/prompt-engineering/prompting-claude-haiku-5-5)
as the Claude Code starting point. Low effort can skip searches, checks or completion.
Asking for a short answer does not reliably reduce thinking cost.

### Run and check

- Give writers exclusive files and checks exclusive build, database and port access.
  Preserve the role's environment.
- Count overlap only for a background child while you do independent work.
  Use completion notifications, not polling or keepalives.
- Finish or stop children and their processes before handoff, `done` or `blocked`.
  Children never post to GitHub. Follow the [pair workflow](agent/teams/README.md).
- Inspect changes and check results before use. Checks must exercise the change;
  a failed launch is not a check. Resolve missing evidence yourself.

### Measure

In the PR or handoff, record the direct-work comparison, result size and use, rework
and later defects. Dispatchers use a root `tmp/` note. Retain session/child IDs and
usage records, including advisor and cache costs, without double-counting.
Compare total cost and task time. Label estimates; a fast child is not proof of a gain.
