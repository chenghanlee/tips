## Read first

| When | Read or do |
|---|---|
| Every task | Read the issue or the user's brief and its linked design sections |
| On pair or dispatcher launch | Read the [pair workflow](agent/teams/README.md) |
| Changing the repository alone | Use an isolated worktree and a PR; the [checks](#checks) and [review](agent/teams/README.md#pr-review-record) still apply. Merge only with the user's authorization. Read-only reviews and disposable output in ignored `tmp/` need neither |
| After context compaction | If paired or dispatching, reread the pair workflow. Reload each required skill before its next use |
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

## Software design

- Build the simplest solution that meets the requirements. Add nothing for hypothetical future needs or for compatibility the requirements do not ask for. Among solutions that meet the requirements, prefer the one easier for the product's users over the one with less code.
- Follow applicable standards and language and framework idioms. Explain deviations in the PR.
- Before building a custom solution, check built-in features, locked dependencies, and commonly used libraries, tools and frameworks for the task. Build one only if none meets the requirements or reuse costs more to integrate and maintain than building and maintaining your own. Say what you checked and why in the PR.
- Use Ecto's query, changeset and migration DSLs. Use raw SQL or `fragment` only for what they cannot express. Bind runtime values as parameters.
- In the same PR, update the docs for what you changed and delete the code, files and docs it leaves unused.

## Skills

Before implementing a feature, fix or refactor, read [developing-software](agent/skills/developing-software/SKILL.md) from the current worktree and apply the sections whose trigger matches the change. When assigned a PR, diff or commit review, read [reviewing-code](agent/skills/reviewing-code/SKILL.md) from the current worktree and apply it. The language and framework skills below still apply.

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

## Tests

- Test the acceptance scenarios in the issue or user brief, and reported regressions. Do not add tests just because functions, branches or inputs changed.
- Read existing tests first. If they already check the required behaviour, leave them unchanged. If a requirement changed, update their assertions. If a scenario or regression has no test, extend an existing test that can check it with the same setup and action. Add a test only if none can. Make the smallest set of changes that covers the scenarios and regressions.
- To test new behaviour or a regression, write or update the test before changing the code. Check that it fails for the reason you expect.
- Use integration tests to check that components work together through their public entry points. Add a unit test only for a boundary case in pure logic that integration tests do not cover. Add a browser test only for a user interaction that lower-level tests cannot check.
- Test the application's behaviour through its public entry points, including its use of a framework or library. Do not test the framework or library itself, private functions or code structure.
- Before adding or changing tests, weigh the trade-offs using the relevant [Test Desiderata](https://testdesiderata.com/) factors: isolated, composable, deterministic, fast, writable, readable, behavioral, structure-insensitive, automated, specific, predictive and inspiring. Follow the rules above when choosing.
- In the same PR, delete tests for requirements that no longer apply and tests your change makes unnecessary. Keep tests for every acceptance scenario and regression that still applies.

## Checks

Before pushing, run the checks for each kind of file you changed:

| Changed files | Run |
|---|---|
| Application code, tests or config | [Test changes](README.md#test-changes), including `mix credo --strict` |
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
- Reviews: follow the [PR review record](agent/teams/README.md#pr-review-record). Put one finding per inline comment, on the line it concerns.
- Review body: only the review decision, details the review record requires, check results and what you did not check (see Evidence), and findings outside the diff, each with its `path:line`.
- Findings: start with [P0, P1 or P2](agent/teams/README.md#severity) and the change you ask for, then explain why it matters. For wrong behaviour, give the steps or input, the actual result and the expected result; otherwise say what it breaks or costs. A `suggestion` block must replace the commented lines exactly.
- Review replies: only ask or answer a question the finding leaves open, link the commit that fixes it, or explain why you will not make the requested change. The reviewer who opened the thread resolves it.
- Blockers: state what is blocked, the exact error or question, and who must act. In a pair, follow the [blocker procedure](agent/teams/README.md#report-and-resolve-blockers).
- Decisions: say what you decided and why in one or two sentences.
- Evidence: link code at its commit SHA and CI at its run URL. When quoting check output, quote only the failing lines. In PR descriptions and reviews, report checks that failed, are pending or were not run, and results of local checks that CI does not cover. Omit passing CI checks.
