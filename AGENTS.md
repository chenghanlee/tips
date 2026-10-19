## Read first

| When | Read or do |
|---|---|
| Every task | Read the issue or the user's brief and its linked design sections; the [design index](docs/design/README.md) names the sections to read for a trigger or feature |
| On pair or dispatcher launch | Read the [common rules](agent/teams/roles/common.md) and your role file; it names the [pair workflow](agent/teams/README.md) sections you read |
| Changing the repository alone | Use an isolated worktree and a PR; the [checks](#checks) and [review](agent/teams/README.md#pr-review-record) still apply. Merge only with the user's authorization. Read-only reviews and disposable output in ignored `tmp/` need neither |
| After context compaction | If paired or dispatching, reread your role file and its workflow sections. Reload each required skill before its next use |
| Repository context | [README](README.md): product, requirements and file locations |
| Fresh checkout, browser tests or worktree isolation | [Local development](docs/development/local-development.md) |
| Product behaviour or copy | [Glossary](docs/design/glossary.md) |
| Before pushing a change | The [checks](#checks) for the files you changed |
| Any PR | [PR review record](agent/teams/README.md#pr-review-record) |

## Boundaries

- Machine installs and machine or client settings need the user's action; propose the exact change. Locked repository dependencies and documented provisioning are allowed.
- Never put secrets in source, logs, issues, PRs, handoffs or chat.
- Never push directly to `main`, edit another agent's work or reset its database.
- Report a denied action with its exact error, secrets redacted. Follow the client's approval policy ([setup](agent/teams/SETUP.md#one-time-setup)); in a pair, follow the [blocker procedure](agent/teams/README.md#report-and-resolve-blockers). Do not bypass the denial.

## Skills

Read the skill for your task from the current worktree and apply it: [design-software](agent/skills/design-software/SKILL.md) when designing a feature, writing a spec or brief, or critiquing one; [implement-software](agent/skills/implement-software/SKILL.md) before planning an implementation, changing code or writing tests; [review-software-correctness](agent/skills/review-software-correctness/SKILL.md) when reviewing a PR, diff or commit for correctness against its brief; [review-software-design](agent/skills/review-software-design/SKILL.md) when reviewing one for design. A solo review applies both review skills. The language and framework skills below still apply.

Before reading, editing or reviewing Elixir code, load `elixir` and each skill that applies:

- `phoenix`: LiveView, components, controllers, routes, Plug, channels, PubSub.
- `ecto`: schemas, changesets, queries, transactions, migrations.
- `oban`: background jobs.
- `otp`: processes, supervision, ETS.

These five are user-maintained files outside version control ([setup](agent/teams/SETUP.md#one-time-setup)). If one is missing, report it before the work that needs it.

## Elixir navigation

`"$TIPS_DEXTER"` answers from an index of this worktree's Elixir files, its `deps/` and the Elixir sources; root `tmp/` is outside the index. [Pair provisioning](agent/lsp/README.md#pair-provisioning) sets the variable. Commands are in the [Dexter reference](agent/skills/dexter/SKILL.md).

| Need | Use |
|---|---|
| Outline an indexed file whose structure you do not know | Dexter `symbols` |
| Where a module or function is defined | Dexter `lookup`; `workspace-symbols` for a partial name; `definition` from a call site |
| Docs, spec or signature | Dexter `hover` |
| Uses of a module or function; its callers; the calls it makes | Dexter `references`; `incoming-calls`; `outgoing-calls`. `prepare-call-hierarchy` confirms the function and arity a position selects |
| Implementations of a callback | Dexter `implementation` |
| Known lines, including lines Dexter returned | `sed -n` or the client's read tool; no outline first |
| Literal text: strings, messages, config keys, comments, atoms | Scoped `rg` or `grep` |
| Anything in a non-Elixir file or outside the index | Scoped `rg` or `grep` |
| File names | `rg --files` |

- For the Dexter rows, a text match does not replace Dexter's answer. If `$TIPS_DEXTER` is unset or fails, report that once, with any error, and use scoped `rg`.
- Before changing a public or private function's name, arity, return shape or behaviour, find its uses with both Dexter `references` at its definition and scoped `rg` for its bare name and any atom or tuple that dispatches to it. Investigate every use that only one of them found.
- An empty Dexter result does not prove absence: dynamic dispatch, macros and generated code hide uses. Check with `rg` before concluding that a function is unused.
- After `mix deps.get` or a dependency change, run `"$TIPS_DEXTER" reindex`.

## Checks

Per commit, run only the fast checks for the files you touched: the formatter, the
linter and the changed test module or test file. Run the full checks below once, at the
PR head, before the push that opens or updates the PR. Do not rerun them on `main` or on
intermediate commits. Run the checks for each kind of file you changed:

| Changed files | Run |
|---|---|
| Application code, tests or config | [Test changes](README.md#test-changes), including `mix credo --strict` and `mix dialyzer` |
| `agent/teams` Python | [Harness checks](agent/teams/development.md#required-checks) |
| Go, including carried patches | [Pinned lint profile](agent/lsp/dexter/patches/README.md#required-go-static-analysis) |
| Markdown | `python3 scripts/check_docs.py` |

Fix the findings your change introduces; report the others.

### GitHub CI pause

By the user's decision on 2026-10-18, use local checks and independent review while
GitHub Actions is paused. This replaces GitHub-hosted execution and passing CI status
as delivery requirements; it does not remove the applicable checks above or the
[local equivalents of CI-only checks](docs/development/local-development.md#local-verification-during-the-ci-pause).

- Run applicable checks locally before handoff. Missing tools, denied execution and
  skipped required tests are blockers, not passes; report them without bypassing denial.
- In the PR, record commands, tested commit, results, relevant environment and retained
  log paths. The independent reviewer verifies that evidence and covers correctness
  and design before submitting a current-head review. Self-review is insufficient.
- After a change, rerun affected checks. A reviewer may carry forward earlier evidence
  only after checking the intervening diff and recording why it still applies.
- Follow the [merge procedure](agent/teams/README.md#merge). Do not wait for paused
  workflows or call their billing failures code failures. Keep review, thread,
  mergeability and merge-authorization requirements. Report any remaining GitHub
  required-status rule to the user; do not bypass it.
- Keep workflow files for restoration. When the user resumes CI, restore its execution
  and merge requirements and update this policy together.

## Writing

- No mannered prose. The user has ADHD.
- Plain and simple English, in chat, issues, PRs, comments and commits. Lead with the result and the next action.
- Omit greetings, praise, rhetorical questions, stock transitions and repeated conclusions.
- State each decision or result once; link its evidence instead of repeating it.

## GitHub

- Issue and PR comments: post only decisions, findings, blockers and the review replies allowed below. Do not post separate progress updates, status updates or acknowledgments.
- Reviews: follow the [PR review record](agent/teams/README.md#pr-review-record). Put one finding per inline comment, on the line it concerns.
- Review body: only the review decision, details the review record requires, check results and what you did not check (see Evidence), and findings outside the diff, each with its `path:line`.
- Findings: start with [P0, P1 or P2](agent/teams/README.md#severity) and the change you ask for, then explain why it matters. For wrong behaviour, give the steps or input, the actual result and the expected result; otherwise say what it breaks or costs. A `suggestion` block must replace the commented lines exactly.
- Review replies: only ask or answer a question the finding leaves open, link the commit that fixes it, or explain why you will not make the requested change. The reviewer who opened the thread resolves it.
- Blockers: state what is blocked, the exact error or question, and who must act. In a pair, follow the [blocker procedure](agent/teams/README.md#report-and-resolve-blockers).
- Decisions: say what you decided and why in one or two sentences.
- Evidence: link code at its commit SHA and CI at its run URL when used. During the [CI pause](#github-ci-pause), record local check evidence instead. When quoting check output, quote only the failing lines. Report checks that failed, are pending or were not run, and local results; omit passing CI checks.
