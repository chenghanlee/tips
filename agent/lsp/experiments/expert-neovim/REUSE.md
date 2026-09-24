# Reuse before invention

The smallest credible architecture remains:

```text
Codex / Claude Code → stdio MCP → published vv-mcp → headless Neovim → installed Expert
                                                     ↑
                                    normal disk edits synchronized to buffers
```

One private session per worktree; share installed binaries. This experiment uses
private vv-mcp registries and XDG directories, while Expert uses its normal shared
engine-package cache and worktree-local `.expert` build/index. Installed server,
Neovim and vv-mcp sources were not patched.

## What to borrow

| Need | Existing mechanism | Decision and limit |
|---|---|---|
| Expert startup and project root | Expert's documented native `vim.lsp.config` / `vim.lsp.enable` | Already used. Absolute installed binary and worktree cwd. No custom LSP client. |
| Reusable server configuration | `nvim-lspconfig`'s Expert config | Optional reference, particularly for umbrella roots. Current flat Tips checkout needs no extra package. |
| File watching | Neovim's dynamic LSP watcher registration | Already delivers native create/change/delete events. Reuse its batching and platform backend. |
| Document versions, changes and saves | Neovim buffers plus native LSP didOpen/didChange/didSave | Already used by experimental sync. Let Neovim own versioning and capability handling. |
| Agent access to editor services | Published vv-mcp 0.3.4 | Reuses stdio MCP, managed headless instances, navigation, diagnostic cache and lifecycle. Community adapter, not an industry standard itself. |
| Test access to Neovim | `pynvim` / Neovim's MessagePack-RPC API | Already used for observations and native editor control. No replacement editor protocol. |
| Process failure diagnosis | Expert's public connectionDetails debug command and OTP `:sys.log_to_file` | Identified repeated normal worker exits exhausting the engine supervisor's restart limit. No custom tracing framework. |
| Busy/failure UI | LSP work-done progress, diagnostics, errors and process exit | Useful inputs for future feedback. Progress end and empty diagnostics are not revision-completion guarantees. |
| Rare full-index recovery | Expert's advertised `workspace/executeCommand` Reindex | Tested in a fixture only as delete recovery. Acknowledgement is not completion; overlap rejects requests. Not an every-edit mechanism. |
| Backpressure if recovery is needed | One in-flight job plus a coalesced follow-up obligation | Ordinary queue convention, not a reason to add a job framework. Needs a valid completion signal before implementation. |
| Independent correctness check | Mix formatter, compiler, ExUnit and Credo | Already run against Tips. LSP feedback does not replace application checks. |

Primary references, inspected alongside pinned local implementations:

- [Expert installation instructions supplied by the user](https://raw.githubusercontent.com/expert-lsp/expert/refs/heads/main/pages/installation.md)
- [Expert editor integration](https://expert-lsp.org/docs/editors/)
- [Neovim LSP documentation](https://neovim.io/doc/user/lsp.html)
- [Neovim API and RPC](https://neovim.io/doc/user/api.html)
- [nvim-lspconfig Expert configuration](https://github.com/neovim/nvim-lspconfig/blob/master/lsp/expert.lua)
- [LSP 3.17 specification](https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/)
- [vv-mcp](https://github.com/beixiyo/vv-mcp.nvim)
- [pynvim](https://github.com/neovim/pynvim)
- [OTP sys diagnostics](https://www.erlang.org/doc/apps/stdlib/sys.html)
- [Elixir Supervisor lifecycle conventions](https://hexdocs.pm/elixir/Supervisor.html)

The raw installation URL was read with curl after the web fetch returned a cache
miss; its [downloaded copy](evidence/upstream/expert-installation.txt) is archived.
Version/provenance details
are in [versions.json](versions.json). Upstream main-branch docs can evolve; the
experiment's runtime versions and copied configs are the reproducibility record.

## The glue that remains ours

The specific requirement is external agent file writes behaving like editor edits
and saves, followed by bounded compiler feedback. That is the small adapter gap.
`sync.lua` currently translates Neovim watcher events into buffer changes and save
events. It is experimental, handles `.ex`/`.exs`, and records conflicts/errors
without yet delivering them to agents. The five-second hook remains future work
for this Expert branch.

Existing components cannot by themselves fix a server's delete-event mismatch,
turn a full-index acknowledgement into completion, or repair a worker lifecycle bug.
Keep those defects at their owning layer. Prefer an upstream correction and a
released server fix over permanently encoding them as client-side workarounds.
No upstream issue or message has been sent.

Adding Mason, elixir-tools.nvim, a second watcher library, an independent index or
a replacement MCP server would not address the failures measured here. They may
serve other needs, but are not required for this installed-Expert experiment.

## Acceptance before rollout

1. All ordinary edit/error/repair/create/delete scenarios pass on real Tips,
   including cold startup, overlapping edits and long compilation.
2. A five-second synchronous hook returns current feedback or explicit pending /
   failed / conflict status. New edits cannot disappear through deduplication.
3. Empty, timed-out, stale and partially failed MCP responses cannot claim freshness.
4. Validate needed `.exs` and HEEx workflows, unsaved-buffer conflicts, branch
   changes and process cleanup. Current evidence covers only part of this matrix.
5. Only then run actual Codex Sol workloads again and test the host-specific
   delivery adapter for Claude Code. Reusing MCP is helpful but does not establish
   hook behavior parity.

See [ROOT_CAUSES.md](ROOT_CAUSES.md) for each why chain, simplest remedy and attempts
to disprove it. Reuse is the design direction; a reliable integration is not yet a
verified outcome.
