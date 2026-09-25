# Checks for maintained integration code

The Neovim beta runtime still lives under `experiments/codex-elixirls-v2/`.
These files are maintained code, despite that directory name:

- `bundle.py`, `build_bundle.py`, `neovim_launcher.py`, `neovim_prepare.py`
- `neovim_init.lua`, `neovim_owner.lua`, `neovim_sync.lua`, `neovim_feedback.lua`
- The pinned compiler, ElixirLS and vv-mcp patches copied by `build_bundle.py`

The [Python profile](pyproject.toml) explicitly selects the four Python files
and the dependency preparation tests, plus three gate probes,
`hookfree_recovery_gate.py`, `seven_ops_acceptance.py` and `hooks_list_gate.py`, for Ruff
only (not strict Pyright).
Historical probes, research, generated bundles and dependency sources are excluded.
When adding a maintained runtime Python file, add it to both check lists in that profile.

Python rules follow agent-team-harness's Python profile: Ruff lint and formatting,
100-character lines, and strict Pyright. The configuration extends the same rules
already used by [agent/teams](../teams/pyproject.toml).

```sh
ruff check agent/lsp agent/teams
ruff format --check agent/lsp agent/teams
pyright --project agent/lsp/pyproject.toml
pyright --project agent/teams/pyproject.toml
python3 -m unittest discover -s agent/teams/tests -t agent/teams -p 'test_*.py'
python3 -m unittest discover -s agent/lsp/experiments/codex-elixirls-v2/tests \
  -t agent/lsp/experiments/codex-elixirls-v2 -p 'test_*.py'
```

CI runs those commands. A local pass does not establish that CI ran. The final
local check uses cached Ruff 0.16.8 and installed Pyright 1.1.413, matching CI's
pins. Use installed tools; do not silently install a different toolchain.

The subprocess exceptions are narrow and independently reviewed by Fable: fixed
bundled or explicitly resolved executables, separate arguments, no shell. They do
not suppress complexity checks, type checks, or arbitrary files.

## Language-server checks

The harness uses Pyright for Python definition, references, hover and diagnostics.
This session has no `codex-lsp-bridge` MCP tool, so the beta checks connect Neovim
directly to the installed `pyright-langserver --stdio`. The live check opens the
maintained Python files, requests their pull diagnostics, and checks hover,
definition and references at the `Build.check_rust()` call. A published empty
diagnostic cache is not substituted for a completed diagnostic request.

For this one-shot check, file-watch registration is disabled: no files change
during the check, and recursively watching the vendored bundle exhausted the
host's descriptor limit in the initial probe. This changes only the check client,
not the ElixirLS integration's watcher behavior.

Lua uses Luacheck 1.2.0 with the `luajit` standard and the adjacent `.luacheckrc`.
The config declares Neovim's `vim` global and permits only the fields intentionally
written by the runtime or boundary tests. From `experiments/codex-elixirls-v2`, run:

```sh
luacheck --codes neovim_init.lua neovim_owner.lua neovim_sync.lua neovim_feedback.lua neovim_patch_boundaries.lua
```

`neovim_patch_boundaries.lua` holds 21 boundary checks.

This is a local lint/static-analysis check; CI does not yet run it. A Lua language
server remains unavailable, so no Lua LSP pass is claimed. The Lua core runs against
an installed bundle in `first_touch_acceptance.py` (see Pinned internals) and in the
probes listed in [INSTALL.md](experiments/codex-elixirls-v2/INSTALL.md#checks-and-evidence).
The older probes that start Neovim by hand from a `--vendor` directory, such as
`neovim_patch_probe.py` and `neovim_revision_probe.py`, are historical records, not
gates. They predate `bundle.py`, do not copy `neovim_owner.lua`, which
`neovim_init.lua` requires, and leave `V2_ELIXIR_LS` unset, which selects Homebrew's
unpatched `elixir-ls`. On r23, six of them failed at startup or on their first check.
`neovim_reconcile_probe.py` is also historical: it drives recovery through the
deleted hook. `hookfree_recovery_gate.py --bundle` replaces it and triggers
recovery through ordinary `lsp` requests only; `--mutant no-scan` and
`--mutant drop-failed` must fail.

`seven_ops_acceptance.py --bundle` is the seven-operation gate. It builds a fixture and
judges answer content from ordinary `lsp` requests: first reads, valid empties and scope,
UTF-16 columns, changed doc and spec, moved definitions, references, symbol renames, a
compile error and its repair, an edit during a running build, and unanswered timeouts.
`--compose` also runs the explicit check from `AGENTS.md` beside the live LS; it needs
`mix` and GNU `timeout` on PATH. Exit 0 is pass, 1 is a failure or cleanup problem, and
2 is inconclusive: a required condition, such as an LS build while the CLI runs, did not
occur. Rerun an inconclusive result; it is not a pass. From the repository root:

```sh
B="$PWD/agent/lsp/vendor/elixirls-neovim-beta-rN"
G=agent/lsp/experiments/codex-elixirls-v2/seven_ops_acceptance.py
PYTHONDONTWRITEBYTECODE=1 python3 "$G" --bundle "$B" --output "$(mktemp -d)/seven" --compose
PYTHONDONTWRITEBYTECODE=1 python3 "$G" --bundle "$B" --output "$(mktemp -d)/control" \
  --control always-current
```

The first command must exit 0 with empty `failed` and `inconclusive`. The negative control
must exit 1 with `"control_caught": true`: every failure is a wrong or empty `current`
answer and cleanup is clean. Each output directory holds the full `results.json`.

`hooks_list_gate.py <worktree> <bundle>` checks which hooks Codex loads for a configured,
Codex-trusted worktree, through Codex's read-only `hooks/list`. It must exit 0 (PASS): the
config names the bundle, no hook runs the bundle, no `mix-credo` or `mix-compile` plugin
hook is enabled, and user hooks are still listed (it needs at least one user hook, for
example in ~/.codex/hooks.json). Its positive control re-lists with
`-c plugins.mix-credo@elixir-agent-tools.enabled=true` (unquoted: Codex keeps quotes in
`-c` keys) and must show an enabled `mix-credo` hook; otherwise the result is
INCONCLUSIVE (exit 1). The gate cannot detect an untrusted worktree, whose
.codex/config.toml Codex does not load; a PASS there is vacuous. Run it after a launch in
that worktree has loaded its config (/mcp lists lsp). Rerun it after a Codex upgrade.

For changes to the maintained vv-mcp patches, apply them to a disposable copy of
the pinned source, then run `cargo test --locked -p vv-mcp`,
`cargo clippy --locked -p vv-mcp --all-targets -- -D warnings`, and Rustfmt's
check on the changed Rust files. Use the pinned Rust toolchain; put the bundled
Neovim on the test PATH for the two upstream live-Neovim tests. Keep this test
environment separate from application commands and immutable installed bundles.

For changes to the ElixirLS or ElixirSense patches, or an ElixirLS or ElixirSense
bump, run their upstream tests on a disposable copy of the pinned source. These tests
ran during the beta research; this is the maintained way to rerun them. Take the
toolchain (it carries the Mix patch) and `mix-home` from any built bundle, and
`elixirls.tar.gz` from a `build_bundle.py` `--cache` directory. From the repository
root:

```sh
E="$PWD/agent/lsp/experiments/codex-elixirls-v2"
B="$PWD/agent/lsp/vendor/elixirls-neovim-beta-rN"
T="$PWD/tmp/elixirls-bundle-cache/elixirls.tar.gz"
W="$(mktemp -d)"
(
  set -eu
  python3 -c 'import json, sys; print(json.load(open(sys.argv[1]))["downloads"]["elixirls.tar.gz"]["sha256"], sys.argv[2], sep="  ")' \
    "$E/bundle-lock.json" "$T" | shasum -a 256 -c -
  cp -R "$B/toolchain" "$B/mix-home" "$W/"
  mkdir "$W/src"
  tar -xzf "$T" -C "$W/src"
  mv "$W"/src/* "$W/elixirls"
  cd "$W/elixirls"
  for p in elixirls-targeted-invalidation elixirls-cached-prune elixirls-dependency-reload \
      elixirls-open-document-version elixirls-references-call-env \
      elixirls-workspace-symbols-full-index; do
    patch -p1 -i "$E/$p.patch"
  done
  export PATH="$W/toolchain/bin:$PATH" MIX_HOME="$W/mix-home" HEX_HOME="$W/hex-home" MIX_ENV=test
  unbuffer mix deps.get --check-locked
  patch -d deps/elixir_sense -p1 -i "$E/elixir-sense-call-env.patch"
  (cd apps/language_server && unbuffer mix test test/providers/references_test.exs \
    test/providers/references/locator_test.exs test/server_test.exs \
    test/providers/workspace_symbols_test.exs test/tracer_test.exs test/mix_project_cache_test.exs)
  (cd deps/elixir_sense && mix test)
)
```

The subshell keeps the directory change and the exported variables out of your
shell. It stops at the first failed step, such as a patch that no longer applies,
and leaves the tree in `$W` for inspection; remove `$W` when done. With the current
patches, the 168 tests in these six files passed (2026-09-25). The ElixirSense patch
is unchanged since r23, when its suite passed (1338 tests, 5 excluded). Of the six ElixirLS patches, targeted-invalidation,
references-call-env and workspace-symbols-full-index add tests; for the other three,
this run shows only that nothing else broke. `references_test.exs` covers the
production path, where the provider passes the parsed AST; the Locator tests re-parse. Run the ElixirSense suite
without `unbuffer`: two of its Logger tests fail when stdout is a terminal. The first
`deps.get` needs network access to Hex and GitHub.

The workspace-symbols patch also guards a module that a build removes while the
index reads it. No deterministic unit test covers that race. An optional,
timing-sensitive check runs against an installed bundle; exit 0 passed, 1 failed,
3 inconclusive (race missed; rerun, not a pass). It is a maintenance check, not a gate:

```sh
PYTHONDONTWRITEBYTECODE=1 python3 agent/lsp/experiments/codex-elixirls-v2/workspace_symbols_crash_probe.py \
  --bundle "$PWD/agent/lsp/vendor/elixirls-neovim-beta-rN" --output "$(mktemp -d)/ws-crash"
```

For Elixir changes, follow `AGENTS.md`: relevant skills, compiler diagnostics,
formatting, strict Credo and meaningful tests. Python/Lua checks do not replace
the end-to-end compiler and lifecycle gates or the three real Tips workloads.

## Pinned internals

The beta relies on these private or mirrored internals. On any Neovim, ElixirLS,
ElixirSense, vv-mcp or toolchain bump, run the listed gates. "Fails open" means a
drift could report clean when it is not.

| Internal | Used in | If it drifts | Gate |
| --- | --- | --- | --- |
| Neovim ignores the `publishDiagnostics` version | translated versions | fails open (dropped diagnostics read as clean) | harness R13 (historical: A3, A10) |
| didOpen/didChange pass through `rpc.notify` | `cmd` wrapper in `neovim_init.lua` | fails open (stale publication accepted) | harness V1, R14 (historical: T2) |
| `vim.lsp.util.buf_versions` (@nodoc) | `neovim_sync.lua` | in-editor edits only | harness R14b (historical: `unsent_probe.py`) |
| ElixirLS `should_parse?` | `parsed()` mirror | a document stuck pending or skipped | harness R12, R15 |
| vv-mcp buffer lookup | `document_uri()` mirror | wrong readiness scope | harness W1 |
| Log text "Starting build with MIX_ENV:" | build start | fails closed (never current) | any harness run |
| Neovim `_watchfiles` poll exclude | native watcher | fails safe (extra scans); `tmp/` noise | none (historical: `tmp-fixture-r23`) |
| vv-mcp `operations` table (`sync_from_disk`) | disk sync before reads | reads skip disk sync | none mapped |
| `Mix.Project.with_deps_lock` (@doc false: hidden, private Mix API) | dependency reload patch | fails closed only if the function disappears (`build_error` → failed; the bundle build only warns). A changed lock can keep compiling and silently stop serializing with `deps.get` | on any Elixir/Mix bump: read the Mix source (same lock as `deps.get`), then the forced-overlap check (historical: `dependency-lifecycle` `tips_git_probe.py --gap-ms 3000`, not yet a repository gate) |
| `Mix.Dep.Converger.converge/1` options, `Mix.Dep` load paths, `Code.delete_path` purge | dependency reload patch | stale dependency modules reported current | none maintained (historical: `drb_probe2.py` v2, `drb_probe3.py` v3c, `drb_probe4.py` v4, `dependency-lifecycle/dl_probe.py` dl) |
| 21 `add_call_to_line` call sites | ElixirSense call-env patch | parse crash at run time | `build_bundle.py` strict compile of `deps/elixir_sense` |
| Parser stale-result rule | open-document version patch | wrong publication version | harness R-series |
| Build publication before `build` telemetry | 150 ms quiet window | a diagnostics request may read `current` before late diagnostics arrive (unmeasured) | none (historical: `build_order_probe.py`, measured schedule, not causal) |

Harness = `experiments/codex-elixirls-v2/first_touch_acceptance.py`. It builds its own
fixture and needs only an installed bundle. `PYTHONDONTWRITEBYTECODE=1` keeps the
bundle unchanged. From the repository root:

```sh
PYTHONDONTWRITEBYTECODE=1 python3 agent/lsp/experiments/codex-elixirls-v2/first_touch_acceptance.py \
  --bundle "$PWD/agent/lsp/vendor/elixirls-neovim-beta-rN" --output "$(mktemp -d)/harness"
```

It exits 0 only when its final `failed` list is empty, `eof_cleanup` is true and
`survivors_after_cleanup` is empty. The full record is in `results.json` in the
output directory. Cases C1, R1-R15, R14b, W1-W3, WS and V1 carry verdicts; Q is a
measurement only.

Historical evidence, not runnable repository gates: acceptance A1-A10
(`first_read_acceptance.py`), trace contract T2 (`trace_contract_probe.py`),
`unsent_probe.py`, `build_order_probe.py` and `tmp-fixture-r23`. They exist only in
the beta session's ignored `tmp/elixirls-v2/beta-team/`, and the harness does not
replace them.
