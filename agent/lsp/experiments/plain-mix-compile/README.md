# Foreground Mix prototype

2026-09-25 · `experiment/plain-mix-compile`

**Archived experiment.** The user chose Neovim + ElixirLS for its combined
compiler feedback, hover, definitions, references, and other language features.
Keep this branch as historical research; do not merge it to main. See the
[decision and research summary](DECISION.md). The reproduction instructions below
remain available for future investigation, not as the selected rollout plan.

Code, research, structured results, and copied raw evidence are preserved in Git.
The [evidence inventory](evidence/archive-index.json) maps original temporary paths
to their archived copies and verifies their hashes. Worktree-local paths in raw
logs are historical provenance and may no longer exist.

**The existing targeted-invalidation patch fixes the tested sequential
same-second case. A longer foreground wait delivers the eight-second compiler
error. The complete hook takes 0.84–0.94 seconds for the tested warm Tips edits,
error and repair.** This is a working experimental feedback path, not an installed
replacement for the Neovim stack.

The Neovim savepoint remains `f878459640028a7c607afab4a523c27a6304ceb9`, tagged
`savepoint/neovim-elixirls-hook-2026-09-25`. No active Codex configuration changed.
For the preceding root-cause investigation, see [ANALYSIS.md](ANALYSIS.md).

## Smallest contract tested

1. Run `prepare` separately. It allows 180 seconds by default for dependency and
   application compilation. Dependencies must already be fetched.
2. After a tool finishes, hash the observed project files. If nothing changed,
   return no context and do not start Mix.
3. For a changed generation, synchronously run one
   `unbuffer mix compile --warnings-as-errors`, with a configurable **60-second
   compilation safety limit**. Use `MIX_ENV=test` and the ordinary project build.
4. Pass changed and previously unfinished paths to the existing private Mix
   `--force-path` patch. Mix selects owning sources and propagates dependencies.
   Normal incremental builds remain; no project-wide forced rebuild per edit.
5. Return compiler output through `PostToolUse.additionalContext`. A timeout,
   interruption or observed edit during compilation is explicitly **unfinished**.
   Terminate the observed owned compiler tree before returning from a timeout.
6. Retain unfinished paths. Do not restart a slow compile after every read or
   on Stop. An explicit `check` (with a larger limit if needed), or another edit,
   retries them. Stop reminds the agent of incomplete/failed validation once;
   `stop_hook_active` prevents a blocking loop.

This directly addresses the old starvation problem: repeatedly cancelling an
eight-second compile at five seconds never lets it produce an error. Waiting
longer allows progress. Any finite safety limit still has an unfinished outcome;
this prototype does not promise automatic late delivery after that limit.

The script uses Python's standard library, Git's file enumeration, an advisory
state lock, ordinary Mix build locking, and the documented hook JSON contract.
The only compiler change is the existing
[targeted patch](../codex-elixirls-v2/mix-targeted-invalidation.patch), unchanged.
No compiler daemon, event queue, editor readiness state, or new dependency graph
is introduced.

## Results

Stock/private comparisons use Elixir 1.20.4 / OTP 29.1 on macOS arm64. These are
individual experiment measurements, not latency guarantees or a paired benchmark
against the final Neovim stack. Evidence and source hashes are in
[foreground-evidence.json](foreground-evidence.json).

| Case | Result |
| --- | --- |
| Stock Mix, sequential equal-size A then B in one timestamp second | Both compiles returned zero; both fresh-VM ExUnit assertions failed with A |
| Same case, existing targeted patch | Both fresh-VM assertions passed with B; unrelated BEAM unchanged; subsequent compile no-op |
| Hook, content edit with original timestamp restored | Detected by content hash; target and compile-time caller returned B in a fresh VM |
| Eight-second undefined-function compilation | Error delivered synchronously in 8.645 s |
| One-second safety limit | Explicit unfinished result in 1.397 s including cleanup; no observed survivors |
| Retry that same unchanged slow source with 15-second limit | Completed in 8.722 s; no edit needed to escape the previous timeout |
| SIGTERM during compilation | Explicit unfinished result; no observed descendants survived |
| Another write during compilation | Result qualified as unfinished; retained path retried; fresh VM then confirmed target and caller matched the latest write |
| Concurrent invocation using the same state directory | Returned unfinished; did not launch a second compiler |
| External `.txt` resource, unchanged size/mtime | Recompiled owning module; fresh-VM assertion passed |
| Resource deletion, then recreation | Deletion delivered the expected compiler error; pending path retained; recreation repaired it |
| Ignored `tmp/` fixture creation | No compile or feedback |
| Ordinary test-only `.exs` error | Compilation passed, explicitly saying tests were not run; no claim that the test was validated |
| Stop after unfinished result | One reminder; no compilation or repeated Stop blocking |

Actual Tips used a fresh detached worktree at
`5fe1cda1bb16bea97df77c078ca0789ae641f909`, a new `_build/test`, and already fetched
dependency sources shared from the earlier cohort. Cold timing includes their
compilation, not dependency downloads. Application source was restored exactly.

| Tips operation | Complete wrapper wall time |
| --- | ---: |
| Separate cold preparation | 49.086 s |
| Unchanged tool, three runs | 0.069–0.070 s |
| Explicit warm no-op check, three runs | 0.706–0.713 s |
| Warm source edit | 0.881 s |
| Equal-size edit with original timestamp restored | 0.942 s |
| Undefined-function error | 0.841 s |
| Repair | 0.892 s |

A fresh-VM ExUnit assertion verified the edited Tips module's compiled docs after
the preserved-metadata edit. Formatting, warnings-as-errors compilation and strict
Credo on the restored Tips file passed. Dependency-free fixtures passed formatting,
compilation and ExUnit; Credo is unavailable there. No LSP connector was available;
these are direct compiler and hook-protocol tests. The full Tips application suite
and a new model-driven Codex cohort were not run.

## Try it in an isolated worktree

Requires Python 3.10+, Git, `unbuffer`, Elixir 1.20.4 and OTP 29.1. The builder
validates pinned upstream source hashes, reuses the existing patch, and builds a
private copy. It does not modify Homebrew or install a language server.

From this experiment checkout:

```sh
python3 agent/lsp/experiments/plain-mix-compile/build_mix.py \
  --destination tmp/plain-mix-bundle \
  --cache /private/tmp/plain-mix-source-cache
```

Use absolute paths below. Keep one private state directory per assigned worktree.
The same private toolchain can be reused across worktrees.

```sh
python3 /absolute/experiment/foreground_mix.py prepare \
  --workspace /absolute/tips-worktree \
  --state /absolute/private-state \
  --toolchain /absolute/plain-mix-bundle/toolchain

python3 /absolute/experiment/foreground_mix.py check \
  --workspace /absolute/tips-worktree \
  --state /absolute/private-state \
  --toolchain /absolute/plain-mix-bundle/toolchain \
  --timeout 120
```

`prepare` and `check` exit 0 for passed, 1 for failed compilation, and 2 for
unfinished validation. Hook mode exits 0 and encodes the outcome in supported JSON
so compile failures reach the agent as context. State and the latest compiler log
are retained in the selected state directory.

An opt-in hook definition, after substituting absolute paths:

```json
{
  "hooks": {
    "PostToolUse": [{
      "matcher": ".*",
      "hooks": [{
        "type": "command",
        "command": "python3 /absolute/experiment/foreground_mix.py hook --workspace /absolute/tips-worktree --state /absolute/private-state --toolchain /absolute/plain-mix-bundle/toolchain --timeout 60",
        "timeout": 90,
        "statusMessage": "Checking saved project files"
      }]
    }],
    "Stop": [{
      "hooks": [{
        "type": "command",
        "command": "python3 /absolute/experiment/foreground_mix.py hook --workspace /absolute/tips-worktree --state /absolute/private-state --toolchain /absolute/plain-mix-bundle/toolchain --timeout 60",
        "timeout": 90
      }]
    }]
  }
}
```

The host timeout needs headroom for observation and process cleanup; 60 seconds
is the compiler limit, not a hard total hook deadline. Increase the host timeout
when increasing the compiler limit. Launch the session at the assigned worktree
root; the prototype rejects a different event `cwd`. Hook trust and the JSON
format follow the [official Codex hook API](https://learn.chatgpt.com/docs/hooks).
This configuration was protocol-tested, not installed in an active Codex session.

## Boundaries retained deliberately

- **Input coverage:** hash tracked files plus nonignored untracked files. This
  conservatively includes test/docs changes, which can cost an unnecessary warm
  compile. It avoids guessing all possible external-resource suffixes. Ignored
  files, dependency changes behind a directory symlink, inputs outside the
  worktree, and environment changes beyond recorded build settings are outside
  this observation contract. Do not put real changing compile inputs in `tmp/`.
- **Observation is not a source lock:** start/end hashes detect sustained changes,
  not every transient A→B→A write. Use one serial writer and a private build/state
  directory; shell background writers or another agent weaken that assumption.
  Passed means the command succeeded and these snapshots agreed. It does not prove
  every compiler read consumed an immutable source snapshot.
- **Compiler scope:** `mix compile` does not run tests or generally compile ordinary
  test `.exs` files. Custom compiler inputs still follow those compilers' rules.
  Every successful feedback message explicitly says tests were not run.
- **Cleanup:** verified for this macOS/OTP/unbuffer process tree and catchable
  interruption. SIGKILL or arbitrary custom daemons escaping observed ancestry
  are not covered. State left as running makes Stop/check report unfinished.
- **Navigation:** foreground Mix does not refresh ElixirLS's separate live state.
  Keep the saved synchronization, watcher and lifecycle work until a combined
  navigation/foreground-feedback experiment verifies a smaller replacement.

At the end of testing, the outstanding milestone was a controlled Codex session
using this foreground path, including a long error without diagnostics polling,
followed by complete Tips workflow comparisons while retaining navigation.
That work was not run before archiving. The user selected Neovim + ElixirLS.

## Reproduce

Use fresh output directories; the probes refuse to overwrite fixtures.

```sh
python3 agent/lsp/experiments/plain-mix-compile/targeted_sequential_probe.py \
  --output tmp/sequential-stock-new
python3 agent/lsp/experiments/plain-mix-compile/targeted_sequential_probe.py \
  --output tmp/sequential-targeted-new \
  --toolchain tmp/plain-mix-bundle/toolchain
python3 agent/lsp/experiments/plain-mix-compile/foreground_probe.py \
  --output tmp/foreground-new \
  --toolchain tmp/plain-mix-bundle/toolchain
```

`tips_probe.py` additionally requires a clean disposable Tips worktree with no
`_build` and an existing dependencies directory; see its `--help`. Raw results
were produced under `tmp/foreground-mix/`; selected logs and results are now
preserved under `evidence/foreground-mix/`. Integration result `record` fields
hold the most recent compilation, even for calls which only returned `{}` or a
concurrency message; inspect `output` for the actual hook response.
