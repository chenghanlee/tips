# Pinned Neovim / ElixirLS bundle

This is a provisional experiment installation. It does not change the active Codex or
Claude configuration. Use one session and one ElixirLS build directory per worktree.

## Build

Supported build host: macOS arm64, Python 3.14.3, Elixir 1.20.4, Erlang/OTP 29.1,
Rust 1.97.0, plus `git`, `curl`, `patch`, and `unbuffer` on PATH.
The installed runtime still requires the matching host Python and OTP installations.
It contains its own Elixir/Mix tree; it does not modify Homebrew or global Mix files.

From the repository root:

```sh
python3 agent/lsp/experiments/codex-elixirls-v2/build_bundle.py \
  --destination "$PWD/agent/lsp/vendor/elixirls-neovim-v2" \
  --cache "$PWD/tmp/elixirls-bundle-cache"

python3 agent/lsp/vendor/elixirls-neovim-v2/bundle.py doctor
```

Use a fresh destination for each build. A failed build has no verified install
manifest. Downloads are checked against `bundle-lock.json`; ElixirLS and Cargo
dependencies use their upstream locks. Hex 2.5.1 is built from pinned source for
OTP 29 rather than installing an incompatible older precompiled archive.
The recipe builds the private Mix patch, ElixirLS patch and vv-mcp formatter and
instance-binding patches.
It never copies a previously patched experimental server or compiler.

The manifest records installed Mix, server, bridge and adapter hashes; it does
not hash every file in the host-copied Elixir tree. `doctor` and MCP startup reject
a mismatched compiler version, changed tracked Mix beam, or changed adapter.
This is a reproducible installation recipe with explicit host prerequisites, not
a claim of byte-identical builds across different host toolchains.

## Session entry points

Run these using absolute paths. Give each client its own state directory, even
when binaries are shared. Each assigned workspace must contain `mix.exs`.

```sh
python3 /absolute/bundle/bundle.py serve \
  --workspace /absolute/tips-worktree --state /absolute/private-session-state

python3 /absolute/bundle/bundle.py hook \
  --workspace /absolute/tips-worktree --state /absolute/private-session-state \
  --budget-ms 5000
```

`serve` is the MCP stdio command; enable its `lsp` tool. The hook reads the regular
JSON hook event from stdin. Register it for `PostToolUse` matching
`^(apply_patch|Bash)$`, and for `Stop`, with a six-second host timeout. PostToolUse
returns `hookSpecificOutput.additionalContext`; Stop reports unconsumed pending
feedback. The tested configuration is generated in `neovim_dogfood.py` and used
by `release_dogfood.py`. See the public
[Codex hook contract](https://learn.chatgpt.com/docs/hooks#posttooluse).

MCP starts once the owned Neovim instance registers, without waiting for ElixirLS
compilation. The normal Codex startup timeout is used in the new agent tests.
MCP and hooks bind to that exact instance. If Neovim dies, the launcher exits and
hooks report unavailable; they do not silently adopt a replacement at the same root.
Neovim starts ElixirLS with `detached = false`, keeping it in the launcher's private
process group. Shutdown terminates that group without making a Neovim RPC.

The normal hook budget is five seconds, including synchronization and the 250 ms
build collection window. Slow builds return pending feedback. An unchanged tool
does not wait another five seconds. The budget is a tested default, not a guarantee
that every compilation finishes synchronously.

Compilation continues after a pending hook response. Its eventual error is
delivered by a later eligible tool's hook or a bounded Stop check, not by an
unsolicited asynchronous push. If Stop also exhausts its budget, validation remains
unfinished; subsequent Stop calls do not loop indefinitely. See [LONG_BUILDS.md](LONG_BUILDS.md).

Neovim owns normal LSP and buffer behavior. The retained patches add retryable
external-file saves/reconciliation, qualified semantic/diagnostic/symbol results,
the worktree `tmp/` watcher exclusion, and targeted compiler invalidation with
pending/in-flight retention. Ordinary incremental compilation remains enabled.
No full forced project rebuild is introduced.

## Boundaries

- This package pins Neovim 0.12.5, including its private watcher-exclusion hook.
  Upgrades require replaying these gates; substituting stock Mix is unsupported.
- Diagnostics and `current` describe the last observed editor compilation.
  Normal formatting, compilation, tests and Credo remain necessary.
- A semantic request can time out while compilation is unavailable or failing.
  It reports an error and retains the feedback qualification; retry after recovery.
- Reconciliation covers the source/template extensions selected in
  `neovim_sync.lua`. Entirely unobserved changes, including an A→B→A history missed
  by both watchers and scans, are outside the tested contract.
- Late notifications can cause a further incremental build. They are retained
  because the same filename can represent a real later edit.
- The internal cohort has three sessions, not a measured long-term failure rate.

The runtime can be relocated without its `sources/`, download cache, or build log.
`bundle_probe.py` tests that runtime through actual MCP; `neovim_reconcile_probe.py
--bundle ...` exercises the resource/overlap boundary with fresh-VM assertions.
Keep the manifest with the runtime. [Operational evidence](OPERATIONAL_FIXES.md)
records the current tests; [earlier release gates](RELEASE_GATES.md) record the
three Tips workloads and original installation.
