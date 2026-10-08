## Read first

| When | Read or do |
|---|---|
| Every task | Read the issue or the user's brief and its linked design sections |
| On pair or dispatcher launch | Read the [shared workflow](agent/teams/README.md) and your [role procedure](agent/teams/README.md#role-procedures) from this worktree |
| Changing the repository alone | Use an isolated worktree and a PR; the [checks](#checks) and [review](agent/teams/pr-review-record.md) still apply. Merge only with the user's authorization. Read-only reviews and disposable output in ignored `tmp/` need neither |
| After context compaction | Reread this file. If paired or dispatching, follow [context recovery](agent/teams/README.md#recover-task-context). Reload each required skill before its next use |
| Repository context | [README](README.md): product, requirements and file locations |
| Fresh checkout, browser tests or worktree isolation | [Local development](docs/development/local-development.md) |
| Product behaviour or copy | [Glossary](docs/design/glossary.md) |
| Before pushing a change | The [checks](#checks) for the files you changed |
| Any PR | [PR review record](agent/teams/pr-review-record.md) |

## Boundaries

- Machine installs and machine or client settings need the user's action; propose the exact change. Locked repository dependencies and documented provisioning are allowed.
- Never put secrets in source, logs, issues, PRs, handoffs or chat.
- Never push directly to `main`, edit another agent's work or reset its database.
- Report a denied action with its exact error, secrets redacted. Follow the client's approval policy ([setup](agent/teams/SETUP.md#one-time-setup)); in a pair, follow the [blocker procedure](agent/teams/README.md#report-and-resolve-blockers). Do not bypass the denial.

## Skills

Before planning an implementation, changing code or writing tests, read [developing-software](agent/skills/developing-software/SKILL.md) from the current worktree. It maps the design and testing rules; retrieve required and triggered references before the decisions they constrain. When assigned a PR, diff or commit review, read [reviewing-code](agent/skills/reviewing-code/SKILL.md) from the current worktree and apply it. The language and framework skills below still apply.

Before reading, editing or reviewing Elixir code, load `elixir` and each skill that applies:

- `phoenix`: LiveView, components, controllers, routes, Plug, channels, PubSub.
- `ecto`: schemas, changesets, queries, transactions, migrations.
- `oban`: background jobs.
- `otp`: processes, supervision, ETS.

These five are user-maintained files outside version control ([setup](agent/teams/SETUP.md#one-time-setup)). If one is missing, report it before the work that needs it.

## Elixir navigation

Before navigating Elixir code, read the [Dexter skill](agent/skills/dexter/SKILL.md)
from this worktree. It owns the Need/Use table, use checks, fallback and commands
for the worktree-bound `"$TIPS_DEXTER"`.

## Checks

Before pushing, run the checks for each kind of file you changed:

| Changed files | Run |
|---|---|
| Application code, tests or config | [Test changes](README.md#test-changes), including `mix credo --strict` and `mix dialyzer` |
| `agent/teams` Python | [Harness checks](agent/teams/development.md#required-checks) |
| Go, including carried patches | [Pinned lint profile](agent/lsp/dexter/patches/README.md#required-go-static-analysis) |
| Markdown | `python3 scripts/check_docs.py` |

Fix the findings your change introduces; report the others.

## Writing

- No mannered prose. The user has ADHD.
- Plain and simple English, in chat, issues, PRs, comments and commits. Lead with the result and the next action.
- Omit greetings, praise, rhetorical questions, stock transitions and repeated conclusions.
- State each decision or result once; link its evidence instead of repeating it.

## GitHub

- Issue and PR comments: post only decisions, findings, blockers and the review replies allowed below. Do not post separate progress updates, status updates or acknowledgments.
- Reviews: follow the [PR review record](agent/teams/pr-review-record.md), including its finding and evidence format.
- Review replies: only ask or answer a question the finding leaves open, link the commit that fixes it, or explain why you will not make the requested change. The reviewer who opened the thread resolves it.
- Blockers: state what is blocked, the exact error or question, and who must act. In a pair, follow the [blocker procedure](agent/teams/README.md#report-and-resolve-blockers).
- Decisions: say what you decided and why in one or two sentences.
- Evidence: link code at its commit SHA and CI at its run URL. When quoting check output, quote only the failing lines. In PR descriptions and reviews, report checks that failed, are pending or were not run, and results of local checks that CI does not cover. Omit passing CI checks.
