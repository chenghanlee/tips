# Save, readiness, delivery and deadline fixes

Date: 2026-09-24. Branch: `experiment/elixirls-codex-v2`.

Implements the four concrete fixes selected after Fable's adversarial review.
This is still an experiment. No active Codex/Claude configuration is changed.
The three fresh Tips workload results are recorded in `DOGFOOD_V2.md`.

## Changes

1. **Complete the save lifecycle.** After `checktime` reloads an unmodified open
   buffer, verify its contents against the disk snapshot and send the attached
   ElixirLS client `textDocument/didSave`, including text as advertised by the
   server. Native watchers still cover unopened files and create/delete events.
   No source rewrite, editor command from the agent, or unrelated `BufWritePost`
   callback is needed. Unsaved buffer conflicts still refuse reload.
2. **One readiness observation.** Hooks and MCP use `neovim_sync.status()`.
   Hover, definition and references check before and after their underlying request. Pending,
   failed, conflicting or uncertain queries cannot return an ordinary empty
   semantic answer. Diagnostics remain available with qualified freshness.
   vv-mcp 0.3.4 strips unknown success fields, so pending/failed/uncertain
   diagnostics use its existing structured error envelope and include the cache
   under `error.diagnostics`. Its MCP `isError` remains false for Lua errors;
   callers must read the explicit `error` object. No Rust bridge patch was added.
3. **Observe privately, deliver by revision.** Startup/private collection never
   changes delivery history. Public deduplication includes the source generation
   and feedback text. Two edits can both deliver the same pending/uncertain text.
   Stop is consumed after successful collection; a failed scan or expired queued
   RPC does not consume its pending feedback.
4. **Budget the whole collection.** Python reserves 300 ms for RPC/teardown/output;
   Lua subtracts its initial scan from the remaining wait. The redundant final
   scan is removed. Local Unix expiry rejects queued calls whose caller timed
   out; a separate local monotonic duration caps the wait without assuming Python
   and Lua share a monotonic epoch. The hard Python alarm leaves 100 ms for a
   failure response. Audit timestamps distinguish attach, RPC and teardown.

`current` is an editor-style observation of the last build, not an authoritative
compiler revision or a substitute for compilation/tests. Marking `building`
before scanning a received start message prevents the demonstrated injected
late-start ordering from certifying a newly discovered edit.

## Boundaries tested before the model rerun

Raw evidence: `tmp/elixirls-v2/four-fixes/` in the experiment worktree.
`before/` preserves the old adapter; `source-hashes.json` identifies the tested
implementation. Failed attempts remain beside the passing runs.

| Test | Evidence | Result |
|---|---|---|
| Queried, open, clean file edited after the watcher settles | `red-save/results.json` | Before fix: pending for 5.041 s, expected compiler error absent |
| Same scenario, then repair | `green-3/results.json` | Error 0.329 s; cleared 0.325 s; two actual didSave notifications |
| Private warmup; first public edit; two pending generations | `green-3/results.json` | Public feedback delivered; unchanged repeat suppressed |
| Pending/uncertain diagnostics over actual MCP transport | `green-3/results.json` | Explicit error/status with diagnostic cache retained |
| Injected scan failure at Stop | `green-3/results.json` | Pending Stop preserved |
| Injected delayed build-start observation | `green-3/results.json` | No false ready state; isolated logic test, not proof of live message ordering |
| Injected 160 ms scan within a 200 ms allowance | `green-3/results.json` | Collection 200.463 ms, rather than scan + full wait |
| Three-second compile; fast repair | `budget-1/results.json` | 3.317 s / 0.322 s |
| Eight/fifteen-second compilation and bounded Stop | `budget-1/results.json` | Full waits 4.770–4.775 s; no repeat Stop loop |
| Stalled Neovim RPC | `budget-1/results.json` | Explicit deadline failure at 4.945 s |
| Two simultaneous edit hooks | `cold-1/results.json` | 4.785 / 4.786 s; one pending delivery for the same revision |
| Stop RPC queued while Neovim paused | `cold-1/results.json` | 4.950 s deadline; expired request preserved Stop; retry delivered completion |
| Edit during a real cold compile | `cold-1/results.json` | Uncertain promptly; later actual compiler error visible through hook and MCP |
| Equal-length overlapping writes | `hooks-1/results.json` | Explicit uncertainty retained; not certified clean |
| Automatic sync, atomic replacement, other worktree unaffected, Claude-shaped failed-tool hook | `hooks-1/results.json` | Passed |
| New/deleted files, unsaved conflict, unavailable server, EOF/hard-kill cleanup | `inversion-1/results.json` | Passed; all observed owned descendants exited |

The fixture runs exercise actual Neovim, vv-mcp, ElixirLS and Mix except where
explicitly labeled injected. Synthetic initial fixture compilation and ExUnit
tests run through `prepare()`. Credo is unavailable in that dependency-free
fixture. Timing observations include Python process startup; these are measured
results, not a hard real-time scheduling guarantee.

Reproduce each suite with a new output directory:

```sh
python3 agent/lsp/experiments/codex-elixirls-v2/neovim_revision_probe.py --vendor tmp/elixirls-v2/neovim-vendor --output tmp/revision-replay
python3 agent/lsp/experiments/codex-elixirls-v2/neovim_hook_budget_probe.py --vendor tmp/elixirls-v2/neovim-vendor --output tmp/budget-replay
python3 agent/lsp/experiments/codex-elixirls-v2/neovim_cold_probe.py --vendor tmp/elixirls-v2/neovim-vendor --output tmp/cold-replay
python3 agent/lsp/experiments/codex-elixirls-v2/neovim_hook_probe.py --vendor tmp/elixirls-v2/neovim-vendor --output tmp/hooks-replay
python3 agent/lsp/experiments/codex-elixirls-v2/neovim_hook_inversion_probe.py --vendor tmp/elixirls-v2/neovim-vendor --output tmp/inversion-replay
```

## Deliberately unresolved

The conservative session uncertainty latch remains. The previous Mix equal-size
overlap reproduction prevents treating a queued rebuild as universal freshness
proof. Automatic clean/rebuild recovery and input scoping were deferred; they
are not quietly implemented here. Unlike before, uncertainty no longer hides
compiler error details or suppresses feedback for subsequent edit generations.
This can still prevent semantic navigation for the remainder of a session.

No compiler completion barrier, upstream Mix fix, watcher fixture exclusion,
durable acknowledgement protocol, Claude model session, or new root isolation
policy is claimed. The native vv-mcp router can create another managed worktree
session when explicitly directed to that root. This pass verifies separate
worktrees and normal assigned-root use, not cross-root request rejection.
