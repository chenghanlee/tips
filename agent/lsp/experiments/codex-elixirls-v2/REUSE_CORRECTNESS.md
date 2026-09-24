# Reuse for compiler correctness and file-event delivery

Research date: 2026-09-24. This is a design recommendation, not another implemented
or validated candidate. The acceptance evidence remains in [CORRECTNESS.md](CORRECTNESS.md).

Keep Neovim, vim.lsp, vv-mcp, and ElixirLS. Existing projects supply useful
conventions for each layer. None of the inspected LSP clients supplies an Elixir
compiler input-consistency fix. Replacing the MCP bridge would leave that defect.

## What the existing implementations actually provide

### LSP: client-owned file watching

The [watched-files specification](https://github.com/microsoft/language-server-protocol/blob/gh-pages/_specifications/lsp/3.17/workspace/didChangeWatchedFiles.md)
recommends client-side watching. A file event contains URI and change type;
it carries neither file contents nor a compiler-consumed revision. A notification
also does not acknowledge completion of a build. Keep these messages as
invalidation signals rather than treating them as freshness certificates.

### Neovim and VS Code: batching and fallible transport

[Neovim's watcher](https://github.com/neovim/neovim/blob/master/runtime/lua/vim/lsp/_watchfiles.lua)
uses a 100 ms batch and prunes consecutive equal path/type events. Its internal
queue is also present in our pinned 0.12.5 copy, but does not expose a public
enqueue API for the external-edit scanner.

[VS Code's language client](https://github.com/microsoft/vscode-languageserver-node/blob/main/client/src/common/client.ts)
routes file events through `notifyFileEvent`, batches them with a 250 ms delayer,
and restores a failed send's events to its pending list. Its
[watcher feature](https://github.com/microsoft/vscode-languageserver-node/blob/main/client/src/common/fileSystemWatcher.ts)
feeds that common callback. These are implementation references; adopting the
whole VS Code extension host is unnecessary for the current stack.

Our transport retry follows the same retention idea. Successful sending is still
different from successful compilation; keep the server-side acknowledgment too.

### Kubernetes workqueue: safe coalescing with multiple producers

The [client-go workqueue](https://github.com/kubernetes/client-go/blob/master/util/workqueue/queue.go)
keeps separate dirty and processing sets. Repeated adds before processing merge;
an add during processing causes another pass after completion. This is a useful
reference algorithm for our existing GenServer and MapSets, not a reason to add
Go or Kubernetes dependencies. Error retry policy remains the caller's concern.

This refines the earlier “one publisher” proposal: **one owner of build scheduling
is necessary; exactly one source of observations is not.** Both native watching
and reconciliation can feed that owner. Unknown late duplicates must remain
eligible for another pass because they may be real intervening edits.

### Watchman and coc.nvim: change cursors and observation recovery

[Watchman clocks](https://facebook.github.io/watchman/docs/clockspec) let clients
query changes since a prior observed position instead of comparing wall-clock
timestamps. Its [query API](https://facebook.github.io/watchman/docs/cmd/query)
reports deletion and fresh-instance state; a fresh instance does not preserve the
old set of deleted paths. A consumer must reconcile those against its prior
inventory. The default query synchronization and lock waits are 60 seconds, so
integration would have to bound both within the remaining hook budget.

[coc.nvim already uses Watchman](https://github.com/neoclide/coc.nvim/blob/master/doc/coc.txt)
for LSP file detection, with an existing
[fb-watchman wrapper](https://github.com/neoclide/coc.nvim/blob/master/src/core/watchman.ts)
as an integration reference. We can inspect that implementation without replacing
vim.lsp or running two LSP client frameworks.

However, Watchman explicitly documents a
[macOS FSEvents synchronization limitation](https://facebook.github.io/watchman/docs/cookies):
changes can arrive after the cookie and flush operation. A quiet-period setting
is a workaround, not proof of immutable compiler input. Therefore Watchman is a
candidate for better observation and recovery, not a demonstrated solution to
every A→B→A case on this Mac. It is not currently installed here.

Watchman's [recrawl convention](https://facebook.github.io/watchman/docs/troubleshooting)
is useful independently: when observation history is unreliable, invalidate
conservatively instead of interpreting a matching final snapshot as proof of no
changes. For us, a known history gap could require project-wide invalidation if
the affected paths cannot be established. A silent loss remains undetectable by
this policy; no history-gap signal can be assumed from our current watcher.

### Gopls: bind analysis to actual content

[Gopls' design](https://go.dev/gopls/design/implementation) represents files with
content, hashes, versions and snapshots, and associates analysis with those
inputs. The useful principle is to identify the bytes that analysis consumes.
It does not mean gopls' Go-specific cache can be inserted into ElixirLS.

Our resource counterexample violates that principle: the metadata describes a
later disk read, while macro execution consumed another version. To eliminate
that class generally, either capture the resource input actually consumed or
make every relevant input stable for the compilation. Merely taking another
snapshot for comparison does not make compilation use that snapshot.

## First principles, Occam, and Pareto

First principles give two separate contracts:

1. Once an input change is observed, keep its invalidation until the relevant
   compilation succeeds; preserve changes arriving during compilation.
2. To certify a build even when mutation history is completely unobserved,
   control the compiler's input versions or prevent concurrent input mutation.

The existing retained targeted patch meets the tested cases for the first
contract. An LSP adapter alone does not establish the second.

Occam favors improving the existing ElixirLS queue over another bridge,
watcher daemon, custom event IDs, or a second client-side scheduling framework.
Pareto favors repairing the demonstrated duplicate-trigger latency while keeping
the accepted external-edit and five-second workflow. This is a prioritization
judgment, not a measured claim that 80% of failures have a particular cause.

## Smallest next candidate

- Keep the existing stack, opened-buffer reload/save synchronization, targeted
  invalidation and successful-compilation acknowledgment.
- Coalesce pending paths at the existing ElixirLS scheduler before starting an
  idle build. A fixed 250 ms initial batching window is a reasonable experiment
  informed by VS Code; it must not slide indefinitely with every new event.
- Make queued work visible as pending immediately. Otherwise batching can create
  a misleading interval before the current compile-start log is emitted.
- Continue to process file deletion/creation semantics. Coalescing compile work
  must not erase deletion notifications or source/index cleanup.
- When a build is in flight, retain incoming paths for a subsequent build.
  Do not suppress them just because a hash matches or a timer is short.
- Preserve the existing failure/no-loop behavior. Once the current worker ends,
  pending work already observed during it can launch promptly. Transport retries
  and the total five-second hook budget remain unchanged.

This changes scheduling, not compiler validity. It can merge nearby duplicate
triggers; it does not promise exactly one build per physical edit. A late duplicate
may conservatively cause another incremental build. Any proposal promising both
perfect late deduplication and no lost real edits needs evidence of shared revision
identity that our current notifications do not carry.

Acceptance before adoption: recover the three-second feedback case; retain an edit
just before/after batch launch; deletion/recreation and A→B→A remain dirty; rejected
sends and failed/crashed builds remain retryable; queued work never looks current;
continuous input cannot postpone launch indefinitely; the five-second cap holds.

## Stronger resource correctness

For the completely unobserved A→B→A case, the next separate candidate would need
stable compile inputs or consumed-input tracking. A frozen build tree is only
effective if Mix and all relevant compile-time resource reads actually use it,
including resource absence. An ordinary copy, symlinked live inputs, hashes around
a build, or an advisory lock ignored by writing tools does not establish this.
Path mapping, generated files, external resources and snapshot advancement need
tests before recommending such an architecture.

No researched tool justifies claiming this stronger contract is solved. Borrow
the established principles, retain the tested small patch, and avoid adding a
watcher or framework solely to rename the remaining uncertainty.
