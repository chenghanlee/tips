# Neovim + ElixirLS beta: operator guide

This is an opt-in internal beta for Codex on macOS arm64. It does not change the
default Expert setup or any client-wide configuration. One Codex session owns one
worktree's language server.

Nothing reports compiler results automatically. The agent asks the `lsp` tool and
validates explicitly before calling work done.

Follow the sections in order, from Prerequisites to Switch bundles or roll back.
Known limits apply throughout. The Reference sections are for builders and maintainers.

## Prerequisites

- A bundle from [Build a release](#build-a-release), with its manifest SHA-256
  recorded. Never change an installed bundle.
- The same host Python 3.14.3 and Erlang/OTP 29.1 the bundle was built with.
  `python3 /absolute/bundle/bundle.py doctor` names a mismatch.
- `codex` on `PATH`, and a worktree that Codex trusts (see Configure and launch).
- GNU `timeout` on `PATH` for Explicit validation (macOS: `brew install coreutils`).

## Prepare a worktree

- The workspace must contain `mix.exs`.
- Fetch dependencies first with `mix deps.get`.
- `bundle.py codex` and the team helper prepare ElixirLS dependencies before the
  client starts. You can also run this step on its own:

  ```sh
  MIX_ENV=test python3 /absolute/bundle/bundle.py prepare-deps --workspace /absolute/worktree
  ```

  It compiles the dependencies once with the project's own Mix, then copies them
  into ElixirLS's private build in the same worktree. It never copies a build from
  another worktree. It prints one JSON line. If it fails, ElixirLS compiles the
  dependencies itself, as before.

Measured on a new Tips worktree on this host:

| Step | Time |
| --- | --- |
| `mix deps.get` | 17 s |
| Dependency preparation after `mix deps.get` | 43 s |
| Dependency preparation including its own fetch | 56 to 61 s |
| ElixirLS ready after preparation | 3 to 4 s |
| ElixirLS ready without preparation | 67 s |

Later sessions in the same worktree are ready in about 3 s. Preparation then
reports that it has nothing to do.

## Configure and launch

```sh
python3 /absolute/bundle/bundle.py codex --workspace /absolute/worktree -- --no-daemon -m gpt-6-sol
```

`bundle.py codex` passes everything after `--` to Codex. `--no-daemon` runs Codex in its own
process, so its shell commands get this launch's environment. Codex 0.157.0's shared
app-server daemon gave them the environment of the launch that started the daemon instead
(measured, see Team use below). The flag leaves a running daemon alone.

The team helper does the same with `--lsp neovim --neovim-bundle /absolute/bundle`, and also
passes `--no-daemon`.
The bundle path is required; there is no default. On a new worktree, allow about a
minute for dependency preparation before the client starts.

Both write `<worktree>/.codex/config.toml`. It starts the `lsp` MCP server and
disables Expert and the automatic `mix-compile` and `mix-credo` plugin hooks in this
worktree only. User-level and other hooks are unchanged. The beta adds no hooks, so
there is no hook trust step. Codex loads this file only in a Codex-trusted worktree;
in an untrusted one there is no `lsp` server and the plugin settings do not apply. In a
trusted worktree, `codex --no-daemon` also works once the file exists. `bundle.py configure`
with the same arguments writes the file only, without preparation or Codex.

Team use: in a Codex 0.157.0 test, a second worktree's session on the shared app-server
daemon ran shell commands with the daemon's `TIPS_DB_SUFFIX` and ports and without `MIX_ENV`;
the same launch with `--no-daemon` had the right values. The flag covers only this guide's
commands and the team helper's `--lsp neovim` launch; other Codex versions and generic manual
Codex launches outside these paths are not covered. Keep this check for now: before any
command that can write a database (`mix test`, `mix precommit`,
`mix setup`, migrations or other Ecto tasks), check in the agent's shell that `PGPORT`,
`TIPS_DB_SUFFIX`, `TIPS_TEST_PORT` and `MIX_ENV` equal the values the team helper set for
this worktree (ports and suffix from [agent/teams/config.toml](../../../teams/config.toml)
for the team and role; `MIX_ENV` is always `test`), for example with
`env | grep -E '^(PGPORT|TIPS_DB_SUFFIX|TIPS_TEST_PORT|MIX_ENV)='`. Stop on a mismatch.
These four are the helper's values, not the whole database target: also confirm that any
`PGHOST`, `PGUSER` or `MIX_TEST_PARTITION` override points at the intended local database
(defaults `localhost`, `postgres`, unset). Do not print `PGPASSWORD`.
Reading, editing and compiling without database side effects are not affected.

`--lsp-approval-mode` sets Codex's per-tool approval mode for `lsp`
([Codex MCP settings](https://developers.openai.com/codex/mcp)). The commands in this
guide use the default, `prompt`. The team helper takes the mode from
`launch.codex_lsp_approval_mode` in [config.toml](../../../teams/config.toml) (`approve`);
the acceptance setup also uses `approve`. `bundle.py codex` rewrites the configuration
on every run, so repeat the worktree's mode on every later `configure` or `codex`
command. A different mode, bundle or Python path refuses with "Configuration differs;
inspect it before using --force".

## Use the seven operations

The `lsp` tool has seven read-only operations. Edits use ordinary writing tools.
Pass an absolute path in `uri`. Positions are 1-based line and character (UTF-16
code units; on ASCII lines, the plain column).

| Operation | Answers |
| --- | --- |
| `hover` | Documentation and signature at a symbol |
| `definition` | Source locations of a symbol |
| `references` | Usages in files the ElixirLS build compiles (usually `lib/` and `test/support/`) and in the queried file. Before an API change, also text-search tests, config and scripts |
| `document_symbols` | Symbols in one file |
| `workspace_symbols` | The file that defines a public module, function, macro, type or callback compiled by the build (not `defp`, tests, scripts or deps). Needs `query` |
| `diagnostics` | Cached compiler diagnostics for one file |
| `workspace_diagnostics` | Cached compiler diagnostics at or under the path in `uri`; pass the project root for all files |

## Read the status

Every answer carries a status and a message.

| Status | Meaning | Do |
| --- | --- | --- |
| `current` | The last observed build completed and matches the files | Use the answer. It is not validation |
| `pending` | A build is running or queued, a file's diagnostics have not arrived, or a build ended during the request | Retry the same request in about 1 s. A cold first build can take minutes |
| `superseded` | Files changed during the request | Retry |
| `unanswered` | No client answered: `timeout` or a server error | Retry. It is not an empty result |
| `starting` | ElixirLS is still starting | Retry in about 1 s |
| `sync_error` | A scan, reload or save failed; the next request retries it | Retry. Cached results may be stale |
| `failed` | The last build failed. If it stopped before the source files (a dependency, lock or config error), the only diagnostic is on `mix.exs:1` | Read the diagnostics. For `mix.exs:1`, run the normal `mix compile` to see the file and line |
| `conflict` | Neovim has unsaved changes and refused a reload. The beta has no MCP writes, so this is not expected | A retry does not clear it. Restart the coding client |
| `exited` | ElixirLS exited | Restart the coding client in the same worktree |

An empty answer never proves absence: check the position and the operation's scope.
Pending, unanswered and empty answers are not a clean build.
[Status details](#status-details) has the exact rules.

## Explicit validation

After the last edit, run `mix format` (it can rewrite files), then run as its own
command:

```sh
MIX_ENV=test timeout --foreground -k 5 90 mix compile --force --warnings-as-errors
```

Exit 0 passes only if nothing was written during or after the command and the tool
reports no interrupt, background move or timeout; otherwise it is unfinished, even
with exit 0. Exit 1 is a compile error or warning. Exit 124 or 137 is unfinished:
rerun, with a larger limit if needed. A timeout does not guarantee that every
program the compile started has exited; a compile-time program that detaches can
still write later (Known limits).
GNU `timeout` bounds the compile. If your tool has its own command timeout, set it
to at least 120 s (Claude Code Bash). If the tool returns a `session_id` instead of an
exit code (Codex `exec_command`, `tty` off), the command is still running; that is not
a background move. Call `write_stdin` on that `session_id` with empty `chars` until a
result has an exit code, and edit nothing meanwhile.
Use this exact command. It is the tested argv. Do not wrap it in `unbuffer`, even
though the general Elixir check convention uses it for other Mix commands: `unbuffer`
puts Mix behind a new pseudo-terminal, so `timeout` would signal and wait for
`unbuffer`, not Mix, and Mix's process group would change. Reaping and timeout
delivery with `unbuffer` are not established (untested). This command is the compile
validation step; an incremental `unbuffer mix compile` or `mix precommit` does not
replace it, though both may run afterwards.
Plain incremental `mix compile` can miss same-second or timestamp-preserving edits.
Do not add `--force` to `mix test` or `mix precommit`; aliases ignore it. Afterwards
run `mix credo --strict` on edited files and `mix test`. The compile does not replace
them; a skipped check is unfinished, not passed. A compile in the shell does not
reload modules in the ElixirLS VM; ElixirLS rebuilds on its own.
On Tips a warm check took about 1.3 s, and a cold test build with dependencies 44 s
(one host, indicative).

## Stop, recover and relaunch

- After Codex closes, Codex stops the MCP server. With `--no-daemon`, as in this guide, the
  worktree was free at the first check after close (one Codex 0.157.0 run). Without the flag,
  Codex's shared app-server daemon stopped it 60 s after close in the 0.157.0 acceptance run.
  Before the session releases the worktree lock, Neovim stops ElixirLS and the compiler's process
  groups it has found: groups below it at that moment and groups it recorded earlier.
  This also covers Codex's forced stop of the MCP server and an ElixirLS crash. If
  Neovim itself dies, the launcher stops the groups Neovim last recorded. Known limits
  lists what these miss.
- Once Codex stops it, an idle session exits in about 0.1 s. A session whose build waits
  on programs that ignore SIGTERM exits in about 2.2 s: 1.5 s grace, then SIGKILL.
- A new session waits up to 3 s for an old one to finish. Until the old session releases
  the worktree, a new session is refused after about 3.5 s. Wait for the existing session
  to release, then start again. Nothing is changed.
- Codex says `required MCP servers failed to initialize: elixir_neovim: handshaking
  with MCP server failed: connection closed`: Codex hides the reason. It can mean that
  another session still owns this worktree; other startup failures show the same message.
  `bundle.py codex` runs the same lock and bundle checks before Codex starts and prints what
  fails there, for example "An existing session owns ...". Check that output and the locks
  below. If another session owns the worktree, close it, or wait for it to release (it may
  still be stopping after Codex closed) and retry.
- A session that stays refused has an owner that is still active (Codex may keep it for a
  while after close), stopped or hung. Find it. Wait for an active owner to release; do not
  stop it only because it is still running. Stop a stopped or hung owner, then relaunch:

  ```sh
  lsof <worktree>/.elixir_ls/session.lock <worktree>/.elixir_ls/server.lock
  kill <pid>
  ```

  Use plain `kill`, not `kill -9`: the owner then stops its compiler programs
  first. If `lsof` lists the Python launcher, stop that one; its cleanup also
  covers a hung Neovim. If `ps -o stat= -p <pid>` shows `T`, the owner is stopped:
  `kill -CONT <pid>` lets it finish its own cleanup.

- "ElixirLS exited": this session has stopped. Restart the coding client in the
  same worktree with the same command. There is no automatic restart.
- A suspected broken ElixirLS build: stop the session first, then delete
  `<worktree>/.elixir_ls/build` and relaunch. Preparation copies the dependencies
  again from `_build`. If the problem persists, also delete `<worktree>/_build`;
  the next launch then compiles the dependencies again (about a minute).

## Switch bundles or roll back

1. Stop the Codex session in that worktree and wait for it to release the
   worktree (see Stop, recover and relaunch).
2. Relaunch with the other bundle and `--force`, plus the worktree's
   `--lsp-approval-mode` if it is not `prompt`:

   ```sh
   python3 /absolute/saved-bundle/bundle.py codex --workspace /absolute/worktree --force -- --no-daemon ...
   ```

   Without `--force`, the command refuses, because the worktree's configuration
   names the other bundle. The team helper needs `--force` for the same reason.

The worktree keeps its ElixirLS build. A switch to the saved bundle and back needed
no full rebuild on this host: each was ready in about 3 s.

### Roll back to r24

The rollback target is the frozen, hook-based r24 bundle, manifest SHA-256
`b3e8891c33c0259a7b4f2210219e50e477c5e41aeb525e3834d91b8a3b7a640f` (path in
[NO_HOOKS_PLAN.md](NO_HOOKS_PLAN.md)). It differs from this beta:

- Launch it with r24's own `bundle.py codex`, as in step 2 (with `--no-daemon`). It adds r24's
  two compiler-feedback hooks to the Codex session. This branch's team helper does
  not, so it would start r24 without its hooks.
- Before any agent work, review and trust both hooks in `/hooks`, then run r24's
  `verify-hooks`. Follow "Review and check the hooks" in the r24 guide:
  `git show a388e4d:agent/lsp/experiments/codex-elixirls-v2/INSTALL.md`.
- r24's configuration turns the automatic `mix-credo` plugin back on in that
  worktree.

To return, relaunch with this beta's bundle and `--force`. r24 passed its hooks only
as launch settings, so returning needs no hook step. The switch to r24 and back
passed through the generated configuration and MCP entry (`beta_rollback_probe.py`);
that test does not cover Codex hook trust.

## Known limits

- macOS arm64 only, pinned to Python 3.14.3 and OTP 29.1. A Homebrew upgrade of
  either stops the bundle until a matching one is built; `doctor` names the mismatch.
- Codex only. Claude Code support is not tested.
- Explicit validation depends on the agent running it. Nothing enforces it; a
  skipped or interrupted check is unfinished.
- Every `lsp` request scans the worktree's non-ignored source files before and after
  it. On a 20-file fixture the two scans took most of a 13 to 20 ms warm request; on
  Tips they would take about 27 ms (inferred from one 13.6 ms scan). The cost grows
  with the number of files.
- Dependency reloading is tested with path and Git dependency updates in plain Mix
  projects. Not tested: updates or removals of rebar3, make or NIF dependencies, a
  Hex version update end to end, umbrella projects, and hosts other than macOS.
  Cold builds, including a rebar3 dependency, are tested.
- ElixirLS compiles the project in its own VM, which also holds ElixirLS's own
  applications. A project dependency with the same application name as one of them
  (for example `typed_struct` or `nimble_parsec`) leaves compile-time callers one build
  behind after that dependency updates, while the status says current; the next edit
  of a caller or a forced compile clears it. A dependency that defines one of ElixirLS's
  modules is wrong from the first build. Both are unsupported. Current Tips
  dependencies have no such overlap (checked 2026-09-25); future ones are not checked.
- LSP error text is not shortened; a crashed request can carry a multi-KB trace. For
  `hover` and the symbol operations the error reaches the agent only through the
  feedback message. A cancelled request (`RequestCancelled`) reads as `timeout`.
- Git-ignored inputs (a `deps/` path dependency, ignored sources) are invisible until
  ElixirLS starts building them; a request answered before then is labelled from the
  last completed build.
- One session per worktree. The locks do not stop editors or servers that ignore
  them.
- Ending a session (EOF) while a compile waits on a program it started can leave
  one stale registry entry. The next start removes it.
- Session files that r24 leaves in a worktree, such as `environment.startup.json`,
  are ignored; nothing reads them.
- Feedback describes the last build ElixirLS observed, not exact source bytes.
  File histories missed between observations (A to B to A) are outside the contract.
- A program that detaches from the compiler, such as a compile-time `cmd &` whose
  shell exits at once, is never tracked. It survives even a normal exit and can
  write into the worktree later.
- Neovim records the compiler's programs about every 250 ms. If Neovim dies
  (a crash or SIGKILL), a program started in the last 250 ms can be missed. If
  Neovim and the launcher are both killed with SIGKILL, nothing stops the programs.
  If Neovim cannot write its record (disk full, permissions), it logs one line in
  `.elixir_ls/session/environment.nvim.log`, and a Neovim crash in that session
  leaves the programs running. In all these cases the lock is free within a second,
  but those programs keep running and can still write into the worktree. Before
  relaunching, list processes working in the worktree with
  `lsof -d cwd | grep "$(realpath <worktree>)"` (`/tmp` is `/private/tmp` on macOS),
  wait for them to end, then delete `<worktree>/.elixir_ls/build`.
- Neovim, ElixirLS and the MCP server run outside the Codex sandbox.
  ElixirLS compiles the worktree, which runs project code such as `mix.exs` and
  macros. As with any compiling language server, trust the worktree's code.

## Reference

### Status details

- After a successful `mix deps.update` or tag bump of a Git dependency, the next
  build report uses the new dependency code (tested). A successful path-dependency
  update is not directly tested.
  A `mix.exs`, config or lock failure reports "failed". After the fix, the next build
  uses the current dependencies, including updates and removals made while builds
  failed. `only:`/`targets:` changes are reflected too, tested from a passing build
  only (all on small fixtures, not on a real project).
- `mix deps.get`, `deps.update`, `deps.unlock` and `deps.clean` wait while ElixirLS
  builds (a cold first build can take minutes), and ElixirLS waits while they run.
  Mix prints "Waiting for lock on the deps directory". `lsp` requests still answer
  and report pending.
- This is Mix's own deps-directory lock, taken through `Mix.Project.with_deps_lock`, a
  hidden (`@doc false`) Mix API. It works only when both sides use the same
  `deps` directory and `TMPDIR`, and `MIX_OS_CONCURRENCY_LOCK` is not `0` or
  `false`. The bundle sets none of these. Commands in the Codex sandboxed shell and
  processes outside it wait for each other.
- Not covered: changes to `deps/` or `mix.lock` that bypass Mix's lock (`git
  checkout`, merge or rebase, manual edits) while ElixirLS builds. Normal source
  edits are not affected. If results look stale after such a change, restart the
  coding client to restart ElixirLS.
- A deps task stuck at a prompt keeps ElixirLS pending until the task exits.
- `hover`, `definition`, `references` and `document_symbols` return `current` once no
  build is running or queued, the last build matches the current files, and ElixirLS
  has published diagnostics for the text last sent for this file. They do not wait
  for the 150 ms quiet window, which still applies to diagnostics. Their
  `current` text makes no diagnostics claim.
- A file ElixirLS has not published yet gives "Diagnostics for <file> have not arrived
  from ElixirLS yet ... Returned results may be incomplete or stale". A `diagnostics`
  read of a newly opened file stays pending until ElixirLS publishes that file: about
  0.5 s in tests, about 2 s for a slow parse.
- `pending` with "Compilation finished while this request ran ... Retry the query."
  means a build ended during the request, including builds of git-ignored inputs such
  as `deps/` path dependencies.
- `unanswered` with "No answer (<client>: <error>). This is not an empty result; retry
  the query." means every client failed; `<error>` is `timeout` or the server's error
  as Neovim formats it. When only some clients failed, the answers are kept and
  "No answer from <client>: <error>; results may be incomplete." is appended.
- `document_symbols` adds "This file has errors in its current diagnostics, so its
  symbols may be incomplete ..." when ElixirLS's diagnostics for the current text
  contain an error. `exited` and `conflict` are never replaced by a retryable status.
- If ElixirLS never publishes an open file (for example, its parser crashes), requests
  that cover that file report "Diagnostics for <file> have not arrived" until ElixirLS
  publishes it or the file is closed. Not seen in 331 parses of 111 Tips files.
- "Current" after a build rests on a measured 150 ms quiet window, not a signal from
  ElixirLS. On an idle host the build's diagnostics came first in 30 of 30 builds. Under
  a slower schedule a diagnostics request may read `current` before late diagnostics arrive; the delay and
  delivery in that case are not measured. `workspace_symbols` reindexes the whole
  project in the background after each build. It does not delay labels, so a
  query right after a build can be labelled current yet old (correct about 4.6 s after
  the build on one fixture); retry if a just-changed symbol is missing or old. An empty
  result never proves absence.
- The application keeps its normal compiler and `PATH`. The bundle's patched Mix
  runs only inside ElixirLS. Explicit compile, tests, formatting and Credo remain
  required.

### Build a release

Build prerequisites: macOS arm64, Python 3.14.3, Elixir 1.20.4 with Erlang/OTP
29.1, Rust 1.97.0, plus `git`, `curl`, `patch` and `unbuffer` on `PATH`.

Build every release into a new directory. Never change an installed bundle: a
live session may be using it, and its manifest pins its files.

```sh
python3 agent/lsp/experiments/codex-elixirls-v2/build_bundle.py \
  --destination "$PWD/agent/lsp/vendor/elixirls-neovim-beta-rN" \
  --cache "$PWD/tmp/elixirls-bundle-cache"
shasum -a 256 agent/lsp/vendor/elixirls-neovim-beta-rN/manifest.json
```

The build ends by running `bundle.py doctor`. A failed build has no manifest;
start again in another new directory. Record the manifest SHA-256 with the release.

- Downloads are checked against `bundle-lock.json`. ElixirLS and Cargo use their
  upstream lock files. Hex 2.5.1 is built from pinned source for OTP 29.
- rebar3 3.25.1 is a pinned, checked download. The build installs it where Mix
  looks for it, so ElixirLS does not download rebar3 at run time, even when Hex
  is unreachable.
- The recipe applies the pinned Mix, ElixirLS and vv-mcp patches. It never copies
  an earlier experimental build.
- The manifest hashes the Mix, server, bridge, adapter, entry and `mix-home`
  files and the Neovim binary. It does not hash the rest of the copied Elixir tree,
  Neovim's runtime files, `vendor/python` or `toolchain/bin`. `doctor` and `serve`
  reject a changed hashed file or a different Python, Elixir or OTP version.
- Bundles built by this recipe after r23 also carry `build_bundle.py`, the recipe
  that built them, and the manifest hashes it. r23 and earlier bundles do not.
- The bundle can move to another directory. The first run adds
  `adapter/__pycache__/`; manifest files do not change.

### Checks and evidence

[CHECKS.md](../../CHECKS.md) lists the lint, type and language-server checks.
Installed-boundary probes, each taking `--bundle`:

- `beta_operational_probe.py`: ownership, crash, reconnect and cleanup.
- `beta_crash_orphan_probe.py`: an ElixirLS crash stops the programs it started
  before the lock is released.
- `beta_python_entry_probe.py`: the server runs the verified Python.
- `beta_rollback_probe.py`: switch a Tips worktree between bundles through the
  generated configuration and MCP entry.
- `beta_feedback_probe.py`: feedback through ordinary `lsp` requests.
- `first_touch_acceptance.py` (also `--output`): diagnostics readiness on its own
  fixture, with delayed, dropped and replayed publications, edits and reloads.
  It is the harness in CHECKS.md's pinned-internals table.
- `hookfree_recovery_gate.py` (also `--output`; `--mutant no-scan|drop-failed`
  must fail): a metadata-preserved resource edit, deletion and recreation, a
  rejected watcher notification, a new file with a syntax error and an edit during
  a build, with the native watcher cancelled and recovered only by ordinary `lsp`
  requests; then EOF cleanup during a compile and a restart. Exit 1 is FAIL,
  2 INCONCLUSIVE.
- `seven_ops_acceptance.py` (also `--output`; `--compose` adds the explicit check
  beside the live LS; `--control always-current` must fail): the seven-operation
  gate. It judges answer content from ordinary `lsp` requests on its own fixture.
  Exit 1 is FAIL, 2 INCONCLUSIVE; rerun an inconclusive result (CHECKS.md).
- `hooks_list_gate.py <worktree> <bundle>`: in a configured, Codex-trusted worktree,
  checks that Codex loads no bundle hook and no `mix-credo` or `mix-compile` hook,
  with a positive control. Exit 0 is PASS; rerun after a Codex upgrade (CHECKS.md).
- `workspace_symbols_crash_probe.py` (also `--output`): the symbol index survives
  modules that a build removes while it reads them. Timing-sensitive; an optional
  maintenance check, not a gate (CHECKS.md).

[COLD_PREPARATION.md](COLD_PREPARATION.md) describes dependency preparation.

Historical (hook era):

- `beta_performance_probe.py` measured timings through the removed hooks. It calls
  the removed `bundle.py hook` mode, so it fails on this beta's bundles.
- [BETA_IMPLEMENTATION.md](BETA_IMPLEMENTATION.md) records the r7 cohort and gates.
