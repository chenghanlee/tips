## Start here

Read [README.md](README.md) for setup, testing, documentation and optional agent workflows.
Follow the engineering instructions below when working on the project.

## Problem Solving

- Ask why 5–15 times to find the root problem. Stop when two more whys do not change the answer.
- Start with first principles, then use Occam's razor and the 80/20 rule to find the simplest working solution for the root problem

## Skills

Before writing, changing, or reviewing Elixir code, read and follow the `elixir` skill and any relevant skills below:

- `phoenix`: LiveView, components, controllers, routes, Plug, channels, and PubSub.
- `ecto`: schemas, changesets, queries, transactions, and migrations.
- `oban`: background jobs, retries, scheduling, and workflows.
- `otp`: processes, supervision, GenServer, Task, Registry, and ETS.

Load only relevant skills. State which skills you are using before making changes.

## Tool Use

Scope searches to relevant paths and file types; broaden as needed.

- **ripgrep (`rg`)**: Find text: names, strings, errors, config keys, and template content. Use `rg --files -g 'PATTERN'` to find files. Fall back to `grep` if unavailable.
- **ast-grep**: Find code structures: calls with specific arguments, pipelines, or expressions inside functions. Prefer it over multiline regexes. Read the `ast-grep` skill and verify patterns against known examples.
- **Dexter**: Use stock Dexter CLI for Elixir navigation. In team worktrees, run from the worktree root (`function` is optional):

  ```sh
  "$TIPS_ELIXIR_TOOLS/bin/dexter" --root "$PWD" lookup --strict --wait 30s Module function
  "$TIPS_ELIXIR_TOOLS/bin/dexter" --root "$PWD" references --wait 30s Module function
  ```

  Direct sessions use the installed absolute binary path. Resolve module/function names from source; arguments do not select arity or resolve a call-site expression. Inspect returned source before editing. Empty and non-empty results may be incomplete, including during indexing; delegated, generated and dynamic callers may be missed. Lookup follows `defdelegate`; use `--no-follow-delegates` to locate the wrapper. Compilation/tests are independent checks, not proof of navigation completeness. Claude does not use the LSP tool for Elixir. See the [Dexter guide](agent/lsp/README.md) for setup and recovery.
- **mix-credo**: Run `mix credo --strict` on any edited `.ex`/`.exs` files and fix issues you introduced. Skip only if the Credo task is unavailable; report dependency and project failures.

Report unavailable tools and failed checks; use appropriate fallbacks. Failed searches do not establish that no matches exist. LSP and Credo checks do not replace formatting, compilation, or tests.

## Software Design

- Use Elixir and Phoenix Framework idioms, standards, and conventions.
- Use proven architecture, standards, and conventions from widely used software similar to the
project that the user is building.
- Strive for simple working and elegant solutions. Elegant solutions make complex things seem easy
and obvious. Choose simplicity over elegance when they conflict.
- Build an MVP for fast iteration and finding product-market fit. Avoid unnecessary enterprise complexity. No backwards compatibility.
- Only accept necessary complexity when it makes the user's experience simpler. Don't make the implementation look simple by pushing its complexity onto the user. Apply this principle across the software architecture, backend, data model, and frontend.
- "Perfection is achieved, not when there is nothing more to add, but when there is nothing left to take away"

## Testing

- Follow the testing trophy, integration first. TDD means writing the failing ExUnit integration test for the acceptance scenario before the code.
- Unit tests only for pure logic with wide blast radius. End-to-end tests only at milestone gates.

## Code Review and Software Architecture Review

- First, check for immediate, local correctness
- Second, assess each review and its proposed fix's direct and downstream effects on its own and related modules, features, or tests.
- Lastly, assess each review and its proposed fix's against the project's software design and implementation as a whole and end to end.

## Writing

- Use plain English. Be direct and concise. Don't use mannered prose.

## Responses to the User

- Write response for a user with ADHD.
