## Read first

| When | Read |
|---|---|
| Launched into a pair, or dispatching | The [pair workflow](agent/teams/README.md) |
| Every task | The issue or the user's brief, then the design sections it links |
| Product and repository context | [README](README.md): what Tips is, where requirements live, where files belong |
| Before pushing or reporting completion | [Test changes](README.md#test-changes) and the checks for the files you touched |
| Any PR | The [PR review record](agent/teams/README.md#pr-review-record) |
| Working alone for the user | Use an isolated worktree and a PR. The required checks and review apply. Merge only within the user's authorization |
| Fresh checkout, browser tests, worktree isolation | The section you need in [local development](docs/development/local-development.md) |
| Product behaviour or copy | [Glossary](docs/design/glossary.md) |

## Boundaries

- Machine installs and machine or client settings belong to the user; propose the exact change. Fetching locked repository dependencies and documented provisioning are allowed.
- Never put secrets in source, logs, issues, PRs, handoffs or chat.
- Never push implementation to `main`. Do not edit another agent's work or reset its database.
- Report a denied action with its exact error. Follow the documented recovery and the active approval policy; never bypass either.

## Software design

- Use Elixir and Phoenix idioms and proven designs from widely used similar software.
- Build the simplest working MVP: no enterprise complexity, no backwards compatibility. Accept complexity only when it makes the user's experience simpler.

## Writing

- Plain, short English, in chat, issues, PRs, comments and commits. Lead with the result and the next action.
- State each decision or result once and link its evidence instead of repeating it.

## Tests

- Integration first. Unit tests are for pure logic with wide blast radius.
- When behaviour changes and existing coverage does not establish it, write the failing acceptance or regression test first and confirm it fails for the right reason.
- Keep the suite lean: add a test only for confidence that is missing; remove redundant tests and simplify costly ones without losing required coverage.

## GitHub

- Comment only for a decision, a review finding or a blocker. No progress comments.
- Omit routine CI inventories; report material local evidence and failed, pending or unrun checks.

## Elixir navigation

- Use `"$TIPS_DEXTER"` before `rg`, `grep`, `sed`, `cat` or a whole-file read to outline a file or find a definition, uses or callers. See the [Dexter reference](agent/skills/dexter/SKILL.md).
- After Dexter navigation, read the source ranges you need; use scoped text searches for literal text, dynamic dispatch and files outside its index. On tool failure, report once and fall back.

## Skills

Before Elixir work, load the `elixir` skill, then those that apply: `phoenix` (LiveView, components, controllers, routes, Plug, channels, PubSub), `ecto` (schemas, changesets, queries, transactions, migrations), `oban` (background jobs), `otp` (processes, supervision, ETS).

## Checks

- Run `mix credo --strict` on edited `.ex`/`.exs` files and fix issues you introduced.
- Go changes, including carried patches: run the [pinned lint profile](agent/lsp/dexter/patches/README.md#required-go-static-analysis). Fix findings our code introduces; report inherited ones separately.
