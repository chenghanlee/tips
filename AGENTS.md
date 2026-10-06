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

- Follow industry standards, conventions and rules for the language, framework and problem you are working on. Explain any exceptions in the PR.
- Use Elixir and Phoenix idioms and conventions, and proven design patterns from widely used similar software.
- Check built-in features and proven libraries, frameworks and tools before writing your own. Reuse them when they meet the requirements. Build your own only when they do not; list the options checked and explain why they do not fit in the PR.
- Prefer Ecto's query, changeset and migration DSLs. Use raw SQL only for a database feature those DSLs cannot express; bind runtime values as parameters.
- Build the simplest working MVP: no enterprise complexity or backwards compatibility. Accept complexity only to simplify the user's experience.
- In the same PR, update the docs that describe what you changed and delete the code, files and docs your change leaves unused.

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

- Before adding or changing tests, use your judgement to choose the relevant [Test Desiderata](https://testdesiderata.com/) factors. Use them to compare the proposed tests with existing coverage and simpler options. In the PR, explain the main gains, costs and why the trade-offs are worth it. Support claims with measurements or concrete examples.
- Test behaviour with integration tests. Add a unit test only for pure-logic boundary cases they do not reach, and an end-to-end test only for a user interaction that lower-level tests cannot exercise.
- Default to no test changes. Read the existing tests for the issue's acceptance scenarios or the reported regression. If they detect the failure, leave them unchanged. Otherwise make the smallest set of changes that detects it: extend a test whose setup and action can exercise the scenario; add one only when none can. Changed functions, branches or input variants do not justify new cases.
- Do not test frameworks, libraries, private functions or code structure.
- If no existing test covers the changed behaviour, write the acceptance or regression test first and confirm it fails for the intended reason.
- In the same PR, delete the tests your change makes redundant. Keep the only test of an acceptance scenario or regression.
- Review test changes as a set against the existing tests for the same acceptance scenarios and regressions. When asking for removal or consolidation, name the existing test or the smaller replacement that keeps the coverage. Passing tests and a reason for each test do not show that the set is needed.

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

- Comment only for a decision, a finding or a blocker; no progress, status or acknowledgment comments.
- Reviews: one finding per inline comment, on the line it concerns. Use the body only for the verdict, verification limits and findings outside the diff, each with its `path:line`.
- Findings: start with [P0, P1 or P2](agent/teams/README.md#rules) and the change you ask for, then the consequence. For wrong behaviour give the steps or input, the actual result and the expected result; otherwise what it breaks or costs. A `suggestion` block is optional and must replace the commented lines exactly.
- Replies: only to ask or answer a question the finding leaves open, link the commit that fixes it, or give the reason you decline it. The reviewer who opened a thread resolves it.
- Blockers: what is blocked, the exact error or question, and who must act. Decisions: what and why, in one or two sentences.
- Link code at its commit SHA and CI at its run URL. Quote only the failing lines.
- Do not list passing checks. Report failed, pending and unrun checks, and local evidence that CI does not cover.
