# Agent language tools

Coding sessions get one **Dexter** language server per worktree: a single Go
binary built from the pinned upstream revision plus one local patch. Claude uses
it through Claude Code's native LSP tool. Codex calls the same binary's `query`
command. Both attach to the same per-worktree daemon and the same handlers.
There is no adapter, MCP server, editor process or second index.

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
any caller directory. Each leaf worktree gets its own daemon and index, and
leaf worktrees run concurrently. A checkout that contains another checkout,
including the main Tips checkout with its linked worktrees under
`.worktrees/`, is refused. A root reached through a symlink is admitted only
under the exact spelling it was bound with. Out of this beta: an application
in a subdirectory or monorepo.

## Team provisioning

`agent/teams/task_worktree.py` writes, per worktree:

- `.dexter/dexter.sh`: `exec vendor/dexter --root <worktree> "$@"` with the
  selected sources exported. Its absolute path is `TIPS_DEXTER` in the session.
- For Claude, `.dexter/claude-plugin/`: a plugin loaded with `--plugin-dir` whose
  LSP server runs the same binary with `--root <worktree> lsp` and the
  same sources. Known alternative language-server plugins are disabled in the
  worktree settings.
- For Codex, `.codex/config.toml` with the Mix check plugins.

Provisioning then runs `dexter.sh query workspace-symbols --wait <timeout> MixProject`
and refuses to launch a client if the index does not answer. `team.py stop`
runs `dexter.sh stop` per worktree before retiring it; an attached client keeps
the daemon alive and the worktree is preserved. A daemon idles out after fifteen
minutes without clients and restarts from its index on the next request.
Do not run `git clean -x` in a team worktree: it removes the bound command and
the index under `.dexter/`.

## Operations

Positions are 1-based line and character (UTF-16). Results carry Dexter's
native LSP JSON, whose ranges are 0-based.

| Claude native LSP | Codex `"$TIPS_DEXTER" query …` |
|---|---|
| `goToDefinition` | `definition <file> <line> <column>` |
| `findReferences` | `references <file> <line> <column> [--include-declaration]` |
| `hover` | `hover <file> <line> <column>` |
| `documentSymbol` | `symbols <file>` |
| `workspaceSymbol` | `workspace-symbols [search]` |
| `goToImplementation` | `implementation <file> <line> <column>` |
| `prepareCallHierarchy` | `prepare-call-hierarchy <file> <line> <column>` |
| `incomingCalls` | `incoming-calls <file> <line> <column>` |
| `outgoingCalls` | `outgoing-calls <file> <line> <column>` |

`query` waits up to `--wait <duration>` (default 30s) for a cold index and exits
non-zero with the reason on stderr. Files are relative to the worktree. Queries
admit the bound worktree, its dependency sources and the configured Elixir
sources; a file from another checkout is refused with `does not belong to
workspace`. The stock `lookup` and `references <module>` name searches are
unchanged.

## Limits

- Freshness is not strict. The daemon watches saved files, but an empty answer
  is not proof of absence. Rerun after large checkouts or generated code.
- Claude's native tool sees the file on disk when it opens a buffer, and an
  open buffer follows later disk changes (`Edit`, `mix format`, generators,
  shell rewrites) by size and mtime. A buffer with real unsaved changes belongs
  to that session alone, so native answers can differ from `query` answers on
  the same worktree until the buffer is saved. One writer per worktree.
- Call hierarchy answers are standard LSP items and carry no reasons: a call
  the resolver cannot own is omitted without a completeness indicator. When
  completeness matters, cross-check
  `findReferences` against the `fromRanges` of `incomingCalls` and review each
  reference with no matching range by hand: it may be a call the hierarchy
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
- Admission fails closed: an unreadable directory anywhere under the worktree
  outside the usual exclusions (`deps/`, `_build/` and the like) refuses
  `query` and native startup with a permission error. Fix the permission or
  remove the directory; there is no skip option.
- Diagnostics are syntax only; use Mix compile, Credo and tests for the rest.
- Rename, code actions and formatting through Dexter are not offered.
- Correctness is bounded by the patch's recorded cases; see
  [patches/README.md](dexter/patches/README.md).
