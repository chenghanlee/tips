# Reuse before extending the bridge

Date: 2026-09-24. This is a source review and experiment decision, not a rollout.

Follow-up: [the headless Neovim comparison has now run](NEOVIM.md), including
actual Codex on synthetic source and local-only Tips queries. The candidate
descriptions below record the original source review before those live tests.

**Use the existing LSP client contract. Compare a mature editor client before
adding a custom synchronization or recovery subsystem to the MCP bridge.**

## Why manual workarounds were necessary

1. **Why must the agent refresh or restart?** The server can answer from state
   that predates a saved edit.
2. **Why did editing an unopened callee remain invisible?** The tested bridge
   synchronizes the requested file, but does not watch other project files.
3. **Why does an editor usually handle this automatically?** Its LSP client owns
   document notifications and registered filesystem watchers.
4. **Why does one agent per worktree not supply that behavior?** Writer count
   does not deliver notifications. The language server also compiles asynchronously.
5. **Why is adding a watcher not the whole solution?** A query can arrive during
   compilation. Our forced overlap also produced a stale successful incremental
   build in plain Mix, with no bridge involved.
6. **Why not hide both failures in a custom refresh engine?** That makes the
   client compensate for compiler state it cannot directly observe or repair
   reliably. An edit during clean-and-rebuild reproduced the compiler failure.
7. **Why reuse an editor client as a control?** It separates missing standard
   client behavior from a server/compiler defect using an existing implementation.
8. **Why would a different client still need the compiler control?** Correct
   client notifications do not establish correct compiler bookkeeping.
9. **Why would more agent instructions not solve it?** The same ownership remains:
   synchronization belongs in the client; compiler correctness belongs below it.

The last two questions do not change that division of responsibility. The root
problem requiring routine manual refresh is missing automatic client behavior;
the compiler overlap is a separate demonstrated limitation.

## Existing implementations and what to borrow

| Resource | Reuse | Boundary |
|---|---|---|
| [LSP watched-file specification](https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/#workspace_didChangeWatchedFiles) | Client-owned watchers, server registration, create/change/delete notifications | Notification delivery is not a build-completion acknowledgment |
| [elixir-tools.nvim source](https://github.com/elixir-tools/elixir-tools.nvim/blob/defb94618c8cd7a8de5943bf09b25ec055263c19/lua/elixir/elixirls/init.lua) | ElixirLS startup, root and settings configuration using `vim.lsp.start` | Lua plugin requires Neovim; it is not a standalone Node LSP client |
| [Neovim watcher implementation](https://github.com/neovim/neovim/blob/master/runtime/lua/vim/lsp/_watchfiles.lua) | Dynamic registrations, workspace-relative watches, event filtering, batching, cleanup | Inspect and test a pinned runtime version; the plugin's minimum version is not proof of identical watcher support |
| [Official ElixirLS VS Code client](https://github.com/elixir-lsp/vscode-elixir-ls/blob/master/src/languageClientManager.ts) | Server configuration on top of Microsoft's `LanguageClient` | The full client uses VS Code APIs; it is not a drop-in library for our standalone bridge |
| [Microsoft LSP libraries](https://github.com/microsoft/vscode-languageserver-node) | Existing protocol types and JSON-RPC implementation | The tested bridge already uses `vscode-languageserver-protocol`; protocol transport alone does not implement the full client lifecycle |
| [Chokidar](https://github.com/paulmillr/chokidar) | Reusable Node filesystem watching, normalized events and atomic-write handling if extending the bridge | Still needs mapping to LSP registrations and open-document synchronization; no compiler-readiness guarantee |

Neovim's client supplies the behavior underneath `elixir-tools.nvim`. Its current
watcher source batches notifications for 100 ms and keeps registrations per client.
The inspected plugin source defaults its managed installation to ElixirLS 0.22.0;
our comparison should explicitly use the installed 0.31.1 executable so a version
change is not mistaken for a client fix.

The standard explicitly recommends clients handle filesystem watching. Our bridge
is the LSP client in this architecture, so this responsibility belongs there unless
we reuse a complete client process.

## Reuse a complete client through MCP

[vv-mcp.nvim](https://github.com/beixiyo/vv-mcp.nvim) documents definitions,
references, hover and diagnostics through Neovim, including managed headless
Neovim when no suitable live client exists. It is a candidate for an isolated
comparison, not a verified ElixirLS integration or an industry standard.

[mcp-diagnostics.nvim](https://github.com/georgeharker/mcp-diagnostics.nvim) also
exposes those features. Its documented automatic reload configuration and explicit
refresh tool need inspection: the existence of that tool does not establish that
agents can omit it safely. Neither project has been installed or run here.

A whole-client reuse path is:

```text
Codex -> existing Neovim MCP bridge -> Neovim LSP client -> ElixirLS
```

It adds a runtime and buffer lifecycle, but could remove client logic we would
otherwise maintain. External disk edits must reload any open Neovim buffers
automatically. Neovim is not currently available on PATH in this environment,
so this review establishes source behavior, not a successful live comparison.

For a separate reference, [gopls MCP](https://go.dev/gopls/features/mcp) supports
attached and headless sessions. Its [query implementation](https://go.googlesource.com/tools/+/c418235894f89f8a19e9990196efd285da936a9e/gopls/internal/mcp/mcp.go)
checks dependency-file changes before reacquiring a server snapshot. Its comments
explicitly acknowledge that this misses added files and timestamp-granularity
changes. Borrow the reconciliation idea if needed, not a claim of perfect freshness.

## First principles, Occam and Pareto

- **First principles:** semantic answers depend on both source synchronization
  and server/compiler state. Keep each responsibility with the component that
  owns it; agent memory is not part of the synchronization mechanism.
- **Occam:** first compare the unmodified bridge with an existing complete LSP
  client. Do not infer that a new watcher, snapshot system, or repeated rebuild
  loop is necessary before that comparison.
- **Pareto:** start with four tools: definition, references, hover and diagnostics.
  Exercise saved edits through ordinary shell/patch tools. Preserve one session
  per worktree. Reuse a whole existing integration if it passes with less maintained
  glue; otherwise adapt the tested bridge using the standard lifecycle and an
  existing watcher library.

## Inversion and adoption gate

Run the same cases against each candidate: unopened callee edit, externally edited
open file, create/delete/atomic replacement, edit during compilation, syntax error
and repair, worktree checkout, and shutdown. The acceptance question is whether
ordinary edits become visible automatically without preopening, refresh calls, or
agent-managed restarts. A blocked or unfinished analysis must not silently appear
as a definitive empty result.

The demonstrated compiler race remains a separate control regardless of client.
Do not claim Neovim fixes it without testing. A clean rebuild after edits stop is
a working recovery control, not yet an automatic integration strategy. See
[the inversion results](INVERSION.md) for observed results and limits.

**Proposed experiment, now completed in [NEOVIM.md](NEOVIM.md):** run the existing
failing fixtures through a pinned Neovim client and an existing MCP adapter
before implementing more bridge machinery.
An additional editor process is justified only if it removes more integration
work than it creates. No production choice has been finalized.
