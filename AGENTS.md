## Read first

| When | Read or do |
|---|---|
| Every task | Read the issue or the user's brief and its linked design sections; the [design index](docs/design/README.md) names the sections to read for a trigger or feature. [PRODUCT.md](PRODUCT.md) states the purpose, audience and principles |
| On pair or dispatcher launch | Read the [common rules](agent/teams/roles/common.md) and your role file; it names the [pair workflow](agent/teams/README.md) sections you read |
| Changing the repository alone | Use an isolated worktree and a PR; the [checks](agent/docs/checks.md) and [review](agent/teams/README.md#pr-review-record) still apply. Merge only with the user's authorization. Read-only reviews and disposable output in ignored `tmp/` need neither |
| After context compaction | If paired or dispatching, reread your role file and its workflow sections. Reload each required skill before its next use |
| Repository context | [README](README.md): product, requirements and file locations |
| Before pushing a change | The [checks](agent/docs/checks.md) for the files you changed; record them as the [CI pause](agent/docs/github-ci-pause.md) says |
| Every `mix test` run | [Test logs](agent/docs/test-logs.md) |
| Any PR | [PR review record](agent/teams/README.md#pr-review-record) |
| Before reading, editing or reviewing Elixir code | [Elixir navigation](agent/docs/elixir-navigation.md): Dexter answers structure and uses; scoped `rg` answers text |
| Before launching a subagent | [Lookup subagents](agent/docs/lookup-subagents.md) for evidence; [Delegate settled work](agent/docs/delegate-settled-work.md) to Haiku or Luna |

## Boundaries

- Machine installs and machine or client settings need the user's action; propose the exact change. Locked repository dependencies and documented provisioning are allowed.
- Never put secrets in source, logs, issues, PRs, handoffs or chat.
- Never push directly to `main`, edit another agent's work or reset its database.
- Report a denied action with its exact error, secrets redacted. Follow the client's approval policy ([setup](agent/teams/SETUP.md#one-time-setup)); in a pair, follow the [blocker procedure](agent/teams/README.md#report-and-resolve-blockers). Do not bypass the denial.

## Skills

Read the skill for your task from the current worktree and apply it: [design-software](agent/skills/design-software/SKILL.md) when designing a feature, writing a spec or brief, or critiquing one; [implement-software](agent/skills/implement-software/SKILL.md) before planning an implementation, changing code or writing tests; [review-software-correctness](agent/skills/review-software-correctness/SKILL.md) when reviewing a PR, diff or commit for correctness against its brief; [review-software-design](agent/skills/review-software-design/SKILL.md) when reviewing one for design. A solo review applies both review skills. Apply [web-design-guidelines](agent/skills/web-design-guidelines/SKILL.md) when reviewing changed UI, as review-software-design describes. Impeccable and Intent are optional design tools; their interactive workflows need the user available. The [UX designer](agent/teams/roles/ux-designer.md) names the trigger for each. The language and framework skills below still apply.

Before reading, editing or reviewing Elixir code, load `elixir` and each skill that applies:

- `phoenix`: LiveView, components, controllers, routes, Plug, channels, PubSub.
- `ecto`: schemas, changesets, queries, transactions, migrations.
- `oban`: background jobs.
- `otp`: processes, supervision, ETS.

These five, `impeccable` and the `intent` skills are user-maintained files outside version control ([setup](agent/teams/SETUP.md#one-time-setup)). If one is missing, report it before the work that needs it.

## Writing

- No mannered prose. The user has ADHD.
- Plain and simple English, in chat, issues, PRs, comments and commits. Lead with the result and the next action.
- Omit greetings, praise, rhetorical questions, stock transitions and repeated conclusions.
- State each decision or result once; link its evidence instead of repeating it.

## GitHub

- Issue and PR comments: post only decisions, findings, blockers and the review replies allowed below. Do not post separate progress updates, status updates or acknowledgments.
- Reviews: follow the [PR review record](agent/teams/README.md#pr-review-record). Put one P0 or P1 finding per inline comment, on the line it concerns. P2s go in the body's [Optional](agent/teams/README.md#optional-p2-findings) part.
- Review body: only the review decision, details the review record requires, check results and what you did not check (see Evidence), findings outside the diff, each with its `path:line`, and the Optional P2s.
- Findings: start with [P0, P1 or P2](agent/teams/README.md#severity) and the change you ask for, then explain why it matters. For wrong behaviour, give the steps or input, the actual result and the expected result; otherwise say what it breaks or costs. A `suggestion` block must replace the commented lines exactly.
- Review replies: only ask or answer a question the finding leaves open, link the commit that fixes it, or explain why you will not make the requested change. The reviewer who opened the thread resolves it.
- Blockers: state what is blocked, the exact error or question, and who must act. In a pair, follow the [blocker procedure](agent/teams/README.md#report-and-resolve-blockers).
- Decisions: say what you decided and why in one or two sentences.
- Evidence: link code at its commit SHA and CI at its run URL when used. During the [CI pause](agent/docs/github-ci-pause.md), record local check evidence instead. When quoting check output, quote only the failing lines. Report checks that failed, are pending or were not run, and local results; omit passing CI checks.
