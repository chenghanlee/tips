# Mix correctness: combined root analysis and alternatives

2026-09-24. Analysis only; no runtime or implementation changes in this step.

## Revised problem statement

After saved source stops changing, ordinary incremental compilation should
converge to compiled behavior and semantic information representing that source.
A build record must not permanently certify an artifact from another revision.
The agent should retain normal edits, qualified useful tools and its five-second
maximum feedback wait while analysis catches up.

The goal is not "detect overlap and force a rebuild." That was one attempted
recovery policy. The goal is trustworthy invalidation and eventual convergence.

Full rebuild is an existing recovery primitive, not inherently an invalid
engineering technique. Its cost has not been shown unscalable in Tips. However,
rebuilding unrelated modules is unnecessary work if normal dependency-based
invalidation can be made correct. No real-workload race frequency is established.

## Combined evidence and corrections

| Contribution | What survives review |
|---|---|
| Original Mix investigation | Plain Mix reproduces the fault without Neovim, MCP or ElixirLS. Manifest digest matches disk B while BEAM behavior and docs remain A. Fresh processes and later incremental builds do not repair it. |
| Fable's independent probes | A stable re-edit invalidates the target and correctly recompiles its compile-time caller. Mix's dependency propagation worked in that fixture. Forced application compilation left its unchanged path dependency alone. |
| Review of Fable's proposal | Notification arrival time cannot establish the revision consumed by the compiler. A successful notify is not a compiler acknowledgement. Build completion and adapter generation equality remain observations, not byte-level proof. |
| Live grace-window test | The existing force path repairs the application when invoked against stable source. Immediate and 300 ms notifications recover; a two-second delayed notification produces another no-op and stale A. |

The dependent's stale result is a downstream consequence of the target's
incorrect freshness record; it does not establish a separate dependency-graph
failure. Rebuilding the entire application is therefore not established as
necessary. Conversely, the stable re-edit probe is evidence of a narrower repair,
not a desirable manual workflow for agents.

Sources: [Mix triage](MIX_TRIAGE.md), [live scheduler test](GRACE_RECOVERY.md),
and `/private/tmp/tips-fable-mix-recovery-review-ms_45e4g/REVIEW.md` and
`CODEX_READBACK.md` with their preserved probes.

## Thirteen whys

1. **Why does the agent still get A after saving B?** The compiled target is A;
   a compile-time caller can embed that old value too.
2. **Why does another successful build not update it?** Incremental compilation
   decides there is no relevant source change to compile.
3. **Why does it make that decision despite disk containing B?** The manifest
   already contains B's fingerprint alongside A's artifact.
4. **Why can the record describe a different revision?** The compiler reads the
   source for parsing, and Mix separately reads its path later for the digest.
   An intervening write can make the reads observe different contents.
5. **Why can that write happen with one agent?** The agent's file-writing tool
   and compiler are concurrent processes. A build can outlive the feedback wait.
6. **Why doesn't the existing build queue prevent this?** It serializes builds;
   normal filesystem writers do not participate in that serialization.
7. **Why don't save notifications or rereading the newest manifest fix it?**
   Notifications can trigger another build, but that build may consult the same
   incorrect record. Rereading the record does not change its association with A.
8. **Why did forced compilation help?** It bypassed the faulty incremental skip
   and regenerated outputs from stable source.
9. **Why did we rebuild the entire application?** That was the available existing
   force switch. We had not established a smaller supported invalidation path;
   this is a tooling choice, not evidence that all modules require rebuilding.
10. **Why didn't the one-second scheduler rule make recovery reliable?** It used
    message timing to infer source/build overlap. A delayed message can arrive
    outside the window while the incorrect manifest persists.
11. **Why can't the adapter's generation counter close that gap?** It counts
    observed changes, not the exact source contents that the compiler consumed.
12. **Why isn't moving the digest read earlier automatically sufficient?** It
    remains a second independent read. A file can change between reads, including
    A→B→A sequences that a before/after comparison can miss.
13. **Why is this the root boundary?** Reuse is justified by recorded input
    identity, but that identity can belong to different bytes than the artifact.
    More waiting or more event counting cannot repair that relationship. The
    compiler must preserve it, or its caller must supply stable inputs or a
    trustworthy invalidation obligation.

The underlying defect is an incorrect relationship between compiler inputs,
outputs and reuse metadata. The failed adapter/server policy is a separate
problem: attempting to infer that relationship from asynchronous event timing.

## Source-level boundary and one additional risk

The pinned [Elixir compiler front end](https://raw.githubusercontent.com/elixir-lang/elixir/v1.20.4/lib/elixir/src/elixir_compiler.erl)
reads a binary in `file/2` and passes those contents to parsing. The pinned
[parallel compiler](https://raw.githubusercontent.com/elixir-lang/elixir/v1.20.4/lib/elixir/lib/kernel/parallel_compiler.ex)
passes filename and lexical tracker through its file callback; the inspected
callback path does not pass the source binary or its fingerprint to Mix.
The retained `Mix.Compilers.Elixir.each_file` later reads the file again.
These sources support the mechanism; the internal callback order was not traced
in the reproductions. The final manifest/artifact mismatch was observed directly.

Also, the retained Mix staleness condition at lines 449–452 can avoid comparing
digests when size and stored mtime match. Correcting digest capture alone must
therefore be tested with unchanged/coarse timestamps. This is a source-supported
design risk, not a newly reproduced failure in this analysis. Our original race
was also reproduced across different whole-second timestamps, so timestamp
resolution is not an explanation that replaces the established digest mismatch.

## Search space

| Approach | Correctness principle and reuse | Cost and unresolved obligations |
|---|---|---|
| **Local compiler/Mix fix** | Carry the identity of the actual source buffer used for compilation into the manifest, and validate that identity correctly before reuse. Preserve Mix's dependency traversal. | Most direct prevention. Requires changes below ElixirLS, auditing metadata fast paths and a maintained version-pinned toolchain. Exact patch scope and deployment cost untested. |
| **Explicit invalidation of changed inputs** | Feed a saved/changed path into Mix's existing stale-file machinery so it and necessary dependents recompile, even when the current fingerprint claims freshness. Receipt time need not determine whether the path is dirty. | Potentially much less work than whole-application force. No general public force-this-path API was established. Requires a local integration, coalescing, retention of edits arriving during builds, and correct handling of external resources/dependencies. Notification loss remains a separate boundary. |
| **Stable compilation snapshot** | Compile from immutable captured inputs; identify results by the snapshot. Apply later edits to the next snapshot. | Established build-system principle, but a shadow project introduces path mapping, generated/configuration files, dependency scope and storage/cleanup ownership. Likely larger than the other two options here. |
| **Serialize writes with compilation** | All writers acquire the same exclusion mechanism as the build. | Conceptually simple only when every writer participates. A post-edit hook is too late; long builds can conflict with the five-second wait and normal-tool workflow. Not provided by a build-only lock. |
| **Cancel/debounce superseded builds** | Reduce opportunities for obsolete work and overlapping writes, as editor systems commonly do. | Exposure reduction alone is insufficient. Cancellation after partial compilation must not leave a reusable inconsistent artifact/manifest. Needs separate cancellation/publication correctness evidence. |
| **Selective use of whole-application force** | Regenerate output when a trustworthy invalidation signal requires it. | Existing primitive and tested stable-source recovery, but broad recomputation. Still requires a reliable trigger; the rejected timing rule does not supply one. |
| **Qualified editor assistance without automatic repair** | Keep useful tools and explicitly limit freshness claims. | Smallest adapter policy and already our direction, but it does not meet a stronger automatic-convergence contract by itself. |

Rereading manifests, restarting without invalidation, adding watchers, simply
touching source files, or extending the grace period do not establish the missing
input/output association. A before/after hash scan is not an immutable snapshot.
Editing binary manifests or checkpoints from Lua would also move ownership of
private compiler state into the bridge; avoid treating that as a free simplification.

## Existing conventions to borrow

- **Correct cache identity:** a reusable result must be identified by the inputs
  actually used to produce it. Source identity and isolation are established
  [build-system principles](https://bazel.build/basics/hermeticity). This is a
  reference principle, not a recommendation to install Bazel for Tips.
- **Dependency-based invalidation:** Mix already propagates source changes to
  compile-time dependents. Reuse that mechanism rather than introducing a second
  dependency graph in the adapter.
- **Dirty work remains pending until serviced:** when a newer change arrives
  during compilation, completion of earlier work must not clear it. Coalesce
  repeated notifications while preserving the remaining obligation.
- **Qualified results during asynchronous work:** useful editor assistance can
  coexist with pending analysis; completed progress is not a proof of input identity.

Mix's documented [compiler task](https://mix.hexdocs.pm/Mix.Tasks.Compile.Elixir.html)
supports full force and opt-in module recompilation callbacks. It does not
establish a generic adapter command that force-invalidates arbitrary source paths.
Adding callbacks to application modules would impose integration complexity on
the application; it is not a drop-in repair for this compiler defect.

Fable rejected a compiler patch on the assumption that it would modify the shared
Homebrew toolchain. That is not the only deployment option: a private pinned
toolchain could be selected for the server. Its packaging, upgrade and parity
costs must be measured; no such deployment was implemented or validated here.
The user's constraint against depending on upstream fixes still holds.

## Next investigation, rather than another timeout policy

Compare two minimal prototypes: preserving source identity at the compiler/Mix
boundary, and explicitly invalidating only the changed compiler inputs. Determine
their actual code and deployment footprint before choosing. A small scheduler
diff is not automatically less ownership than a somewhat larger direct fix.

Each candidate must pass equal-size overlap, delayed notifications, a second edit
during recovery, A→B→A, same/coarse timestamps, compile-time callers, creation and
deletion, and compilation failure followed by repair. Check external resources
and path dependencies before claiming support for them. Stable ordinary edits
must remain incremental; unchanged queries should not cause recompilation.

First principles favor restoring correct input identity. Occam favors whichever
candidate restores that property with the fewest owned mechanisms, rather than
the fewest lines in one file. Pareto favors keeping the working Neovim/MCP/hook
integration and confining changes to invalidation and compilation. This analysis
does not declare either unimplemented candidate the working solution.
