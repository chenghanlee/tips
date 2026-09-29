# Agent language tools

The team launcher uses one **Dexter daemon per worktree**, shared by
Codex and Claude through our Python `dx` adapter. Each workflow gets a fresh LSP
session. There is no MCP bridge, editor process, or custom watcher. This branch
has one explicit local backend patch for function argument-count lookups.
This remains a prototype: strict saved-index freshness and concurrent native-write
rename safety are not established. See [validation](dexter/VALIDATION.md).

## Build and validate

Follow [Dexter setup](dexter/README.md#build-and-run): build the pinned source and
reviewed local patch with `dexter/build.sh`, provide matching Elixir sources using
`DEXTER_ELIXIR_LIB_ROOT`, and run the real-server tests. Keep the adapter, binary,
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
startup instructions and disables known language-server plugins in each client's
project settings. New coding sessions do not configure the old MCP bridge;
unrelated inherited MCP servers remain available. Codex must trust the project
to load its project settings. Remove any separately configured legacy Elixir MCP
server before this pilot; the launcher does not rewrite global configuration.
The launcher does not change user-wide settings or shell approvals. A shell
denial must be reported, not bypassed.

Provisioning requires the shared `agent/lsp/dexter/vendor/dexter` build. Set
`TIPS_DEXTER_HOME` to an absolute adapter directory for a staged prototype pilot.
At first provisioning, sources default to the main checkout's
`agent/lsp/vendor/elixir-<version>/lib`, using the target worktree's
`elixir --short-version`. `DEXTER_ELIXIR_LIB_ROOT` overrides that default;
`dx` validates and remembers the selection per tree. Subsequent provisioning
keeps the saved selection, and a joining teammate cannot replace it.
A provisioning failure preserves the checkout and does not launch a coding agent.
Successful startup is not a promise of fresh results or successful compilation.

Same-team agents can explicitly join a task branch with `--share` and distinct
roles/panes. It cannot be combined with `--review-ref`; independent reviewers
still get their own detached worktrees by default. Shared agents must not change
configuration or switch the shared branch while teammates run. Main remains
merge-only while it contains nested team worktrees.

`team.py stop N` stops team clients, then calls each unique worktree's `dx stop`
before dropping databases/removing clean, merged worktrees. Recovery snapshots
move to a unique directory under the main checkout's `tmp/dexter-recovery/`;
retirement prints that path and never prunes it. A failed move preserves the
worktree and databases. That recovery directory is not disposable by default;
retention is local and best-effort, so move needed copies before cleaning `tmp/`.
A known external
Herdr teammate or a Dexter stop refusal preserves the worktree. Individual agent
exit never requests daemon shutdown. Unregistered/external clients remain outside
the team ownership contract: do not retire a tree they still use.

Do not run `git clean -x` in team worktrees: it removes the bound command, index
and recovery snapshots while the daemon may still be running. At merge, remove
the main checkout's user-owned legacy MCP entry that points to the deleted
`launch_worktree_lsp.sh`; this branch does not edit ignored local settings.

Run Mix compilation, Credo on edited Elixir files, and relevant tests after
`dx` mutations: shell-based edits do not trigger the native edit hooks.
Dexter's formatter
provides syntax diagnostics only. Per-worktree locks order cooperating `dx` writes;
native editing tools bypass them. Do not overlap native edits with an in-place
rename. The full limitations and recovery evidence are in the
[adapter guide](dexter/README.md#honest-limits).
