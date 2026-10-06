## Read first

| When | Read |
|---|---|
| Launched into a pair, or dispatching | The [pair workflow](agent/teams/README.md) |
| Every task | The issue or the user's brief, then the design sections it links |
| Product and repository context | [README](README.md): what Tips is, where requirements live, where files belong |
| Before pushing or reporting completion | [Test changes](README.md#test-changes) and the checks for the files you touched |
| Any PR | The [PR review record](agent/teams/README.md#pr-review-record) |
| After context compaction | In a pair or dispatching: reread the pair workflow. Before the next action that needs a skill, reload it |
| Working alone for the user | Use an isolated worktree and a PR. The required checks and review apply. Merge only within the user's authorization |
| Fresh checkout, browser tests, worktree isolation | The section you need in [local development](docs/development/local-development.md) |
| Product behaviour or copy | [Glossary](docs/design/glossary.md) |

## Boundaries

- Machine installs and machine or client settings belong to the user; propose the exact change. Fetching locked repository dependencies and documented provisioning are allowed.
- Never put secrets in source, logs, issues, PRs, handoffs or chat.
- Never push implementation to `main`. Do not edit another agent's work or reset its database.
- Report a denied action with its exact error. Follow the documented recovery and the active approval policy; never bypass either.

## Software design

- Use Elixir and Phoenix idioms, conventions and proven design patterns from widely used similar software.
- Prefer Ecto's query, changeset and migration DSLs. Use raw SQL only for a database feature they do not support, and bind runtime values as parameters.
- Build the simplest working MVP: no enterprise complexity, no backwards compatibility. Accept complexity only when it makes the user's experience simpler.

## Writing

- No mannered prose. The user has ADHD.
- Plain and simple English, in chat, issues, PRs, comments and commits. Lead with the result and the next action.
- Omit greetings, praise, rhetorical questions, stock transitions and repeated conclusions.
- State each decision or result once and link its evidence instead of repeating it.

## Tests

- Weigh each test's value against its cost with Kent Beck's [Test Desiderata](https://testdesiderata.com/); its properties are trade-offs, not a checklist.
- Test behaviour with integration tests. Add a unit test only for pure-logic boundary cases they do not reach, and an end-to-end test only for a user interaction that lower-level tests cannot exercise.
- Default to no test changes. First read the existing tests for the issue's acceptance scenarios or the reported regression. If they already detect the failure, change nothing. Otherwise make the smallest set of test changes that detects it: extend an existing test when its setup and action can exercise the scenario; add a test when they cannot. Do not add test cases because functions, branches or input variants changed.
- Do not test the framework, a library, a private function or the code's structure.
- When behaviour changes and no existing test establishes it, write the failing acceptance or regression test first and confirm it fails for the right reason.
- In the same PR, delete the tests your change makes redundant. Keep the only test of an acceptance scenario or regression.
- Reviewing: judge the added and changed tests as a set against the existing tests for the same acceptance scenarios and regressions. Ask for removal or consolidation by naming the existing test, or the smaller replacement, that keeps the coverage. Passing tests, and a reason for each test, do not show the set is needed.

## GitHub

- Comment only for a decision, a review finding or a blocker. No progress, status or acknowledgment comments.
- Review: put each finding inline on the line it concerns, one finding per comment. The review body holds only the verdict, the verification limits and findings outside the diff; give each of those findings its `path:line`.
- Finding: line one is the severity (`P0`, `P1` or `P2`, [defined here](agent/teams/README.md#rules)) and the change you ask for. Then the consequence. For wrong behaviour: the steps or input, the actual result and the expected result. Otherwise: what it breaks or costs. A `suggestion` block is optional; it must replace the commented lines exactly.
- Reply to a finding only to ask or answer a question it leaves open, to link the commit that fixes it, or to give the reason you decline it. The reviewer who opened a thread resolves it.
- Blocker: what is blocked, the exact error or question, and who must act. Decision: what was decided and why, in one or two sentences.
- Link evidence instead of pasting it: a commit-SHA permalink for code, the run URL for CI. Quote only the failing lines.
- Do not list passing checks. Report failed, pending and unrun checks, and local evidence that CI does not cover.

## Elixir navigation

- Use `"$TIPS_DEXTER"` before `rg`, `grep`, `sed`, `cat` or a whole-file read to outline a file or find a definition, uses or callers. See the [Dexter reference](agent/skills/dexter/SKILL.md).
- After Dexter navigation, read the source ranges you need; use scoped text searches for literal text, dynamic dispatch and files outside its index. On tool failure, report once and fall back.

## Skills

Before reading, editing or reviewing Elixir code, load the `elixir` skill. Also load `phoenix` for LiveView, components, controllers, routes, Plug, channels or PubSub; `ecto` for schemas, changesets, queries, transactions or migrations; `oban` for background jobs; `otp` for processes, supervision or ETS.

## Checks

- Before pushing a change to `.ex` or `.exs` files, run `mix credo --strict`. Fix the findings your change introduced; report the others.
- Before pushing a Go change, including a carried patch, run the [pinned lint profile](agent/lsp/dexter/patches/README.md#required-go-static-analysis). Fix the findings our code introduces; report the others.
