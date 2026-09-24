# Direct compiler correction versus targeted invalidation

2026-09-24. Elixir 1.20.4 / OTP 29 / ElixirLS 0.31.1. Isolated prototypes on
`experiment/elixirls-codex-v2`; no installed toolchain, active configuration,
Neovim adapter, hook, or application source was changed.

## Finding and recommendation

Both approaches repair the reproduced `.ex` race and preserve incremental
dependency recompilation. **Targeted invalidation is the better next candidate
for this integration**, because it also repairs the demonstrated external-resource
race and does less work on ordinary builds. This is a recommendation for the next
implementation boundary, not approval to deploy this prototype.

The direct correction is stronger for compiler-owned source identity: a later
ordinary build can repair `.ex` output without receiving the changed path. But
the small direct patch does not fix external resources. Targeted invalidation
depends on delivery and retention of changed paths; it repairs the stale output
without correcting the original input/fingerprint race.

The existing dependency graph worked in these fixtures, consistent with Fable's
stable-re-edit result. Neither approach needs a graph in the MCP adapter.

## What was implemented

| | Direct correction | Targeted invalidation |
|---|---|---|
| Core change | Carry the exact source binary parsed by the parallel compiler through its callback; record its digest in Mix. Compare source digests on subsequent builds even when timestamps match. | Add an experimental `--force-path` option. Feed matching sources, or sources declaring that external resource, into Mix's existing changed-source calculation. |
| ElixirLS change | None for invalidation. Ordinary builds use the private patched toolchain. | Accumulate paths from accepted watched-file events and saves; pass them into the next build. Events arriving during that build remain pending for the following build. |
| Existing behavior reused | Mix dependency propagation, compilation, manifests and failure checkpoints. | The same mechanisms, plus ElixirLS's existing build queue. |
| Patch footprint | Two compiler/Mix modules; 34 added and 22 removed lines. | Two Mix modules, 10 added/3 removed; two ElixirLS modules, 22 added/9 removed. |
| Packaging | A private pinned Elixir toolchain. | A private pinned Elixir toolchain and ElixirLS fork. |

`--force-path` is a **local experimental addition**, not an existing Mix or LSP
API. It bypasses the initial skip for a selected input; Mix decides which
dependents must also compile. It does not independently compile a single module
or bypass dependency ordering. ElixirLS's existing startup force remains; no
time-window or additional whole-application recovery force was introduced.

Both variants were loaded from private copies of the installed toolchain, about
11 MiB each. The final plain-Mix probes verify both module paths and candidate
bytecode hashes. ElixirLS probes log the compiler path from inside compilation.
Early `-pa` attempts were shadowed by Mix's library-path setup; those setup runs
are explicitly excluded from the comparison evidence.

## Acceptance results

Assertions run in a fresh VM against already compiled artifacts, with
`--no-compile`: they cannot repair the artifacts they are checking. Each checks
the target's executable result and its compile-time caller against the final
saved value. Probes also check that an unrelated module was not recompiled and
that a subsequent build without changes becomes a no-op. Compile-marker controls
confirm that the overlapping writes actually occurred.

| Boundary | Direct | Targeted |
|---|---|---|
| Equal-size source overwrite during compilation | Pass | Pass |
| Overwrite preserving exact file size and mtime | Pass | Pass |
| Another overlapping compilation, reverting B to A | Pass | Pass |
| Ordinary stable edit | Pass | Pass |
| Syntax failure, repair, then a build without another path hint | Pass | Pass |
| Create source, delete it, verify artifact removal, then edit target | Pass | Pass |
| External resource read as A, overwritten with B during compilation | **Fails: target and caller stay A** | Pass |
| Later build explicitly run, but changed-path hint omitted | Pass | **Fails: target and caller stay A** |

The last row does not mean direct compilation happens without a trigger. The
probe explicitly invokes a later build. It tests whether that build needs the
specific changed-path hint in order to recover.

Baseline controls reproduce stale source, same-stat and external-resource cases;
an ordinary stable edit passes. There are 20 retained plain-Mix runs, including
these four baseline controls. The two candidate failures are intentional boundary
discoveries, not a claim that the entire acceptance suite passes.

**Eight live ElixirLS runs also passed**, four per candidate:

- Notification delivered two seconds after the overlapping build completed.
- Another edit during the recovery build, ending at C.
- Revert during recovery, ending back at A.
- Ten ordinary stable edits. Each compiled two files: target and dependent.

These runs verified fresh hover documentation and both executable assertions.
No unexpected builds appeared during the settle window; all launcher processes
exited with status 0. This is an MCP-independent LSP test, not another Codex or
Neovim dogfood cohort.

## Why the direct fix still fails on external resources

1. Why does the target retain A? It read A from the declared external resource
   while its module was compiling.
2. Why does the next incremental build skip it? Resource metadata can describe
   the later B contents, so the current disk contents appear unchanged.
3. Why didn't passing the exact `.ex` source fix this? That source did not change;
   the resource is a separate compiler input.
4. Why isn't that resource covered by the source callback? Project code or a
   macro reads it, while Mix records the declared resource separately afterward.
5. Why not just hash it earlier too? A separate read still need not observe the
   bytes used by the macro. Moving the race boundary does not establish identity.
6. Why does targeted invalidation recover? The changed-resource hint causes the
   owning source and its necessary dependents to compile despite that metadata.
7. Why is that a bounded repair rather than universal prevention? It requires a
   later stable compilation and delivery of the relevant changed path. It does
   not prove what arbitrary macro file reads consumed.

The next two whys lead back to the same boundary: compiler outputs can depend on
inputs beyond the `.ex` buffer. General prevention needs input identity or stable
inputs across those reads; the small direct source patch does not provide that.
This resource fixture uses `@external_resource` with a `.heex` file, not Phoenix's
HEEx compiler. It demonstrates the shared mechanism, not full Phoenix validation.

## Performance

Synthetic, dependency-free projects with 49 or 1,000 `.ex` files; approximately
8 KiB per unrelated file. No artificial compile sleeps. Measurements run repeated
Mix tasks inside a warm VM, so they exclude VM and language-server startup.
Ten no-op samples and five per other phase; table values are median milliseconds.
These are single-host exploratory measurements, not Tips latency or capacity
estimates. OS cache state and background load were not controlled statistically.

| Files | Candidate | No changes | Stable edit | Repeated unchanged path hint | Full application force |
|---:|---|---:|---:|---:|---:|
| 49 | Baseline | 19.87 | 31.30 | 20.45 | 125.62 |
| 49 | Direct | 23.95 | 34.74 | 24.41 | 128.83 |
| 49 | Targeted | 20.70 | 32.47 | 33.14 | 128.53 |
| 1,000 | Baseline | 54.73 | 70.75 | 54.15 | 1,151.91 |
| 1,000 | Direct | 141.50 | 151.29 | 133.95 | 1,121.56 |
| 1,000 | Targeted | 76.72 | 94.25 | 93.90 | 1,148.18 |

Only targeted receives a path hint in the duplicate column; the other two run a
normal unchanged build. This exposes an actual cost: duplicate hints can cause
target/dependent recompilation. A set coalesces hints waiting together; it does
not eliminate duplicate delivery across separate builds.

The direct implementation reads and hashes every source on every build. The
targeted implementation still scans the manifest and normalizes source/resource
paths, but does not add those full-content reads. Its empty-hint path could skip
unnecessary path normalization; that optimization was not included or measured.
The dominant avoided cost in the large fixture is compiling unrelated modules.

## Remaining ownership and decision

First principles favor recording the actual compiled inputs. The direct patch
does this for `.ex`, but its external-resource failure demonstrates why source-only
correctness is insufficient for the broader integration.

Occam favors targeted invalidation for the current scope: keep the working
Neovim/MCP/hook stack and reuse Mix's stale-source traversal. Pareto favors
avoiding unrelated recompilation without building immutable project snapshots,
another dependency graph, or permanent tool restrictions.

Before adopting targeted invalidation, address these concrete boundaries:

1. **Retain accepted paths until serviced.** This prototype transfers them at
   build launch. A build that fails before invoking Mix could lose them. Passing
   the syntax-error test proves Mix checkpoint recovery after the compiler is
   entered; it does not prove this earlier boundary. Keep a separate in-flight
   set, acknowledge it only after compilation, and merge it back on failure,
   without an automatic retry loop for persistent compilation errors. A newer
   event for the same path must survive completion of the older build.
2. **Preserve the change-delivery contract.** The omitted-hint failure is real.
   Existing retryable synchronization is relevant, but this experiment did not
   validate its end-to-end delivery into the new path queue. Do not deduplicate
   using the potentially incorrect compiler manifest.
3. **Test project scope before broad claims.** Umbrella applications, changed path
   dependencies, actual Phoenix resource compilation, and build cancellation or
   process death need acceptance tests. The current result covers application
   sources and declared resources in a small project.

Neither current prototype is a complete general Mix correction. Do not combine
them reflexively: that would inherit both maintenance surfaces before resolving
these specific obligations. No real Tips occurrence rate for the original race
has been established, and no forced-build scaling failure was demonstrated.

## Checks and artifacts

- Both candidates' core modules formatted and compiled with warnings as errors.
- Targeted ElixirLS changed files passed formatting. Existing server suite:
  **77 passed** under the private targeted toolchain.
- ElixirLS test-environment `compile --warnings-as-errors` failed on existing type
  warnings in `elixir_ls_utils/test/support/modules_with_docs.ex`. Local server
  launch also reports the existing `parser.ex:542` warning. These are not clean
  warnings-as-errors results for the entire server.
- `mix credo --strict`: unavailable, task not found in the ElixirLS project.
  No applicable LSP connector was available for reviewing the core modules;
  version-pinned source inspection was used. Real LSP protocol tests ran afterward.
- Python syntax checks passed. Full upstream Elixir compiler tests, full Tips
  tests and the three agent workloads were not rerun for these prototypes.

Durable artifacts:

- [Evidence, timings, checks and raw-run paths](compiler-comparison-evidence.json).
- [Direct core patch](compiler-direct.patch).
- [Targeted Mix patch](mix-targeted-invalidation.patch) and
  [ElixirLS path-queue patch](elixirls-targeted-invalidation.patch).
- [Core builder](build_compiler_comparison.py),
  [server builder](build_targeted_server.py),
  [plain-Mix acceptance probe](compiler_comparison_probe.py),
  [live LSP probe](compiler_lsp_probe.py), and
  [benchmark](compiler_comparison_bench.py).

Raw output:
`/private/tmp/tips-elixirls-codex-v2/tmp/elixirls-v2/invalidation-comparison`.
Builders consume the pinned source files in its `upstream/` directory; URLs and
SHA-256 digests are recorded in the evidence. The server builder uses a private
dependency/cache seed and restores the compared files from pinned upstream source;
it does not retain the rejected grace-window server change.

Source references: pinned
[parallel compiler](https://raw.githubusercontent.com/elixir-lang/elixir/v1.20.4/lib/elixir/lib/kernel/parallel_compiler.ex),
[Mix compiler](https://raw.githubusercontent.com/elixir-lang/elixir/v1.20.4/lib/mix/lib/mix/compilers/elixir.ex),
and [compiler task](https://raw.githubusercontent.com/elixir-lang/elixir/v1.20.4/lib/mix/lib/mix/tasks/compile.elixir.ex).
The compiler reads and resource metadata code support the explanation above;
the executable acceptance results establish the observed failures and recovery.
