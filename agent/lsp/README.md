# Agent language tools

The team launcher uses one **unmodified Dexter daemon per worktree**, shared by
Codex and Claude through our Python `dx` adapter. Each workflow gets a fresh LSP
session. There is no MCP bridge, editor process, custom watcher, or upstream patch.
This remains a prototype: strict saved-index freshness and concurrent native-write
rename safety are not established. See [validation](dexter/VALIDATION.md).

## Build and validate

Follow [Dexter setup](dexter/README.md#build-and-run): build the pinned stock source
with `dexter/build.sh`, provide matching Elixir sources using
`DEXTER_ELIXIR_LIB_ROOT`, and run the stock-server tests. Keep the adapter, binary,
and stdlib sources outside retiring task worktrees. The installed Homebrew release
currently lacks the required daemon commands; the pinned source build is separate.

## Team integration

`agent/teams/task_worktree.py` generates a tiny bound command at
`.dexter/dx/command.sh`, runs `start` immediately after provisioning, and exports
its absolute path as `TIPS_DX` to the launched agent. Both harnesses use it:

```sh
printf '%s\n' '{"file":"lib/example.ex","line":12,"column":8}' | "$TIPS_DX" hover
```

The command binds the exact worktree, shared executable, and timeout. Changing
shell directories does not reroot it. All Dexter LSP workflows are available;
see the [workflow table](dexter/README.md#available-workflows). The launcher passes
startup instructions and disables known native ElixirLS/Dexter plugins and the
old Expert MCP bridge for that session. Claude uses an explicit empty MCP configuration for these coding sessions, so
other inherited MCP servers are also absent there. It does not change user-wide
settings or shell approvals. A shell denial must be reported, not bypassed.

Provisioning requires the shared `agent/lsp/dexter/vendor/dexter` build. Set
`TIPS_DEXTER_HOME` to an absolute adapter directory for a staged prototype pilot.
Set `DEXTER_ELIXIR_LIB_ROOT` at initial provisioning; `dx` remembers it per tree.
A provisioning failure preserves the checkout and does not launch a coding agent.
Successful startup is not a promise of fresh results or successful compilation.

Same-team agents can explicitly join a task branch with `--share` and distinct
roles/panes. It cannot be combined with `--review-ref`; independent reviewers
still get their own detached worktrees by default. Shared agents must not change
configuration or switch the shared branch while teammates run. Main remains
merge-only while it contains nested team worktrees.

`team.py stop N` stops team clients, then calls each unique worktree's `dx stop`
before dropping databases/removing clean, merged worktrees. Recovery snapshots must be reviewed and removed before retirement; clean Git
status alone does not make ignored recovery data disposable. A known external
Herdr teammate or a Dexter stop refusal preserves the worktree. Individual agent
exit never requests daemon shutdown. Unregistered/external clients remain outside
the team ownership contract: do not retire a tree they still use.

Use ordinary Mix compilation and tests for compiler diagnostics. Dexter's formatter
provides syntax diagnostics only. Per-worktree locks order cooperating `dx` writes;
native editing tools bypass them. Do not overlap native edits with an in-place
rename. The full limitations and recovery evidence are in the
[adapter guide](dexter/README.md#honest-limits).
