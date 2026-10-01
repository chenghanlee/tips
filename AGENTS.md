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
- **Dexter LSP**: In provisioned coding sessions, Claude uses the native `LSP` tool and Codex runs `"$TIPS_DEXTER" query <operation> <file> <line> <column>`; both are Dexter bound to the worktree. Read [the operations table](agent/lsp/README.md#operations). Positions are 1-based. Prefer LSP for symbol resolution. Freshness is unverified; do not interpret an empty answer as proven absence. Use normal Mix compile/tests for compiler diagnostics. Report an unavailable tool rather than starting an alternate language server. For these navigation tasks, try the operation first (Claude name / Codex name), before text search or reading whole files:
  - Find a module or function by name: `workspaceSymbol` / `workspace-symbols`, before `rg 'defmodule Name'` or `rg 'def name'`.
  - Go from a call to its definition: `goToDefinition` / `definition`, before grepping for the `def`.
  - Find indexed references to a function or module: `findReferences` / `references`, before `rg -F 'name('`. Run it before changing a name, arity or return shape.
  - Read a function's docs, spec and signature: `hover`, before opening its file.
  - Outline a file's modules and functions: `documentSymbol` / `symbols`, before reading the file.
  - List a behaviour callback's implementations, starting at its `@callback`: `goToImplementation` / `implementation`, before `rg '@behaviour'` or `rg '@impl'`.
  - Find what calls a function: `incomingCalls` / `incoming-calls`, before grepping callers and reading each one.
  - Find what a function calls: `outgoingCalls` / `outgoing-calls`, before reading its body.
  - Check which `Module.function/arity` a position selects for those two: `prepareCallHierarchy` / `prepare-call-hierarchy`.
  - Search by name with no file position, from either client's shell: `"$TIPS_DEXTER" lookup Module [function]` for the definition and `"$TIPS_DEXTER" references Module [function]` for its uses.

  Results can leave out real references and calls, even on a fresh index: see [the limits](agent/lsp/README.md#limits). When completeness matters, cross-check with `rg` and the source. Keep `rg` for text Dexter does not index: strings, comments, config keys and templates.
- **mix-credo**: Run `mix credo --strict` on any edited `.ex`/`.exs` files and fix issues you introduced. Skip only if the Credo task is unavailable; report dependency and project failures.

- **Go static analysis**: For every Go change, including carried upstream patches, run the same custom golangci-lint profile as `tiny_big_agents`, including Staticcheck and NilAway. Use the [pinned Dexter profile and instructions](agent/lsp/dexter/patches/README.md#required-go-static-analysis) for Dexter. Keep checks and thresholds enabled; compare with the unchanged baseline, fix findings introduced by our code, and report inherited findings separately. Do not refactor unrelated upstream code to clear its lint debt.

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
