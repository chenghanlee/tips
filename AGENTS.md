## Read first

| When | Read or do |
|---|---|
| Every task | Read the issue or the user's brief and its linked design sections |
| On pair or dispatcher launch | Read the [pair workflow](agent/teams/README.md) |
| Working alone | Use an isolated worktree and a PR; the required checks and review still apply. Merge only with the user's authorization |
| After context compaction | If paired or dispatching, reread the pair workflow. Reload each required skill before its next use |
| Repository context | [README](README.md): product, requirements and file locations |
| Fresh checkout, browser tests or worktree isolation | [Local development](docs/development/local-development.md) |
| Product behaviour or copy | [Glossary](docs/design/glossary.md) |
| Before pushing or reporting completion | [Test changes](README.md#test-changes) and the checks for changed files |
| Any PR | [PR review record](agent/teams/README.md#pr-review-record) |

## Boundaries

- Machine installs and machine or client settings need the user's action; propose the exact change. Locked repository dependencies and documented provisioning are allowed.
- Never put secrets in source, logs, issues, PRs, handoffs or chat.
- Never push implementation to `main`, edit another agent's work or reset its database.
- Report a denied action with its exact error. Follow the documented recovery and active approval policy. Do not bypass either.

## Software design

- Build the simplest solution that meets the requirements. Add nothing for hypothetical future needs or backwards compatibility. Among solutions that meet the requirements, prefer the one easier for the product's users over the one with less code.
- Follow applicable standards and language and framework idioms. Explain deviations in the PR.
- Before building a custom solution, check built-in features, locked dependencies, and commonly used libraries, tools and frameworks for the task. Build one only if none meets the requirements or reuse costs more to integrate and maintain than building and maintaining your own. Say what you checked and why in the PR.
- Use Ecto's query, changeset and migration DSLs. Use raw SQL or `fragment` only for what they cannot express. Bind runtime values as parameters.
- In the same PR, update the docs for what you changed and delete the code, files and docs it leaves unused.

## Skills

Before reading, editing or reviewing Elixir code, load `elixir` and each skill that applies:

- `phoenix`: LiveView, components, controllers, routes, Plug, channels, PubSub.
- `ecto`: schemas, changesets, queries, transactions, migrations.
- `oban`: background jobs.
- `otp`: processes, supervision, ETS.

## Elixir navigation

`"$TIPS_DEXTER"` answers from an index of this worktree's Elixir files, its `deps/` and the Elixir sources; root `tmp/` is outside the index. Commands are in the [Dexter reference](agent/skills/dexter/SKILL.md). For the Dexter rows, a text match does not replace Dexter's answer.

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

- Before changing a public or private function's name, arity, return shape or behaviour, find its uses with both Dexter `references` at its definition and scoped `rg` for its bare name and any atom or tuple that dispatches to it. Investigate every use that only one of them found.
- An empty Dexter result does not prove absence: dynamic dispatch, macros and generated code hide uses. Check with `rg` before concluding that a function is unused.
- After `mix deps.get` or a dependency change, run `"$TIPS_DEXTER" reindex`.
- If `$TIPS_DEXTER` is unset or fails, report that once, with any error, and use scoped `rg`.

## Tests

- Test the acceptance scenarios in the issue or user brief, and reported regressions. Changed functions, branches or input variants alone do not justify more tests.
- Read existing tests first. If they already check the required behaviour, leave them unchanged. If a requirement changed, update their assertions. If a scenario or regression is not covered, extend a test whose setup and action can exercise it; add one only when none can. Make the smallest set of changes that covers the scenarios and regressions.
- When adding coverage for new behaviour or a regression, write the test before implementing the change and confirm it fails for the intended reason.
- Use integration tests that exercise cooperating components through public entry points. Add a unit test only for a pure-logic boundary case not covered by integration tests. Add a browser test only for a user interaction that lower-level tests cannot exercise.
- Do not test frameworks, libraries, private functions or code structure.
- Before adding or changing tests, weigh the relevant [Test Desiderata](https://testdesiderata.com/) factors within these rules: isolated, composable, deterministic, fast, writable, readable, behavioral, structure-insensitive, automated, specific, predictive and inspiring.
- In the same PR, delete obsolete tests and tests your change makes redundant. Keep coverage of every acceptance scenario and regression that still applies.
- Reviewers: assess test changes together with the existing tests for the same scenarios and regressions. Passing tests and a reason for each test do not show that all are needed. When asking to remove or merge tests, name the existing test or smaller replacement that keeps the coverage.

## Checks

Before pushing:

- Changed `.ex` or `.exs` files: run `mix credo --strict`.
- Go changes, including carried patches: run the [pinned lint profile](agent/lsp/dexter/patches/README.md#required-go-static-analysis).

Fix the findings your change introduces; report the others.

## Writing

- No mannered prose. The user has ADHD.
- Plain and simple English, in chat, issues, PRs, comments and commits. Lead with the result and the next action.
- Omit greetings, praise, rhetorical questions, stock transitions and repeated conclusions.
- State each decision or result once; link its evidence instead of repeating it.

## GitHub

- Issue and PR comments: only decisions, findings, blockers and the review replies allowed below. No standalone progress, status or acknowledgment comments.
- Reviews: follow the [PR review record](agent/teams/README.md#pr-review-record). Put one finding per inline comment, on the line it concerns. Limit the body to the verdict, the record's required metadata, verification evidence and limits (see Evidence), and findings outside the diff. Give each finding outside the diff its `path:line`.
- Findings: start with [P0, P1 or P2](agent/teams/README.md#severity) and the change you ask for, then the consequence. For wrong behaviour, give the steps or input, the actual result and the expected result; otherwise say what it breaks or costs. A `suggestion` block must replace the commented lines exactly.
- Review replies: only ask or answer a question the finding leaves open, link the fixing commit, or say why you decline it. The reviewer who opened the thread resolves it.
- Blockers: state what is blocked, the exact error or question, and who must act. In a pair, follow the [blocker procedure](agent/teams/README.md#report-and-resolve-blockers). Decisions: state what and why in one or two sentences.
- Evidence: link code at its commit SHA and CI at its run URL. When quoting check output, quote only the failing lines. In PR descriptions and reviews, report failed, pending and unrun checks and local evidence that CI does not cover. Do not list passing checks.
