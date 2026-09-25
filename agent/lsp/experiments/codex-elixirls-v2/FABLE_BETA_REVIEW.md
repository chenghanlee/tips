# Fable beta-readiness review: Neovim + ElixirLS stack for Tips agents

2026-09-25. Inputs: `SAVEPOINT.md`, `OPERATIONAL_FIXES.md`, `LONG_BUILDS.md`, `INSTALL.md`,
`operational-fixes.patch`, `operational-fixes-evidence.json`, installed bundle
`agent/lsp/vendor/elixirls-neovim-v2` (doctor passes, manifest `80f2…3f16`), raw
`tmp/elixirls-v2/operational-fixes/`, Codex's `ownership-baseline/results.json`, and my probe
`probes/startup/` (isolated Tips copy; no runtime, bundle, worktree or config touched).

## 1. Verdict

**Not beta-ready yet, but close. Four small blockers, none in the compiler or synchronization
engine.** The four operational failures from my release review are fixed in the runtime I read
and in the evidence I checked (`operational_acceptance` 7/7, cold MCP init 0.42–0.44 s in my
own runs, no survivors after shutdown in four sessions). The remaining blockers are all about
*how a beta agent reaches this stack and what happens on the first minute and on the second
session*. All are days-of-work small.

Blockers before an internal beta:

| # | Blocker | Evidence | Smallest fix |
|---|---|---|---|
| B1 | No shipped entry point; the current generator ships the wrong one | `task_worktree.py:282-300` writes Expert `elixir-lsp` MCP + `mix-compile` plugin for Codex; the Neovim stack exists only as `codex exec -c …` overrides with `--dangerously-bypass-hook-trust` (`neovim_dogfood.py:133-160`) | Opt-in generator branch (§3) |
| B2 | No ownership guard on a worktree | Codex's `ownership-baseline`: two ready sessions share one `.elixir_ls/build` | `flock` on `<worktree>/.elixir_ls/session.lock` held by the launcher; second `serve` exits with a clear message |
| B3 | 74 s cold start on every fresh task worktree | `probes/startup/results.json`: cold 74.0 s; warm 3.5 s; **seeded 3.4 s** after a 0.78 s copy of `_build/test` → `.elixir_ls/build/test` | Seed in worktree setup after the worktree's own deps compile |
| B4 | Release-cohort agents ran their own `mix`/Credo on the private toolchain | `release_dogfood.py:76` prepends `toolchain/bin` to the agent's PATH | Never put the bundle toolchain on the agent's PATH; re-run the workload gate without it |

Everything else I found is a should-fix or a documented limit (§4, §5).

## 2. Measured baseline (Tips, macOS arm64, v2 bundle, `+S 4:4`)

Session start, isolated copy of the provider worktree, MCP over stdio, ready = `neovim_sync.ready()`:

| Case | MCP init | Ready | Builds | Compile |
|---|---|---|---|---|
| Cold (`.elixir_ls` absent) | 0.44 s | 74.0 s | 2 | 71.8 s + 0.37 s |
| Warm (existing `.elixir_ls`) | 0.43 s | 3.5 s | 1 | 1.64 s |
| Seeded (`_build/test` copied, 0.78 s) | 0.42 s | 3.4 s | 1 | 1.69 s |
| Warm after seed | 0.50 s | 3.5 s | 1 | 1.74 s |

Shutdown 1.05–1.14 s on EOF, no survivors, in all four. Per-edit costs from earlier evidence
still hold: warm `.ex` edit hook 1.4–2.9 s, `.exs` edit hook ~1.5 s for a Mix no-op build,
unchanged-tool hook 0.06–0.09 s, doctor/verify 0.40 s.

Interpretation: after B3 the first useful navigation moves from ~75 s to ~4 s. The remaining
per-edit cost is dominated by ElixirLS's build pipeline (~1 s reload + compile + index) and the
`.exs` no-op builds, not by the hook, the scanner or verification. Do not optimize those.

## 3. Entry point: essential for beta versus full team rollout

Codex's mid-review note is right: today the generator, the launcher and the harness disagree
on backend, hooks, PATH and state. What a beta agent needs is *one* static configuration per
worktree that a human can also read.

Essential for the internal beta (opt-in, no global switch):
- `task_worktree.py --lsp neovim` (or a role/team config key) writes for a Codex worktree:
  `.codex/config.toml` with `[mcp_servers.elixir_neovim]` → `bundle.py serve --workspace
  <worktree> --state <worktree>/.elixir_ls/session` (gitignored by ElixirLS already), the
  `lsp` tool enabled, no `elixir-lsp` Expert server, **`mix-compile` plugin disabled**; and
  `.codex/hooks.json` with `PostToolUse` (`^(apply_patch|Bash)$`) and `Stop` calling
  `bundle.py hook` with the same two paths, timeout 6 s. One compile feedback path only.
- Hook trust: the user's `~/.codex/hooks.json` already runs user-level hooks on this machine.
  Decide once whether beta hooks live there (static paths need `bundle.py` to derive workspace
  from the event's `cwd` and state from the workspace; a 10-line change) or in the worktree's
  `.codex/hooks.json` with a documented one-time trust step. Do not ship
  `--dangerously-bypass-hook-trust`.
- Agent shell PATH stays Homebrew. The bundle toolchain is for Neovim/ElixirLS only (B4).
- `ERL_FLAGS` for ElixirLS set by `prepare()`, not inherited from the agent's env.
- Ownership lock (B2) and seed step (B3) run inside the same generator/launcher path so the
  shipped entry point is what gets tested (`REQUEST.md` item 4).

Deferred to full rollout: `team.py` role wiring and pane env, Claude-side parity, upgrade and
rollback drill, per-team resource caps, retiring the Expert generator branch.

## 4. Should-fix before beta (small, not blocking)

- **S1 ElixirLS death has no recovery.** `neovim_init.lua` starts the client once; Neovim does
  not restart a crashed server. Hooks then report `unavailable` for the rest of the session while
  the MCP server looks healthy. Code-supported, not reproduced. Fix: `on_exit` → one delayed
  `vim.lsp.enable`/restart with backoff, or launcher exits when no `elixirls` client exists for
  10 s so Codex surfaces it. Test: `kill` the beam, expect either recovery within 15 s or an
  MCP failure the agent sees.
- **S2 Debug logging in production.** `neovim_init.lua:7` sets `vim.lsp.set_log_level('debug')`;
  every `didSave` (full file text) and every RPC is written to `lsp.log`, and `_G.v2_events`
  keeps every notification for the session (`neovim_init.lua:19-26`). Fine for a 5-minute
  harness run, pointless growth for a multi-hour agent. Beta: `info` level, keep `v2_events`
  behind an env flag, keep `--audit` off.
- **S3 `.exs` saves still trigger a full ElixirLS build cycle** (~1.5 s hook wait, Mix no-op).
  Deferred unless the workload gate shows test-heavy tasks dominated by it; `config/*.exs`
  must keep triggering builds, so any skip must be path-scoped.
- **S4 Second cold build.** Cold sessions run a 0.37 s follow-up build right after the 72 s
  build (2 builds, `probes/startup/results.json`). Harmless; note in logs, do not fix.

## 5. Delivery and validation claims: what the evidence supports

- Supported: pending → later-tool or Stop delivery of a late error, with the agent quoting the
  receipt before repair (`late-agents/{stop,tool}`); Stop is bounded and not repeated; repair
  feedback ~0.5 s.
- Not supported, do not claim: that an unprompted agent notices late errors. Both late-agent
  prompts instruct receipt quoting and forbid MCP; the release cohort instructed diagnostics
  polling. The claim to make in the operational contract is exactly `LONG_BUILDS.md`'s: "an
  error reaches the agent at its next eligible tool or at Stop; if Stop still reports pending,
  validation is unfinished".
- Not supported by the release cohort: "final checks passed with the normal toolchain" (B4).
- Ownership: Codex's baseline shows duplicate ownership is *accepted*, not that it corrupts.
  Treat it as unsupported and lock it; do not spend time proving corruption.

## 6. Proposed beta gates (pass/fail, shipped entry point only)

1. **Entry point**: `task_worktree.py --lsp neovim` on a fresh worktree yields a Codex session
   whose `hooks/list` shows exactly the two bundle hooks, whose MCP list shows only
   `elixir_neovim`, and whose `which mix` inside the agent shell is Homebrew.
2. **Start**: MCP `initialize` ≤ 2 s; ready ≤ 10 s on a seeded worktree; ≤ 120 s unseeded.
3. **Ownership**: a second `serve` on the same worktree exits non-zero within 1 s with a
   message naming the owner; a hook from a foreign state dir reports the identity mismatch.
4. **Warm loop**: 20 ordinary `.ex` edits through the hook: p50 ≤ 2.5 s, max ≤ 5 s, one build
   per edit except documented late duplicates (report the count).
5. **Late error**: a seeded 8 s compile error is delivered by the next tool or Stop; repair
   clears it; Stop is not repeated.
6. **Failure boundaries**: Neovim SIGKILL → launcher exits, hook says unavailable, no managed
   replacement; ElixirLS SIGKILL → S1 behaviour; stalled Neovim (SIGSTOP) → EOF/SIGTERM
   shutdown ≤ 3 s, no survivors.
7. **Concurrency**: three seeded worktrees started within 5 s of each other, each ready ≤ 20 s,
   no cross-worktree files touched, no survivors after all three exit.
8. **Workload**: two or three real Tips tasks with the *normal* prompt (no receipt or polling
   instructions) and one seeded error each; record hook latency distribution, build count, and
   whether the error surfaced before the agent declared the task done. Report, do not threshold.

## 7. Documented limits for the beta contract (not blockers)

Unobserved A→B→A histories; late duplicate incremental builds; `current` means "last observed
ElixirLS build completed", not consumed bytes; `.exs` edits cost a no-op build; only
`neovim_sync.lua`'s extension list is reconciled (`.po` and other resources are not); macOS
arm64 with exact Python 3.14.3/Rust 1.97.0 pins (relax to major.minor when convenient); no
upgrade/rollback drill; three-worktree concurrency observed once, larger teams unmeasured;
SIGKILL after 2 s at shutdown can leave a partial `.elixir_ls/build` that the next session's
forced startup build repairs.

## 8. Replies to Codex's two notes

- **Ownership/flock**: agree. Take the lock in the launcher before starting Neovim, hold it for
  the process lifetime, write `owner.json` beside it, and make the hook's identity check the
  only reader. `flock(2)` on APFS is fine; no lease timer needed because the OS releases it on
  death.
- **Entry point**: §3 splits essential from rollout. The single most important sentence for the
  generator: *one backend, one compile-feedback hook, Homebrew `mix` in the agent shell, private
  toolchain only inside Neovim.*

## Probes

`probes/startup/startup_probe.py`, `results.json`, `*.stderr.log` — four sequential sessions on
the isolated copy `/private/tmp/tips-fable-release-review-9xb93ihp/probes/mixtime/tips`, each
through `bundle.py serve` stdio and pynvim readiness polling. No leftovers after any session.

## Addendum: ElixirLS-only death (Codex `runtime-baseline`)

Codex reproduced S1: killing only ElixirLS leaves Neovim and the MCP server alive; the hook says
`unavailable` in 0.185 s, but the hover error still carries `retryable=true, retryAfterMs=1000`
with no restart path. Agreed classification: explicit unavailability works; the retry guidance is
wrong. I withdraw the "restart with backoff" option; supervising ElixirLS restarts is not worth
inventing for a beta.

Smallest correction, all in the adapter:
- `neovim_init.lua`: an `on_exit` handler records `exited = {code, signal, time}`.
- `neovim_sync.status()`: split `unavailable` into `starting` (no client yet) and `exited`
  (client gone). `exited` message: "ElixirLS exited (code N); restart this session"; hook and
  MCP set `retryable=false` and omit `retryAfterMs`. `starting` keeps `retryable=true`.
- Launcher: when the owned Neovim reports no `elixirls` client after the exit is observed, exit
  non-zero so Codex marks the MCP server failed and the operator restarts the session. This is
  the "tested session reconnect": a fresh `serve` on the same worktree, which the ownership lock
  must allow once the old launcher is gone.

Gate 6 becomes: ElixirLS SIGKILL → hook `exited` in < 1 s, hover `retryable=false`, launcher
exits within 15 s, a new `serve` on the same worktree reaches ready (warm ≤ 10 s), no survivors.

Fixture-only numbers Codex reported (unchanged hooks 0.12–0.17 s, snapshots 5–6 ms) are
consistent with my Tips-copy numbers (0.06–0.09 s hooks); neither needs optimization.

## Disposition on Codex's challenges and BETA_PLAN.md (2026-09-25)

**B3, cold start.** Accepted as reframed. My probe measured `ready()` (last observed
compilation complete), not first useful navigation. Earlier cohort evidence shows document
symbols, hover and definition can answer during the cold build while references time out, so
"75 s to first useful navigation" is not established. Reclassify B3 from blocker to: the entry
point performs explicit cold preparation, ideally overlapping worktree provisioning so the
agent's first prompt is not the clock start; seeding stays an experiment behind Codex's gates
(stale source / same second, preserved time, env and path identity, external resource and
deletion, interrupted copy). One addition to step 3: measure first successful hover, definition
and references separately from `ready()`, from the agent's first prompt.

**B4, private PATH.** Accepted as a coverage gap, not a proven defect. The Mix patch only reads
`--force-path`; an empty list preserves stock behaviour, so cohort results stand as application
evidence. Keep it as a step 1 gate condition (record `which mix` in the agent shell equals
Homebrew), not a blocker.

**Addendum, ElixirLS exit.** Accepted: no launcher RPC polling. Propagate through the existing
child-exit observation: Neovim's LSP `on_exit` records `exited`, answers in-flight requests with
`exited`/`retryable=false`, then quits itself after a short grace so the launcher's existing
`nvim.poll()` path exits the MCP server. Gates accept either an `exited` reply or MCP closure,
whichever the race yields; a hook that loses the race reports `unavailable`, whose text already
says the source is not proven error-free. Recovery is a full session relaunch, tested once.

**BETA_PLAN.md.** Confirmed as the plan. Three small gaps to close in the text:
1. Step 1 must name where the hooks live and how they are trusted (user `~/.codex/hooks.json`
   with paths derived from the event `cwd`, or worktree `.codex/hooks.json` with a documented
   one-time trust step). "Standard Codex hooks" is not yet a decision.
2. Step 2 gate list: add "hook invoked with a foreign state directory reports the identity
   mismatch" (already implemented, should be gated).
3. Step 5: record per agent which `mix` its shell used, and keep controlled fault-delivery
   sessions separate from the three natural workloads, as written.

No remaining pushback. Blockers stand as B1 (entry point) and B2 (ownership); B3 and B4 become
gate conditions; S1 is resolved by the addendum design.

## Probe caveats (Codex, accepted)

- `probes/startup/results.json` `shutdown_s` includes an unconditional `sleep(1)` before the
  measurement ends; actual teardown was 0.05–0.14 s. Treat all numbers there as readiness
  measurements only, not lifecycle evidence.
- `leftovers()` in that probe matches command lines containing the review folder path only. An
  orphaned ElixirLS beam's argv contains bundle paths, not the workspace path, so it would be
  missed. Codex's owned-PID tracking in the seven host gates is the authoritative cleanup
  evidence; use owned-tree tracking for the beta gates.
