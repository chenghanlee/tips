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

- **ripgrep (`rg`)**: Find text in migrations, config, strings, errors, templates and docs. Use `rg --files -g 'PATTERN'` to find files. For Elixir symbols, try Dexter first. Fall back to `grep` if unavailable.
- **Dexter LSP**: Elixir navigation in provisioned coding sessions, bound to your worktree. Use it before symbol searches or broad source reads; read the source you edit and the boundaries you review. Claude calls `LSP`; either client can run `"$TIPS_DEXTER" query <operation> <file> <line> <column>`. CLI positions and compact output are 1-based UTF-16; `--raw` returns 0-based LSP JSON.

  | Task | Claude / Codex operation | Try before |
  |---|---|---|
  | Know the name, not its current position | Shell in either client: `"$TIPS_DEXTER" lookup Module [function]` | guessing positions after edits |
  | Find uses by name | Shell in either client: `"$TIPS_DEXTER" references Module [function]` | a multi-pattern symbol search |
  | Find a module or function by name | `workspaceSymbol` / `workspace-symbols <name>` | `rg 'defmodule Name'`, `rg 'def name'` |
  | Go from a call to its definition | `goToDefinition` / `definition` | grepping for the `def` |
  | Find references to a function or module | `findReferences` / `references` | `rg -F 'name('` |
  | Read docs, spec and signature | `hover` (both) | opening the file |
  | Outline a file | `documentSymbol` / `symbols <file>` | reading the file |
  | List implementations, from the `@callback` head | `goToImplementation` / `implementation` | `rg '@behaviour'`, `rg '@impl'` |
  | Find callers of a function | `incomingCalls` / `incoming-calls` | grepping for callers |
  | Find calls a function makes | `outgoingCalls` / `outgoing-calls` | reading its body |
  | Check which `Module.function/arity` a position selects | `prepareCallHierarchy` / `prepare-call-hierarchy` | |

  - After edits or checkout advancement, refresh symbols or use name lookup. Put the column on the intended name; `def`, `defp` and indentation have different columns. Check the CLI's cursor token; hierarchy also reports its selected callable/arity.
  - Find references before changing any function's name, arity or return shape, including private helpers. Incoming calls name calling tests, but at a default-argument head cover only the maximum arity; use references or query a lower-arity call too. Then cross-check the same names with scoped `rg` and source; investigate differences.
  - For Claude dependency navigation: use native hover; use the CLI for definition, references, implementation and workspace symbols into `deps/`. Native filtering can hide valid locations.
  - Results can be incomplete. Empty answers and initial index readiness prove neither absence nor freshness. A client truncation warning or an explicit limit means you have only part of the output; narrow the query or save it to a file. Navigation finds code; source inspection and tests establish correctness.
  - Dexter reports no compiler errors: run Mix compile and tests.
  - If Dexter is unavailable, report it. Do not start another language server.
  - Details: [operations](agent/lsp/README.md#operations), [limits](agent/lsp/README.md#limits).
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
