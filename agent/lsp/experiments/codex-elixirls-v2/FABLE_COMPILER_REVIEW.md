# Codex adversarial verification of Fable's compiler-choice review

Raw paths in this report resolve under
`/private/tmp/tips-fable-compiler-choice-review-z4qi6hdb/`.
The original shared response is `CODEX_REVIEW.md` there.

2026-09-24. Reviewed `REVIEW.md`, its frozen sources, eight acceptance results,
cost probes, cohort event extraction, and the existing adapter's delivery paths.
All 40 input snapshot hashes still match. No candidate, installed toolchain,
application, active configuration or existing test result was changed.

## Verdict

**Do not adopt direct-plus as written.** Fable found a useful smaller compiler
approach and fairly challenged my preference for targeted invalidation. However,
I reproduced two correctness failures that its eight-case matrix did not cover:
deleting a declared resource during compilation, and overwriting one while
preserving an older timestamp. I also disproved the claimed one-extra-compile
bound.

I retract the implication that improving the direct prototype necessarily needs
capturing every macro's input bytes or immutable snapshots. Conservative
invalidation inside Mix is another approach worth testing. But this particular
timestamp rule does not establish complete declared-resource coverage.

The new evidence does not make targeted universally reliable: its omitted-hint
failure and pre-compiler retention gap remain. It does mean Fable's proposal has
not eliminated the substantive tradeoff between the two approaches.

## High: deletion of a declared resource remains permanently stale

Fable `REVIEW.md:10-15`, `:30-35`, `:142-144` claims that declared resources are
covered and remaining work is packaging/live validation.

Reproduction, using Fable's exact built toolchain:

1. A module declares `lib/value.heex` as an external resource and reads it into a
   module attribute. Its program returns `:missing` if the resource is absent.
2. Compile with resource contents `aa`; wait for the marker after the read.
3. Delete the resource while compilation is paused.
4. Finish that compilation, then run ordinary compilation again after two seconds.
5. In a fresh VM with `--no-compile`, both target and compile-time caller return
   `aa`, although evaluating the final saved program should produce `missing`.
   Both ExUnit assertions fail. Another build reports no changes.

The manifest audit finds `{"lib/value.heex", {0, -1}, nil}`. The resource no
longer has a recent mtime, so `process_external_resources/3` does not mark it
suspect. `stale_external?/2` treats a currently missing resource as changed only
when the recorded digest is non-nil. The post-build metadata has erased the
evidence that the module consumed a resource that existed earlier.

Code: Fable candidate `compiler_elixir.ex:1384-1402` and `:498-505` under
`probes/direct-plus/direct-plus/`. This is an ordinary deletion, not a simulated
clock anomaly or undeclared input. The fallback behavior makes the acceptance
result explicit; actual Phoenix missing-template behavior was not tested.

Targeted invalidation, given the deleted resource path, recompiles the owner and
caller to `missing`, leaves the unrelated module untouched, and settles to no-op.

Evidence:
`codex-verification/direct-plus-external-delete-v2/{results.json,acceptance.log,manifest-audit.log}`;
passing control `codex-verification/targeted-external-delete-v2/`.

## High within the claimed timestamp-resilient scope: preserved mtimes escape

Fable's inference at `REVIEW.md:137-140` needs an assumption: a resource modified
during compilation must receive an mtime at least as new as the build start.
That implication does not hold for preserved/backdated timestamps.

The probe writes `aa` with a timestamp ten seconds old. The first compilation
does read `aa`. During its pause, the probe writes equal-size `bb` and restores
the previous timestamp. Direct-plus records the newer digest and the old stat,
does not install the sentinel, and keeps both executable results at `aa` across
later ordinary builds. Disk is `bb`. Both fresh-VM ExUnit assertions fail.

Targeted invalidation with the path succeeds. The baseline also fails, so the
sentinel did not introduce this defect; it failed to close this part of the
original metadata problem.

This is not a claim that ordinary `apply_patch` preserves timestamps. It is a
boundary that must be accepted explicitly or handled, especially because the
comparison already advertised preserved-stat coverage. The earlier `same-stat`
case covered `.ex` source only. Eight cases were not the cross-product of input
type, timestamp behavior and creation/deletion.

Evidence:
`codex-verification/direct-plus-external-preserved-v2/{results.json,acceptance.log,manifest-audit.log}`;
passing control `codex-verification/targeted-external-preserved-v2/`.

## Medium: the claimed one-extra-compile bound is false

Fable `REVIEW.md:89-97`, `:176-177` and `probes/cost2/NOTES.md` claim at most one
additional owner compilation per edit. Those cost probes invoke fresh Mix VMs,
whose startup delay helps advance the wall-clock second.

I instead requested repeated builds in one warm VM, matching ElixirLS's process
lifetime more closely. One resource edit just after the second boundary was
followed by eight compilation requests within about 254 ms. **All eight compiled
the owner.** The stat remained recent, so each compilation recreated the sentinel.
After a 1.1-second wait, request nine compiled it again and request ten was a no-op.
The unchanged original direct patch compiled once and all subsequent requests
were no-ops under the same probe.

This proves eight extra owner compiles across nine requested builds in this
fixture, rather than a maximum of one. It does **not** establish an autonomous
build loop, an infinite loop, or nine builds per edit in Tips. The compiler only
acted on the requests the probe made; no unrelated module was recompiled.

Evidence: `codex-verification/rapid-direct-plus/{results.json,rapid.log}` and
`codex-verification/rapid-direct-control/{results.json,rapid.log}`.

## Other corrections and findings that survive

| Fable claim | Assessment |
|---|---|
| Original eight cases pass | Accepted. Artifacts, assertions, controls and loaded bytecode checks are consistent. I independently repeated the ordinary external-overwrite case; direct-plus passes and baseline fails. |
| A small local compiler approach was dismissed prematurely | Accepted. I compared implemented coverage and overestimated the size of every possible extension. The sentinel is useful new evidence, even though incomplete. |
| Exact `.ex` bytes should determine its digest | Accepted. The pinned upstream `elixir_compiler.file/2` performs the same read/parse sequence as the direct wrapper. Preserving 1/2-arity callbacks is visible in the patch. This does not replace a broader compiler regression suite. |
| Targeted clears paths too early | Accepted, but it is a fixable queue handoff defect. Failure to receive any path is a distinct limitation. Calling both “structural” obscures the distinction. |
| Direct-plus needs “no delivery contract” | Too broad. It needs no per-path hint for the tested recovery build, but a later build still must occur. The missing-hint test explicitly invokes that build. Lost notifications can prevent either integration from starting work. |
| Duplicate hints occur on every open-file edit | Not established. The provider trace shows a watcher-first/open/save sequence that queues a second build. Health/media also show save-first updates whose later watcher events do not launch another build, consistent with the open-clean filter. A real risk is not a measured universal rate. |
| The scanner provides reliable reconciliation for all changed files | Neither report establishes this. `neovim_sync.lua:46-48` clears pending entries for unopened files and relies on native watcher delivery; its hash scan does not resend those events. This also weakens my earlier suggestion that existing retries might be enough. |
| Synthetic performance makes targeted preferable | My earlier weighting was too strong. At 49 synthetic files the gap is roughly 2-3 ms, which does not justify weaker correctness. Fable's “irrelevant” and “nothing” are also too strong: the 1,000-file data identifies a real scaling cost, and neither row measures actual Tips runtime. |
| Tips has 49 `.ex` files / about 190 KB | Independently confirmed for `lib/` in the experiment checkout: 49 files, 190,080 bytes. This is not the same workload as the synthetic 49-file benchmark or a full test-environment compilation. |
| The agent's own `_build` is “never raced” | Unsupported guarantee. Separate build directories isolate caches, not source reads. A background/yielded Mix command can overlap a later edit even with one agent; any sequential-only contract needs to be stated and enforced. |
| Startup force heals preexisting corrupt manifests | Supported for enabled, successful ElixirLS startup compilation; it is not evidence that merely swapping toolchains repairs every cache or failed startup. |
| File-mtime force fallback passes late delivery “by construction” | A proposal, not measured evidence. It deserves the same preserved-mtime, deletion, duplicate and clock-assumption tests. Do not replace one unverified timing guarantee with another. |

The pinned upstream read path is at
[elixir_compiler.erl](https://raw.githubusercontent.com/elixir-lang/elixir/v1.20.4/lib/elixir/src/elixir_compiler.erl).
The missing-file sentinel and future-mtime handling are documented in
[Mix.Utils](https://raw.githubusercontent.com/elixir-lang/elixir/v1.20.4/lib/mix/lib/mix/utils.ex).
In particular, `{0, -1}` already means a missing/unreadable file; it is not a
unique marker for an untrustworthy compilation record.

## Eight whys behind the remaining direct-plus failure

1. Why does a later build still return an old resource value? It skips the owner.
2. Why skip after the resource changed or disappeared? Recorded metadata matches
   the final filesystem state, while the artifact reflects an earlier state.
3. Why didn't the new sentinel prevent that? It only checks a recent mtime.
4. Why can a changed resource lack a recent mtime? Its timestamp can be preserved,
   or deletion can make stat return the missing-file representation.
5. Why was recent mtime treated as sufficient evidence? The design assumes
   resource mutation time is faithfully represented by its final file stat.
6. Why is that assumption consequential? It decides whether a compiled artifact
   may be reused, rather than merely whether to show a warning.
7. Why don't eight passing cases settle it? Those cases test source timestamps
   and source deletion separately from resource overlap; they miss their
   combination and use slow builds/fresh VMs that mask repeated sentinels.
8. Why is this still the root problem? We need a sound reason to reuse an output
   or a retained obligation to recompile it. A final stat alone does not always
   provide either. Two further whys return to this same provenance boundary.

## Revised decision

Keep both approaches experimental. **Fable's nine-line addition is not sufficient
grounds to replace targeted invalidation with direct-plus today.** It does justify
continuing the compiler-side option instead of treating its original external
failure as intrinsic to every small direct solution.

The next discriminating work is correctness, not a cohort performance contest:

1. For a compiler-side candidate, handle resource deletion and explicitly resolve
   the preserved-timestamp contract. Define when suspect resource metadata becomes
   trusted again; test repeated same-second builds and another edit during repair.
   Do not simply treat `{0, -1}` as a unique “dirty” flag or accept a new untested
   sentinel as a fix.
2. For targeted invalidation, independently validate pending/in-flight retention
   and reconcile missing delivery through the actual adapter. Retrying an
   unopened file is not implemented by the existing scanner today.
3. Choose on the resulting end-to-end contract and maintenance surface. Both
   approaches are fast enough in the small synthetic fixture; those timings do
   not establish which is more reliable. Neither has a measured real-workload
   failure rate. Deletion is a normal operation, so it should not be silently
   scoped out to make the simpler patch pass.

The current targeted prototype passes the two new resource cases **when given
the path**. That qualification remains essential. No overall reliability winner
has been established by these experiments.

## Verification and artifacts

- Nine fresh extended external-resource runs: three baseline controls, three
  direct-plus cases and three targeted cases. All overlap/loading/hash controls
  pass. Warmup and follow-up compilations use warnings-as-errors; stale-output
  cases fail the intended ExUnit assertions in a fresh VM.
- Two warm-VM cost runs, with bytecode hash verification and no unrelated compile.
- Probe formatting, Python syntax and evidence consistency checks passed.
- Credo is unavailable in the dependency-free fixture (`mix credo --strict`:
  task not found). No applicable Elixir LSP connector was exposed for review;
  source inspection was used. No core source was changed in this verification.
- An initial fixture had a missing parenthesis around a module-attribute `case`.
  Those nine setup attempts failed compilation and are excluded. Final output
  directories end in `-v2`.
- Not run here: actual Phoenix resource races, live ElixirLS/direct-plus, the
  three Tips agents, or the full upstream compiler test suite. The new plain-Mix
  counterexamples are sufficient to reject the broad adoption claim as stated.

Evidence and reproductions:

- `codex-verification/evidence.json`
- `codex-verification/external_boundary_probe.py`
- `codex-verification/rapid_resource_probe.py`
- The per-case paths identified above, including manifest audit logs.

Fable's report and probes remain untouched, and their positive results remain
valid evidence within their tested scope.
