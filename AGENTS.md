## Read first

| When | Read |
|---|---|
| Launched into a team | The [team agreement](agent/teams/README.md) and your role card |
| Working alone for the user | Use an isolated task worktree and a PR. Merge only within the user's authorization, after the required checks and review. An [owner waiver](agent/teams/roles/lead-tpm.md#merge) needs the user's explicit instruction |
| Every task | The assigned issue or contract, or the user's brief. Start with the design sections it links; follow the shared rules and boundaries they affect |
| Product and repository context | [README](README.md): what Tips is, where requirements live, where files belong |
| Before pushing or reporting completion | [Test changes](README.md#test-changes) and the checks for the files you touched |
| Fresh checkout, browser tests, worktree isolation | The section you need in [local development](docs/development/local-development.md) |
| Product behaviour or copy | [Glossary](docs/design/glossary.md) |

Design files are large. List headings with `rg -n '^#{2,3} ' <file>`, then read the relevant sections and the shared invariants they point to.

## Boundaries

- Machine installs and machine or client settings belong to the user; propose the exact change. Fetching locked repository dependencies and documented provisioning are allowed.
- Never put secrets in source, logs, issues, PRs, handoffs or chat.
- Never push implementation to `main`. Do not edit another agent's work or reset its database.
- Report a denied action with its exact error. Follow the documented recovery and the active approval policy; never bypass either.

## Problem Solving

- Ask why 5–15 times to find the root problem. Stop when two more whys do not change the answer.
- Start with first principles, then use Occam's razor and the 80/20 rule to find the simplest working solution for the root problem.

## Software Design

- Use Elixir and Phoenix idioms, standards and conventions, and proven designs from widely used similar software.
- Choose the simplest working solution; simplicity beats elegance when they conflict. Remove unnecessary parts.
- Build an MVP for fast iteration: avoid unnecessary enterprise complexity; no backwards compatibility.
- Accept complexity only when it makes the user's experience simpler; never push it onto the user. This applies to architecture, backend, data model and frontend.

## Testing

- Follow the testing trophy, integration first. TDD means writing the failing ExUnit integration test for the acceptance scenario before the code.
- Unit tests only for pure logic with wide blast radius.
- Write new end-to-end tests, including browser journeys, for milestone gates; CI keeps rerunning existing coverage.

## Review

1. Local correctness of the change.
2. Effects of the change, and of each proposed fix, on callers, related modules, features and tests.
3. Fit with the project's design and implementation, end to end.

## Skills

Before writing, changing, or reviewing Elixir code, read and follow the `elixir` skill and any relevant skills below:

- `phoenix`: LiveView, components, controllers, routes, Plug, channels, and PubSub.
- `ecto`: schemas, changesets, queries, transactions, and migrations.
- `oban`: background jobs, retries, scheduling, and workflows.
- `otp`: processes, supervision, GenServer, Task, Registry, and ETS.

Load only relevant skills. State which skills you are using before making changes.

## Tool Use

- Search text with `rg`, scoped to relevant paths and file types; broaden as needed. `rg --files -g 'PATTERN'` finds files.
- Before Elixir symbol searches or broad source reads, use worktree-bound `"$TIPS_DEXTER"`. Before first use this session, read [Operations](agent/lsp/README.md#operations) and [Limits](agent/lsp/README.md#limits), plus `"$TIPS_DEXTER" query --help` and `"$TIPS_DEXTER" lookup --help`; current help governs syntax and output.
- Before changing a function's name, arity or return shape, check definition-site references and scoped text searches for its name and dynamic dispatch. Name affected callers and material downstream effects once in PR evidence.
- Empty results do not prove absence. If Dexter is unavailable or denied, report it once and use scoped source searches; do not start another language server. Compile and tests still supply compiler and runtime verification.
- Run `mix credo --strict` on edited `.ex`/`.exs` files and fix issues you introduced. Skip only if the Credo task is unavailable; report dependency and project failures.
- Go changes, including carried patches: run the [pinned lint profile](agent/lsp/dexter/patches/README.md#required-go-static-analysis). Fix findings our code introduces; report inherited ones separately.
- Report unavailable tools and failed checks. Tool checks do not replace formatting, compilation or tests.

## Writing

Applies to chat, issues, PRs, comments, commits and handoffs.

- Simple, plain English. No mannered prose. Concise and succinct. Write like the reader has ADHD. Less is more.
- Lead with the result and the next action, if any.
- State each decision or result once, then link its evidence. Do not copy the contract, the diff or earlier rounds.
- Keep what the reader needs to act or audit: revision, findings, checks you ran, relevant limits.
- Omit walkthroughs of unchanged code, routine process narration and lists of things that were fine.
- Give a finding the space it needs to be actionable.
