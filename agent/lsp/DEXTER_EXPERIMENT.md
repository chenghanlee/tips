# Codex + Dexter LSP experiment

This branch replaces the opt-in ElixirLS backend from `9698a87` with Dexter LSP
0.7.2. Expert remains the default. Each worktree runs its own MCP bridge and
Dexter LSP process; database/test-port allocation and safe retirement stay in
the existing team workflow.

## LSP, not CLI lookups

The installed Homebrew package is `dexter-lsp`; its executable is `dexter`.
`dexter lsp /absolute/worktree` starts the LSP server over stdio. Codex calls
MCP tools, and the bridge sends `textDocument/definition`,
`textDocument/references` and `textDocument/hover` requests. Neither navigation
nor the timing pilot uses `dexter lookup`, `references`, or `reindex` CLI commands.

The tested upstream version is
[Dexter v0.7.2](https://github.com/remoteoss/dexter/tree/v0.7.2), commit
`b642f0e3cfa1c00be386aebe9ebd2626abdfe3f2`.

## Worktree isolation

- Share installed binaries, not `.dexter/`, `deps/` or `_build/`.
- The launcher validates the Git root, rejects symlinked project/index state,
  and locks `.dexter/codex.lock` against duplicate launcher instances.
- Both the agent shell and server discard inherited shared Mix build/dependency
  path overrides. Assigned database/port settings are passed explicitly to MCP.
- Dexter 0.7.2 searches ancestor database markers before Git roots, even when
  supplied a path. The launcher creates an empty local SQLite file if missing
  so a parent checkout's index cannot capture the worktree. It never truncates
  an existing database.
- The bridge rejects source queries outside its root and sends saved edits
  through `didChange` and `didSave`. Atomic replacements also refresh the open
  document: an index-only update otherwise leaves Dexter hover text stale.
- Closing Codex shuts down its server without deleting source or databases.
  Existing team retirement checks remain responsible for destructive cleanup.

The lock is advisory and coordinates these launchers only. Do not run another
editor's Dexter in the same worktree or delete `.dexter/` under a live server.

## Build and try

Prerequisites: installed `dexter-lsp`, Python 3.12+, and the existing
[bridge build tools](README.md#build-and-validate). No global client settings or
shared installed binaries need to change for the experiment.

```bash
export TIPS_ELIXIR_TOOLS="$PWD/agent/lsp/vendor"
agent/lsp/build_install_mcp_bridge.sh
python3 -m unittest discover -s agent/lsp/tests -v
python3 agent/lsp/pilot_dexter.py "$PWD/tmp/dexter-pilot-1"
# Repeat against two detached checkouts of the actual application's tracked source:
python3 agent/lsp/pilot_dexter.py "$PWD/tmp/dexter-app-pilot-1" --project "$PWD"
```

Use a new output directory for every run. Logs, sample timings, worktrees and
failure evidence are preserved there. App runs do not fetch dependencies, start
Phoenix, migrate databases or run the app. Timing results describe the indexed
source present in those checkouts.

Standalone Codex MCP configuration:

```toml
[mcp_servers.elixir-lsp]
command = "python3"
args = ["/path/to/experiment/agent/lsp/launch_worktree_dexter.py", "/path/to/assigned/worktree"]
cwd = "/path/to/assigned/worktree"
startup_timeout_sec = 120
tool_timeout_sec = 120
enabled_tools = ["definition", "references", "hover", "diagnostics"]

[mcp_servers.elixir-lsp.env]
TIPS_ELIXIR_TOOLS = "/path/to/experiment/agent/lsp/vendor"
MIX_ENV = "test"
# Add this worktree's allocated PGPORT, TIPS_DB_SUFFIX and TIPS_TEST_PORT.
```

`elixir-lsp` remains the MCP service name for existing role instructions; its
backend in this configuration is Dexter LSP. Start Codex with `--no-daemon -C
/path/to/assigned/worktree`. Set `TIPS_DEXTER_COMMAND` to an absolute executable
path if `dexter` is not on `PATH`.

After review/adoption into the canonical checkout, the existing team helper
accepts `--lsp dexter` for Codex roles. Its task/team/pane arguments remain
required. It resolves its launcher from the canonical checkout; invoking a
modified helper from another worktree does not install it there.

## Feature comparison

Dexter is not a full replacement for ElixirLS. Based on the installed Dexter
0.7.2 capabilities and [ElixirLS 0.31.1 documentation](https://github.com/elixir-lsp/elixir-ls/tree/v0.31.1):

| Operation | Dexter LSP | ElixirLS | This Codex bridge |
|---|---|---|---|
| Definition, references, hover | Yes, source-based | Yes | Exposed and tested |
| Completion, document/workspace symbols, formatting | Yes | Yes | Not enabled in this experiment |
| Signature help, call hierarchy, code actions | Yes | Yes | Not enabled in this experiment |
| LSP rename | Yes | Not advertised by 0.31.1 | Not enabled in this experiment |
| Compiler warnings/errors on save | No | Yes | Dexter returns an explicit unavailable message |
| Dialyzer analysis and inferred `@spec` suggestions | No | Yes, when enabled | ElixirLS baseline had Dialyzer disabled |
| Step-through debugging | No DAP implementation | Separate debug adapter | Not exposed |

Matching operation names do not guarantee identical resolution of macros,
generated code or framework constructs. Dexter indexes without compiling;
the pilot checks concrete results, not comprehensive semantic parity.
Dexter's formatter can publish syntax-error diagnostics, but those are not
compiler or Dialyzer feedback. This bridge does not invoke formatting as a
substitute for compiler diagnostics. Run compilation, Credo and relevant tests
to verify code.

## Timing methodology

The pilot measures from immediately before a saved-file write to the first
MCP response containing the expected new result. It alternates ordinary writes
and atomic file replacement, polls at 5 ms intervals, and runs two servers
concurrently. It checks changed doc strings, moved definition lines, and added
and removed references. Queries wait for initial indexing before measurement.

Same-file queries synchronize that document immediately. Cross-file queries
leave the queried file unchanged and rely on the filesystem watcher to update
the edited target. The inherited bridge debounce is 300 ms; this is part of
the measured agent experience, not Dexter's parsing time.

An empty diagnostic list is never used as a freshness signal. A ten-second
failure to observe a new result fails the pilot and retains its logs. Results
are local observations, not latency guarantees or proof of full team capacity.

## Measured results (2026-09-29)

Two concurrent Dexter 0.7.2 servers in detached Tips checkouts at `9698a87`;
115 tracked `.ex`, `.exs` and `.heex` files per checkout, plus three fixture
modules. Dependencies and stdlib source were not populated. macOS arm64,
Elixir 1.20.4 / OTP 29.1. Twenty edit rounds per worktree:

| Saved edit → matching LSP result through MCP | Samples | Median | p95 | Maximum |
|---|---:|---:|---:|---:|
| Same-file hover | 40 | 1.60 ms | 14.71 ms | 15.07 ms |
| Cross-file definition moved to a new line | 40 | 305.71 ms | 311.97 ms | 319.05 ms |
| Cross-file hover with changed docs | 40 | 306.25 ms | 311.77 ms | 314.06 ms |
| Reference added (ordinary write) | 20 | 307.97 ms | 314.38 ms | 316.39 ms |
| Reference removed (atomic replacement) | 20 | 9.19 ms | 11.28 ms | 11.45 ms |

The last two rows use different save methods: atomic replacement emits an
immediate deletion event, so reference removal appears before the debounced
create/index event. Do not interpret their difference as an intrinsic Dexter
add-versus-remove cost. The first three rows include both save methods.
These are end-to-end saved-edit timings, not the earlier ElixirLS measurement
from delivery of `didSave` to publication of a compiler error.

All measured edits became visible. Workspace mismatch, duplicate ownership,
ancestor-index isolation, independent shutdown and lock reuse checks passed.
Evidence is retained under `tmp/dexter/tips-measured/` in this experiment
worktree. The raw LSP traces show the request/response transport and roots.

An earlier run failed because atomic replacement refreshed Dexter's index but
not its open-document text. The bridge fix is covered by a regression test
and the subsequent 40 samples per navigation operation. An earlier shutdown
check returned `EPERM` from a process-group signal probe; the final pilot
verified absence of live group members using the process table instead.

## Cold and warm comparison

`compare_lsp_startup.py --help` lists the launcher/tool paths required to compare
this branch with the retained ElixirLS implementation at `9698a87`. It creates
two fresh detached Tips worktrees and copies the same already-fetched dependency
snapshot into each. No project `_build/`, `.dexter/` or `.elixir_ls/` cache is
copied. Warm runs restart the server without changing files or deleting its
state. One server runs at a time.

The 2026-09-29 run used application revision `8150138` (the parent of `9698a87`,
whose changes are agent tooling only), 2,874 Dexter-indexed source files including
dependencies, and ElixirLS 0.31.1 with Dialyzer disabled. The readiness check
requires correct project and Ecto dependency definitions, project hover docs,
and a project reference, all through MCP/LSP:

| From process launch | Dexter cold | Dexter warm (2 runs) | ElixirLS cold | ElixirLS warm (2 runs) |
|---|---:|---:|---:|---:|
| MCP initialization returned | 1.48 s | 1.52–1.53 s | 2.99 s | 2.30–2.34 s |
| All four navigation checks succeeded | 1.50 s | 1.55–1.56 s | 54.44 s | 4.20–4.22 s |
| Background index/build completed | 1.12 s | 0.60–0.62 s | 48.09 s | 2.22–2.25 s |

The server-reported work durations exclude process launch: Dexter's cold index
took 641 ms, and its unchanged warm reindex took 85–90 ms. ElixirLS reported
46.085 s for cold compilation and 891–900 ms for warm build checks. These are
different jobs: Dexter does not verify compilation.

The inherited bridge waits one second after LSP initialization for either
backend. This explains why Dexter's faster warm index does not reduce the
observed MCP startup below roughly 1.5 seconds. The experiment preserves that
baseline behavior. Readiness checks run serially; a blocked request can delay
subsequent checks, so the result is time to complete the check set, not the
earliest instant each independent operation could possibly work.

Cold means cold per-worktree server state, not a freshly booted machine.
Dependency fetching/tool installation are excluded, and OS filesystem caches
were not flushed. This is one cold observation and two warm observations per
server, not a statistical performance guarantee. Raw evidence and logs are in
`tmp/dexter/startup-comparison/`.

Validation: both real Codex clients completed all four exposed MCP calls in
separate worktrees. All 78 team lifecycle tests, five launcher tests, the patched
bridge's Go checks, Pyright and documentation checks passed. The synthetic
fixtures compiled successfully. Ruff was unavailable. The experiment remains
opt-in and has not changed shared installed tools, global client configuration,
or live teams.
