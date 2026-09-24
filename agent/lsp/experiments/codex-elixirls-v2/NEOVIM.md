# Headless Neovim experiment

Date: 2026-09-24. Branch: `experiment/elixirls-codex-v2`.

Follow-up: [normal file edits with automatic compiler feedback](HOOKS.md) now
passes an actual Codex edit/repair session. The earlier editor-save experiment
below records how we reached that design; agents keep their normal writing tools.

**Result: the reuse architecture works, including actual Codex startup. The
unmodified MCP adapter still needs automatic buffer refresh for read operations.
A small hook using its existing helper fixed the ordinary edit cases tested.
A follow-up prototype returned explicit startup/build hints through MCP and
observed compiler errors 28–33 ms after Neovim saves. Compiler overlap and a
reliable readiness contract remain unresolved. No rollout was made.**

```text
Codex / protocol test client
  -> vv-mcp 0.3.4
  -> managed headless Neovim 0.12.5
  -> ElixirLS 0.31.1
  -> assigned Git worktree
```

## What was reused

- Official Neovim macOS arm64 release; release checksum verified before execution.
- Published `vv-mcp` binary and matching Lua plugin at v0.3.4, commit
  `b64e27e1d0f1a95984512c11a1ca7ad31208e8dd`; binary checksum verified.
- `vv-utils.nvim` pinned at `13e73d5174b37af24ca475dc39b61667432aaebc`.
- Installed ElixirLS executable `/opt/homebrew/bin/elixir-ls`, unchanged.
- Neovim's built-in `vim.lsp.config` / `vim.lsp.enable`, document lifecycle and
  dynamically registered filesystem watchers.
- `pynvim` 0.6.0 for test observations and explicitly identified recovery controls.

The Elixir-specific Neovim plugin was source-reviewed but was not required to run
the test: an explicit ElixirLS command, filetypes and Mix root marker configure
Neovim's existing client directly. The test did not use the plugin's installer,
interactive commands or UI. No custom LSP implementation or filesystem watcher
was written.

The MCP adapter launched and managed Neovim itself. Each session received its
own registry and XDG configuration/cache/state paths. Source changes came from
ordinary Python filesystem writes and Git checkout, outside Neovim.

## Results

The retained comparison is `neovim-baseline` versus `neovim-sync-reads`.
An earlier exploratory `neovim-3` run also completed. Both retained runs used
real Git worktrees with the same symbols and different commits.

| Scenario | Unmodified adapter | Existing refresh helper enabled for reads |
|---|---|---|
| ALPHA/BETA hover, root-specific definitions, 2/3 references | Correct | Correct |
| Edit unopened callee; query unchanged caller | Automatically fresh by second sample, about 0.26 s | Same |
| Atomic replacement of unopened callee | Automatically fresh by second sample, about 0.26 s | Same |
| Create/delete a caller file | References updated automatically | Same |
| Edit open caller on disk from `answer` to undefined `missing` | Compiler warning arrived, but hover used old buffer through 32 queries / 8.08 s | Buffer refreshed automatically; old hover disappeared |
| Repair open caller on disk | Warning cleared, but hover still used the old buffer through 32 queries / 8.07 s | Correct hover returned automatically |
| Git checkout BETA to ALPHA, changing open caller and unopened target | Hover updated; references incorrectly stayed at 3 | Hover updated and references became 2 |
| Equal-size second edit while first build sleeps | First build succeeds, queued build is no-op, hover remains old | Same compiler failure |
| Separate `.elixir_ls/build` directories | Yes | Yes |
| Close one MCP stdin | All observed descendants exited; other session answered | Same |
| Close second MCP stdin | All observed descendants exited | Same |

An immediate hover after an unopened-file edit can still return the previous
documentation before the watcher/build completes. The approximately 0.26-second
observations are polling samples, not a maximum-latency guarantee. The fixture
startup-to-first-hover samples were approximately 1.5–1.7 seconds on this host.

### The small adaptation

`vv-mcp` already contains `sync_from_disk`, which invokes Neovim's `checktime`.
Its operation metadata enables that helper for `fix_document`, but not hover,
definition, references or diagnostics. The optional experiment configuration is:

```lua
local operations = require('vv-mcp.lsp.operations')
for _, name in ipairs({ 'hover', 'definition', 'references', 'diagnostics' }) do
  operations.get(name).sync_from_disk = true
end
```

With `autoread=true`, the helper reloads unmodified buffers from disk. Neovim's
existing reload lifecycle then closes/reopens the LSP document. Normal reads
perform this automatically; the model does not need a refresh tool or preopening
step. The helper rejects overwriting an unsaved modified buffer.

**This is an experimental hook into an internal operation table, not a documented
public option or an upstream release fix.** It needs an upstream change or a
supported configuration path before adoption. Only the four listed operations
were adapted. Workspace diagnostics and other operations were not changed.

The harness also ran explicitly labelled manual `checktime`/save controls.
Ordinary edit and repair observations were captured before those controls; they
are not evidence of a required model workflow. The missing-function hover is
correctly empty after synchronization, and the repaired valid call returns docs.

## Actual Codex and local Tips

An actual Codex CLI session, using temporary command-line MCP configuration and
only generated synthetic source, called hover, definition, references and
diagnostics, then listed its instance. It returned ALPHA documentation, the
correct definition, two references and the exact fixture root. No retries were
needed. Codex exited zero and all observed owned processes exited.

A separate local MCP session queried Tips at the `Tips.ProviderConfig.mode/0`
call site. It returned the expected definition in `provider_config.ex` and one
reference in `search_probe.ex`. The first hover returned empty success during
initial compilation; the query became useful about 2.3 seconds after the first
request began. This run had warm dependencies/build caches. Process cleanup
passed. No Tips source was sent to a model by this local test.

This does not validate model-driven editing on the full application, HEEx,
umbrella/path-dependency behavior, Linux watcher behavior or high session counts.
No active Codex/Claude configuration or main-checkout application code changed.

## Inversion and decision

The controlled slow build reproduced the earlier compiler failure through the
real Neovim watcher: write A, wait for compilation to start, write equal-size B,
then observe a successful A build followed by `mix_compile_noop`. Repeated hover
still returned A. This agrees with the independent plain Mix reproduction in
[INVERSION.md](INVERSION.md). Its ordinary-workload frequency remains unmeasured.

The Tips startup result separately shows that the adapter does not distinguish
an empty answer during build from an authoritative empty answer. Neither client
initialization nor an empty diagnostic cache establishes build completion.

**Continue with this reuse path rather than implementing a new LSP client.**
The next changes belong at the narrow existing interfaces: automatic read-time
buffer refresh in the adapter, honest build-readiness behavior, and the isolated
compiler reproduction below it. Do not require agent-managed refresh/restarts or
claim that borrowing an editor client resolves compiler correctness.

## Follow-up: startup messages and editor feedback

The user asked whether an agent could receive an indexing/retry message and the
same edit-save-diagnostics experience as an editor user. Both mechanisms were
tested locally in `neovim-feedback-final`; the probe exited zero.

### Why the workaround exists

1. Why does the agent see an empty hover? The query can arrive before compilation.
2. Why can queries arrive then? LSP initialization and compilation finish separately.
3. Why is that confusing? The adapter renders an unavailable answer like an empty one.
4. Why does an editor feel better? It keeps processing background status and diagnostics.
5. Why does that not automatically help an agent? A background Neovim notification
   is not itself an edit-tool response or visible agent feedback.
6. Why do manual refresh instructions fail? They make the model coordinate this
   asynchronous lifecycle instead of the adapter/tool owning it.
7. Why would another instruction solve that? It would not change that ownership.
8. Why would another refresh command solve it? It would still leave that ownership
   with the model. The last two whys leave the root answer unchanged.

First principles: save the intended text, deliver normal editor notifications,
and return the diagnostics/status observed afterward. Occam: reuse Neovim's
buffer API, `:write`, and diagnostic handler. Pareto: one bounded edit-and-save
response covers ordinary edits; long builds need an explicit pending response.
There is no reason to rebuild an LSP client or require preopening/restarts.

### Custom message through actual MCP

The optional `neovim_feedback.lua` wrapper uses ElixirLS 0.31.1's observed build
log and build telemetry, plus workspace-index log messages. During controlled
startup it returned this tool-text payload instead of an empty hover:

```json
{
  "error": {
    "code": "elixirls_not_ready",
    "message": "ElixirLS is compiling the project. Retry in about 1 second; this is not a no-result answer.",
    "phase": "compiling",
    "retryable": true,
    "retryAfterMs": 1000
  }
}
```

Later calls returned the expected documentation. A whitespace hover after idle
remained legitimately empty. Compile failure produced a distinct message asking
the caller to read diagnostics and repair the source; diagnostics remained
accessible. A deliberately three-second build still returned the retry message
after the one-second observation budget.

This proves message delivery and the tested distinctions, not reliable project
freshness. Log strings are version-specific, not a stable readiness API. An event
may not have arrived yet; compiler completion does not cover queued work or
Dialyzer. The equal-size overlapping-save compiler failure still applies.
The wrapper assumes the isolated single-project Neovim configuration used here.
The published adapter returns strings, so MCP `isError` remains false even when
the tool text contains this explicit error. Production status semantics need an
adapter-supported interface rather than this internal wrapper.

### Edit and save inside Neovim

The probe used official Neovim RPC to change a loaded buffer, invoke `:write`,
and collect a subsequent `textDocument/publishDiagnostics` notification in one
bounded RPC call. Three warm edits introduced a real undefined-local-function
compiler error:

| Sample | Save to error publication | Edit/save/observation inside Neovim |
|---|---:|---:|
| 1 | 33.12 ms | 43.23 ms |
| 2 | 28.45 ms | 36.78 ms |
| 3 | 29.35 ms | 37.02 ms |

Normal `didChange` and `didSave` notifications were observed. Each source change
was saved, each repair restored the expected hover, and all owned processes
exited. These are small-fixture measurements, not end-to-end Codex/UI latency or
a subsecond guarantee for Tips. An empty diagnostic publication after repair
arrived before compilation finished; it must not be presented as a clean-build
certificate.

The simplest proposed agent interface is one edit operation that applies the
change, saves, and returns compiler feedback within a short budget. If work is
still pending, it says so. This avoids a separate save/refresh choreography for
the model. This edit interface is **not implemented in vv-mcp or Codex** here:
vv-mcp 0.3.4's `editor` tool is read-only. Its specialized rename/fix operations
can write, but arbitrary edits in this probe used Neovim RPC. Built-in Codex
`apply_patch` edits need an explicit integration with this path or equivalent
automatic feedback; starting headless Neovim alone does not provide it.

### Inversion results

- Initial prototype: indexing completion incorrectly erased a compile failure.
  ElixirLS can update its index after a failed build. The wrapper now preserves
  that failure until another build; all three error/repair cycles exercised it.
- Legitimate empty hover: stayed empty rather than falsely claiming indexing.
- Long build: returned pending rather than pretending there were no results.
- Second run: assertions and process cleanup passed, but a test observation
  attempted RPC after shutdown and raised `BrokenPipeError`. The harness now
  skips that observation after exit; the final run passed completely.
- Remaining limits: log-message changes, crashes, missed events, queued builds,
  and overlapping saves require further validation before rollout. The status
  prototype is a UI hint, not a compiler synchronization protocol.

## Reproduce and inspect

Pinned downloads and Python package versions: [neovim-versions.json](neovim-versions.json).
The installed experiment dependencies are under `tmp/elixirls-v2/neovim-vendor`.
From this worktree, with new output paths:

```sh
python3 agent/lsp/experiments/codex-elixirls-v2/neovim_probe.py --vendor tmp/elixirls-v2/neovim-vendor --output tmp/elixirls-v2/nvim-baseline-replay
python3 agent/lsp/experiments/codex-elixirls-v2/neovim_probe.py --vendor tmp/elixirls-v2/neovim-vendor --output tmp/elixirls-v2/nvim-sync-replay --sync-reads
python3 agent/lsp/experiments/codex-elixirls-v2/neovim_codex_probe.py --vendor tmp/elixirls-v2/neovim-vendor --output tmp/elixirls-v2/nvim-codex-replay
python3 agent/lsp/experiments/codex-elixirls-v2/neovim_tips_probe.py --vendor tmp/elixirls-v2/neovim-vendor --workspace "$PWD" --output tmp/elixirls-v2/nvim-tips-replay
python3 agent/lsp/experiments/codex-elixirls-v2/neovim_feedback_probe.py --vendor tmp/elixirls-v2/neovim-vendor --output tmp/elixirls-v2/nvim-feedback-replay
```

The Codex probe makes model requests with synthetic source only. The Tips probe
is local-only. The probes record adversarial results; exit zero means the probe
completed, not that all freshness acceptance criteria passed.

Durable observations: [neovim-evidence.json](neovim-evidence.json). Raw protocol
transcripts and logs remain under the corresponding `tmp/elixirls-v2/neovim-*`
directories. The first two launch attempts created only empty directories because
the process-table prerequisite was checked too late before an automatic retry.
The probe now checks that prerequisite before creating output.

## Validation

The synthetic projects' baseline compilation and ExUnit tests passed. After the
last fixture repair, formatting, warnings-as-errors compilation and ExUnit tests
passed. Credo was unavailable in the dependency-free fixture (task not found).
Python syntax and documentation-link checks passed. The Tips application suite
was not rerun because application source was not changed.

Sources: [Neovim headless/RPC documentation](https://github.com/neovim/neovim/blob/v0.12.5/runtime/doc/starting.txt),
[vv-mcp](https://github.com/beixiyo/vv-mcp.nvim/tree/v0.3.4),
[adapter context](https://github.com/beixiyo/vv-mcp.nvim/blob/v0.3.4/lua/vv-mcp/lsp/context.lua),
[operation metadata](https://github.com/beixiyo/vv-mcp.nvim/blob/v0.3.4/lua/vv-mcp/lsp/operations.lua),
[ElixirLS build events](https://github.com/elixir-lsp/elixir-ls/blob/v0.31.1/apps/language_server/lib/language_server/build.ex),
[ElixirLS workspace indexing](https://github.com/elixir-lsp/elixir-ls/blob/v0.31.1/apps/language_server/lib/language_server/providers/workspace_symbols.ex).
