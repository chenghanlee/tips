# Fixed build batching

Date: 2026-09-24. Branch: experiment/elixirls-codex-v2.

The two proposed candidates describe the same mechanism. One implementation was
tested against the fuller contract: pending/in-flight path sets, a fixed 250 ms
collection window, immediate queued status, failure retention, and ordinary
incremental compilation. No new queue service or dependency was added.

The candidate repairs the measured duplicate-build latency regression. It does
not promise to recognize every duplicate, or repair entirely unobserved changes.
It remains an isolated experiment; active tools and Tips application code were
not changed. This run used protocol/MCP clients, not another model-driven cohort.

## Why this is the small change

1. Why did one edit cause two builds? Reconciliation and native watching both
   delivered notifications.
2. Why did the existing set not merge them? The first event launched a build
   immediately and moved its path out of the pending set.
3. Why retain the later event? The same path can describe a real edit during
   compilation; its filename is not an edit identity.
4. Why collect before starting instead? All paths collected before the worker
   starts can be serviced by that build, under the existing observed-change contract.
5. Why use a fixed window? Continuing events must not postpone compilation forever.
6. Why keep late duplicates? Eliminating them requires stronger information than
   these notifications provide. Accepting some redundant work keeps the mechanism
   small and preserves observed invalidations.

## Implementation

- All accepted build triggers use the existing ElixirLS server process and path
  sets. An idle trigger starts one Erlang timer; additional triggers do not reset it.
- The timer starts the existing build path after 250 ms. Events during compilation
  enter the next pending batch. A successor gets the same bounded collection window.
- A private build_queued event on ElixirLS's existing telemetry notification
  channel marks feedback pending before the build-start log arrives.
- Neovim tracks queued and running work separately. Completion of an older build
  cannot clear queued work. Existing qualified semantic results remain available.
- Successful compilation acknowledges only the running batch. Failures, skipped
  compilation, and worker death retain paths for a later trigger without spinning.
- The existing hook setting was left at five seconds for comparison. That is a
  baseline for this experiment, not an immutable product requirement. The 250 ms
  wait is included in its elapsed time.

The combined [ElixirLS patch](elixirls-targeted-invalidation.patch) is 212 lines
of unified diff, including the prior retention changes and upstream test timing
adjustments. The [builder](build_targeted_server.py) reconstructs it from pinned
ElixirLS source. The private Mix targeted-invalidation patch is unchanged.

## Results

| Check | Result |
| --- | --- |
| Same test against the previous server | Three-second edit still pending at 4.771 s; two compile starts |
| Fixed 250 ms batching | Error delivered at 3.541 s; one compile start |
| Repair | Diagnostics cleared at 0.555 s |
| Eight-second compile | Pending at 4.773 s; later final check delivered the error |
| Fifteen-second compile | Both bounded checks returned pending; eventual completion stayed usable |
| Unchanged tool during build | Returned in 0.091 s |
| Stalled Neovim RPC | Unavailable feedback at 4.942 s; process cleanup passed |
| Save + watcher burst | One compile; later events did not reset the original timer |
| Ten duplicate notifications during compilation, no second edit | Exactly one extra build; no loop |
| Same-path edit during compilation | Target and compile-time caller both reflect the later edit |
| Queued notification with no scanner generation change | Actual MCP diagnostics report pending before the worker starts |
| Reload failure, compilation failure, disabled compilation | Retained invalidation repairs target and caller on a later trigger |
| Worker killed before compilation | Retained invalidation survives and repairs on a later trigger |
| Another edit during recovery | Fresh-VM assertions pass for the latest target and caller |
| Missed native notification plus rejected first send | Actual Neovim/MCP reconciliation retries and repairs |
| Resource deletion/recreation and preserved timestamps | Fresh-VM target/caller assertions pass |
| Fixture exclusions and qualified results | Existing real MCP checks pass; no fixture-triggered builds |

The combined existing/server/worker/batching suite passed 80 tests. A further
three-test batching run passed after adding the explicit late-duplicate case:
81 distinct server tests passed across those runs. Eleven Lua boundary checks
passed. Formatting and Python syntax checks passed. The two modified production
Elixir modules compile with warnings as errors.

Full-project warnings-as-errors still fails on the existing parser.ex:542
warning. ElixirLS has no Credo task. No applicable Elixir LSP connector was
available for source editing; source inspection and executable checks were used.

The first two end-to-end attempts overlapped installation of the isolated server.
They returned unavailable/pending and do not measure warm edit latency. The timing
runner now explicitly waits for startup readiness before making its measured edit.
The old-server control uses that same runner and still reproduces the two builds.
An existing server test also assumed a save would finish compiling within 100 ms;
it now waits for scheduled work using the updated integration-test helper.

## Decision and remaining boundary

Keep this candidate for the next real workload validation. Five seconds was
enough for the measured three-second compile once duplicate work was merged;
these results do not yet justify increasing the default. A larger budget would
allow some genuinely longer builds to return synchronously, at the cost of waiting
longer on each affected edit. Choose that tradeoff using actual workload timings.

Late duplicates can still cost a follow-up incremental build. This is deliberate,
tested, and preferable to a growing history of guessed event identities.
There is no measured 99% reliability claim. Completely unobserved A→B→A histories
remain outside the observed-change contract described in [CORRECTNESS.md](CORRECTNESS.md).
Batching does not make filesystem observations a proof of compiler-consumed bytes.

Evidence: [machine-readable results and hashes](batching-evidence.json).
Raw logs, fixtures and the private server are under tmp/elixirls-v2/batching/.
Replay uses build_targeted_server.py, build_batching_test.exs,
invalidation_worker_test.exs, neovim_patch_boundaries.lua,
neovim_hook_budget_probe.py, neovim_patch_probe.py --batching,
neovim_reconcile_probe.py --slow-budget, and the existing compiler_lsp_probe.py
failure/recovery cases.
