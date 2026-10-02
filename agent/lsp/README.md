# Agent language tools

Coding sessions get one **Dexter** language server per worktree: a single Go
binary built from the pinned upstream revision plus one local patch. Claude and
Codex both run its bound command, `"$TIPS_DEXTER"`, from their shell tool and
attach to the same per-worktree daemon. There is one interface and one index:
no editor client, plugin, adapter or MCP server.

This is a read-only beta. Rename and other edits are not offered.

## Build

Requires Go 1.26.3 and Git. `build.sh` needs a Git repository that contains the
pinned upstream commit; its checkout is not read:

```sh
git clone https://github.com/remoteoss/dexter tmp/dexter-upstream
bash agent/lsp/dexter/build.sh tmp/dexter-upstream
```

The script exports the pin, applies `dexter/patches/dexter-go.patch` in a
temporary copy, builds `dexter/vendor/dexter` and writes `dexter/vendor/build.json`
with the pin, patch checksum, binary checksum and the local build id. The id is
the SHA-256 of the pin and patch checksum and is linked into the binary:

```sh
agent/lsp/dexter/vendor/dexter version   # 0.7.2, then: local_build_id <id>
```

A daemon and a client with different ids refuse each other and nothing replaces
the running daemon. Before rebuilding over active teams, stop each worktree's
daemon with its bound command, build, then re-provision.
The build refuses to replace a binary used by a running daemon and aborts if
it cannot inspect processes. Keep agents stopped until the build finishes.

`--keep <dir>` leaves the prepared source in place for `go test ./...`.
[patches/README.md](dexter/patches/README.md) records what the patch changes and
the Go static-analysis rule for it.

## Elixir sources

Dexter indexes the Elixir standard library from source. Put the release matching
`elixir --short-version` in the main checkout's ignored `agent/lsp/vendor/elixir-<version>/`
(from the [Elixir repository](https://github.com/elixir-lang/elixir); the tree
holds `VERSION` and `lib/elixir/lib/enum.ex`), or point `DEXTER_ELIXIR_LIB_ROOT`
at another checkout's `lib/`. A Homebrew installation has no sources. Provisioning
refuses to start unless the tree's `VERSION` matches the worktree's toolchain.

## Bound checkout

`--root` must be the exact checkout Dexter serves: a directory holding `.git`
or `mix.exs`, never one with only a `.dexter/` index. The command works from
any caller directory. Each worktree gets its own daemon and index, and
worktrees run concurrently. Nested checkouts, including scratch clones and
linked worktrees under `.worktrees/`, are excluded from the parent's index
and watcher. Dependency sources under `deps/` remain available. A root reached
through a symlink is admitted only under the exact spelling it was bound with.
Out of this beta: an application in a subdirectory or monorepo.

## Team provisioning

`agent/teams/task_worktree.py` writes, per worktree:

- `.dexter/dexter.sh`: `exec vendor/dexter --root <worktree> "$@"` with the
  selected sources exported. Its absolute path is `TIPS_DEXTER` in the session.
- For Codex, `.codex/config.toml` with automatic compilation disabled and Credo enabled.

Claude's launch settings disable automatic compilation and known
language-server plugins, including in linked worktrees.

Provisioning then runs three steps in the worktree, with the role's environment.
Any failure stops the launch:

1. `mix deps.get --check-locked`, for a new checkout and for a review head.
   Dexter indexes dependency sources from disk and does not watch `deps/`, so
   they must exist first. A fetch that would rewrite `mix.lock` fails;
   provisioning never changes a lock. A resumed developer worktree skips this
   step: it may hold an unfinished dependency change, and its agent must be
   able to start to finish it.
2. `dexter.sh query workspace-symbols --raw --wait <timeout> MixProject`. It
   starts the daemon and refuses a client if the index does not answer.
3. `dexter.sh reindex`. A daemon that was already running indexed the checkout
   before the fetch; this reconciles it with the disk.

The same steps run when a reviewer's checkout is advanced in place, and again
when the same review head is requested for a running reviewer. An agent
that fetches or changes dependencies later runs `"$TIPS_DEXTER" reindex` itself.

`team.py stop` runs `dexter.sh stop` per worktree before retiring it; an
attached client keeps the daemon alive and the worktree is preserved. A daemon
idles out after fifteen minutes without clients and restarts from its index on
the next request. Do not run `git clean -x` in a team worktree: it removes the
bound command and the index under `.dexter/`.

The daemon belongs to the worktree, not to a client. A `query` that starts the
daemon is its parent until that query ends, and `team.py` refuses to stop a
client while one of its descendants survives. So a client stopped during a cold
start, for example on the first query after the daemon idled out, is refused
and everything is preserved. Wait for the query to end (within `--wait` plus
30 seconds), then run the stop again: the daemon is then nobody's child and
still serves the worktree. Do not use `dexter.sh stop` to hurry this: it
refuses while the query is attached, and retirement runs it anyway.

## Operations

`"$TIPS_DEXTER" query --help` and `"$TIPS_DEXTER" lookup --help` are the
contract for syntax, output, caps and exit status. Every checkout shares one
binary, so its help describes what you are running; this guide and
[AGENTS.md](../../AGENTS.md#tool-use) give the workflow. Where they differ, the
help is right.

- `query <operation> <file> <line> <column>`: the nine read-only operations.
  AGENTS.md lists which one answers which question.
- `lookup Module [function]`: the definition's file and line, by name.
- `reindex [file|path]`: reconcile the index with the disk.

There is no reference search by name: it missed uses that the positional search
finds. Take the definition's line from `lookup` and the name's column from
`query symbols`, then run `query references` there.

Queries admit the bound worktree, its dependency sources and the configured
Elixir sources; a file from another checkout is refused with `does not belong
to workspace`. Do not start another language server.

## Limits

- Freshness is not strict. The daemon watches saved files, but an empty answer
  is not proof of absence. Rerun after large checkouts or generated code.
- Index scope: the worktree, its `deps/` and the configured Elixir sources. The
  root's `tmp/` directory and nested checkouts are left out, so scratch copies
  of application modules never answer for the application. Index-based
  discovery (`workspace-symbols`, `lookup`, `references`, call hierarchy)
  therefore finds nothing in reviewer scratch tests under `tmp/`; search them
  with `rg`. A query on a scratch file itself, such as `symbols`, still reads
  it. Configured Elixir sources are indexed even when they lie under `tmp/`,
  but not watched there: run `reindex` after changing them.
- File-backed navigation uses saved disk text.
  Cached files follow later disk changes
  (`Edit`, `mix format`, generators, shell rewrites) by size and mtime.
  Save before navigating; unsaved editor buffers are not supported.
  One writer per worktree.
- Call hierarchy selects one callable identity, `Module.function/arity`. A
  definition with default arguments prepares its maximum arity; prepare at a
  lower-arity call to inspect that callable's incoming calls. The hierarchy
  follows written source calls, not generated runtime wrapper edges.
  References at a default-argument head may cover multiple arities: compare
  them with incoming calls only at the same selected arity.
- Call hierarchy answers are standard LSP items and carry no reasons: a call
  the resolver cannot own is omitted without a completeness indicator. When
  completeness matters, cross-check
  `references` against the sites of `incoming-calls` and review each
  reference with no matching site by hand: it may be a call the hierarchy
  left out, or a reference the heuristic over-counted (injected defs). A
  function reached only through a `use` chain with no indexed row can be
  missing from both.
  Omitted on purpose:
  - incoming: calls in typespecs, quote bodies and defs inside `quote`, files
    that do not parse cleanly, top-level and module-body calls, test labels
    built by interpolation, modules named by a variable, heads named by
    `unquote`;
  - outgoing: Erlang module calls (`:ets`, `:crypto`), anonymous calls
    (`fun.()`), field access, operators and language forms (`if`, `case`).
  Text that moved since the index was built is re-checked and dropped when the
  occurrence no longer matches.
- A known generated export can resolve to its module declaration when its
  function source location cannot be resolved. This is a module anchor, not the function
  body. Hierarchy items retain the callable identity and select the real module
  token within its declaration. Dexter does not reconstruct arbitrary
  compile-time macro expansion.
  Function hover follows available `use`-injected source before compiled metadata;
  an unresolved function returns no hover instead of its module's documentation.
  Function docs are read from string, heredoc and sigil literals, including
  `~S'''`; a computed doc expression is not evaluated.
- Implementation lookup starts at the selected `@callback` head and uses its
  exact arity, including zero-arity forms such as `@callback type :: t` and
  `@callback type() :: t`. Ordinary function heads and call sites return no
  implementations, even when a callback shares the name.
- Implementation results are indexed public `def`/`defdelegate` source
  definitions with the selected name and arity. Direct behaviour declarations,
  simple `use` wrappers and Phoenix-style atom dispatch are supported. Only
  the selected wrapper branch is followed; a controller or component branch
  does not inherit a sibling `live_view` branch's callbacks.
- Wrapper membership is an approximation: a selected `use` chain reaching the
  queried behaviour's callback is treated as adoption. It can include a module
  whose provider declares the callback but injects no `@behaviour`, including
  an unknown dispatch atom passed directly to that provider. Error frequency
  has not been measured; implementation lists are not guaranteed complete.
- Implementation lookup can omit behaviour/use directives inside block
  conditionals, such as `if Code.ensure_loaded?(Plug) do ... end`. An
  `@behaviour` inside inline `do:` syntax is not excluded and may be counted
  even when it is not adopted. Arbitrary macro expansion, generated-only
  implementations, macrocallback implementation matching and general
  `defprotocol`/`defimpl` traversal are outside this beta's supported scope.
- Diagnostics are syntax only; use Mix compile, Credo and tests for the rest.
- Rename, code actions and formatting through Dexter are not offered.
- Correctness is bounded by the patch's recorded cases; see
  [patches/README.md](dexter/patches/README.md).
