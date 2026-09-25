# Root analysis of the four dogfood findings

Date: 2026-09-24. This is analysis of the preserved three-agent run. No runtime
adapter or application behavior was changed for this analysis.

Reviewed the agent event streams, all 68 hook audit entries, startup results,
Neovim LSP traces, the Python/Lua adapter, the installed vv-mcp Lua implementation,
Neovim 0.12.5 buffer lifecycle code and installed ElixirLS 0.31.1 notification
handlers. The archived Lua files used by all three agents exactly match the
current files reviewed. Selected records with original line numbers are preserved
in [dogfood-root-cause-evidence.json](dogfood-root-cause-evidence.json).

| Finding | Root problem | Confidence |
|---|---|---|
| Health stayed stale | External reload updates document text but does not complete the save/build lifecycle | Confirmed by trace and both implementations |
| Five-second silence | Observing a result updates delivery history; deduplication also ignores edit generation | Confirmed by startup, audits and code |
| Permanent uncertainty | A broad overlap detector sets a session-wide flag with no recovery transition | Confirmed; stale provider compiler output itself was not demonstrated |
| Media timeout and empty diagnostics | Missing build leaves a wait unsatisfiable; timing lacks complete budget accounting; diagnostics expose cache contents without freshness state | Missing build/cache contract confirmed; exact timeout overrun phase unknown |

## 1. Health diagnostics stayed stale after repair

### Evidence

The last ElixirLS build finished with an error at 16:29:58. At 16:30:04 the trace
records `didClose`, then `didOpen` containing the repaired `query_database()` call,
then the changed-file notification. There is no `didSave` or later ElixirLS build
in that session. These are health LSP log lines 494 and 507–510.

Health hook audit line 12, after the repair, records:

```text
generation=1, completed=0, building=false, diagnostic_count=3
status=pending, elapsed=4.986s, output={}
```

All four post-repair diagnostic queries retained the old error/warning set.
Ordinary Mix compilation and the application tests passed. Those checks ran
outside the language server's own build and did not refresh its diagnostic cache.

### Eight whys

1. **Why did the error remain after the repair?** ElixirLS never compiled the
   repaired revision, so its previous compiler diagnostics remained applicable
   to its old build state.
2. **Why did the file-change notification not compile it?** ElixirLS's handler
   skipped a changed document that was already open and marked clean.
3. **Why was the document open and clean?** Neovim reloaded it with close/open;
   ElixirLS constructs a newly opened source file with `dirty?: false`.
4. **Why did reload use close/open?** That is Neovim's standard `on_reload`
   implementation. Our `checktime` path uses it; it is not an ordinary buffer edit.
5. **Why was there no save notification afterward?** The adapter invoked
   `checktime` only. Neovim's normal `didSave` handler is attached to `BufWritePost`,
   which this external reload did not invoke.
6. **Why did the adapter rely on that path?** It assumed refreshing saved text plus
   a watcher notification was equivalent to the edit/save lifecycle expected by
   ElixirLS. The implementations show that assumption is false for an open,
   clean document.
7. **Why would waiting longer not solve it?** No build was running for generation
   1. Waiting cannot supply the missing build trigger.
8. **Why would another diagnostics query not solve it?** That query reads the
   cached diagnostics; it does not send the missing save/build trigger either.

**Root:** text synchronization was implemented without the complete saved-document
lifecycle. One agent per worktree does not remove this condition. Another changed,
unopened file in the same batch can trigger a project build and mask the defect,
which makes relying on watcher behavior especially fragile.

Code anchors: [collector](neovim_sync.lua), lines 39–47; Neovim runtime
`lua/vim/lsp.lua`, lines 939–969; ElixirLS `server.ex`, lines 655–659, 750–769 and
788–801; `source_file.ex`, line 11. The exact local runtime sources are under the
vendor and Mix install paths recorded in the raw evidence.

## 2. Edits waited five seconds but delivered no pending message

### Evidence

The health startup result privately recorded pending at generation 0. Health
audit line 12 records generation 1 pending after 4.986 seconds with an empty
message/output. The first delivered pending receipt arrived at Stop, audit line
20. The model's preceding final response explicitly said it saw no receipt.

There is a second manifestation independent of startup: media audit line 9
delivered pending for generation 2 in 4.978 seconds; line 13 waited 4.993 seconds
for generation 3 and delivered nothing. Its text matched generation 2.

### Seven whys

1. **Why did a completed hook return `{}` after waiting?** The Lua collector
   returned an empty message, so Python correctly emitted no additional context.
2. **Why was the message empty despite pending state?** The deduplication key
   matched `last_output`.
3. **Why did health already have that key when the agent had seen nothing?** The
   launcher's warmup called the same collector, which updated `last_output` before
   the launcher wrote its result to a private startup file.
4. **Why could a private read change public delivery history?** `collect()` combines
   state observation, rendering and notification bookkeeping. It updates the
   output key even when invoked without a hook event.
5. **Why was media's new edit treated as a duplicate too?** The key is only
   `status .. ':' .. message`; it contains no source generation or edit identity.
6. **Why did an unchanged subsequent tool not repair the omission?** The collector
   had already advanced `last_post_generation`, and its separate unchanged-tool
   guard suppresses pending messages. The result was consumed internally without
   being delivered externally.
7. **Why did Stop finally produce a message?** Stop explicitly bypasses the text
   deduplication check. That explains the later delivery, but does not satisfy the
   missing synchronous feedback after the edit.

**Root:** the adapter confuses “collected” with “reported to the agent,” and
“same words” with “same edit.” Neither a larger time budget nor another read
changes those identities. The five-second wait itself worked in these cases.

Code anchors: [launcher](neovim_launcher.py), lines 49–52;
[collector](neovim_sync.lua), lines 129–150; hook (`neovim_hook.py`, removed in Solution 2; see a388e4d), lines 46–64.

## 3. Cold-start edits left feedback permanently uncertain

### Evidence

The provider's first edit changed only `test/tips/provider_config_test.exs` while
the 73.215-second cold build was running. Audit line 9 changed uncertainty from
false to true. Later, line 12 had `generation=completed=2`, and lines 18–25 had
`generation=completed=3`, with `building=false` and `uncertain=true`.

The test file is outside Tips' configured `elixirc_paths` (`lib` and
`test/support` in test). The detector does not use that distinction. This trace
establishes a broad conservative warning, not a demonstrated stale provider
module. Separate earlier experiments did demonstrate a real overlapping-edit
staleness bug in Mix/ElixirLS.

### Eight whys

1. **Why did uncertainty survive later completed builds?** `M.uncertain` stayed
   true and has priority over the normal diagnostics/completed branches.
2. **Why did it become true?** Any selected file hash changing while `M.building`
   is true sets the flag.
3. **Why did this ordinary first edit qualify?** The initial build was still
   running when the agent updated its acceptance test.
4. **Why does a test edit count like a compiler-input overlap?** The scan groups
   Git-listed `.ex`, `.exs` and `.heex` files together. It does not record which
   changed paths affect which build inputs, nor whether a cold build has read them.
5. **Why didn't later successful telemetry clear the flag?** Its handler updates
   `completed` and the build result, but has no uncertainty reset. Earlier
   equal-size overlap tests showed that a successful incremental no-op can still
   leave old compiled code, so unconditional clearing would be unsafe.
6. **Why did a valid precaution become permanent?** The state records a single
   session-wide boolean, without an affected-revision scope or a verified recovery
   transition. The only ordinary reset is creating a fresh module/session.
7. **Why don't passing CLI compilation and tests clear it?** Those are different
   compiler invocations/build state. The adapter has no evidence that they repair
   ElixirLS's in-memory state or its separate build directory.
8. **Why is merely removing the warning not a solution?** It would discard a real
   known correctness hazard without establishing that recovery occurred. The
   missing element is a justified recovery boundary, not a shorter warning.

**Root:** a conservative hazard detector has no recovery contract and is broader
than the event it is intended to detect. Cold startup increases the chance of
entering that state; the permanent state is our adapter policy, not proof that
ElixirLS remains busy or broken.

There is also a downstream code consequence: uncertainty is checked before
nonempty diagnostic lines, so the flag can suppress useful error details as well
as clean/completed messages. That consequence follows from branch order; the
provider audit itself had zero diagnostics and did not demonstrate hidden errors.

Code anchors: [collector](neovim_sync.lua), lines 8–19, 34–37, 56–66 and 109–118;
[previous compiler overlap evidence](INVERSION.md). No recovery implementation was
tested in this analysis.

## 4. Media's final check timed out, then diagnostics were empty

### Evidence

Media's last ElixirLS build ended at 16:30:10, before its production edit at
16:30:41. The target reload at LSP log lines 514–518 has the same close/open/
watcher pattern as health. A later test-file edit repeats the pattern at lines
525–533. No save or subsequent build appears.

Before Stop, audit line 18 had `generation=3`, `completed=1`, `building=false`.
Stop at line 19 returned the Python alarm's unavailable message after 5.003
seconds. Later MCP diagnostics succeeded with empty objects, and audit line 20
still had that generation mismatch. Neovim therefore was not persistently dead.
The next Stop was quiet because the bounded final check had been consumed.

### Ten whys, separating the timeout and freshness branches

1. **Why did Stop report unavailable?** The hook's own five-second `SIGALRM`
   raised its custom timeout before Python obtained the collector result. This
   was not the host's six-second cleanup timeout or a Mix compiler timeout.
2. **Why could the collector not return a completed result?** Its readiness
   condition required `completed == generation`, but those values were 1 and 3.
3. **Why did the generations remain different?** The later saved edits did not
   trigger another ElixirLS build. The trace shows the same missing-save path as
   finding 1. There was no slow build for Stop to finish waiting on.
4. **Why did the planned pending reply lose to the Python deadline?** The precise
   overrun phase is not recorded. A confirmed budgeting weakness makes this
   possible: Python computes a relative wait before RPC dispatch; Lua then scans,
   waits for that full duration, scans again and formats diagnostics. A fixed
   100 ms reserve covers all dispatch, scans, callbacks and reply work only if
   that work happens to fit.
5. **Why can't the log tell us whether scanning, scheduling or reply handling
   caused this particular overrun?** The audit records total time and the final
   exception only, without dispatch/entry/scan/wait/return timestamps. The custom
   error string names Neovim, but is raised by our generic deadline handler.
6. **Why didn't successful diagnostics afterward resolve freshness?** The
   published diagnostics operation reads `vim.diagnostic.get()`, the cache already
   held by Neovim. It neither compiles nor waits for a revision-covering build.
7. **Why didn't that response disclose the pending generation?** The readiness
   wrapper explicitly covers hover, definition and references, excluding
   diagnostics. The diagnostics output has no build-generation metadata.
8. **Why can the hook say pending while MCP returns an empty result?** They use
   separate views: the hook tracks saved/build generations; the MCP operation
   returns cached messages. There is no common freshness contract joining them.
9. **Why wouldn't a larger timeout establish freshness?** It would not start the
   missing build, and a cache read still would not prove a completed compilation.
10. **Why wouldn't repeated empty reads establish it?** They can repeatedly read
    the same old or not-yet-populated cache. Repetition adds no evidence that the
    latest source was compiled.

**Root:** the compiler never caught up because of finding 1, while the diagnostics
API omitted that fact. Separately, the nested time budgets do not account for all
work under one deadline. The exact cause of the observed timeout remains
unresolved; it must not be presented as a proven Neovim hang or parallel-hook bug.

The media agent ran several shell checks concurrently earlier, but the transcript
shows those completed before subsequent diagnostics, status checks and the final
response. Their presence alone does not establish that parallel hooks caused
the Stop timeout.

Stop consumes `stop_pending` before waiting. The following quiet Stop therefore
means “the one final attempt was used,” not “the compiler became current.” This
avoids a continuation loop but is another reason the final uncertainty must remain
visible to the agent.

Code anchors: hook (`neovim_hook.py`, removed in Solution 2; see a388e4d), lines 29–55; [collector](neovim_sync.lua),
lines 83–106; [readiness wrapper](neovim_feedback.lua), lines 30–36; vendor
`vv-mcp/lsp/diagnostics.lua`, lines 37–44 and 79–83.

## What the evidence implies

The common issue is that several different facts are treated as interchangeable:
buffer synchronized / build triggered; result observed / result delivered;
historical overlap / current recoverable state; cache empty / current build clean.
Those equivalences are false in the recorded workflows.

First principles require keeping those facts separate. Occam's razor points to
the existing save/build and hook-delivery boundaries, rather than new agents,
manual rituals or more waiting. The highest-value follow-up is to reproduce the
missing save and delivery omissions deterministically, then investigate recovery
and complete deadline accounting. Exact timeout attribution requires phase timing
in a focused replay; the preserved totals cannot reconstruct it after the fact.
