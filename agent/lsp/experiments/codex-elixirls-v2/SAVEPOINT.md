# Neovim + ElixirLS + hook savepoint

Created 2026-09-25 before exploring plain `mix compile` feedback.

Git tag: `savepoint/neovim-elixirls-hook-2026-09-25`.
Retained branch: `experiment/elixirls-codex-v2`.
Retained worktree: `/private/tmp/tips-elixirls-codex-v2`.

The tag preserves the implementation, dependency patches, pinned build recipe,
test probes, structured evidence, and experiment reports in this directory.
The stack remains provisional; this is a recovery point, not a production release.
See [operational results](OPERATIONAL_FIXES.md), [long-build behavior](LONG_BUILDS.md),
and [installation and replay instructions](INSTALL.md).

The installed bundle remains at `agent/lsp/vendor/elixirls-neovim-v2/` in the
retained worktree. Its manifest SHA-256 is:

```text
80f20594670350ae2f1a3355a7c3b196adf82891ad1de9935e2aa76811e13f16
```

At checkpoint creation, `bundle.py doctor` passed and all five adapter runtime
files matched the saved source. Python syntax checks passed. The recorded
operational, reconciliation, long-build, Rust, Lua, and agent-delivery results
are preserved in [operational-fixes-evidence.json](operational-fixes-evidence.json).
Those behavioral tests were not rerun solely to create this Git checkpoint.

Installed binaries, caches, raw traces under `tmp/`, and `nvim.log` remain local
and are not Git artifacts. Rebuild from the pinned recipe if those temporary
files disappear. The structured results and replay code are committed.

For a separate source checkout of this savepoint:

```sh
git worktree add --detach /private/tmp/tips-neovim-savepoint \
  savepoint/neovim-elixirls-hook-2026-09-25
```

Plain-Mix exploration uses a separate branch and worktree. Active Codex and
Claude configuration is unchanged.
