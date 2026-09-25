# Cold preparation: seed ElixirLS with project-built dependencies

Date: 2026-09-25. Owner: wH:pD. Independent review: wH:pQ. Decisions: Astra.

On a new Tips worktree, ElixirLS compiles all 60 dependencies into its private
build (`.elixir_ls/build`) before navigation works. The agent's first `mix test`
then compiles them again into `_build`. `neovim_prepare.py` compiles them once
with project Mix, before the client starts, and copies them into ElixirLS's build.
ElixirLS then compiles only Tips.

## Results

Tips `fd4e2da`, project Elixir 1.20.4 / OTP 29 (Homebrew), macOS arm64. All runs
under concurrent load (load average 5-12). Full evidence:
`tmp/elixirls-v2/beta-team/cold/RESULT.md`.

Three separate measures on a new worktree:

| Measure | Unseeded (r7) | Seeded |
| --- | ---: | ---: |
| Total: provisioning start to ElixirLS ready | about 98 s | about 63-69 s |
| Client start: Mix before the client starts | 21 s (`deps.get`) | 57-66 s (`deps.get` + `deps.compile` + 0.6 s copy) |
| After preparation: session start to ElixirLS ready | 77.2 s | 3.0-3.3 s |

- The client starts about 40 s later when seeded. The total is still about 30 s
  shorter, because ElixirLS no longer compiles dependencies after the client starts.
- Dependencies compile once instead of twice (ElixirLS, then the first `mix test`).
- The first launch of a newly copied bundle was slower after preparation: 5.7 s
  ready, 1.4 s to connect. The second launch was 3.3 s.
- Relaunching an existing worktree needs no Mix: 0.3 s, including bundle
  verification.

## How it works

1. **Fast path.** If `.elixir_ls/build/test/lib` already holds a dependency, report
   `ready` and run no Mix. ElixirLS or an earlier seed owns that build.
2. **Toolchain.** Use the project Mix from `PATH`, never the bundle's private one.
   Its Elixir version and OTP major must match the bundle; otherwise stop.
3. **Mix.** `mix deps.get --check-locked`, then `mix deps.compile`, with
   `MIX_ENV=test`. This is ElixirLS's default and the only environment the
   adapter uses. No input, output on stderr, no timeout.
4. **Seed each dependency.** Only directories in both `_build/test/lib` and
   `deps/`, so never the Tips app.
   - Every BEAM, compressed ones included, must name `<worktree>/deps/<dep>/`.
     Otherwise skip the dependency: navigation would open another checkout.
   - Copy to hidden staging, `.seed-<dep>-<id>`, which Mix ignores.
   - Retarget each relative link that leaves the copy (`priv`, `include`, `src`).
     The ElixirLS build is one directory deeper than `_build`.
   - Drop `.mix` manifests that name the normal `_build`. Mix's Erlang manifest
     lists outputs by absolute path; a later compile would delete them there.
   - If the source changed during the copy, skip. Otherwise publish with one
     rename. Never overwrite.
5. Write `.elixir_ls/.gitignore` (`*`), as ElixirLS does at startup.

ElixirLS's first build still checks each copy's Elixir/OTP version, lock, marker
and app file. It recompiles anything stale or skipped.

## Where it runs

Always under session ownership, before the client starts. Never inside `serve`:
Mix takes about a minute and must not delay MCP startup or touch its stdio.

- `bundle.py prepare-deps --workspace W`: stdout is the JSON report alone; Mix
  output goes to stderr. Exits 1 when a live or orphaned session owns W, W is not
  a Mix project, or the bundle fails verification.
- `bundle.py codex`: runs the same step after `configure`, inside the same
  ownership block, then execs Codex.
- `task_worktree.py --lsp neovim --start`: runs `prepare-deps` before the pane
  setup, in the client's environment. If it fails, the launcher prints the
  failure and still starts the client.

## Report

`status`: `seeded`, `ready` or `not-seeded`. Also `detail`; `seeded`, a list of
dependencies; `skipped`, a map of dependency to reason, each reason at most 500
characters; and `seconds` per step. `not-seeded` covers these cases:

- Mix is missing or is the bundle's.
- The toolchain version differs.
- Mix failed.
- No dependency could be copied.

In every one, ElixirLS compiles the dependencies itself, as before.

## Limits

- The client starts about 40 s later on a new worktree, while `deps.compile` runs.
  Callers that time out shell commands must allow for it.
- The fast path runs no `deps.get`. If `mix.lock` changed in an existing worktree,
  ElixirLS's own dependency check handles it, as before.
- A `_build` damaged outside Mix is copied as is; the normal build is equally
  broken. The only known cause is copying `_build` between worktrees. The project
  forbids that, and it also deletes the donor's files
  (`tmp/elixirls-v2/beta-team/cold/G1B_EVIDENCE.md`). To recover:
  1. Stop the session: exit Codex for that worktree. Its ElixirLS uses
     `.elixir_ls`.
  2. Confirm nothing owns the worktree:
     `bundle.py prepare-deps --workspace <worktree>` must not report "An existing
     session owns". If it does, a session or an orphaned server is still running.
     Stop it first.
  3. Run `rm -rf _build .elixir_ls` in the worktree.
  4. Run `bundle.py prepare-deps` again, or start with `bundle.py codex`.
- A shared, read-only dependency tree (G1b) was rejected: Phoenix and rebar3 write
  into `deps/` while compiling.

## Checks

```sh
python3 -m unittest discover -s agent/lsp/experiments/codex-elixirls-v2/tests \
  -t agent/lsp/experiments/codex-elixirls-v2 -p 'test_*.py'
```

- 11 tests on real directory trees, links and subprocesses.
- Ruff 0.16.8 and strict Pyright 1.1.413 pass.
- All 19 mutants, each removing one safeguard, are caught
  (`tmp/elixirls-v2/beta-team/cold/checks/`).
