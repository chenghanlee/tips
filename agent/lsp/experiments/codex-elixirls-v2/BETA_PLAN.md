# Neovim + ElixirLS: internal beta plan

Reviewed plan and revalidation, 2026-09-25. Base: `fd4e2da8b013996ffb8527f30784f423fb9fc61a`.
Runtime changes and beta admission are not yet complete. This plan retains Neovim,
ElixirLS, vv-mcp, incremental compilation and the existing small patches.

## Outcome and boundaries

An agent assigned a Tips worktree can edit normally, use hover/definition/references,
receive bounded compiler feedback, and distinguish pending, failed and unavailable
validation. One agent owns one worktree's language-server session. No manual
save/index/reload steps are required for ordinary edits.

Start with an opt-in, pinned macOS arm64 Codex beta. Claude parity remains the next
client gate; do not claim it from Codex evidence. Keep the five-second default hook
budget and the 250 ms bounded build collection window. A timeout means unfinished
validation, while compilation continues. Normal compilation, tests, formatting and
Credo remain required; this service does not execute tests or enable Dialyzer.

## Why the remaining work is operational

1. Why are successful probes insufficient for beta? They supply configuration and
   lifecycle discipline that the ordinary launch path does not yet supply.
2. Why does that matter? The normal worktree helper still selects Expert; the test
   harness selects this bundle, private state and feedback hooks instead.
3. Why not copy the harness instructions to each agent? That makes each launch
   responsible for choosing matching paths, hooks and versions correctly.
4. Why can a mistaken launch affect reliability? Two accepted sessions can compile
   against the same worktree build directory, and duplicated hooks can add work.
5. Why do we need more than a root argument? A path selects a project; it does not
   establish exclusive ownership of its state or the lifetime of its compiler.
6. Why can failure still confuse an agent? Starting and permanently stopped servers
   currently receive the same retry guidance, despite having different recovery paths.
7. Why not solve that with another supervisor, cache or bridge? Existing OS locks,
   Neovim lifecycle callbacks and client configuration cover the missing boundaries.
8. Why prioritize these over compiler micro-optimization? The current measurements
   show functional warm feedback and retries; another architectural layer would add
   failure modes before proving that it removes the dominant user cost.

Further whys reach the same root: move essential launch/recovery assumptions out of
the test harness and into the supported entry point, then measure that exact path.

## Current evidence

- Bundle doctor passes: 1,312 tracked runtime files, Elixir 1.20.4 / OTP 29.1,
  Python 3.14.3. This run took 0.398 s.
- All seven existing operational checks pass again on the host. Cold fixture MCP
  registration took 0.376 s. Stalled Neovim EOF/SIGTERM cleanup took 2.11/2.08 s,
  with no observed survivors. Scan-failure recovery delivered the compiler error
  in 0.175 s without another edit.
- A sandbox run denied process inspection and process-group signaling. It is a
  failed environment check, not a passing lifecycle test. Beta must test the host
  process launch path actually used by MCP and hooks.
- A new ownership probe accepted two live, ready sessions with distinct state
  directories against the same fixture root and `.elixir_ls/build`. This demonstrates
  missing ownership enforcement, not demonstrated artifact corruption.
- A new ElixirLS-only crash probe returned explicit unavailability in 0.185 s.
  Neovim/MCP remained alive; hover incorrectly advised retrying in one second even
  though the stack has no server restart. No observed descendants survived cleanup.
- Twelve unchanged fixture hooks took 0.123–0.173 s. Twenty fixture scans took
  5.3–6.4 ms. These are not Tips timings and do not justify rewriting the scanner.
- Fable measured cold Tips MCP registration at 0.44 s but last-observed compilation
  readiness at 74 s. Warm restart readiness was 3.5 s. One cold sample and one warm
  sample do not establish a latency distribution or time to useful source navigation.

Raw current evidence: `tmp/elixirls-v2/beta-review/`. Previous corrected operational
and actual agent feedback evidence remains in [OPERATIONAL_FIXES.md](OPERATIONAL_FIXES.md).

## Sequence

### 1. Make beta launch reproducible

Implementation correction (2026-09-25): Codex 0.156.1 deliberately loads hooks
from the main repository for linked worktrees. The generated worktree hook file
below was therefore not discovered by the actual client. The implemented beta
uses `bundle.py codex` (or the team helper's matching `codex-args`) to attach the
same hooks as session configuration. Their command resolves the session cwd and
has one stable definition across worktrees. Normal `/hooks` review still applies;
the user reviewed both beta-r7 hooks. No shared-main or home hook file was changed.
The original planned file layout below is retained as planning history.

Add an opt-in `--lsp neovim` selection to the existing worktree configuration path,
using standard Codex MCP/hooks configuration. Generated worktree `.codex/config.toml`
selects the bundle; `.codex/hooks.json` contains `PostToolUse` for
`^(apply_patch|Bash)$` and `Stop`. Both use the same canonical workspace and private
state under that workspace's `.elixir_ls/session`. The operator reviews and trusts
these project-local hooks through `/hooks`; verify the project layer is trusted
and neither hook is skipped. Leave home-directory hooks untouched.
Explicitly choose the bundle, canonical workspace, private session state, required
tools and hook timeout. Verify the existing host prerequisites and fetched project
dependencies before starting an agent. Report preparation failures clearly.

Inspect inherited configuration: avoid leaving Expert or a second compiler-feedback
hook active accidentally. Preserve formatting/tests/Credo and normal client
permissions. Do not copy test-only trust-bypass flags into the beta launcher.
Keep the bundle's private compiler confined to Neovim/ElixirLS. Record the normal
project compiler path and version inside each agent shell. The earlier private-PATH
cohort remains application evidence, but does not prove host-toolchain compatibility;
adding the patched Mix directory to PATH does not itself pass targeted invalidations
to ordinary Mix commands. Set and record ElixirLS's own scheduler limit (start with
the tested `+S 4:4`) without modifying the agent's application environment.

Gate: an actual Codex session launched through this path registers the intended
MCP tool and receives hook feedback, with no harness-only environment injection.
No global/client-main configuration switch is needed for this opt-in beta.

### 2. Enforce ownership and truthful failure guidance

Use nonblocking OS advisory locks for the canonical worktree and session state,
acquired before preparing shared session files or starting children. Retain locks
through owned-child cleanup. A second launch must fail promptly and leave the first
session untouched. Do not use a PID-file existence check as mutual exclusion.

Use Neovim's existing LSP exit callback to distinguish startup from a server that
has exited. Keep useful qualified results where available. A dead server must not
promise that polling will restore it: record the exit and return `retryable=false`
with a reconnect instruction, without `retryAfterMs`. After a short bounded grace,
Neovim exits and the launcher's existing child monitor closes the session. No new
launcher RPC polling. A racing request may receive the exited error or MCP closure;
either is acceptable, provided a later hook reports unavailable with a recovery
instruction. Test a complete session reconnect before documenting it as the recovery
action. Automatic restart supervision is deferred.

Gates: same root/different states; same state/different roots; simultaneous launch;
symlink aliases; graceful exit/relaunch; forced termination; peer crash; unrelated
worktree survives; a hook with a foreign state directory reports a mismatch.
In particular, test launcher SIGKILL and immediate relaunch: automatic lock release
alone does not prove that all old compiler children have exited. A lock is
cooperative: it does not stop an unrelated editor or
stock server that ignores it. Document the one-owner beta contract.

### 3. Remove experiment overhead; measure before further optimization

Make full protocol debug logging and the unbounded `_G.v2_events` payload history
opt-in for probes. Retain actionable errors and a small amount of bounded session
status; do not make compiler-state observation depend on verbose recording.
The current unconditional event history is a code-supported long-session memory
growth risk; no memory exhaustion has been demonstrated.

Measure cold preparation, MCP registration, first successful hover, definition and
references individually, compiler readiness, warm edits, unchanged hooks and shutdown
separately. Also measure from the agent's first prompt: pre-provisioning work and
latency visible to the agent are different costs. Record build counts
alongside timings. Repeat on the same Tips revision/environment before and after a
change; report sample counts, median, tail and maximum rather than a single best run.

Start compilation early and preserve each worktree's existing cache. Fable's
cache-seeding experiment is promising but copying builds is not yet an approved
optimization: validate environment, paths, source freshness and interrupted copies
before treating another build tree as reusable. Do not weaken content hashing or
pending/in-flight retention to remove a few milliseconds or duplicate builds.

### 4. Replay correctness and recovery at the shipped boundary

Use the installed bundle/configuration, not direct Lua calls as the acceptance path.
Fault injection may use RPC; the agent-facing observation must use MCP/hooks.
Retain the already discriminating tests: same-second/preserved-time changes,
opened and unopened files, atomic replacement, deletion/recreation, failed first
notification, edits during compilation, failed compilation then repair, queued work
after old completion, fixture-noise exclusion, and another worktree staying correct.

Test 8-second and longer builds through later tool feedback and Stop, without
requesting diagnostic polling. Check deadline behavior, repeated Stop, stuck RPC,
ElixirLS exit, Neovim exit, launcher termination, reconnect and zero observed owned
survivors. Deliberate exclusions remain explicit: missed A→B→A histories, inputs
outside the observed scope, and independent writers that ignore session ownership.

### 5. Admit a small agent cohort and retain rollback

Run three isolated Tips workloads through the final beta entry point: API rename
with references, a small schema/validation change, and a compiler-error repair or
focused integration regression. Give agents ordinary task instructions and the tool
contract; do not tell them to poll diagnostics or inspect hook receipts/logs.
Record actual use of navigation and automatic feedback, task checks, latency,
compiler path/version inside each agent, and cleanup. Controlled fault-delivery
tests remain separate from natural agent uptake.

Before admission, install into a new immutable destination, verify its manifest,
restart a session on it, then restart on the saved bundle. No in-place mutation of
a live installation. A beta pass requires every correctness/lifecycle gate and all
three application workloads to pass or have an explicitly accepted existing
application failure. Tooling failures cannot be waived as application failures.

## Reuse and deferrals

Reuse `vim.lsp`, Neovim diagnostics/watchers/lifecycle, the existing bridge and
ElixirLS queue; Python's [fcntl.flock](https://docs.python.org/3/library/fcntl.html#fcntl.flock)
provides nonblocking process exclusion. Standard
[Codex hooks](https://learn.chatgpt.com/docs/hooks) supply bounded synchronous
feedback and `additionalContext`. No new watcher, queue service, protocol or graph
is proposed.

Provisional performance targets for this host: MCP initialization within 2 s; warm
Tips readiness within 10 s; 20 warm `.ex` edit hooks with median at most 2.5 s and
maximum within the five-second budget; stalled-peer cleanup within 3 s. An unchanged
tool must not spend another five seconds waiting. Cold prepared dependencies may
still require an initial ElixirLS build: measure it separately and use 120 s as the
initial investigation threshold for this Tips revision. Three warm worktrees started
together should each reach readiness within 20 s. These are candidate gate targets,
not established service guarantees; preserve failures and diagnose them rather than
silently moving thresholds or weakening freshness.

Defer cross-platform packaging, broader team rollout, automated crash restart,
cache transplantation, test-suite automation, Dialyzer and a new performance SLA.
This beta is an empirical limited rollout, not a claimed production failure rate.

## Fable review disposition

Fable reviewed the plan and accepted the challenges below in its appended
disposition. Full review: [FABLE_BETA_REVIEW.md](FABLE_BETA_REVIEW.md).
Current structured observations: [beta-plan-evidence.json](beta-plan-evidence.json).

- Entry point and ownership are the two confirmed launch blockers.
- The dead-server retry guidance also gets a small correction and a reconnect gate.
- Cold preparation is a gate condition, not a mandate to copy an unvalidated cache.
  `ready()` timings do not measure first useful navigation.
- Normal host-toolchain workload verification is an evidence gap, not a demonstrated
  defect in earlier application results.
- Full event recording becomes opt-in; scanner rewrites, `.exs` build suppression,
  duplicate-build elimination and automatic server restart are deferred.
- Fable's startup probe includes a one-second sleep in its shutdown timing and
  filters process command lines rather than retaining all owned PIDs. Its readiness
  measurements remain useful; use Codex's owned-tree probes for cleanup evidence.
- Retain a simple bundle switch-back smoke test before beta, even though a full
  upgrade/rollback matrix can wait. Preserving a tag alone does not exercise rollback.

This is consensus on the implementation/gate plan, not approval of an implemented
beta release. The runtime, installed bundle and active client configuration were
not changed during this planning and revalidation pass.
