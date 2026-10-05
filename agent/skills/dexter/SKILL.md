---
name: dexter
description: Load before reading, searching, writing, changing or reviewing Elixir code. Use Dexter LSP first for source navigation with any tool.
---

# Dexter

Read-only Elixir language server CLI, bound to this worktree as `"$TIPS_DEXTER"`.

## Before text tools

Before using shell tools (`rg`, `grep`, `sed`, `cat`), native Read/Grep tools
or a whole-file read for an Elixir
navigation goal in the table below, use its matching Dexter operation first.
This applies to Codex and Claude. Reuse an answer while the file and checkout
are unchanged; then read only the source range you need.

- Adding a function to an existing module counts: outline that module first.
- Literal text, non-Elixir files, filename discovery and dynamic-dispatch
  cross-checks can use scoped text tools directly.
- Index-based searches outside Dexter's index use scoped text tools; `symbols`
  can still outline a scratch file in the bound worktree.
- Reading `--help` is setup, not navigation.

## Setup, once per session

```bash
"$TIPS_DEXTER" query --help
"$TIPS_DEXTER" lookup --help
```

Help governs syntax, output, limits and exit status. Run only `lookup`, `query` and `reindex`; never `init`, `lsp` or `stop`.

If Dexter is missing, unavailable or denied, report the exact error once and use scoped `rg`. Do not start another language server.

## Operations

`Q` = `"$TIPS_DEXTER" query`. `<pos>` = `<file> <line> <column>`, 1-based UTF-16, path relative to the bound worktree.

| Goal | Run | Use before |
|---|---|---|
| Outline a file: names, lines, columns | `Q symbols <file>` | `cat`, `sed`, whole-file read |
| Find a function by name | `"$TIPS_DEXTER" lookup Module function --strict` | `rg 'def name'` |
| Find a module by name | `"$TIPS_DEXTER" lookup Module` | `rg 'defmodule'` |
| Find by partial name | `Q workspace-symbols <search>` | `rg` for the name |
| Go from a call to its definition | `Q definition <pos>` | grepping for the `def` |
| Read docs, spec, signature | `Q hover <pos>` | opening the file |
| Find uses (add `--include-declaration` for the definition too) | `Q references <pos>` at the definition | `rg -F 'name('` |
| Find callers | `Q incoming-calls <pos>` | grepping for callers |
| List the calls a function makes | `Q outgoing-calls <pos>` | scanning its body |
| Confirm the `Module.function/arity` at a position | `Q prepare-call-hierarchy <pos>` | guessing the arity |
| Find implementations of a callback | `Q implementation <pos>` at the `@callback` head | `rg '@behaviour'`, `rg '@impl'` |

## Positions

1. `lookup Module function --strict`. Without `--strict`, a missing function returns the module's line and exits 0.
2. `Q symbols <file>`: take line and column from the row with the name and arity you want.
3. Run the positional query. Read `cursor:` first; it names the selected token. If it is not your name, fix the position and rerun.
4. For call hierarchy, check `selected:` shows your callable and arity. A default-argument head selects only the maximum arity.
5. Take positions again after an edit or checkout change.

One line down can give `cursor: review`, a variable, instead of `cursor: changeset`, the function.

## Before changing a name, arity or return shape

Private helpers included.

1. `references` at the definition.
2. Scoped `rg` for the bare name and any atom or tuple that dispatches to it.
3. Investigate each difference. Source and tests establish the impact.

## After Dexter

- Read the smallest source range you need. Dexter returns no function bodies.
- Use `rg` for literal text, dynamic dispatch, non-Elixir files and files outside the index.

## Limits

- Zero rows does not mean unused. An empty result exits 0.
- Dynamic dispatch (`schema.changeset(...)`, `apply`, MFA tuples), macros and generated code can hide uses. Some `use` wrappers and atom dispatch resolve. Assume neither completeness nor absence.
- Call hierarchy silently omits calls it cannot resolve. It does not replace `references`.
- `--limit 0` lifts the row limit, except `workspace-symbols` stops at 50: narrow the search. If the tool client cuts output, narrow the query or save it to a file.
- Index discovery excludes root `tmp/` and nested checkouts, except configured Elixir sources. `symbols` reads scratch files in the bound worktree. Files in another checkout are refused.
- Dexter reads saved files and reports no compiler errors. Run Mix compile, Credo and tests.
- For completeness of call hierarchy or `implementation`, read the
  Limits section in `agent/lsp/README.md` from the repository root.

## Reindex

The daemon watches saved files; normal edits need none. Run `"$TIPS_DEXTER" reindex` after:

- you run `mix deps.get` or change a dependency;
- you change the configured Elixir sources;
- an answer misses something you saved or shows something you deleted (`reindex <file>`, then rerun).
