# Neovim + ElixirLS beta: build, launch and roll back

This is an opt-in internal beta for Codex on macOS arm64. It does not change the
default Expert setup or any client-wide configuration. One Codex session owns one
worktree's language server.

## What an agent gets

- One MCP tool, `lsp`, with seven read-only operations: `hover`, `definition`,
  `references`, `document_symbols`, `workspace_symbols`, `diagnostics` and
  `workspace_diagnostics`. Edits use ordinary writing tools.
- Compiler feedback from two hooks: `PostToolUse` for `apply_patch` and `Bash`,
  and `Stop`. Each hook has a five-second budget, including a 250 ms window
  that collects nearby build triggers. The budget bounds the call into Neovim;
  Python start-up and output are outside it, so it is not a hard total cutoff.
- A slow build returns "pending". The error arrives with a later tool's hook or
  at `Stop`. Nothing arrives after the agent has stopped.
- A build that stops before it reaches the source files, such as a dependency,
  lock or config error, reports "failed". The only diagnostic is then on
  `mix.exs:1`. Run the normal `mix compile` to see the file and line.
- After a successful `mix deps.update` or tag bump of a Git dependency, the next
  build report uses the new dependency code (tested). A successful path-dependency
  update is not directly tested.
  A `mix.exs`, config or lock failure reports "failed". After the fix, the next build
  uses the current dependencies, including updates and removals made while builds
  failed. `only:`/`targets:` changes are reflected too, tested from a passing build
  only (all on small fixtures, not on a real project).
- `mix deps.get`, `deps.update`, `deps.unlock` and `deps.clean` wait while ElixirLS
  builds (a cold first build can take minutes), and ElixirLS waits while they run.
  Mix prints "Waiting for lock on the deps directory". Hooks still return within
  about five seconds and report pending.
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
  for the 150 ms quiet window, which still applies to diagnostics and hooks. Their
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
- If ElixirLS never publishes an open file (for example, its parser crashes), every
  tool call that changed files waits about 5 s until ElixirLS publishes that file
  (usually after it changes) or the file is closed. It reports
  either "Diagnostics for <file> have not arrived" or "could not be confirmed within
  the hook budget; validation remains unfinished". The next `Stop` then either blocks
  once after about 5 s or, after the second text, lets the turn end at once. Not seen in 331
  parses of 111 Tips files.
- "Current" after a build rests on a measured 150 ms quiet window, not a signal from
  ElixirLS. On an idle host the build's diagnostics came first in 30 of 30 builds. Under
  a slower schedule a hook may return before late diagnostics arrive; the delay and
  delivery in that case are not measured. `workspace_symbols` reindexes the whole
  project in the background after each build. It does not delay hooks or labels, so a
  query right after a build can be labelled current yet old (correct about 4.6 s after
  the build on one fixture); retry if a just-changed symbol is missing or old. An empty
  result never proves absence.
- The application keeps its normal compiler and `PATH`. The bundle's patched Mix
  runs only inside ElixirLS. Normal compile, tests, formatting and Credo remain
  required.

## Build a release

Host prerequisites: macOS arm64, Python 3.14.3, Elixir 1.20.4 with Erlang/OTP
29.1, Rust 1.97.0, plus `git`, `curl`, `patch` and `unbuffer` on `PATH`.
The installed bundle also needs the same host Python and OTP at run time.

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

## Launch

```sh
python3 /absolute/bundle/bundle.py codex --workspace /absolute/worktree -- -m gpt-6-sol
```

The team helper does the same with `--lsp neovim --neovim-bundle /absolute/bundle`.
The bundle path is required; there is no default. On a new worktree, allow about a
minute for dependency preparation before the client starts.

Both write `<worktree>/.codex/config.toml` and pass the two hooks as session
settings. The configuration starts the `lsp` MCP server, disables Expert and the
separate compiler-feedback plugin, and keeps Credo.

- Bare `codex` in the worktree gets no feedback. Codex 0.156.1 reads a linked
  worktree's hooks from the main checkout, so the hooks must come from this command.
- Use the same Python every time. The hook command contains its path, and Codex
  trusts the exact command.

## Review and check the hooks

Codex runs a hook only after you trust its exact definition. Do this after the
first launch of a bundle, and after every upgrade or rollback, before any agent work.

1. In Codex, open `/hooks`.
2. Find the two hooks named "Reading ElixirLS compiler feedback": `PostToolUse`
   with matcher `^(apply_patch|Bash)$`, and `Stop`.
3. Check the command: `<python> /absolute/bundle/bundle.py hook --workspace "$PWD"
   --state "$PWD/.elixir_ls/session" --budget-ms 5000`, with the bundle you chose.
   Trust both.
4. Prove it with the read-only check, using the same bundle and Python:

   ```sh
   python3 /absolute/bundle/bundle.py verify-hooks --workspace /absolute/worktree
   ```

   It prints both hooks and exits 0 only when both are enabled and trusted.

The check asks `codex app-server --stdio` for `hooks/list`, with the launch's own
session settings. It changes nothing. Codex labels the `app-server` command
experimental; `hooks/list` is part of its stable protocol schema.

A hook marked untrusted or modified does not run. The `lsp` tool still works, but
compiler feedback is missing, with no error. Treat that as unfinished setup, not
as a working beta session.

Codex keeps one trusted hash per hook position. Trusting one bundle's hooks
therefore un-trusts another bundle's hooks. Every switch needs a new review.

## Stop and restart

- Closing Codex stops the session. Before it releases the worktree lock, Neovim
  stops ElixirLS and the compiler's process groups it has found: groups below it
  at that moment and groups it recorded earlier. This also covers Codex's forced
  stop of the MCP server and an ElixirLS crash. If Neovim itself dies, the launcher
  stops the groups Neovim last recorded. Known limits lists what these miss.
- An idle session stops in about 0.1 s. A session whose build waits on programs
  that ignore SIGTERM stops in about 2.2 s: 1.5 s grace, then SIGKILL.
- A new session waits up to 3 s for an old one to finish, so an immediate restart
  works. A second session while one is live is refused after about 3.5 s. This
  startup wait is separate from the five-second hook budget.
- On a slow host a restart can still be refused while the old session stops.
  Nothing is changed; retry after a few seconds.

## Switch bundles or roll back

1. Stop the Codex session in that worktree and wait for it to exit.
2. Relaunch with the other bundle and `--force`:

   ```sh
   python3 /absolute/saved-bundle/bundle.py codex --workspace /absolute/worktree --force -- ...
   ```

   Without `--force`, the command refuses, because the worktree's configuration
   names the other bundle. The team helper needs `--force` for the same reason.
3. Review the hooks and run `verify-hooks` again, as above.

The worktree keeps its ElixirLS build. A switch to the saved bundle and back needed
no full rebuild on this host: each was ready in about 3 s.

## Recovery

- Codex says `required MCP servers failed to initialize: elixir_neovim: handshaking
  with MCP server failed: connection closed`: another session still owns this
  worktree. Codex hides the reason. `bundle.py codex` prints it before Codex starts:
  "An existing session owns ...". Close the other session, or retry after a few
  seconds if it is still stopping.
- A session that stays refused has a stopped or hung owner. Find it, stop it, then
  relaunch:

  ```sh
  lsof <worktree>/.elixir_ls/session.lock <worktree>/.elixir_ls/server.lock
  kill <pid>
  ```

  Use plain `kill`, not `kill -9`: the owner then stops its compiler programs
  first. If `lsof` lists the Python launcher, stop that one; its cleanup also
  covers a hung Neovim. If `ps -o stat= -p <pid>` shows `T`, the owner is stopped:
  `kill -CONT <pid>` lets it finish its own cleanup.

- "ElixirLS exited" or "ElixirLS feedback unavailable": this session has stopped.
  Restart the coding client in the same worktree. There is no automatic restart.
- A suspected broken ElixirLS build: stop the session first, then delete
  `<worktree>/.elixir_ls/build` and relaunch. Preparation copies the dependencies
  again from `_build`. If the problem persists, also delete `<worktree>/_build`;
  the next launch then compiles the dependencies again (about a minute).

## Known limits

- macOS arm64 only, pinned to Python 3.14.3 and OTP 29.1. A Homebrew upgrade of
  either stops the bundle until a matching one is built; `doctor` names the mismatch.
- Codex only. Claude Code support is not tested.
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
- The hook's Neovim may consume feedback up to 100 ms before the hook's own cutoff. If
  the reply then arrives late, the agent gets the deadline text and that feedback is
  not repeated.
- The hook's own timeout kills and reaps its Neovim client (measured). If something
  outside the hook SIGKILLs the hook, its client keeps running until Neovim answers or
  exits (inferred, not measured).
- LSP error text is not shortened; a crashed request can carry a multi-KB trace. For
  `hover` and the symbol operations the error reaches the agent only through the
  feedback message. A cancelled request (`RequestCancelled`) reads as `timeout`.
- Git-ignored inputs (a `deps/` path dependency, ignored sources) are invisible until
  ElixirLS starts building them; a request answered before then is labelled from the
  last completed build.
- One session per worktree. The locks do not stop editors or servers that ignore
  them.
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
- Neovim, ElixirLS, the MCP server and the hooks run outside the Codex sandbox.
  ElixirLS compiles the worktree, which runs project code such as `mix.exs` and
  macros. As with any compiling language server, trust the worktree's code.

## Checks and evidence

[CHECKS.md](../../CHECKS.md) lists the lint, type and language-server checks.
Installed-boundary probes, each taking `--bundle`:

- `beta_operational_probe.py`: ownership, crash, reconnect and cleanup.
- `beta_crash_orphan_probe.py`: an ElixirLS crash stops the programs it started
  before the lock is released.
- `beta_python_entry_probe.py`: the server runs the verified Python.
- `beta_rollback_probe.py`: switch a Tips worktree between bundles through the
  generated configuration and hook command. It does not test Codex trust.
- `beta_feedback_probe.py` and `beta_performance_probe.py` (`--prepared` after
  dependency preparation): feedback and timings.
- `first_touch_acceptance.py` (also `--output`): diagnostics readiness on its own
  fixture, with delayed, dropped and replayed publications, edits, reloads and hooks.
  It is the harness in CHECKS.md's pinned-internals table.
- `hook_contract_probe.py` (also `--output`): the bundled hook's PostToolUse and Stop
  text contract (publication pending, deadline) on the harness fixture; exits 1 on a
  failed check (CHECKS.md).
- `neovim_reconcile_probe.py` (also `--vendor <bundle>/vendor` and `--output`):
  unopened edits, delete, recreate and edit-during-build with the native watcher
  cancelled.
- `workspace_symbols_crash_probe.py` (also `--output`): the symbol index survives
  modules that a build removes while it reads them. Timing-sensitive; an optional
  maintenance check, not a gate (CHECKS.md).

[BETA_IMPLEMENTATION.md](BETA_IMPLEMENTATION.md) records the r7 cohort and gates.
[COLD_PREPARATION.md](COLD_PREPARATION.md) describes dependency preparation.
