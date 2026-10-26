# Elixir navigation

`"$TIPS_DEXTER"` answers from an index of this worktree's Elixir files, its `deps/` and the Elixir sources; root `tmp/` is outside the index. [Pair provisioning](../lsp/README.md#pair-provisioning) sets the variable. Commands are in the [Dexter reference](../skills/dexter/SKILL.md).

| Need | Use |
|---|---|
| Outline an indexed file whose structure you do not know | Dexter `symbols` |
| Where a module or function is defined | Dexter `lookup`; `workspace-symbols` for a partial name; `definition` from a call site |
| Docs, spec or signature | Dexter `hover` |
| Uses of a module or function; its callers; the calls it makes | Dexter `references`; `incoming-calls`; `outgoing-calls`. `prepare-call-hierarchy` confirms the function and arity a position selects |
| Implementations of a callback | Dexter `implementation` |
| Known lines, including lines Dexter returned | `sed -n` or the client's read tool; no outline first |
| Literal text: strings, messages, config keys, comments, atoms | Scoped `rg` or `grep` |
| Anything in a non-Elixir file or outside the index | Scoped `rg` or `grep` |
| File names | `rg --files` |

- For the Dexter rows, a text match does not replace Dexter's answer. If `$TIPS_DEXTER` is unset or fails, report that once, with any error, and use scoped `rg`.
- Before changing a public or private function's name, arity, return shape or behaviour, find its uses with both Dexter `references` at its definition and scoped `rg` for its bare name and any atom or tuple that dispatches to it. Investigate every use that only one of them found.
- An empty Dexter result does not prove absence: dynamic dispatch, macros and generated code hide uses. Check with `rg` before concluding that a function is unused.
- After `mix deps.get` or a dependency change, run `"$TIPS_DEXTER" reindex`.

## Bounded reading

For an application file of unknown length, check its line count (`wc -l`). Above 300
lines, run `symbols` and read definition ranges with `sed -n`; find a non-definition
line (attribute, alias, struct, `use`) with scoped `rg -n` and read around it. Read the
whole file only once, when a named question needs it. Refresh symbol positions after an
edit. For a file in `deps/`, never read the whole file: use `definition` from a call site
or `lookup Module function --strict`, and read only the returned range. If Dexter is
unavailable, report it once and use scoped `rg` and ranges, not a whole-file fallback.
