# Independent review request for Fable

Operator request: independently review and verify the root problems behind four
findings from three actual Codex Sol agents dogfooding the Neovim/ElixirLS adapter
on the current Tips application. The operator also explicitly requests that you
know how to reply to Codex when finished.

You are Fable in Herdr pane `wH:p1`. The requesting Codex agent is in `wH:p9`.
This is a request to investigate and critique, not to implement fixes. Please
conduct the review yourself and preserve the existing experiments and unrelated
Claude integration edits. Your current working directory may be the main Tips
checkout; the reviewed implementation is in the separate experiment worktree.

## Review approach

Read the raw evidence and relevant code, form your own explanation, then compare
it with Codex's hypotheses below and in `ROOT_CAUSES.md`. Do not treat agreement
with the report as the objective. Try to disprove the explanations, detect missing
causal steps, and distinguish observations from source-supported inference.

For each finding:

1. Give an independent verdict: confirmed, partly confirmed, contradicted or
   insufficient evidence.
2. Explain the actual mechanism, with file/line and trace/audit references.
3. Ask 5–15 whys to reach the root; stop when two further whys do not change it.
4. Identify any overclaim in Codex's account, especially about the timeout.
5. State the smallest additional observation or controlled test that would settle
   remaining uncertainty. Separate causes from symptoms and design tradeoffs.

Read applicable `AGENTS.md`/README and relevant skills before reviewing Elixir
code. Their paths in the main checkout are `.agents/skills/elixir/SKILL.md` and
`.agents/skills/otp/SKILL.md`. The experiment checkout's older AGENTS LSP tool names
describe Expert; the tested adapter below actually uses Neovim + ElixirLS.
Avoid treating an unavailable LSP tool or an empty result as proof of absence.

## Locations

Main checkout (unrelated dirty Claude integration; preserve it):
`/Users/chenghanlee/Software_Projects/tiny_big_agents/tips`

Experiment worktree, branch `experiment/elixirls-codex-v2`:
`/private/tmp/tips-elixirls-codex-v2`

All paths in the next two lists are relative to that experiment worktree.

Implementation and reports, under `agent/lsp/experiments/codex-elixirls-v2/`:

- `neovim_sync.lua`: file hashing/reload, observed build state, diagnostics,
  deduplication, overlap flag and bounded Stop state.
- `neovim_hook.py`: Python five-second deadline, pynvim RPC and host output.
- `neovim_launcher.py`: eager Neovim startup, private warmup, MCP lifetime.
- `neovim_feedback.lua`: MCP readiness wrapper and separate phase tracking.
- `neovim_init.lua`: standard ElixirLS settings, handlers and adapter setup.
- `neovim_dogfood.py`: exact three-agent prompts, configuration, launch and cleanup.
- `neovim_hook_probe.py`, `neovim_hook_budget_probe.py`,
  `neovim_hook_inversion_probe.py`: earlier local acceptance cases and scope.
- `DOGFOOD.md`, `dogfood-evidence.json`: workload results and retained failures.
- `ROOT_CAUSES.md`, `dogfood-root-cause-evidence.json`: Codex's analysis and
  selected evidence with original line numbers. These are hypotheses to verify.
- `INVERSION.md`, `inversion-evidence.json`, `mix_overlap_probe.py`: prior
  evidence motivating the conservative overlap flag; includes a plain Mix case.
- `neovim-versions.json`, `hook-budget-evidence.json`: pinned versions and older
  fixture results. Those passing fixture results do not override dogfood failures.

Raw run evidence, under `tmp/elixirls-v2/sol-dogfood-run/`:

- One subdirectory each: `provider/`, `media/`, `health/`.
- `events.jsonl`: complete model/tool transcript. Read completed items; each
  started/completed pair refers to the same tool call, not two calls.
- `hook-audit.jsonl`: event, tool, collector state, output JSON and elapsed time.
  These records do not include per-phase RPC timing or wall-clock timestamps.
- `environment.startup.json`: private launcher warmup result, not agent context.
- `codex-environment/state/nvim/lsp.log`: raw LSP notifications, requests,
  diagnostic publication and build telemetry with local timestamps.
- `codex-environment/config/nvim/lua/neovim_sync.lua` and
  `neovim_feedback.lua`: exact runtime copies. Codex verified them byte-for-byte
  against the reviewed scripts; independently check if needed.
- `command.json`, `prompt.md`, `environment.json`: actual invocation and isolated
  experiment configuration. Local PostgreSQL defaults are nonproduction values.
- `process-results.json`: observed owned processes and no survivors before cleanup.
- `application.patch`: each completed application change, relative to its HEAD.
- `baseline.json`, `baseline-*.log`: original compilation and targeted tests.
- `final.md`: last response only; Stop continuation can replace a preceding task
  summary. Use `events.jsonl` to see all responses.
- Media/health `full-suite.log` and `verification.json`: parent full-suite checks.
  Provider's full-suite run is recorded in its agent event stream.

The earlier `tmp/elixirls-v2/sol-dogfood/` is a failed CLI-argument launch, before
any model session. Do not mistake it for the successful three-agent cohort.

## Exact installed code supporting the investigation

Vendor root:
`/private/tmp/tips-elixirls-codex-v2/tmp/elixirls-v2/neovim-vendor`

- Neovim 0.12.5: `nvim-macos-arm64/share/nvim/runtime/lua/vim/lsp.lua`.
  Relevant buffer save/reload handlers are around lines 893–969.
- Neovim watcher: `nvim-macos-arm64/share/nvim/runtime/lua/vim/lsp/_watchfiles.lua`.
- Published vv-mcp Lua package: `beixiyo-vv-mcp.nvim-d7ce20b/lua/vv-mcp/lsp/`.
  Inspect `context.lua`, `diagnostics.lua`, `operations.lua`, `init.lua`.
- vv-utils helper: `beixiyo-vv-utils.nvim-13e73d5/lua/vv-utils/lsp/fix.lua`.
- Published bridge binary: `vv-mcp` 0.3.4; Python packages in `python/`
  include pynvim 0.6.0, msgpack 1.2.2, greenlet 3.5.6.

Installed ElixirLS 0.31.1 source root:
`/Users/chenghanlee/Library/Caches/mix/installs/ex-1.20.4-erl-17.1/j0Y-iTjQ3PounKzK7QFzFw/deps/elixir_ls`

- `apps/language_server/lib/language_server/server.ex`: `didOpen` around 620–660;
  `didChange` around 693–747; `didSave` around 750–770; watched-file build predicate
  around 773–855.
- `apps/language_server/lib/language_server/source_file.ex`: default dirty flag,
  around line 11.
- Launcher: `/opt/homebrew/bin/elixir-ls` resolves into
  `/opt/homebrew/Cellar/elixir-ls/0.31.1/libexec/`.

The toolchain was Elixir 1.20.4 / OTP 29.1, Codex CLI 0.156.1. ElixirLS's observed
project MIX_ENV was `test`; each worktree had its own `.elixir_ls/build`.
Dialyzer and dependency fetching were disabled in the Neovim settings.

## Workload context and controls

Three actual `codex exec -m gpt-6-sol` sessions ran concurrently on application
commit `81501387eb77b220c95693f58076f7f8255da1b0`, with separate dependency copies,
builds, test databases, ports and server lifetimes. Normal `apply_patch` and shell
tools were used; agents were told not to manually save/refresh/index/restart.

- Provider: `/private/tmp/tips-lsp-sol-provider`, branch
  `experiment/elixirls-sol-provider`; renamed `ProviderConfig.mode/0` to
  `provider_mode/0` across real callers/tests/docs. 508 full-suite tests passed.
- Media: `/private/tmp/tips-lsp-sol-media`, branch
  `experiment/elixirls-sol-media`; shared bigint validation and expanded boundary
  coverage. 509 full-suite tests passed.
- Health: `/private/tmp/tips-lsp-sol-health`, branch
  `experiment/elixirls-sol-health`; repaired a deliberately incomplete private
  rename. Parent changed the definition from `probe/0` to `query_database/0`
  before launch, leaving the caller broken. Agent repaired that caller. This was
  seeded, not a naturally occurring defect in main. 508 full-suite tests passed.

All full suites excluded four browser/real-provider tests. Formatting,
warnings-as-errors compilation and strict Credo passed. Baselines passed before
the injected health defect. Application correctness does not establish adapter
correctness. No active Codex/Claude configuration was rolled out.

## Codex's current explanations — challenge these

### 1. Health diagnostics stayed stale after successful repair

Observed: health LSP log 494 is the final failed build. Lines 507–510 at 16:30:04
show close/open with repaired text followed by the watched-file event. No save or
new build follows. Audit line 12: generation 1, completed 0, building false,
three diagnostics, pending after 4.986 seconds. Post-repair diagnostic queries
retain the old `probe/0` error, while ordinary Mix compilation/tests pass.

Hypothesis, considered confirmed by Codex: external reload completes text
synchronization but omits the saved-document build trigger. Neovim reload uses
close/open, creating a clean ElixirLS document; ElixirLS's changed-file handler
skips a build for an open clean file. Our hook does not invoke a save notification.
Another unopened changed file in a batch can mask the failure by triggering a
project build. Check the protocol and implementation, not just the prose report.

### 2. Some edits waited five seconds without a pending message

Observed: private health startup records pending. Audit line 12 returns `{}`
after 4.986 seconds on its first edit; line 20 finally delivers pending through
Stop. Separately, media audit line 9 delivers pending for generation 2; line 13
suppresses it for generation 3 after 4.993 seconds.

Hypothesis, considered confirmed: `collect()` updates `last_output` during private
startup as if a result were delivered. Its key is status plus text, without edit
generation. The new edit is marked processed even when its output is suppressed;
unchanged-tool suppression then preserves silence. Stop bypasses text dedup.

### 3. Cold-start edits left feedback permanently uncertain

Observed: provider's first edit changes only `test/tips/provider_config_test.exs`
during the 73.215-second cold build; audit line 9 sets uncertain. Later audit
lines 18–25 have generation=completed=3, building=false, uncertain=true.

Hypothesis, considered confirmed as a policy/state limitation: any selected file
hash change during any build latches a session-wide boolean, with no verified
recovery transition or affected-input scope. The initial changed test is outside
Tips' configured `elixirc_paths`. This run does NOT prove that provider compiled
code was stale. Earlier separate equal-size overlapping-edit tests did prove
staleness can survive a successful incremental no-op, even in plain Mix. Clearing
the flag on any successful telemetry would therefore need justification.

Also examine whether checking uncertainty before diagnostic lines hides useful
errors. That is a code-derived concern; this provider run had no diagnostics.

### 4. Media Stop timed out; empty diagnostics did not establish freshness

Observed: final ElixirLS build ends at 16:30:10, before the production edit at
16:30:41. Media LSP lines 514–518 and 525–533 show reload/watcher sequences with no
later save/build. Audit line 18 has generation 3/completed 1/building false.
Line 19 records unavailable at 5.003 seconds; later diagnostics return empty,
line 20 still has the mismatch, and the next Stop is quiet.

Confirmed portions according to Codex: the hook's own SIGALRM fired, rather than
the six-second host guard; the current revision had no completed LSP build;
MCP diagnostics read `vim.diagnostic.get()` without current-generation status;
the readiness wrapper excludes diagnostics. A quiet subsequent Stop means its
one final attempt was consumed, not that the compiler became current.

UNRESOLVED: which phase caused the actual RPC overrun. Code has a budgeting risk:
remaining duration is computed before RPC; Lua scans, waits that full duration,
scans again and formats/responds, with only a fixed 100 ms reserve. This does not
prove that scans caused the observed timeout. Audit lacks phase timestamps.
Parallel shell checks occurred earlier but their tool completions precede later
diagnostics/status/final response. Do not assume parallel hooks caused this Stop
timeout or call it a persistent Neovim hang; later calls succeeded.

## Useful falsification questions

- Did a save/build occur somewhere the extraction missed? Is the relevant open
  document state actually what the handler predicate assumes?
- Does the first edit's silence follow from startup bookkeeping, generation-less
  deduplication, a race, or some combination? Can code and raw records distinguish?
- Does “uncertain” establish any concrete stale result in this workload, or only
  an intentionally conservative approximation? What verified recovery already
  exists in the prior experiments, and what remains unproven?
- Is the timeout actually attributable from the available timestamps? What can
  be established about entry into the collector and consumption of Stop state?
- Does the proposed diagnosis overfit event order while overlooking conditions
  such as other changed files in the same watcher batch or temporary test files?

Use read-only investigation first. If a small controlled experiment is needed,
use a new disposable directory and preserve original traces/application edits.
Do not run another model cohort, change shared runtime code, restart somebody
else's server, or merge/push changes as part of this review.

## How to reply to Codex when done

Post your complete independent review as your normal final response in your own
pane `wH:p1`, organized by the four findings, with references and uncertainty.
Codex will read it through `herdr agent read`. Then notify Codex's pane using
the Herdr skill's agent messaging surface, without waiting for Codex to finish:

```sh
herdr agent prompt wH:p9 "Fable's independent review of the four Neovim/ElixirLS findings is complete in pane wH:p1. Read my final review with herdr agent read wH:p1 --source recent-unwrapped --lines 200."
```

Because tool calls must precede your final response, you may send that notification
immediately before posting the full final review. Codex should wait for your pane
to settle before reading. Do not use `--wait` on the notification; that would risk
a mutual wait. If Herdr rejects the notification because the target is blocked,
leave the review in your pane and report the failed notification rather than
answering/bypassing its approval UI. The requesting Codex agent already verified
its own current pane as `wH:p9`; do not target the UI-focused pane implicitly.
