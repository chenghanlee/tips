# Compiler and invalidation correctness

Date: 2026-09-24. Isolated branch: `experiment/elixirls-codex-v2`.

The next candidate should be retained targeted invalidation, under an explicit
observed-change contract. The compiler resource candidate still fails a required
adversarial case. Neither is ready for rollout: reconciliation introduced a
duplicate-build regression, and completely unobserved transient changes remain
outside the targeted candidate's guarantee.

No installed compiler, active launcher configuration, or Tips application source
was changed. These results are local synthetic acceptance tests, not a new Tips
agent cohort or a measured real-workload failure rate.

## What changed

- ElixirLS keeps pending and in-flight path sets separately. Only a successful
  Mix compile (`:ok` or `:noop`) acknowledges the running worker's batch.
  Project-reload errors, compilation errors, disabled compilation and worker
  death retain unacknowledged paths for the next requested build. Retention
  does not itself schedule retries, so persistent failures do not cause a loop.
- A newer event for the same path belongs to the pending set; completion of the
  old build cannot erase it. Acknowledgment is bound to the worker PID.
- Neovim now retries watched-file notifications for unopened and deleted files,
  instead of clearing them and assuming its native watcher delivered them.
  It preserves create/change/delete types and matches the pinned ElixirLS default
  extension list. Existing opened-buffer reload/save handling remains.
- A separate compiler experiment compares resource content before and after
  compilation. It uses an explicit provisional digest tag, distinguishes a
  stable missing resource from an unverified one, and checks content even when
  timestamps are preserved. This candidate is **rejected**, as explained below.

The retained patches are [Mix targeted invalidation](mix-targeted-invalidation.patch)
and [ElixirLS scheduling/retention](elixirls-targeted-invalidation.patch).
`--force-path` is our private pinned Mix extension, not an upstream option.
It uses Mix's existing source/resource ownership and dependency traversal;
it does not introduce another dependency graph or a force-everything policy.

## Acceptance results

Every executable freshness check asserts both the edited/resource-owning module
and a compile-time caller. Protocol/MCP acceptance runs inspect artifacts in a
fresh VM using `--no-compile`, so verification cannot silently repair the result.

| Boundary | Result |
| --- | --- |
| Original timestamp resource patch: deletion and preserved timestamp | Both fail; stale target and caller reproduced |
| New resource candidate: deletion, preserved timestamp, another edit during repair | All pass; later unchanged builds settle to no-op |
| New resource candidate: eight requests within one second | First compiles the owner; seven subsequent requests are no-ops; unrelated module untouched |
| New resource candidate: A→B→A between snapshots | **Fails both assertions**: target/caller B, disk A; follow-up incorrectly no-ops |
| Old targeted server: reload failure before Mix, then unrelated event | **Fails both assertions**; invalidation lost at build launch |
| Retained targeted server: reload failure, compile failure, disabled compilation | All repair on a later trigger; no autonomous retry loop |
| Retained targeted server: edit during repair and revert | Both pass; new pending event survives old completion |
| Actual build worker killed before Mix | Later unrelated event repairs target and caller |
| Ten ordinary source edits through ElixirLS | Each compiles target + dependent; normal incremental behavior preserved |
| Old scanner with native watcher disabled | Missed unopened resource remains stale |
| Revised scanner, actual Neovim + vv-mcp + patched ElixirLS/Mix | Rejected notification retried exactly once; preserved timestamp, deletion, recreation, overlapping resource edit all pass |
| Opened-buffer deletion, rejected notification after buffer removal | Next scan retries through unopened-file path; passes |
| Targeted A→B→A with final resource invalidation | Both assertions pass |
| Targeted A→B→A with no invalidation | **Fails both assertions**; same explicit observability boundary |
| Long compile through actual MCP/hook | Pending at 4.803 s; unchanged hook 0.101 s; later completion and artifact assertions pass |

Additional checks: 78 ElixirLS tests pass together (77 existing tests and the
worker-death acceptance test). Ten Neovim boundary checks and the existing MCP
qualification/watcher/error/repair probe pass. Python syntax checks pass.
Changed Elixir files format successfully; patched core modules compile with
warnings as errors. Full ElixirLS warnings-as-errors fails on its existing
`parser.ex:542` warning. Credo is unavailable in that project. No applicable LSP
connector was available for editing the compiler/server sources; source inspection
and executable checks were used.

One existing budget test **fails**: it expects a three-second compile to finish
inside its edit hook. Scanner reconciliation sends a change notification, then
the native watcher sends a creation notification for the same path; the log shows
two build starts and two compile markers. The hook correctly returns pending at
4.773 seconds. This is a feedback-latency regression, not a deadline overrun.
That test stopped at its first failed assertion; its later scenarios did not run.
The separate successful long-build probe above used the patched complete stack
with native watching deliberately disabled to test reconciliation.

## The contract we can support

For a supported file that is observed changed, retain its invalidation until a
successful compilation services that batch. An edit during that build creates
another pending invalidation. At hooks/LSP reads, reconcile persistent content,
creation and deletion differences missed by native watching. Failed transport
acceptance remains retryable without another edit. Normal compilation and tests
remain necessary; feedback status is an editor observation, not a certificate
of the bytes consumed by every compiler or macro.

The scanner covers Git-tracked/nonignored regular files with the pinned server's
default extensions, excluding disposable `tmp/` fixtures. It does not claim to
cover arbitrary resources outside that scope or custom additional extensions.
After a failed build, retained paths wait for another build trigger; no timer
retries a persistent error. Process restart uses the existing startup force build.

A resource that becomes B and returns to A entirely between observations, with
both file events absent, is not a persistent content difference. Neither a
hash snapshot nor a queue can reconstruct that missing history. The negative
control makes this limitation explicit; the observed-event case passes.

## Unresolved findings: nine whys each

### 1. Why does the compiler resource candidate still trust stale output?

1. Why does a later build keep B when disk contains A? The manifest describes A,
   so the incremental check finds no change.
2. Why does the manifest describe A? Resource fingerprinting reads the path after
   the module has consumed its resource.
3. Why can the module contain B? Compile-time code read B during the controlled
   interval before the file reverted to A.
4. Why did the new pre-compilation fingerprint not catch it? That read also saw A.
5. Why is equality of those two reads insufficient? It proves endpoint equality,
   not that the contents stayed constant between them.
6. Why do timestamps not supply the missing proof? They are metadata, can be
   preserved, and do not identify the bytes consumed. Deletion also has to remain
   distinguishable from provisional metadata.
7. Why does the exact-source correction work better for `.ex`? It fingerprints the
   same buffer passed to the parser. Resource reads happen separately in macro or
   application code; the current callback receives paths rather than those bytes.
8. Why cannot a different sentinel fix this? A sentinel can retain a suspicion
   already detected; it cannot detect the invisible intermediate read.
9. Why cannot more boundary hashes establish a general guarantee? Any finite
   sampling schedule can miss an intermediate version. The missing information
   is the consumed input, or a trustworthy observation that invalidates it.

**Root:** artifact provenance is missing for external-resource reads. The proposed
trust transition, “equal before/after content implies trusted,” is unsound under
concurrent writes. More sentinel policy does not repair that transition.

Directions requiring separate tests: capture consumed resource bytes, compile
against stable inputs, or use observed change events to invalidate owners. The
last is the smaller implemented candidate for our editor workflow; this does not
prove that every possible direct compiler correction must be large.

### 2. Why can targeted invalidation miss an entirely unobserved revert?

1. Why does targeted invalidation fail the no-event A→B→A control? Mix never
   receives the resource path as an invalidation.
2. Why does queue retention not recover it? There was no accepted item to retain.
3. Why does scanning not manufacture the missing event? Its old and new hashes
   both describe A.
4. Why can artifacts nevertheless contain B? The compiler independently observed
   the intermediate B while our snapshots did not.
5. Why can the native watcher not be assumed to settle the question? Notifications
   and scans are different observation paths; the tested fault explicitly removes
   notifications. Faster scanning does not make that path reliable by definition.
6. Why does one agent not prevent the interleaving? Compilation runs concurrently
   with shell/file-writing tools, including after the five-second hook returns.
7. Why does the generation counter not reveal it? Generations count observed
   differences; they are not a journal of every write.
8. Why cannot another manifest read recover the history? The failure already has
   a manifest whose A fingerprint agrees with disk but disagrees with compiled B.
9. Why cannot another retry solve it? Retrying a known path repairs it, but choosing
   that path requires evidence that this scenario deliberately withholds.

**Root:** missing observations, not missing retry state. Persistent missed edits
and rejected sends are now repaired; completely missed transient histories are
a different contract. A stronger guarantee requires controlled write/compile
coordination, consumed-input tracking, or conservative recovery with a justified
trigger. None has been established here as a small, general replacement.

### 3. Why does reconciliation cause duplicate builds?

1. Why did the three-second example return pending? A second build was running
   when the hook exhausted its budget.
2. Why did a second build start? A second file notification arrived during the first.
3. Why were there two notifications? The scanner now repairs missing delivery;
   Neovim's native watcher still independently publishes its event.
4. Why did existing Neovim deduplication not merge them? Its 100 ms queue and
   per-path/type cache cover its own native events. Our `client:notify` call
   bypasses that queue; the recorded events also have different change types.
5. Why does ElixirLS preserve the second event? An event during a build can be a
   real later edit. Its pending-build behavior is necessary for the overlap case.
6. Why not drop the second event when disk hashes match? Matching endpoints can
   also describe A→B→A, precisely the resource counterexample above.
7. Why not use a debounce window? It groups arrival times, not physical edits or
   compiler-consumed versions. A real edit can occur within the same window.
8. Why do we need two independent publishers? We do not inherently need two;
   we need native observation plus fallback reconciliation. Publication ownership
   was split when the missing-delivery fix was added.
9. Why cannot a delivery-generation ID simply be added afterward? These events
   arrive without a shared edit identity. Assigning independent IDs would label
   both notifications without proving they represent the same write.

**Root:** overlapping notification ownership without enough information for safe
post-hoc deduplication. The next discriminating design is a single publication
boundary that accepts native observations and scan results, with a documented
coalescing contract. This is a candidate to test, not a claim that deduplication
can always distinguish duplicates from real intermediate edits. Extending the
hook deadline would hide the regression and leave the root unchanged.

## Decision and replay

Prefer retained targeted invalidation for the next integration candidate: it
repairs observed source/resource changes using Mix's dependency traversal and
does not modify Kernel.ParallelCompiler or invent trusted resource metadata.
Keep its observation limits explicit. Do not adopt the resource content-bracket
candidate or call either approach generally correct under unobserved writes.
Resolve duplicate publication before treating this as product-ready feedback.

Evidence: [machine-readable checks and hashes](correctness-evidence.json).
Full fixtures, LSP/MCP transcripts and logs are in
`/private/tmp/tips-elixirls-codex-v2/tmp/elixirls-v2/correctness/`.

Replay tools: `build_resource_candidate.py`, `build_targeted_server.py`,
`compiler_comparison_probe.py`, `compiler_lsp_probe.py`, `resource_aba_probe.py`,
`resource_rapid_probe.py`, `neovim_reconcile_probe.py`, and
`invalidation_worker_test.exs`. The existing compiler/protocol runners were
extended in place after initial red/green runs; their temporary duplicate runner
names in earlier command records are not separate implementations.

The resource candidate is under `correctness/resource-candidate/`; the retained
server is under `correctness/targeted-server/elixir-ls/`. The targeted private Mix
toolchain remains `invalidation-comparison/targeted/toolchain/`. Tests use pinned
Elixir 1.20.4, ElixirLS 0.31.1, Neovim 0.12.5 and vv-mcp 0.3.4.
