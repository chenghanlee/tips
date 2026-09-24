# Mix overlap: root cause and triage

Date: 2026-09-24. Tested toolchain: Elixir 1.20.4 / OTP 29.1.

**Root problem: the incremental compilation manifest can describe newer source
than the compiled artifact it accompanies.** A later incremental build can
therefore accept stale output as current. This occurs in plain Mix; Neovim and
the MCP adapter are not required to reproduce it.

[Evidence](mix-triage-evidence.json). [Earlier reproduction](INVERSION.md).
[New probe](mix_triage_probe.py). No integration runtime or application code was
changed during this analysis.

## What is demonstrated

Read-only inspection of both retained plain-Mix reproductions found:

| Artifact | Version represented |
|---|---|
| Source on disk | B |
| Manifest content digest | B, not A |
| Compiled BEAM documentation | A |

Their stored and actual mtimes differ across whole seconds. Equal size plus the
matching B digest causes the next incremental compilation to skip the source.
This strengthens the old source-supported hypothesis: the incorrect association
between digest and compiled output is now observed directly. The internal
callback execution order itself was not instrumented.

A new dependency-free fixture changed both documentation and executable behavior
from `:aa` to equal-length `:bb` while compilation was paused for 1.5 seconds.
A second module captured the target's answer in a module attribute at compile
time. After the overlapping compile and **two** later incremental compiles:

- Source said `:bb`; the manifest digest matched that source.
- The target function returned `:aa` in a new VM.
- Its compile-time caller also returned `:aa` in that VM.
- Both behavioral acceptance tests failed.

Then `unbuffer mix compile --force --warnings-as-errors`, without another edit,
compiled both files. Both functions returned `:bb`, and both tests passed.
Each observation used a new VM and the same `_build/dev` directory, ruling out
an old module merely remaining loaded in one long-lived process.

This extends the demonstrated impact beyond hover documentation and beyond the
edited file. It does not establish that every dependent operation, module or
diagnostic becomes stale.

## Ten why questions

1. **Why can the agent receive old information after saving?** The server may
   still use compiled artifacts representing an earlier source revision. That
   occurred even after perfect notification delivery in the earlier direct LSP
   probe.
2. **Why does another successful compile not repair it?** Incremental compilation
   decides the affected source does not require rebuilding. The old and new
   probes both recorded successful no-op follow-up compiles.
3. **Why does Mix consider the source unchanged?** Its manifest digest already
   matches B on disk, although the compiled module represents A. This is now
   confirmed by artifact inspection, not inferred only from hover output.
4. **Why can the digest and module represent different revisions?** Compilation
   and digest calculation read the mutable file at different times. The retained
   compiler source's `each_file` callback reads the disk content when filling an
   absent digest, after the file has compiled.
5. **Why does equal byte length matter?** A size change independently marks the
   source stale. Equal size bypasses that condition, leaving the mistaken digest
   comparison decisive. The earlier different-size control rebuilt successfully.
6. **Why doesn't a changed timestamp catch the mistake?** In the examined path,
   an mtime change leads to a content comparison; it does not always force
   compilation. The digest falsely says the content is already represented.
7. **Why can one agent trigger the race?** The writer and compiler are separate
   processes. Startup compilation or a build continuing beyond the five-second
   hook can overlap a later write. An overlapping project build is only a risk
   signal; the file must be consumed during the relevant compilation window.
8. **Why can't another save, retry, or readiness counter prove recovery?** These
   can request another build or observe its completion. They cannot make a
   mistaken incremental decision recompile the source. Even comparing the
   current disk hash with the manifest hash would pass in this reproduction.
9. **Why isn't this necessarily confined to one file or to documentation?**
   The new fixture demonstrates stale runtime behavior and a stale compile-time
   dependent. A per-file warning may identify the triggering source, but cannot
   claim the impact stops at that path.
10. **Why isn't one forced rebuild a complete automatic fix?** It repaired the
    stable-source fixture, but another write can race the recovery build too.
    The earlier ElixirLS clean-overlap test reproduced exactly that second race.
    Recovery needs a completion condition and bounded behavior under continued
    editing, rather than a permanent restriction or an endless rebuild loop.

The last questions return to the same invariant: a compiled artifact and its
freshness record must describe the same input revision. More watcher events or
more elaborate status wording cannot establish that invariant.

## Triage

| Dimension | Assessment |
|---|---|
| Confidence | High for the demonstrated artifact mismatch and stale behavior on this toolchain |
| Impact | Correctness: stale executable behavior and a compile-time dependent, as well as documentation |
| Frequency | Unknown in real workloads; deliberately widened race, no confirmed Tips cohort incident |
| Trigger | Write during compilation of relevant source; equal-size rewrite in the demonstrated case |
| Isolation | Plain Mix reproduces it; not specific to vv-mcp, Neovim, Codex or multiple agents |
| Recovery evidence | Stable-source force compile works in plain Mix; stable-source mixClean/rebuild worked in ElixirLS |
| Current adapter | Retains ordinary editor behavior and qualifications; does not repair this compiler invalidation defect |

The previous claim that a later content change can recover is supported by
Fable's isolated probe, but it is not a user workflow or an unconditional recovery
guarantee. The new compile-time caller also disproves a general claim that impact
is limited to the rewritten file.

Separate CLI build directories reduce shared-state contamination from an
ElixirLS race. They do not make plain Mix intrinsically immune to concurrent
source changes. Conversely, a stale ElixirLS build is not evidence that the
independent Tips test build is stale.

## Smallest next investigation

First principles: correct recovery must either bind artifacts to the source
bytes actually compiled or invalidate the affected build state and complete a
rebuild against stable inputs. Simply moving a separate hash read earlier would
still leave a read/write race unless that relationship is guaranteed.

Occam: evaluate the existing ElixirLS `mixClean` plus rebuild path before adding
a new compiler implementation. A shell force compile in ordinary `_build` does
not repair the running server's separate `.elixir_ls/build` state. The new force
probe establishes the recovery principle, not a working LSP recovery adapter.

Pareto: keep ordinary saves, normal incremental builds and the five-second hook.
Test the exceptional recovery boundary in an isolated fixture, including a
compile-time caller, an edit during recovery, continued edits, and an edit that
does not participate in compilation. Require eventual fresh behavior after edits
stop, bounded hook waits, no unrelated build cleanup and no permanent loss of
tools. Do not infer corruption merely from any `.exs` edit during any build.

Upstream changes remain outside the user's chosen scope. Any eventual patch or
recovery behavior stays local. The evidence currently supports investigating
bounded recovery; it does not establish an exact automatic trigger or prove
that a new detector is the smallest reliable implementation.

## Reproduction and verification

Run with a new output directory from the experiment worktree:

```sh
python3 agent/lsp/experiments/codex-elixirls-v2/mix_triage_probe.py --output tmp/elixirls-v2/mix-triage-replay
```

The retained run is `tmp/elixirls-v2/mix-triage-1/`. It contains A/B source,
before/after inspections, compile logs, failing/passing ExUnit output and a copy
of the stale build artifacts captured before force recovery. The fixture's
formatting check and final warnings-as-errors compilation passed. Credo is
unavailable in this dependency-free fixture (`task "credo" could not be found`).
No Tips application code changed, so its suite was not rerun for this analysis.

Compiler source examined: the retained v1.20.4
`tmp/elixirls-v2/mix_compiler_elixir.ex`, especially lines 449–452 (staleness),
567–576 (initial source record), and 1271–1300 (`each_file`). Its SHA-256 is in
the evidence JSON. GitHub source retrieval failed during this review; the local
copy from the original investigation was available. The official
[Mix compiler documentation](https://mix.hexdocs.pm/Mix.Tasks.Compile.Elixir.html)
confirms incremental source/dependency compilation and the existing `--force`
option. The race findings come from our artifacts and probes, not that page.
