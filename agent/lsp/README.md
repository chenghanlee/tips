# Agent language tools

Each checkout uses one **Dexter** language server: a Go
binary built from the pinned upstream revision plus one local patch. Claude and
Codex both run its bound command, `"$TIPS_DEXTER"`, from their shell tool and
attach to the same per-checkout daemon. There is one interface and one index:
no editor client, plugin, adapter or MCP server.

This beta is read-only. It does not support renaming or other edits.

## Operations

Follow the [AGENTS.md](../../agent/docs/elixir-navigation.md) Elixir navigation table and its
use check. The [Dexter reference](../skills/dexter/SKILL.md) gives commands and
position handling. If this guide differs from `"$TIPS_DEXTER" query --help` or
`"$TIPS_DEXTER" lookup --help` on syntax, output, limits or exit status, follow the help.

- Zero rows never means unused. `use Module, :atom`, MFA tuples, `apply` and
  generated code may have no indexed use.
- Call hierarchy explains candidates and does not replace `references`. It
  covers every clause of the selected callable; at a default-argument head,
  only the maximum arity.
- A client truncation warning or an explicit limit means you have only part of
  the output; narrow the query or save it to a file.
- `"$TIPS_DEXTER" reindex [file|path]` reconciles the index with the disk. Run
  it after fetching or changing dependencies.
- Dexter reports no compiler errors: run Mix compile and tests.
- If Dexter is unavailable, report it. Do not start another language server.

There is no reference search by name: it missed uses that the positional search
finds. Take the definition's line from `lookup` and the name's column from
`query symbols`, then run `query references` there.

Queries accept files in the bound checkout, its dependency sources and the configured
Elixir sources; a file from another checkout is refused with `does not belong
to workspace`. Do not start another language server.

## Limits

- Freshness is not strict. The daemon watches saved files, but an empty answer
  is not proof of absence. Rerun after large checkouts or generated code.
- Index scope: the checkout, its `deps/` and the configured Elixir sources. The
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
  One writer per checkout.
- Call hierarchy selects one callable identity, `Module.function/arity`. A
  definition with default arguments prepares its maximum arity; prepare at a
  lower-arity call to inspect that callable's incoming calls. The hierarchy
  follows written source calls, not generated runtime wrapper edges.
  References at a default-argument head may cover multiple arities: compare
  them with incoming calls only at the same selected arity.
- Call hierarchy answers are standard LSP items. They omit calls that cannot
  be resolved, without explaining omissions or indicating completeness. When
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
  function source location cannot be resolved. This points to the module, not the function
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

## Bound checkout

`--root` must be the exact checkout Dexter serves: a directory holding `.git`
or `mix.exs`, never one with only a `.dexter/` index. The command works from
any caller directory. Each checkout gets its own daemon and index, and
checkouts run concurrently. Nested checkouts, including scratch clones and
linked worktrees under `.worktrees/`, are excluded from the parent's index
and watcher. Dependency sources under `deps/` remain available. A root reached
through a symlink is admitted only under the exact spelling it was bound with.
This beta does not support an application in a subdirectory or monorepo.

## Pair provisioning

Each launched client runs `python3 <harness>/bootstrap.py` in its own allocation
([allocations](../teams/README.md#allocations)). It writes, in its own clone, at
git-ignored paths:

- `.dexter/dexter.sh`: `exec <shared vendor/dexter> --root <clone> "$@"` with the
  selected sources exported. Its absolute path is `TIPS_DEXTER` in the session.
- `.agents/skills`: a link to the main checkout's shared skills.

Then it runs three steps in the clone. Any failure blocks the client with its error:

1. `mix deps.get --check-locked`, unless a fetch for the clone's current
   `mix.lock` already succeeded; a failed fetch or a new lock fetches again. A
   fetch that would change `mix.lock` fails.
2. `dexter.sh query workspace-symbols --raw --wait <timeout> MixProject` starts
   the daemon and checks that its index answers.
3. `dexter.sh reindex` reconciles the index with the disk.

Each client has its own clone, daemon and index. After a later dependency change,
follow [Reindex](../skills/dexter/SKILL.md#reindex).

`team.py stop` stops each clone's daemon with the Dexter binary and sources recorded in
the allocation's `bootstrap.json`, not with the clone's wrapper, and retains the clone.
A daemon idles out after fifteen minutes without clients and restarts from its index
on the next request. Do not run `git clean -x` in a clone: it removes the bound
command and the index under `.dexter/`.

The daemon belongs to the clone, not to a client. A `query` that starts the
daemon is its parent until that query ends, and `team.py` refuses to stop a
client while one of its descendants survives. So a client stopped during a cold
start, for example on the first query after the daemon idled out, is refused
and everything is preserved. Wait for the query to end (within `--wait` plus
30 seconds), then run the stop again: the daemon is then nobody's child and
still serves the clone. Do not use `dexter.sh stop` to hurry this: it
refuses while the query is attached, and retirement stops the daemon anyway.

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
the running daemon. Before rebuilding over active pairs, stop each clone's
daemon with its bound command, build, then rerun each client's `bootstrap.py`.
The build refuses to replace a binary used by a running daemon and aborts if
it cannot inspect processes. Keep agents stopped until the build finishes.

`--keep <dir>` leaves the prepared source in place for `go test ./...`.
[patches/README.md](dexter/patches/README.md) records what the patch changes and
the Go static-analysis rule for it.

## Verification scope

The [Dexter workflow](../../.github/workflows/dexter.yml) owns check selection. Compare
the whole PR with its fetched base (`origin/<base>...HEAD`), treating renames as a
deletion and an addition. Its event paths select whether Dexter checks apply; its
`Select Dexter coverage` step selects the full suite:

- Non-Markdown changes under `agent/lsp/` or to that workflow run the pinned build,
  Go tests, build-script tests and real-daemon harness tests.
- Non-Markdown changes under `agent/teams/` alone run the real-daemon harness tests.
  Keep this conservative directory scope: shared configuration, process helpers and
  fixtures can affect provisioning, isolation and stopping.
- Markdown-only and unrelated changes need no Dexter checks. A new daemon operation
  still needs a test of its contract if existing integration tests do not exercise it.

For integration-only checks, reuse an existing binary after checking it against this
checkout's pin and patch. Set `TIPS_TEST_REAL_DEXTER` to the absolute Dexter home whose
`vendor/dexter` the tests will use, and `DEXTER_ELIXIR_LIB_ROOT` to the matching
[Elixir sources](#elixir-sources), then run:

```sh
bash agent/lsp/dexter/build.sh --check "$TIPS_TEST_REAL_DEXTER/vendor/dexter"
python3 -m unittest discover -s agent/teams/tests -t agent/teams -p 'test_*.py' -k real_daemons -v
```

`--check` reads the executable's linked build id without building, writing files or
inspecting/stopping daemons. Without an operand it checks this checkout's
`agent/lsp/dexter/vendor/dexter`. A missing or mismatched binary needs an owned
worktree build using the instructions above; never replace another team's active
binary. A clean CI runner must build a binary even for integration-only checks.

The id covers the upstream pin and patch, not the build script or Go toolchain, and
does not prove tests passed. Full-scope changes keep the full suite. Carry earlier
evidence only after the reviewer checks the changed inputs and records why it applies,
under the [CI pause policy](../../agent/docs/checks.md#github-ci-pause).

## Elixir sources

Dexter indexes the Elixir standard library from source. Put the release matching
`elixir --short-version` in the main checkout's ignored `agent/lsp/vendor/elixir-<version>/`
(from the [Elixir repository](https://github.com/elixir-lang/elixir); the tree
contains `VERSION` and `lib/elixir/lib/enum.ex`), or point `DEXTER_ELIXIR_LIB_ROOT`
at another checkout's `lib/`. A Homebrew installation has no sources. Provisioning
refuses to start unless the tree's `VERSION` matches the checkout's toolchain.
