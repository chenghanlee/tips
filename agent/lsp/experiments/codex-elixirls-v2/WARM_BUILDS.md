# Warm builds: cached dependency prune

Date: 2026-09-25. Owner: wH:pP. Independent review: wH:pR. Decisions: Astra.

`elixirls-cached-prune.patch` makes a warm Tips edit about 0.6 s faster. The full
ElixirLS reload stays, and so do both timers and the 5 s hook budget. Astra decided:
no content-based reuse (G2b) and no timer work (G4/G5) in this slice.

## Root cause

- A warm r7 hook took ~1.43 s. The build took ~0.9-1.0 s of that, and 667 ms of the
  build was `prune_existing_mix_project`.
- Before every build, prune called `Mix.Project.in_project/4` for all 60 Tips
  dependencies. Each call compiled that dependency's `mix.exs` only to purge the module
  again.
- No other step loads those projects. Hex dependencies converge from lock data. Mix
  1.20.4 `Mix.Dep.Loader.mix_dep(dep, children, _)` never evaluates their `mix.exs`.
  Measured: 0 of 60 were cached when prune started.

## Change

- Prune now purges only the dependency projects Mix actually loaded. Mix caches every
  project it loads under `{:app, app}` (`Mix.Project`, 1.20.4). Prune runs before
  `Mix.State.clear_cache`, so that cache lists exactly the projects loaded since the
  last reload.
- Path, Git and umbrella dependencies, and dependencies that were just compiled, are
  still purged.
- Every other reload step is unchanged.
- The patch applies after `elixirls-targeted-invalidation.patch`.
- SHA-256: `04c680dfb3ebdf49613b4f97651b79f7e1f71f7f7439c998a0b48aa706baa75a`.

## Results

Paired ABAB with the real PostToolUse hook. 30 edits per arm over three edit kinds
(1-module recompile, no-op, router). Concurrent load: 8.3 on 10 CPUs.

| | r7 | cached prune |
|---|---:|---:|
| Hook median | 1.433 s | 0.808 s |
| Hook p90 / max | 1.499 / 1.655 s | 0.832 / 0.870 s |
| Prune phase (instrumented median) | 667 ms | 2.3 ms |
| Builds per edit | 1 | 1 |

pR repeated the timing independently: its own cached-prune build, its own fixture, ABAB,
not instrumented, n=30 per arm, load 7.8-15.1 on 10 CPUs.

- Hook median: 1.423 s (r7) vs 0.805 s (cached prune).
- Hook p95: 1.513 s vs 0.846 s.

## Correctness gates

- **ElixirLS checks.**
  - `mix format --check-formatted`: pass.
  - Compile: no new warnings.
  - `server_test.exs`: 77/77, including umbrella dependency loading.
  - Tracer and project-cache tests: 8/8.
- **Tips scenarios (`warm_scenario_probe.py`).** 26 steps through the real hook:
  - path, Git and Hex dependency changes
  - `mix deps.update` and `mix deps.get`
  - lock-only edits
  - config and `mix.exs` breaks and repairs, including a config change with the mtime kept
  - source breaks and repairs
  - new, referenced and deleted modules

  Every step gives the same status, diagnostics, build results and build starts as r7.
  That includes the dependency and config values compiled into a probe module.
- **Purges seen (instrumented run).**
  - After the cold startup compile, the next build purged all 50 loaded dependency
    projects.
  - Path and Git dependency projects are purged on every build.
  - A rebuilt Hex dependency (`mime`) is purged on the next build.
- **Edits during a build (`--during`).** Three edits were each made while a build was running: a new
  module file, a path dependency `mix.exs` version change, and a config value change.
  - Each ended in the final settled state after a second build.
  - r7 and cached prune gave the same results in ABAB order, two runs per arm.
  - The path dependency case is the one that matters for this patch: its project is
    loaded by the running build and purged by the next build.

- **Independent review (wH:pR): accept, no findings.** pR's own runs agree with these
  results.
  - **Negative control:** a bundle that never purges dependency projects. pR's checks
    catch it: ElixirLS publishes "redefining module ...MixProject" warnings on the
    dependency `mix.exs`, so a missed purge is visible to the user.
  - **One r7 leak removed:** when a removed dependency's directory is gone, r7 logs
    "Unable to prune ... File.Error" and keeps that project loaded. The patch purges it.
  - Details: `tmp/elixirls-v2/beta-team/warm-review/REVIEW.md`.

## Existing r7 findings (not caused by this patch)

r7 and the patch behave the same in each case.

- **F1 (owner p1, Astra 2026-09-25):** a build worker crash leaves the hook reporting
  "pending" until the next source edit.
  - Crash causes seen: dependency compile error, lock mismatch, compile_env mismatch.
  - Cause: `neovim_sync.lua` does not treat `build_error` telemetry as a finished build.
  - Reproductions: `tmp/elixirls-v2/beta-team/warm/F1.md`.
- **F2 (pR, sent to Astra):** after a dependency is removed from `mix.exs` in a session,
  code that calls it still compiles without a warning. A fresh session warns
  "module ... is not available".
- **O1 (pR, sent to Astra):** after a Git dependency tag update, go-to-definition of a
  new function in it returns no location.

## Limits

- The patch depends on Mix's `{:app, app}` cache key, and the bundle pins Elixir 1.20.4.
  If the key changed, the result would be "redefining module" warnings, not stale builds.
  - ElixirLS publishes these warnings as diagnostics on the dependency `mix.exs` (pR's
    negative control).
  - The r7 scenario comparison would catch them: every build loads the path and Git
    dependency projects, and the diagnostics must match r7 at every step.
  - Check this again on any toolchain bump.
- Dependency `mix.exs` files are now evaluated only when Mix itself loads them, the same
  as command-line `mix compile`.
- Tested on macOS only.

## Integration (p1)

1. In `build_bundle.py` `build_server()`, apply `elixirls-cached-prune.patch` after the
   targeted-invalidation patch.
2. Add the patch to `PROVENANCE_FILES`.
3. Build a new immutable bundle.
4. Run doctor, the existing gates, `warm_scenario_probe.py` (compare with an r7 run
   using `compare_scenarios.py`) and a warm A/B with `warm_phase_probe.py`.

## Files

- In this directory:
  - `elixirls-cached-prune.patch`
  - `warm_phase_probe.py` (timing)
  - `warm_scenario_probe.py` (scenarios; `--during` for edits during a build)
  - `compare_scenarios.py`
- Local evidence (ignored by git): `tmp/elixirls-v2/beta-team/warm/`.
  - `RESULT.md`, `PHASES.md` and `F1.md`
  - `runs/` and `scenarios/`
  - derived bundles and measurement-only patches
