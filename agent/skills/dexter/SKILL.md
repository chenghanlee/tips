---
name: dexter
description: Command reference for the Dexter Elixir language server CLI. Operations, positions, limits and reindexing for source navigation.
---

# Dexter

Read-only Elixir language server CLI, bound to this worktree as `"$TIPS_DEXTER"`.

AGENTS.md says when to use it; this is the command reference.

## Setup, once per session

```bash
"$TIPS_DEXTER" query --help
"$TIPS_DEXTER" lookup --help
```

Use the help for syntax, output, limits and exit status. Run only `lookup`, `query` and `reindex`; never `init`, `lsp` or `stop`.

If Dexter is missing, unavailable or denied, report the exact error once and use scoped `rg`. Do not start another language server.

## Operations

`<pos>` = `<file> <line> <column>`, 1-based UTF-16, path relative to the bound worktree.

| Goal | Run |
|---|---|
| Outline a file: names, lines, columns | `"$TIPS_DEXTER" query symbols <file>` |
| Find a function by name | `"$TIPS_DEXTER" lookup Module function --strict` |
| Find a module by name | `"$TIPS_DEXTER" lookup Module` |
| Find by partial name | `"$TIPS_DEXTER" query workspace-symbols <search>` |
| Go from a call to its definition | `"$TIPS_DEXTER" query definition <pos>` |
| Read docs, spec, signature | `"$TIPS_DEXTER" query hover <pos>` |
| Find uses (add `--include-declaration` for the definition too) | `"$TIPS_DEXTER" query references <pos>` at the definition |
| Find callers | `"$TIPS_DEXTER" query incoming-calls <pos>` |
| List the calls a function makes | `"$TIPS_DEXTER" query outgoing-calls <pos>` |
| Confirm the `Module.function/arity` at a position | `"$TIPS_DEXTER" query prepare-call-hierarchy <pos>` |
| Find implementations of a callback | `"$TIPS_DEXTER" query implementation <pos>` at the `@callback` head |

## Positions

1. If the definition's file or line is unknown: `"$TIPS_DEXTER" lookup Module function --strict`. Without `--strict`, a missing function returns the module's line and exits 0.
2. If its column in the saved file is unknown: `"$TIPS_DEXTER" query symbols <file>`, then take the line and column from the row with the name and arity you want. If you already have the current position, go to step 3.
3. Run the positional query. Read `cursor:` first; it names the selected token. If it is not your name, fix the position and rerun.
4. For call hierarchy, check `selected:` shows your callable and arity. A default-argument head selects only the maximum arity.
5. Get positions again after an edit or checkout change.

## Limits

- Zero rows does not mean unused. An empty result exits 0.
- Dynamic dispatch (`schema.changeset(...)`, `apply`, MFA tuples), macros and generated code can hide uses. Some `use` wrappers and atom dispatch resolve. Results may be incomplete.
- Call hierarchy silently omits calls it cannot resolve. It does not replace `references`.
- `--limit 0` lifts the row limit, except `workspace-symbols` stops at 50: narrow the search. If the tool client cuts output, narrow the query or save it to a file.
- Index discovery excludes root `tmp/` and nested checkouts, except configured Elixir sources. `symbols` reads scratch files in the bound worktree. Files in another checkout are refused.
- Dexter reads saved files, returns no function bodies and reports no compiler errors. Run Mix compile, Credo and tests.
- For completeness of call hierarchy or `implementation`, read the
  Limits section in `agent/lsp/README.md` from the repository root.

## Reindex

The daemon watches saved files; normal edits do not need reindexing. Run `"$TIPS_DEXTER" reindex` after:

- you run `mix deps.get` or change a dependency;
- you change the configured Elixir sources;
- an answer misses something you saved or shows something you deleted (`reindex <file>`, then rerun).
