# Installed Expert investigation — 2026-09-24

**Decision: keep this as an experiment. The installed Expert 0.1.10 route has not
passed the full Tips workflow.** Native Neovim and published vv-mcp are useful
reusable foundations. Reliable automatic compiler feedback is still unproven.

Priority: working > simple > performant > elegant. Each chain stops at an evidenced
cause or an explicit unknown. Repeating “why” must not turn a hypothesis into fact.
The previous ElixirLS/Sol findings are regression requirements, not proof about Expert.

## Evidence map

Paths below refer to the retained evidence, relative to this report:

- A = `evidence/pilot`
- B = `evidence/tips-validation`
- Source = the official [Expert v0.1.10 source](https://github.com/expert-lsp/expert/tree/v0.1.10),
  whose archive matches the Homebrew formula SHA256 recorded in `versions.json`.
  Third-party source is not vendored here. Installed runtime is namespaced
  `XPExpert`/`XPEngine`.
- Each run has `results.json`, MCP JSONL, Neovim LSP log, and copied runtime config.
  Some Tips runs also have archived `expert.log` and `project.log`.
- `evidence.json` summarizes timings, qualifications and original paths.
- [ARCHIVE.md](ARCHIVE.md) describes retained files, redactions and verification.

These probes record observations; exit code zero means the probe finished, not that
every semantic check passed. Inspect `matched`, validated flags and cleanup results.
Times are observed samples, not statistical latency estimates.

## 1. Empty success during startup

Evidence: A/baseline's first hover was empty before later returning the expected
ALPHA/BETA documentation. Clean Tips B/save-reindex needed about 47.5 seconds after
the first hover for documentation, then another 7 seconds for expected references.

1. **Why did an empty response look final?** The MCP result had no error and no items.
2. **Why were there no items?** Expert can return LSP `null` before its engine is ready.
3. **Why was the request accepted?** LSP initialization and project-engine startup
   are separate; initialization does not mean compilation or indexing is complete.
4. **Why did the adapter not distinguish them?** Navigation normalizes the response;
   its ordinary empty-result shape does not convey Expert's background state.
5. **Why is retrying every empty result inadequate?** A ready server can legitimately
   find no symbol; a failed engine can stay empty forever. Empty is not a readiness signal.
6. **Why does this affect the five-second design?** A response deadline limits how
   long an agent waits; it cannot establish that compilation has finished.

Source: `apps/expert/lib/expert.ex`, `check_engine_initialized` failure returns
`{:reply, nil, lsp}`. Published vv-mcp `lua/vv-mcp/lsp/navigation.lua` normalizes
navigation; `diagnostics.lua` reads Neovim's diagnostic cache.

**Simplest remedy:** retain Neovim's LSP client and consume standard `$/progress`,
server errors and client exit events. Report “starting/indexing”, “failed”, or
“feedback still pending” when known. Do not convert empty diagnostics into “latest
edit compiled cleanly.” A progress token ending also does not prove overall success.
Revision-correlated compiler completion is still an integration requirement, not an
implemented guarantee. First principles distinguish transport, engine, compiler and
index readiness; Occam rejects arbitrary startup sleeps; Pareto starts with explicit
pending/failure instead of a complicated readiness oracle.

**Inversion:** test a nonexistent symbol after readiness, cold startup, engine
failure and a build longer than five seconds. Cold and failed startup were observed;
the final five-second delivery hook is not implemented in this exploration.

## 2. Disk edits and repairs did not trigger compiler feedback

Evidence: A/baseline missed an external undefined-function error for 12.1 seconds;
`checktime` still missed it for 8.1 seconds. An actual editor save produced it in
1.5 seconds. External repair stayed stale. A/autosave and subsequent modes refreshed
docs and error/repair. In B/tips-editor-delete-reindex those took about 1.5–1.7 seconds.

1. **Why was feedback stale?** The relevant compilation was not triggered by the disk edit.
2. **Why did Neovim's watcher not trigger it?** `didChangeWatchedFiles` is a filesystem
   event, not an editor save; Expert handles the two differently.
3. **Why did reload not fix it?** Neovim reload sends close/open; that refreshes a
   document but is not `didSave`.
4. **Why does save matter?** Expert's didSave handler schedules project compilation;
   didOpen just opens its document and ensures the engine exists.
5. **Why can one agent still hit this?** The mismatch is between disk, buffer and
   server state. It needs neither a second agent nor another worktree.
6. **Why not require agents to open and save explicitly?** That exposes a mandatory
   synchronization protocol as optional agent behavior—the previous DX failure.

Source: `apps/expert/lib/expert/state.ex` didOpen, didChange and didSave handlers;
Neovim runtime `lua/vim/lsp.lua` reload and BufWritePost handlers. Traces show native
watched-file notifications did arrive, so adding another filesystem watcher is not
the root fix.

**Simplest remedy:** reuse the existing Neovim watcher; synchronize saved disk text
to an unmodified buffer and let Neovim send its native change/save events. The
experimental `sync.lua` does this without rewriting the file. Refuse to overwrite
unsaved buffer changes. This addresses an observed cause but the combined Tips
workflow still fails finding 7. Do not call the adapter production-ready.

First principles require equivalent editor events for equivalent saved changes.
Occam removes custom polling and agent rituals. Pareto tests unopened callees,
equal-length edits, atomic replacements, compiler errors and repairs first.

**Inversion:** those edit shapes passed with synchronization in fixtures. Test-file
side effects, HEEx, rapid changes during cold startup, and unsaved-buffer conflict
delivery remain unvalidated; current sync implementation only handles `.ex`/`.exs`.

## 3. Compilation succeeded but new references remained absent

Evidence: A/autosave refreshed docs/error/repair but did not find a newly created
caller within 20.5 seconds. B/editor-events, using actual buffer edits plus save,
found it in 5.1 seconds without a full reindex.

1. **Why could hover be current while references were stale?** They consume different
   server state: compiled/document information and the search index.
2. **Why did project compilation not refresh every reference?** Subsequent
   project-compiled events do not rebuild an already enabled search store.
3. **Why was the incremental update missing?** Reload/open/save did not take the
   didChange → document compilation → `file_compile_requested` path.
4. **Why does that event matter?** The indexing handler enqueues that URI for reindexing;
   ordinary filesystem create/change events fall through its no-op handler.
5. **Why did real buffer edits help?** Neovim emitted didChange; Expert ran the
   per-document indexing path. The fixture's new caller then became queryable.
6. **Why was it still around five seconds?** Build edit delay, URI reindex debounce
   and search-store flushing add latency. Source defaults include 1-second URI
   debounce and 2.5-second store flushing; timing attribution is an inference.

Source: `apps/engine/lib/engine/dispatch/handlers/indexing.ex`, `build/state.ex`,
`commands/reindex.ex`, and `search/store.ex`.

**Simplest remedy:** use native buffer changes and save for ordinary edits, then
measure compiler and reference freshness separately. Do not make full project
reindexing the normal edit path. First principles separate compilation from indexing;
Occam reuses the incremental path; Pareto focuses on changed files. No timer tuning
or server patch has been made. Five seconds cannot be a promise that references are fresh.

**Inversion:** create a previously absent caller and verify its exact path in actual
reference locations; preserve existing callers. Use a unique name so persisted
stale entries cannot fake success. Tiny-fixture success did not establish full Tips
reliability; see finding 7 and the final control results in `evidence.json`.

## 4. A deleted caller remained in reference results

Evidence: B/editor-events first indexed the new caller, then kept returning it for
20.3 seconds after deletion. Trace contains the correct LSP delete event, type `3`.

1. **Why did the deleted reference remain?** Its index entries were not cleared.
2. **Why did the watcher not clear them?** The event reached Expert but missed the
   indexing handler's deletion pattern.
3. **Why did it miss the pattern?** Expert forwards numeric `change.type`; the engine
   handler matches the atom `:deleted`.
4. **Why is numeric 3 correct?** LSP FileChangeType.Deleted is 3, and Expert's GenLSP
   dependency represents the field as the numeric enum.
5. **Why not send a string/atom from Neovim?** That would violate the protocol to
   compensate for an internal server representation mismatch.
6. **Why not filter nonexistent results in MCP?** That hides one symptom while the
   authoritative index still contains stale state. It does not repair the index.

Source: `apps/expert/lib/expert/state.ex:246`,
`apps/engine/lib/engine/dispatch/handlers/indexing.ex:15`, and installed GenLSP's
`protocol/structures/file_event.ex` / `enumerations/file_change_type.ex`.

**Simplest remedy at the owning layer:** normalize the LSP enum inside Expert and
exercise it through a protocol-level deletion test. That is an upstream-fix
recommendation; the installed binary and source remain unchanged here. For the
stock binary, its advertised Reindex command repaired a fixture deletion, but this
is only an experimental recovery candidate with concurrency/completion caveats.

First principles put enum translation at the protocol boundary. Occam prefers that
small server correction to client emulation of an index. Pareto keeps rare recovery
out of the ordinary edit path. **Inversion:** deletion counts only after creation
was confirmed; missing/error/empty responses do not pass. Older baseline deletion
results without a confirmed creation are explicitly not validated.

## 5. Full reindex after every edit failed under real workload

Evidence: A/save-reindex passed the tiny fixture. Clean Tips B/save-reindex accepted
one Reindex and rejected three overlapping requests with `Already Running`; error
formatting also raised String.Chars on the tuple. The newly created caller never
became visible within the probe. Its indexing progress ended before the full job
finished (about 2.3 seconds versus 6.9 seconds in that run).

1. **Why did later edits lose their intended recovery?** Their Reindex requests were rejected.
2. **Why were requests rejected?** Expert allows one full-index task and returns
   `{:error, "Already Running"}` while it exists.
3. **Why did the adapter overlap them?** It requested a full reindex for each batch
   without waiting for actual job completion or preserving a follow-up obligation.
4. **Why didn't the successful response prevent this?** It acknowledges starting
   the asynchronous task; it is not a completion barrier.
5. **Why couldn't a progress end substitute?** That token covers source indexing;
   store replacement and task cleanup can still be running.
6. **Why did it look fine in a fixture?** Small full reindexes completed between
   edits. The test did not exercise the real timing window.

Source: `apps/engine/lib/engine/commands/reindex.ex` `handle_call({:perform, ...})`
and `do_reindex`; `apps/expert/lib/expert/provider/handlers/commands.ex` `reindex_all`.

**Simplest remedy:** remove full reindexing from normal edits. Reuse incremental
document changes. If rare stock-server recovery is retained, borrow the standard
serialized/coalesced work-queue convention: one job running, remember changes that
arrive meanwhile, and run again only after a trustworthy completion signal. The
current public completion signal has not been validated sufficiently to implement
that reliably. A timer or request acknowledgement is not enough.

First principles distinguish acceptance from completion. Occam removes unnecessary
full jobs before adding scheduling machinery. Pareto reserves expensive recovery
for proven gaps. **Inversion:** rapid edits on Tips defeated the fixture-only fix.
Do not tune timeouts to hide the rejected requests.

## 6. Startup failed under the sandbox but looked like endless indexing

Evidence: A/tips-autosave failed while updating Expert's shared engine cache with
`not owner`. It never produced baseline hover. A controlled run with required
cache access started normally. This was an environment failure, not a measured
three-minute compilation. Progress still included “Engine is ready”/“Engine node
started” end messages after the failure.

1. **Why was the engine unavailable?** Its preparation step failed.
2. **Why did preparation fail?** The process could not remove/replace a cached beam
   in the installed server's normal macOS cache location.
3. **Why didn't per-session XDG directories isolate that?** Expert uses Erlang's
   platform user-cache path, which resolves under `~/Library/Caches` here.
4. **Why was ownership text misleading?** File ownership was correct; the restricted
   launch failed, and the otherwise comparable permitted launch succeeded.
5. **Why did the client keep looking merely unready?** Empty requests and progress
   endings were not interpreted alongside the actual startup error.

Source: `apps/expert/lib/expert/engine_node/builder.ex`, `apps/forge/lib/forge/path.ex`
and `priv/build_engine.exs`; startup error in the raw run trace.

**Simplest remedy:** use the stock cache convention with the narrow required launch
permissions, and surface preparation failures. Reuse process exit/error handling;
do not change HOME or invent a second cache manager. First principles require a
working executable environment; Occam fixes that environment; Pareto checks startup
before spending time on application probes. The initial failed run was stopped
and its observed owned processes were cleaned up.

**Inversion:** startup failure must produce a failed/unavailable state, not an
unbounded “indexing” state. Do not generalize an environment-specific failure into
an Expert performance claim.

## 7. Expert's engine exited in the combined Tips workflow

Evidence: B/tips-editor-delete-reindex passed doc edit, error and repair. After a
new caller was added, project compilation succeeded; at 17:32:42.892 the engine
application exited `shutdown`. References then failed with `noproc` for
`XPEngine.Module.Loader`; a later filesystem notification failed against
`XPEngine.Api.Proxy`. No Reindex had been requested before the engine exit.

1. **Why did references stop answering normally?** The request called a registered
   engine process that no longer existed.
2. **Why was the process gone?** The engine application had shut down, taking its
   services with it. This is more than slow indexing.
3. **Why did the engine application shut down?** Its supervisor exhausted its
   restart allowance. OTP tracing in B/tips-supervisor-trace exposes repeated normal
   exits of `XPEngine.ModuleStore`, replacement child PIDs, restart timestamps and
   the configured limit of 3 restarts in 5 seconds; the fourth closely spaced exit
   is followed by engine shutdown.
4. **Why did that worker repeatedly exit?** `Engine.ModuleStore.handle_info` rebuilds
   completion candidates on each `project_compiled` event, then returns
   `{:stop, :normal, state}` intentionally.
5. **Why was a normal exit counted as a restart?** `use GenServer` supplies a
   permanent child specification. The application uses it unchanged, so every
   normal exit restarts the worker and re-registers its compile listener.
6. **Why did rapid edits expose it?** Successful successive compilations produced
   enough worker stop/restart cycles inside the supervisor's five-second window.
   Isolated edits stayed below the limit; more responsive compilation made this
   lifecycle mismatch easier to hit.
7. **Why did earlier logs miss the cause?** They showed the engine shutdown and
   downstream `noproc` errors but no initiating abnormal exception—the child exits
   were normal. Standard OTP supervisor tracing supplied the missing evidence.
8. **Why not restart the engine, raise the limit, or slow edits?** Those mask a worker
   lifecycle error, discard in-flight state, or delay normal work. Expected compile
   events should not consume a supervisor's fault-recovery budget.

Source: `apps/engine/lib/engine/module_store.ex:20` and `application.ex:20`; identical
behavior was checked in the installed engine source. The trace records ModuleStore
PIDs `<0.5430.0>` → `<0.5571.0>` → `<0.5687.0>` → `<0.5806.0>`, all exiting normally.
Before the last exit the restart timestamps include -576460736, -576460738 and
-576460739. The full trace is B/tips-supervisor-trace/`engine-supervisor.trace`.
See the official [Supervisor semantics](https://hexdocs.pm/elixir/Supervisor.html)
and [OTP sys diagnostics](https://www.erlang.org/doc/apps/stdlib/sys.html).

**Simplest owning-layer fix to propose upstream:** if completion candidates must
refresh after each compile, keep the listener alive with `{:noreply, state}` after
the rebuild. If the intended contract is genuinely one-shot, use an appropriate
non-permanent restart policy—but that would stop later compile refreshes, so it is
not a behavior-preserving default fix. Verify repeated compilation and completion
freshness together. No installed source, runtime restart policy or binary was patched.
The proposed source correction is not yet tested.

First principles align process lifetime with its ongoing event-listener role. Occam
repairs that small mismatch instead of adding restarts or throttling. Pareto prioritizes
reliable ordinary compilation over more adapter features. **Inversion:** two normal
runs reproduced the combined failure, then the traced run identified its mechanism.
Native unique-file creation passed in 4.8 seconds; isolated automatic disk creation
passed in 5.4 seconds, with healthy queries six seconds later. These controls show
that creation alone is insufficient to reproduce the failure. Deletion and Reindex
happened after shutdown, excluding the delete recovery command as its cause.

## Carry forward from the actual ElixirLS/Sol dogfood

The earlier three real Sol sessions remain the evidence for hook-specific failures:
deduplication consuming undelivered pending messages, uncertainty without recovery,
and empty diagnostics without freshness. The Expert exploration does not have the
five-second hook and has not retested or fixed those delivery defects.

Once the server behavior is reliable, the minimal shared adapter should synchronize
normal disk edits, wait at most five seconds on one absolute deadline, and return
compiler feedback or an explicit pending/failure result. Standard LSP document
versions are useful but do not by themselves certify all asynchronous project jobs.
Keep delivery bookkeeping separate from collection; test it through actual agents
before claiming parity between Codex and Claude Code.
