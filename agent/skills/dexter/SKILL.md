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

Help governs syntax, output, limits and exit status. Run only `lookup`, `query` and `reindex`; never `init`, `lsp` or `stop`.

If Dexter is missing, unavailable or denied, report the exact error once and use scoped `rg`. Do not start another language server.

## Operations

`Q` = `"$TIPS_DEXTER" query`. `<pos>` = `<file> <line> <column>`, 1-based UTF-16, path relative to the bound worktree.

| Goal | Run |
|---|---|
| Outline a file: names, lines, columns | `Q symbols <file>` |
| Find a function by name | `"$TIPS_DEXTER" lookup Module function --strict` |
| Find a module by name | `"$TIPS_DEXTER" lookup Module` |
| Find by partial name | `Q workspace-symbols <search>` |
| Go from a call to its definition | `Q definition <pos>` |
| Read docs, spec, signature | `Q hover <pos>` |
| Find uses (add `--include-declaration` for the definition too) | `Q references <pos>` at the definition |
| Find callers | `Q incoming-calls <pos>` |
| List the calls a function makes | `Q outgoing-calls <pos>` |
| Confirm the `Module.function/arity` at a position | `Q prepare-call-hierarchy <pos>` |
| Find implementations of a callback | `Q implementation <pos>` at the `@callback` head |

## Positions

1. `lookup Module function --strict`. Without `--strict`, a missing function returns the module's line and exits 0.
2. `Q symbols <file>`: take line and column from the row with the name and arity you want.
3. Run the positional query. Read `cursor:` first; it names the selected token. If it is not your name, fix the position and rerun.
4. For call hierarchy, check `selected:` shows your callable and arity. A default-argument head selects only the maximum arity.
5. Take positions again after an edit or checkout change.

## Before changing a name, arity or return shape

Private helpers included.

1. `references` at the definition.
2. Scoped `rg` for the bare name and any atom or tuple that dispatches to it.
3. Investigate each difference. Source and tests establish the impact.

## Limits

- Zero rows does not mean unused. An empty result exits 0.
- Dynamic dispatch (`schema.changeset(...)`, `apply`, MFA tuples), macros and generated code can hide uses. Some `use` wrappers and atom dispatch resolve. Assume neither completeness nor absence.
- Call hierarchy silently omits calls it cannot resolve. It does not replace `references`.
- `--limit 0` lifts the row limit, except `workspace-symbols` stops at 50: narrow the search. If the tool client cuts output, narrow the query or save it to a file.
- Index discovery excludes root `tmp/` and nested checkouts, except configured Elixir sources. `symbols` reads scratch files in the bound worktree. Files in another checkout are refused.
- Dexter reads saved files, returns no function bodies and reports no compiler errors. Run Mix compile, Credo and tests.
- For completeness of call hierarchy or `implementation`, read the
  Limits section in `agent/lsp/README.md` from the repository root.

## Reindex

The daemon watches saved files; normal edits need none. Run `"$TIPS_DEXTER" reindex` after:

- you run `mix deps.get` or change a dependency;
- you change the configured Elixir sources;
- an answer misses something you saved or shows something you deleted (`reindex <file>`, then rerun).
