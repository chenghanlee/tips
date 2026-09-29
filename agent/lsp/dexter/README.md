# Dexter agent prototype

Experimental. **No upstream code is patched. This is not yet a fully correct production integration.**

Both Codex and Claude run `dx.py` through their existing shell tool. It speaks the
standard LSP protocol to stock `dexter lsp`. That frontend connects to Dexter's
one shared daemon per canonical Git worktree. Each command gets a fresh LSP
session; ending the command does not stop teammates' daemon.

This uses Dexter's **LSP feature set**, not its limited lookup/reference CLI.
The CLI is used only for startup, reconciliation and shutdown. There is no MCP
server, editor, gateway, first-party file watcher or second index.

## Why a small client remains necessary

- Current Codex 0.158.0 no longer hosts an MCP server; see the official
  [removal notice](https://learn.chatgpt.com/docs/mcp-server).
- Claude Code 2.1.284 `mcp serve` was probed with `initialize` and `tools/list`.
  No LSP tool was listed. Loading Dexter's stock Claude plugin did not establish
  a full LSP export. Its Bash tool could call this command, but putting an MCP
  server in front of the same shell command adds a process without removing code.
- Dexter's stock Claude plugin launches `dexter lsp`. It is a server launch
  configuration, not a full-feature client available to both harnesses.
- Stock `lspprobe` is useful as a reference but supports only four request types.

`dx.py` is first-party integration code that we maintain. It does not modify
Dexter, Codex, Claude, or a library. MCP would change transport; it would not
remove responsibility for LSP sessions, notifications, follow-ups and edits.

## Build and run

Requires Python 3.10+, Git, Go for building, and the project's Elixir toolchain
for formatting. macOS/Linux only (`flock`). The installed Homebrew 0.7.2 is too
old for the daemon architecture even though the audited source has that version
constant. Pin **cd099f31b7701803292584887bb614628f721b0a**.

Build an unmodified checkout of that exact revision:

```sh
bash agent/lsp/dexter/build.sh /absolute/path/to/dexter-source
```

With the local build, the shortest smoke check is:

```sh
export DEXTER_ELIXIR_LIB_ROOT=/absolute/path/to/matching-elixir-source/lib
python3 agent/lsp/dexter/dx.py --root "$PWD" start </dev/null
printf '%s\n' '{"query":"Tips.Content"}' |
  python3 agent/lsp/dexter/dx.py --root "$PWD" workspace-symbols
```

### Standard-library sources

`start` requires authentic Elixir sources matching `elixir --short-version` in
the worktree's toolchain. Set the stock `DEXTER_ELIXIR_LIB_ROOT` variable to the
source checkout's **lib** directory, containing `elixir/lib/enum.ex`; `VERSION`
must be one directory above it. A source-less Homebrew library directory is not
sufficient. Obtain the matching release from the official
[Elixir repository](https://github.com/elixir-lang/elixir). A single unchanged,
shared source directory outside the active worktrees is sufficient; no separate
copy per agent is needed. This does not install or change the Elixir runtime.

The client checks sources and version before indexing, then saves the path/version
in `.dexter/dx/stdlib.json`. Subsequent commands need no environment override:
they reuse that worktree configuration for both CLI and LSP processes, including
when Dexter automatically starts a replacement daemon. Their `stdlib` field
reports configuration, not proof that every library symbol is indexed.

For an existing database without saved configuration, or when the configured
path/version changes, `start` first uses stock `dexter stop` to retire the old
daemon. It never uses `--force`; an attached teammate makes configuration fail
without disconnecting them. Retry after the team is idle. Repeating `start`
with unchanged configuration does not restart the daemon. Run `start` again
after changing toolchains. Do not independently start this worktree's daemon
with a different environment. `stop` remains usable if sources are unavailable.

The build writes an ignored `vendor/build.json` with the binary checksum.
The client defaults to this local vendor build and verifies its manifest checksum.
For an explicit binary from another location, use its absolute path and checksum:

```sh
DX=/absolute/path/to/tips/agent/lsp/dexter/dx.py
DX_BINARY=/absolute/path/to/tips/agent/lsp/dexter/vendor/dexter
DX_SHA256=checksum_from_build_json
TREE=/absolute/path/to/the/exact/worktree

# Run immediately after worktree provisioning. Starts indexing and waits for the batch.
python3 "$DX" --binary "$DX_BINARY" --sha256 "$DX_SHA256" --root "$TREE" start </dev/null

printf '%s\n' '{"file":"lib/example.ex","line":12,"column":8}' |
  python3 "$DX" --binary "$DX_BINARY" --sha256 "$DX_SHA256" --root "$TREE" hover
```

Provisioning can run `start` in the background while other worktree setup
continues; keep its exit status/output and wait before claiming setup succeeded.
`DEXTER_DAEMON_IDLE_TIMEOUT=0` is set by the client. Only worktree retirement
should call `stop`; never call it when one agent exits. Stock stop refuses active
LSP clients. It cannot know about a teammate who is thinking between commands.

Root must be the exact Git checkout containing `mix.exs`. First `start` runs
stock `dexter init <exact-root>` before starting the daemon. Every later command
requires that root's own regular database; the client also checks the pinned
frontend's reported root before language operations. Without this, Dexter can
silently choose an ancestor's database despite `-C`.

Use sibling worktrees. A root **containing another checkout** is refused
(except `stop`): stock Dexter can index the nested trees too, including unregistered clones. A child worktree
with its own database is supported; its parent cannot be queried while it
contains that child. Worktree creation/removal must not race active workflows. The guard looks for
nested `.git` files/directories, excluding `_build`, `node_modules` and legitimate
Mix `deps`. Git-less source copies remain indistinguishable from project source;
Dexter ignores `.gitignore`, so keep disposable source copies outside the root.
Main Tips should remain merge-only while it contains `.worktrees/` and fixture
clones under `tmp/`; this prototype does not relocate existing worktrees.
Positions `line`/`column` are **1-based UTF-16**. LSP ranges in input/output remain
**0-based UTF-16**. File URIs and raw LSP response fields are preserved.

## Available workflows

All commands take one JSON object on stdin, and return one JSON object. Omitted
stdin means `{}`. Nonzero exit means failure; inspect `error.kind` and `detail`.

| Commands | Input beyond `file` |
| --- | --- |
| `definition`, `type-definition`, `declaration`, `implementation`, `hover`, `highlights`, `signature`, `prepare-rename` | `line`, `column` |
| `references` | `line`, `column`, optional `include_declaration` |
| `symbols`, `folding`, `diagnostics` | no position needed |
| `workspace-symbols` | `query`; no file |
| `completion` | position; optional `select` index or exact label resolves the item in the same session |
| `call-hierarchy` | position; returns prepared items |
| `incoming-calls`, `outgoing-calls` | position, optional `select`; prepare + follow-up in one session |
| `code-actions` | position, optional zero-based `range` and raw `diagnostics` |
| `format` | optional LSP formatting `options` |
| `rename` | position, `new_name`, **`apply: true` required** |
| `write` | `file`, complete `text`, `expected_sha256` (`null` means create only) |
| `capabilities` | returns raw initialize response |
| `start`, `reindex`, `stop` | lifecycle; reindex optionally takes `file` |

The wrapper has named workflows for every capability family advertised by this
pin. **Request coverage is not proof of semantic parity** across every Elixir
construct. See [VALIDATION.md](VALIDATION.md) for evidence and remaining gaps.

### Edits and follow-ups

- Formatting and code actions return proposals unless `apply: true` is provided.
  For a code action, `select` is an index or exact action title.
- Completion preserves snippets and resolution data. To apply, select an item,
  set `apply: true`, and supply `insert_text` with filled-in plain text for a
  snippet. If Dexter supplies no text-edit range, provide `replace_range`; the
  client refuses to guess which partial word to replace. Additional edits are
  applied with the main edit. This gives agents access to snippets without
  implementing an interactive snippet editor.
- `expected_sha256` on a lookup or LSP mutation rejects a known obsolete source
  position. Use the SHA from a previous result's `source` field.
- Rename is an **immediate mutation**, never a preview. Module/function rename
  may write files inside Dexter before responding. Variable/alias rename can
  return edits for the client to apply. Rename sessions never send `didOpen`,
  avoiding Dexter's proposed-open-buffer index pollution.
- Mutations save source contents (including ignored source that Dexter may index) and initial Git status in a private snapshot,
  preserve pre-existing dirty edits, report changed files, then reconcile those
  paths. Snapshots are for manual recovery; no automatic revert is attempted. They are
  not automatically pruned because they may contain the only copy of dirty work.
  Remove reviewed snapshots manually when recovery is no longer needed.
- Returned edits are validated before any client writes; create/rename/delete
  resource operations are processed in order. This is **not** a multi-file
  transaction. A crash or server-side partial failure can still leave edits.

### Team contract

A per-worktree advisory lock in `.dexter/dx/operation.lock` serializes client workflows.
Do not delete `.dexter/` or its lock while any team member is active: replacing
the lock inode would break coordination. Snapshots are under `.dexter/dx/snapshots/`.
This placement avoids writing Git metadata, which Codex commonly mounts read-only. Cooperating agents use
`write` with a saved-content hash for ordinary source replacement, and use the
client's applying workflows for LSP edits. Native Claude Edit, Codex apply_patch,
arbitrary shell commands, Git checkout, and external editors **do not acquire
this lock**. Do not promise lost-update protection when these run concurrently.
A client crash/timeout can leave a server-side rename running after its lock
is released. Pause team writes and inspect the snapshot/diff; do not retry the
mutation automatically. No crash recovery guarantee is made.
For this pilot, use `dx` as the language-tool path in both harnesses; do not
enable a separate native Dexter plugin as an alternate lookup path. Its
long-lived open-document state has a different saved-file synchronization contract.
The prototype does not change either harness's global settings or production
launchers. Team adoption remains an explicit acceptance gate.

## Honest limits

Every answer says `freshness: "unverified"`, including an empty response.
Reindex waits for processing, but stock Dexter can silently drop read/parse/store
errors and leave old symbols. There is no verified revision/readiness handshake.
Timeouts, protocol errors and process failures are distinct from valid empty
results; an upstream hidden failure cannot be made visible by this adapter.

Diagnostics here are **formatter/syntax diagnostics**, requested by opening saved
text and asking Dexter to format it without applying edits. They are not compiler
diagnostics or a readiness signal. Use the normal project compile/test commands
for compiler feedback. No diagnostic notification before the deadline is an error,
not a clean result.

Same-worktree lookups currently serialize under the exclusive operation lock.
Shared read locks are a possible measured optimization, not part of this prototype.

The client rejects dynamic watcher registration honestly; it relies on Dexter's
native watcher plus an explicit full reconciliation before each lookup. That
adds latency. It is not yet proven for all dependency/path-dependency changes.
One fresh session discards per-session caches, not the shared daemon's stale data.

Known stock limitations include silent partial rename writes and missing outgoing
results in the tested unqualified local-call fixture. Results are preserved as
returned. No workaround is presented as an upstream fix.

## Tests

```sh
DEXTER_ELIXIR_LIB_ROOT=/absolute/path/to/matching-elixir-source/lib \
DEXTER_BINARY=/absolute/path/to/the/audited/dexter \
  python3 -m unittest discover -s agent/lsp/dexter/tests -v
```

The default checksum is the original audited macOS build. A separately built
binary needs its audited checksum passed to the client; update the test invocation
as described in validation if using another build. Tests create disposable actual
Git worktrees and stop their own daemons. They never use the Tips database.
