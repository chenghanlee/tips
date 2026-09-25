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
- **ast-grep**: Find code structures: calls with specific arguments, pipelines, or expressions inside functions. Prefer it over multiline regexes. Read the `ast-grep` skill and verify patterns against known examples. Use LSP for symbol resolution.
- **elixir-lsp (Expert)**: Use `definition(filePath, line, column)` at a call site for implementations (1-based positions; UTF-16 columns), `references(filePath, line, column)` at an application call site for usages before API changes, `hover` for docs and types, and `diagnostics` for compiler feedback on changed `.ex`, `.exs`, `.heex`, and `.leex` files. Prefer LSP over text search when resolving symbols.
- **mix-credo**: Run `mix credo --strict` on any edited `.ex`/`.exs` files and fix issues you introduced. Skip only if the Credo task is unavailable; report dependency and project failures.
- **Compile check**: After your last edit, run `MIX_ENV=test timeout --foreground -k 5 90 mix compile --force --warnings-as-errors` exactly, as its own command, without `unbuffer` (this command only; see agent/lsp/experiments/codex-elixirls-v2/INSTALL.md) and wait for its exit code: GNU `timeout` bounds it; if your tool has its own command timeout, set it to at least 120 s (Claude Code Bash); a `session_id` instead of an exit code (Codex `exec_command`, `tty` off) means it is still running, so wait with `write_stdin` (empty input) on that `session_id` and edit nothing meanwhile. Exit 0 passes only if nothing was written during or after it and it was not interrupted, backgrounded or timed out; 1 is an error or warning; anything else is unfinished, so rerun. Incremental `mix compile` can miss same-second edits.

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
