# Installed Expert + headless Neovim experiment

**Archived 2026-09-24.** See [ARCHIVE.md](ARCHIVE.md) for the decision, retained
evidence, checksum verification and historical retrieval. Do not merge this
experimental branch into main.

**Result: useful reusable foundations, but not ready for rollout.** Installed
Expert 0.1.10 has a delete-event mismatch and a worker lifecycle defect exposed by
rapid compilations. No server patch or active client configuration was installed.

Read [ROOT_CAUSES.md](ROOT_CAUSES.md) for 5–8 whys per finding and inversion tests,
[REUSE.md](REUSE.md) for existing standards/tools to borrow, and
[evidence.json](evidence.json) for measured results and original artifact paths.

Separate exploration on `experiment/expert-neovim-codex`, based on Tips `8150138`.
Use `/opt/homebrew/bin/expert` (Homebrew 0.1.10), not Tips' patched Expert or old Go bridge.
Reuse Neovim 0.12.5 and the published vv-mcp 0.3.4 from the ElixirLS experiment.
No global client configuration or installed server source is changed.

## Why this experiment

1. Why revisit the server? The ElixirLS pilot passed application tests but failed
   automatic feedback reliability in actual Codex Sol workflows.
2. Why did feedback fail? Reload and save were different events, and our feedback
   bookkeeping also had independent defects.
3. Why try Expert through Neovim? It tests the installed server with a mature LSP
   client and a published MCP adapter, without the previous server patches.
4. Why start with a minimal configuration? ElixirLS-specific telemetry and recovery
   assumptions would obscure Expert's own behavior.
5. Why retain the previous scenarios? Passing startup alone says little about
   external edits, stale diagnostics, worktree separation or process cleanup.
6. Why inspect the protocol? Empty diagnostics and successful requests do not prove
   that the latest revision was compiled or indexed.
7. Why use normal disk edits? That is the agent workflow; any required editor
   synchronization must happen automatically, without agent rituals.

First principles: file contents, LSP document state, compiler state and indexed
references are distinct. Measure them before equating them. Occam: start with the
documented native `vim.lsp.config` / `vim.lsp.enable` configuration. Pareto: test
navigation, unopened-callee edits, error/repair, references and lifecycle first.
Inversion: deliberately change files outside the editor, use equal-length/atomic
edits, create/delete callers and keep two roots with identical module names alive.

Prior evidence: `/private/tmp/tips-elixirls-codex-v2/agent/lsp/experiments/codex-elixirls-v2/`
(`DOGFOOD.md`, `ROOT_CAUSES.md`, `INVERSION.md`, raw Codex transcripts).
The earlier five-second hook failures are regression requirements, not code to copy
unchanged. The baseline has no readiness flag, deduplication or save shim; opt-in
experimental synchronization modes allow comparison against it.

Official editor convention: <https://expert-lsp.org/docs/editors/>.

## What the experiment established

| Scenario | Observed result |
|---|---|
| Two worktrees, same symbols, different commits | Correct root-specific docs, definitions and reference counts after readiness |
| Native configuration with normal disk edits | Stale hover and diagnostics; a real save triggered compilation |
| Automatic buffer change + save | Updated docs and error/repair in about 1.5–2 seconds in tested warm cases |
| New caller, incremental indexing | About 5.1 seconds in fixture; isolated Tips disk creation 5.4 seconds |
| Delete a confirmed indexed caller | Native event did not clear it; numeric LSP enum mismatches Expert's atom pattern |
| Full reindex after every edit | Fixture passed; Tips rejected overlapping commands, so not a viable normal path |
| Combined Tips edits/error/repair/create | Reproduced engine shutdown; OTP trace identifies permanent ModuleStore worker stopping normally after every compile and exhausting the 3-in-5-second restart allowance |
| MCP stdin EOF | All observed owned descendants exited in completed lifecycle probes; other fixture worktree continued answering |

The smallest owning-layer remedies are to normalize the delete enum and align
ModuleStore's lifetime with its compile-listener role. These are source-informed
upstream recommendations, not installed or validated fixes. Automatically slowing
edits, restarting servers, or reindexing everything would hide or amplify defects.

These runs use a real stdio MCP client and actual Tips code, **not a new Codex Sol
cohort**. The previous actual Sol sessions supplied the acceptance scenarios.
No five-second host hook is implemented on this Expert branch yet. Diagnostic
disappearance is observed behavior, not a general revision-freshness guarantee.

## Reproduce locally

Prerequisites: installed `/opt/homebrew/bin/expert` 0.1.10, Elixir 1.20.4/OTP 29.1,
`unbuffer`, and the retained Neovim/vv-mcp/pynvim vendor directory specified in
[session.py](session.py) and [versions.json](versions.json). The fixture scripts
also use Git. This is a local pilot, not a portable installer.

Run from this worktree; choose new output directories outside any indexed project:

```sh
python3 agent/lsp/experiments/expert-neovim/fixture_probe.py --output /private/tmp/expert-native-new
python3 agent/lsp/experiments/expert-neovim/fixture_probe.py --sync --edit-sync --output /private/tmp/expert-sync-new
python3 agent/lsp/experiments/expert-neovim/fixture_probe.py --sync --edit-sync --delete-reindex --output /private/tmp/expert-delete-new
```

For real Tips, run from a disposable checkout with its own dependencies. The
script temporarily changes ProviderConfig and creates a unique caller, restoring
source in `finally`. It uses the local development database convention on port
5433 for application checks and disables real provider calls. Expert needs access
to its normal macOS engine cache; a restricted launch can fail before indexing.

```sh
python3 /private/tmp/tips-expert-neovim-codex/agent/lsp/experiments/expert-neovim/tips_probe.py --sync --edit-sync --delete-reindex --output /private/tmp/expert-tips-new
```

Add `--trace-supervisor` to capture OTP supervisor events through Expert's public
debug connection. No source patch is made. `create_probe.py --via-editor` compares
an actual Neovim write with `create_probe.py`'s external disk edit, without the
preceding error/repair sequence. Both use unique filenames and check continued
responsiveness after creation.

**Read the result fields.** These are exploratory probes: finishing with exit code
zero does not imply all `matched` checks passed. `deletion_validated` requires
creation to have been observed first. Raw results from earlier probe versions are
preserved and qualified in `evidence.json`, including an invalid stale-path control.

## Validation and remaining scope

Tips baseline checks passed: formatting, warnings-as-errors compilation, provider
tests (8 passed, 1 excluded), and strict Credo. The first Credo invocation used an
invalid `--files` option and failed; the corrected `--files-included` run passed.
Those checks protect application code, not the adapter's freshness claims.
Python and Lua syntax and repository documentation checks are recorded separately.

Required before claiming a working integration: server defects resolved with
protocol/workflow regressions, cold and overlapping edits, HEEx/test-file behavior,
five-second pending/error delivery, and actual Codex/Claude host runs. The experiment
does not change the existing project launcher, hooks, or global configuration.
