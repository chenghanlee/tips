# Dexter agent prototype

Experimental. **This branch carries one local Dexter patch for argument-count
lookups. This is not yet a fully correct production integration.**

Both Codex and Claude run `dx.py` through their existing shell tool. It speaks the
standard LSP protocol to `dexter lsp`. That frontend connects to Dexter's
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

`dx.py` and its `dexter_client/` package are first-party integration code that we maintain.
The local backend correction is kept separately in `patches/function-arity.patch`;
the adapter does not implement function resolution. The patch also corrects
generated call-hierarchy labels such as `Repo.query!(sql, [])` to `/2`; graph
follow-ups remain name-based. Codex, Claude and third-party
libraries are unchanged. MCP would change transport; it would not
remove responsibility for LSP sessions, notifications, follow-ups and edits.

## Build and run

Requires Python 3.12+, Git, Go for building, and the project's Elixir toolchain
for formatting. macOS/Linux only (`flock`). The installed Homebrew 0.7.2 is too
old for the daemon architecture even though the audited source has that version
constant. Pin **cd099f31b7701803292584887bb614628f721b0a**.

Supply an unmodified checkout of that exact revision. The build script exports
it to a temporary directory, checks and applies the local patch there, then
builds the binary. It leaves your source checkout unchanged and removes the
temporary copy on exit:

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

The build writes an ignored `vendor/build.json` with the upstream revision,
local patch checksum and binary checksum.
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

Switch builds only while the team is idle. **Before running `build.sh` over an
active binary**, use each worktree's existing bound command to `stop` its daemon.
After building, re-provision the bound commands with the new checksum and `start`
the worktrees. Old bound commands pin the old checksum and will refuse the new
binary. Do not mix stock and patched
clients on one running daemon: they share the upstream protocol version, and a
new frontend is not proof that the existing daemon has the patch. The isolated
patch tests use fresh roots and do not replace any existing team's binary.

Provisioning can run `start` in the background while other worktree setup
continues; keep its exit status/output and wait before claiming setup succeeded.
The client defaults `DEXTER_DAEMON_IDLE_TIMEOUT` to `0` to keep the team watcher
running. Tests and scratch runs can explicitly set a short duration such as `5s`;
an idle restart is not equivalent to a continuously running watcher. Only worktree retirement
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
The default omits repeated protocol metadata and renders simple navigation
locations as `path:start-line:start-column-end-line:end-column`, with 1-based
UTF-16 positions and worktree-relative paths. External URIs stay absolute.
It keeps every match, warning/error notification, and diagnostics publication.
Use `--json` for the full report with original LSP fields and zero-based ranges;
other structured results in the compact view also retain their LSP ranges.
Failures always retain the full report.
For LSP workflows, `daemon_log` retains the proxy-reported log path in both views. Inspect that log
when results look incomplete: upstream read/parse/index errors may appear there
despite a successful lookup. The adapter does not parse the log or certify freshness.
Dexter sometimes returns column 1 and a zero-width range for a symbol farther
along the line. Use the reported line to inspect the source; do not treat the
column as a precise token boundary. The argument-count patch returns precise
function-token ranges for verified call references; other locations can remain
line-level.

| Commands | Input beyond `file` |
| --- | --- |
| `definition`, `type-definition`, `declaration`, `implementation`, `hover`, `highlights`, `signature`, `prepare-rename` | `line`, `column` |
| `references` | `line`, `column`, optional `include_declaration` |
| `symbols`, `folding`, `diagnostics` | no position needed |
| `workspace-symbols` | `query`; no file |
| `completion` | position; optional `select` index or exact label resolves the item in the same session |
| `call-hierarchy` | position; returns prepared items |
| `incoming-calls` | position, optional `select`; prepare + `references` + one source-owner parse in one session; see [incoming calls](#incoming-calls) |
| `outgoing-calls` | position, optional `select`; prepare + follow-up in one session |
| `code-actions` | position, optional zero-based `range` and raw `diagnostics` |
| `format` | optional LSP formatting `options` |
| `rename` | position, `new_name`, **`apply: true` required** |
| `write` | `file`, complete `text`, `expected_sha256` (`null` means create only) |
| `capabilities` | returns raw initialize response |
| `start`, `reindex`, `stop` | lifecycle; reindex optionally takes `file` |

The wrapper has named workflows for every capability family advertised by this
pin. **Request coverage is not proof of semantic parity** across every Elixir
construct. See [VALIDATION.md](VALIDATION.md) for evidence and remaining gaps.

### Incoming calls

Stock Dexter's `callHierarchy/incomingCalls` assigns each reference to the nearest
preceding `def` in the file, so a call inside an ExUnit `test`, `setup` or `describe`
block is dropped, or attributed to an unrelated helper closed above it. The client
does not send that request. `incoming-calls` prepares the item, asks stock
`references` (declaration excluded) in the same session, then parses every caller
file once with the public `Code.string_to_quoted` parser (one `elixir` subprocess,
no compilation, no evaluation) to name the lexical unit containing each reference
line. It stays under the same operation lock as every other lookup.

`result` is `{"sites": [...], "unavailable": [...]}`, and
`result_kind` says what it is: `source_call_owners_at_indexed_reference_lines`.
Each site has `path`, 1-based `line`, `status: "resolved"`, `kind: "call"` and an
`owner` with `kind` (`def`, `defp`, `defmacro`, `defmacrop`, `test`, `setup`,
`setup_all`), `module`, `name` (`null` for `setup`), `line`, `end_line`, and for
function and macro owners `arity` plus `arity_ambiguous` (default arguments).
`test`/`setup` owners are recognised by their literal syntactic form on the page,
not by expanding ExUnit macros. `positions` is
`1-based source lines; not exact LSP ranges`: use the line to open the source.
`block_followups` is `unsupported`: `test`/`setup` owners are source block labels,
not functions Dexter knows, so no further call-hierarchy request can be made from them.

Every reference line the index returned is accounted for exactly once. Lines the
parser cannot own honestly go to `unavailable` with `path`, `line`, a `reason` and a short `detail`:
`parse_error`, `no_call_candidate`, `not_direct_call` (captures, `quote`, typespecs),
`ambiguous_callee`, `multiple_owners`, `no_owner` (module body),
`dynamic_identity` (`def unquote(...)`, `defmodule unquote(...)`) or
`source_unavailable` (caller file outside the root boundary or unreadable). When that list is
non-empty the command keeps the full `result` but reports `ok: false` with
`error.kind: "incoming_unavailable"` and exits 1, so a partial answer is never read
as a complete one. `upstream_reference_count` is the raw number of `Location` objects the index
returned; two on one line count twice there but are answered once. A reference the
index missed cannot appear anywhere in this result.

Identity is inherited from the index, not re-resolved: the parser matches the
prepared function name on the reported line and does not resolve aliases, imports or
arity itself. `caller_sources` lists `{path, sha256}` for every file the parser read;
those are read hashes, not an acknowledgement of the indexed revision, and
`freshness` stays `unverified`. A caller file whose bytes differ between the parser's read and the recheck after
parsing rejects the whole result. Measured on a seven-site fixture (2026-09-30, one cold and three warm requests):
`elapsed_ms` 413-432 with one unavailable site, 467 with six clean sites, against
56-60 for the stock lookup on the same fixture. Almost all of the difference is the
parser subprocess. Paths inside `result` and `caller_sources` are absolute.

```sh
printf '%s\n' '{"file":"lib/demo/target.ex","line":5,"column":7}' |
  python3 agent/lsp/dexter/dx.py --root "$PWD" incoming-calls
```

Abridged receipt (usual `operation`, `root`, `source`, `prepared_items`, `reconcile`,
`freshness`, `warnings` and `daemon_log` fields omitted):

```json
{"result_kind": "source_call_owners_at_indexed_reference_lines",
 "positions": "1-based source lines; not exact LSP ranges",
 "block_followups": "unsupported",
 "upstream_reference_count": 2,
 "caller_sources": [{"path": "/abs/test/demo/helper_test.exs", "sha256": "c345…"}],
 "result": {
   "sites": [
     {"path": "/abs/test/demo/helper_test.exs", "line": 9, "status": "resolved", "kind": "call",
      "owner": {"kind": "setup", "module": "Demo.HelperTest", "name": null, "line": 8, "end_line": 11}},
     {"path": "/abs/test/demo/helper_test.exs", "line": 23, "status": "resolved", "kind": "call",
      "owner": {"kind": "defp", "module": "Demo.HelperTest", "name": "bottom_helper", "arity": 0,
                "arity_ambiguous": false, "line": 22, "end_line": 24}}],
   "unavailable": [
     {"path": "/abs/test/demo/capture_test.exs", "line": 5, "reason": "not_direct_call", "detail": "capture"}]},
 "ok": false,
 "error": {"kind": "incoming_unavailable", "detail": "1 reference line(s) have no supported source owner"},
 "elapsed_ms": 423.1}
```

With an empty `unavailable` list the same receipt has `ok: true`, no `error`, and exit 0.

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
  avoiding Dexter's proposed-open-buffer index pollution. The argument-count
  patch corrects shared name classification, so captures, pipe targets and mid-token
  cursors can now reach function rename. That rename still operates across all
  argument counts of the name; it does not safely rename just one overload.
- Mutations save source contents (including ignored source that Dexter may index) and initial Git status in a private snapshot.
  `write` preserves only its target's pre-edit contents; rename and apply workflows
  retain the full source snapshot because their changes can span files.
  Workflows preserve pre-existing dirty edits, report changed files, then reconcile those
  paths. Snapshots are for manual recovery; no automatic revert is attempted. They are
  not automatically pruned because they may contain the only copy of dirty work.
  Remove reviewed snapshots manually when recovery is no longer needed. Team
  retirement moves them to the main checkout's `tmp/dexter-recovery/` and prints
  the unique destination; it does not delete them.
  This folder is an exception to the usual disposable `tmp/` convention. Retention
  is local and best-effort, not a backup: move needed recovery data before manually
  cleaning `tmp/`, running `git clean -x`, or deleting the main checkout.
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
The team launcher generates session-local settings and eagerly starts this adapter.
It does not change either harness's global settings. Full team adoption remains
an explicit acceptance gate; see [team integration](../README.md#team-integration).

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

Known upstream limitations include silent partial rename writes and missing outgoing
results in the tested unqualified local-call fixture. Results are preserved as
returned. The argument-count patch does not establish safe multi-arity rename,
complete call hierarchy, or strict index freshness. See the
[patch validation record](patches/README.md) before relying on a particular construct.

## Client structure

`dx.py` is the executable entry point. The modules under `dexter_client/` have
separate responsibilities:

- `cli.py`: arguments, binary/root checks, output and exit status.
- `workspace.py`: daemon lifecycle, worktree isolation, locks and recovery snapshots.
- `protocol.py`: subprocess ownership, LSP framing, requests and notifications.
- `workflows.py`: each language operation's request and follow-up sequence.
- `edits.py`: edit-target boundaries, UTF-16 coordinates and applying returned edits.

These are modules in the same process, not additional services. Dependencies flow
from the CLI through the worktree/workflows to protocol and file operations;
those lower layers do not import the CLI. Local state has concrete types. Raw
LSP objects preserve extension fields rather than defining a second LSP schema.
Keep the package beside `dx.py` when using the adapter from another checkout.

## Tests

The adapter inherits the team harness's Ruff rules (including complexity at most
10) and is included in its strict Pyright project. From the repository root:

```sh
ruff check agent/teams agent/lsp/dexter
ruff format --check agent/teams agent/lsp/dexter
pyright --project agent/teams/pyproject.toml
python3 -m unittest discover -s agent/lsp/dexter/tests -v
```

Tests reuse the harness's subprocess helper, so run them from the repository root
with `agent/teams` present. CI runs these static checks and the protocol/edit tests. Real Dexter tests need
the pinned local binary and sources and otherwise report skips:

```sh
DEXTER_ELIXIR_LIB_ROOT=/absolute/path/to/matching-elixir-source/lib \
DEXTER_BINARY=/absolute/path/to/the/audited/dexter \
  python3 -m unittest discover -s agent/lsp/dexter/tests -v
```

For this patched build, set `DEXTER_BINARY` to the local `vendor/dexter`
produced by `build.sh`; the tests then use its build manifest. Normal client use
can also supply an audited external binary with an explicit `--sha256` argument.
Without a matching manifest or explicit checksum, the client retains the original
stock-build checksum as its fallback. Tests create disposable actual
Git worktrees and stop their own daemons. They never use the Tips database.
