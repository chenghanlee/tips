---
name: dexter
description: Use the Dexter Elixir language server CLI for source navigation. Covers commands, source positions, result limits and reindexing.
---

# Dexter

Dexter is a read-only Elixir language server CLI. Use `"$TIPS_DEXTER"` to query
the server bound to this worktree.

[AGENTS.md](../../../AGENTS.md) defines when to use Dexter. This skill defines
how to run its commands and interpret results.

## Before the first query in a session

```bash
"$TIPS_DEXTER" query --help
"$TIPS_DEXTER" lookup --help
```

Read the help for syntax, output, limits and exit status.

- Run only `lookup`, `query` and `reindex`. Never run `init`, `lsp` or `stop`.
- If Dexter is missing, unavailable or denied, report the exact error once and
  use scoped `rg`. Do not start another language server.

## Operations

`<pos>` means `<file> <line> <column>`:

- Use a file path relative to the bound worktree.
- Lines and columns are 1-based. Columns use UTF-16 code units.

| Goal | Run |
|---|---|
| Outline a file: names, lines, columns | `"$TIPS_DEXTER" query symbols <file>` |
| Find a function by name | `"$TIPS_DEXTER" lookup Module function --strict` |
| Find a module by name | `"$TIPS_DEXTER" lookup Module` |
| Find by partial name | `"$TIPS_DEXTER" query workspace-symbols <search>` |
| Go from a call to its definition | `"$TIPS_DEXTER" query definition <pos>` |
| Read docs, spec, signature | `"$TIPS_DEXTER" query hover <pos>` |
| Find uses | `"$TIPS_DEXTER" query references <pos>` at the definition; add `--include-declaration` to include the definition |
| Find callers | `"$TIPS_DEXTER" query incoming-calls <pos>` |
| List the calls a function makes | `"$TIPS_DEXTER" query outgoing-calls <pos>` |
| Confirm the `Module.function/arity` at a position | `"$TIPS_DEXTER" query prepare-call-hierarchy <pos>` |
| Find implementations of a callback | `"$TIPS_DEXTER" query implementation <pos>` at the `@callback` head |

## Positions

1. If the definition's file or line is unknown, run
   `"$TIPS_DEXTER" lookup Module function --strict`. Without `--strict`, a missing
   function returns the module's line and exits 0.
2. If the column in the saved file is unknown, run
   `"$TIPS_DEXTER" query symbols <file>`. Use the line and column for the required
   name and arity. Skip this step if you already have the current position.
3. Run the positional query. Read `cursor:` first to confirm the selected token.
   If it names a different token, correct the position and rerun.
4. For call hierarchy, confirm that `selected:` shows the required callable and
   arity. A default-argument head selects only the maximum arity.
5. Refresh positions after an edit or checkout change.

## Limits

### Incomplete results

- An empty result exits 0. It does not prove that a function is unused.
- Dynamic dispatch (`schema.changeset(...)`, `apply`, MFA tuples), macros and
  generated code can hide uses. Some `use` wrappers and atom dispatch resolve,
  but results may be incomplete.
- Call hierarchy omits unresolved calls without reporting them. It does not
  replace `references`.
- For call hierarchy and `implementation` completeness, read the Limits section
  in the [LSP guide](../../lsp/README.md).

### Output and file scope

- `--limit 0` removes the row limit except for `workspace-symbols`, which stops at
  50 rows. Narrow the search when it reaches that limit.
- If the tool client truncates output, narrow the query or save output to a file.
- Index discovery excludes root `tmp/` and nested checkouts, except configured
  Elixir sources. `symbols` can read scratch files in the bound worktree.
  Dexter refuses files in another checkout.
- Dexter reads saved files. It returns no function bodies and reports no compiler
  errors. Run Mix compile, Credo and tests.

## Reindex

The daemon watches saved files. Normal edits do not require reindexing.

| Condition | Action |
|---|---|
| After `mix deps.get` or a dependency change | Run `"$TIPS_DEXTER" reindex`. |
| After changing configured Elixir sources | Run `"$TIPS_DEXTER" reindex`. |
| A result omits saved content or includes deleted content | Run `"$TIPS_DEXTER" reindex <file>`, then rerun the query. |
