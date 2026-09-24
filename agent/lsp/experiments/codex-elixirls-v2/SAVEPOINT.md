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

## Direction selected after the foreground Mix experiment

On 2026-09-25 the user chose this Neovim + ElixirLS route for its combined compiler
feedback, hover, definitions, references, and other language features.

The foreground Mix alternative is archived separately at commit
`1ec4c6fb6e9545c184452e147530f929173d6e46` on `experiment/plain-mix-compile`, tagged
`archive/plain-mix-compile-2026-09-25`. Its code, research, structured results and
101 copied evidence files remain in Git after its disposable worktrees are removed.
Read its decision with:

```sh
git show archive/plain-mix-compile-2026-09-25:agent/lsp/experiments/plain-mix-compile/DECISION.md
```

The foreground archive is not merged into this branch or main. The original
Neovim savepoint tag is unchanged. The retained bundle passed `doctor` again when
this decision was recorded. This selects the route for continued integration;
the documented rollout limitations remain and no active client configuration was
changed by the archival operation.
