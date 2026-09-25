# Beta completion team

Objective: implement beta-ready elixir_neovim_lsp for Tips. Priority: correctness,
working behavior, simplicity, performance, reliability, resilience, in that order.
User authorized six Opus 5.5 max agents through Herdr, with Astra as orchestrator.
Judge the combined architecture, not only local patches. Each new module, state
field and workaround must earn its maintenance cost. Reuse, combine or remove
overlapping responsibilities and obsolete mechanisms where that improves the
whole system. At integration milestones, review clear ownership of synchronization,
document/build readiness, feedback and lifecycle; propose concrete simplifications
with preserved behavior and regression evidence. Do not turn this into a broad
rewrite, a giant module or another framework. Astra owns the whole-system decision.
Explicitly assess unnecessary abstractions/components, duplicated or derivable
state, contradictory flags, pass-through wrappers, hidden ordering dependencies,
read-side mutations and generic machinery for a single case. Findings need concrete
cost or failure evidence, not stylistic labels. Prefer removal/consolidation while
preserving distinct correctness facts and required ownership boundaries. Measure
simplicity by fewer concepts and change points, not merely fewer lines.
Prefer established standards, conventions and mechanisms from mature LSP/AST/editor
adapters and libraries over new local protocols or frameworks. For each remaining
custom mechanism, name the existing facility considered and the concrete gap that
requires our code. Reuse Neovim/LSP request and diagnostic semantics, Mix dependency
scope/locks, OS locking/timeouts and the bundled MessagePack codec where applicable.
A small implementation of a standard protocol is distinct from inventing a protocol,
but it still needs an ownership/maintenance justification against supported clients.
Do not copy a convention blindly when it fails the measured requirement. Keep the
smallest compatibility patch at the responsible boundary; prefer deleting redundant
state. This is a design acceptance criterion, not a new broad research phase or a
reason to reopen settled evidence without a specific counterexample.

Upstream patches ARE custom mechanisms and owned maintenance, not reuse for free.
The user explicitly prefers avoiding patches because of regression, rebase and
upstream-consistency obligations. A small diff or combining patches into fewer files
does not eliminate that burden. Prefer supported configuration/extensions and unmodified
libraries first. For a patch retained in the final candidate, state the exact promised
behavior requiring it, alternatives evaluated, upstream internals touched, durable
regression/upgrade checks, and whether it is correctness-required or optional performance.
Identify patches we can delete or avoid; do not silently weaken correctness to do so.
Complete already-authorized candidate tests, but do not add new upstream modifications
beyond reviewed scope without a concrete maintenance/alternative disposition. Final
integration must assess the combined fork surface, not approve patches one by one merely
because each is locally reasonable. Existing candidates are not automatic approval to ship.

Read the user-provided Opus guide before beginning assigned work:
`/Users/chenghanlee/.codex/attachments/08ddd100-018a-42a4-8d10-92897d13a8c3/pasted-text-1.txt`.

## Current state

- G7 phase2 prompt sent EXACTLY ONCE after pS injection ACCEPT: fault4e553b52,
  generation3 already built before prompt. Test measures automatic delivery/use,
  NOT edit-to-warning latency. p1 lifecycle/evidence, pS immediate observe-only
  post-state. Phase1 last_post_generation0->2 proves at least1 PostToolUse under
  Codex0.157 code mode, exact call unknown. Startup timing CORRECTION: completed0
  means initial observed build ended; old '+55s still compiling' claim withdrawn.


- G7 phase1 completed on actual Codex0.157.0 (updated before user trust), not
  G5's0.156.1. Task/checks pass; refs correct; one corrected agent position miss.
  Code-mode exec may change PostToolUse matching; NOT yet established. Root GO
  phase2 controlled warning on0.157.0 as discriminator. No matcher/runtime edits
  before observation; p1 injects approved tester fault after baseline, pS verifies,
  root sends phase2 prompt after ready. Keep client-version evidence separate.


- User trusted r24 hooks and quit. verify-hooks/cleanup PASS. Root launched actual
  GPT-6-Sol high in new pane wH:pZ, worktree /private/tmp/tips-lsp-r24-accept.
  pS startup identity PASS: r24 manifest1449/1449, exact argv/hooks, process stack
  and session Lua; build still running at+55s. Root sent phase1 prompt.md exactly
  ONCE after identityOK. p1 lifecycle/evidence active, pS per-phase review.
  Codex reports weekly1% remaining; no model-switch authorization or bypass.


- G7 provisioning authorization: p1 may create linked branch
  experiment/elixirls-r24-accept at fd4e2da, worktree /private/tmp/tips-lsp-r24-accept,
  via git -C experiment checkout worktree add. Shared .git worktrees/ref metadata
  is explicitly permitted; main working files/uncommitted edits remain off limits.
  No force/overwrite/commit. Provision only, Codex launch awaits review packet/trust.


- r24 G0-G6 ACCEPTED after pS assertion-level review: manifest b3e8891c intact,
  1449 hashes; Stop33 including identity, hooks7, Lua23, dependency10/10 fresh-Mix
  parity, cleanup clean. Inherited rustfmt and 16 dep warnings disclosed. Generated
  unmanifested __pycache__ retained/documented, no source mutation/rebuild.
- G7 preparation activated: p1 prepares isolated worktree + concrete single-line
  hook-review packet at combined-preparation/p1/r24/HOOK_REVIEW_PACKET.md; pS checks
  before root user prompt. No actual Codex launch/trust bypass/admission yet.
  Actual directed all7, live workspace-symbol content after source edit, automatic
  warning use without polling hints, fresh docs/spec and clean exit planned.
  pQ closes exact gate-profile/docs review (Ruff probe only, core Pyright unchanged).


- r24 built: manifest b3e8891c33c0259a7b4f2210219e50e477c5e41aeb525e3834d91b8a3b7a640f;
  fresh compile, doctor/G0 pass, sources match frozen inputs, old bundles unchanged.
  p1 running G2-G6, pS independent artifact/evidence review. Build success != admission.
- Maintained hook_contract_probe1ab84bfb ACCEPTED after pS PEER_PROBE08bb9d8b.
  G4 uses exit status plus assertion summary, crashed hooks cannot pass quiet cases.
  Ruff profile only; probe excluded from core strict Pyright as user permits.
  No bundle change/rebuild. Evidence limits (startup failure/malformed audit/killed
  probe) retained; don't claim cleanup/evidence creation on literally every path.


- BUILD GO: p1 authorized fresh immutable r24 (path must be absent) using recipe
  58794ce51b1ef281e563bc2802fe34d93e9a43d198a5bcbd95d08d9760ffdd72,
  accepted staging diff32a41f09 and 30-source identity map. pS ACCEPT staging;
  27 independently composed source checks match frozen inputs. p1 executes final
  GATE_PLAN v3 G0-G6, pS independently verifies artifact/evidence. Reuse unchanged
  composed-source G1 results; no copied _build or mutation of old bundles. New
  runtime correction means new immutable candidate. G7 user trust/actual-Codex
  awaits reviewed tool gates and root packet; no admission/commit/push yet.


- Dependency design DECIDED: use peer-reviewed frozen cand8 / folded2 41788874
  in combined beta, replacing existing dependency-reload patch. Reject rs1b as-is:
  active-filter independent H1/S1/H3 show permanent starting on hung shutdown,
  failed spawn/frozen VM. No restart deadline or further lifecycle machinery for
  this release. Preserve comparison for post-beta simplification. Retained deps
  lock uses hidden/private Mix.Project.with_deps_lock, not a public-API claim.
  Shared app/module collision fixtures remain unsupported (cand8 app-name lag
  included). pR provides exact input handoff and bounded current-Tips identity
  exposure check; any detected overlap must be reported before admission.
  p1 may complete all canonical source staging; pS reviews composition, then root
  authorizes immutable combined build. No beta admission/merge yet.


- Parallel preparation activated while pP finishes restart review: p1 stages ALL
  approved canonical sources except dependency changes (NO final build); pQ fixes
  and minimally promotes hook_contract_probe exit-status gate; pD prepares existing
  final gate commands/doc corrections read-only; pS independently reviews pQ and
  p1 staged composition. Missions in T/combined-preparation/p*-MISSION.md.
  pR supports pP on corrected observer evidence. No duplicated broad experiments.
  rs1b starting-forever on hung shutdown/failed spawn is a confirmed blocker as-is;
  pP finishing affected client_id-observer reruns, not a new repair loop.


- Hook candR3 ACCEPTED for integration after pS review PEER_CANDR2.md (target R3)
  and root source read: hook 9501fcf0, manifest 4f19a99c. Neovim's supported client
  replaces custom RPC; no runtime fallback selector. Preserve two pinned disconnect
  classifications and their upgrade gates. Actual hook assertions pass; final bundle
  source-identity check must pass too. Normal timeout kills/reaps client; external
  SIGKILL of hook can orphan client (inferred, not exercised). No hard total cutoff
  or eliminated late-consumption residual claim. Remaining design decision:
  dependency restart comparison under independent pP review.


- Hook narrow peer target now candR3, not R2: hook
  9501fcf03cf61c9a51b9fe702b26201708d8ea5f67cf462bab3741f6b35aab1b,
  manifest 4f19a99cd0abdc92be13c6f6898cd6f2c5f5f9960859a7ad94e88a4a4dbab974.
  Startup OSError is generic unavailable, not disconnected; deadline is evaluated
  outside that catch. pS active in dcaf10c8, retargeted without repeating review.
  Integration gates must inspect assertion summaries: hook-contract probe currently
  exits 0 even on a failed case. Preserve this check or repair harness exit status.


- Freshness final deltas ACCEPTED after pS peer: cand7c manifest
  88a4f39761744cb0b60b34d9f7f84a5ef1ef8ea4c04c9ddd0bf815dc9768c34a;
  Neovim format_rpc_error replaces Normalize.error/cap/cut. Whole 4.9 KB error
  tested through MCP, format 11/11 and Luacheck clean. Hookcut manifest
  7e817f6631a735135d102599c8eeef813a6ab4725c009c6177fbebb106bfba89;
  guarded UTF-8-safe 600-byte summary cut. Peer fuzz 20,065 messages: 0 failures
  (r23 5,813); combined cand7c+hookcut 0. Record freshness-labels/peer-pS/PEER_DELTAS.md.
  No live Codex/gate-chain claim. Hook-client candR2 peer and dependency-restart
  comparison remain open; r23 and canonical runtime unchanged.


- Workspace-symbols closeout frozen, p1 ACCEPT Addendum 3: ElixirLS patch
  508c6bfd (full index + guard, three dead init fields removed), candidate bundle
  e7dead5b; regression probe 862d3cad (unguarded red / frozen green, timing-sensitive).
  ws tests 7 pass. Text v3 4c00c45a; J 348814e4 folds with pQ Lua compatibility.
  Exact inputs recorded in workspace-symbols/peer-p1/STATUS.md. p1 checkpointed,
  clearing for integrator role; do not build before remaining decisions close.


- Hook transport: candR (supported bundled nvim remote-expr client) is preferred
  over cand2 custom RPC; +10–17 ms measured. pD finalizes candR2: post-JSON-decode
  cutoff, known disconnect vs unrelated nonzero client error (do not consume the
  persistent marker on unknown failure), concise stderr. pS narrow peer follows
  freshness delta review. Cand2 is historical fallback, no runtime selector.


- Hook review now includes a bounded supported-client comparison: pD evaluates
  bundled nvim --server --remote-expr with subprocess timeout and structured Lua
  success/error JSON. pS measured 7.6 ms/call. Test truthful error classification,
  timeout/reaping, output and late expiry; compare total ownership against cand2's
  custom one-request RPC client. Exact old traceback prefix is not a requirement.
  Cand2 remains frozen fallback, not an automatic integration choice.

- Workspace milestone accepted for integration: final full index 854031d5 + narrow
  module-disappearance guard 2052574c, J 348814e4 and text v3 4c00c45a. pP folds
  guard and removes three dead init fields, preserves runnable crash regression;
  p1 checks that final delta. No new supervisor/retry machinery. p1 is designated
  single integrator after current-task checkpoint/clear, but canonical runtime and
  final build wait for freshness delta, hook peer, and dependency-alternative decision.


### Latest dispositions — 2026-09-25, after cand7b peer review

- Freshness cand7b accepted as reviewed fallback. pQ/pS now reduce ownership:
  use Neovim's format_rpc_error, permit full upstream MCP error text, remove
  Normalize.error and its custom byte cap/cut. Preserve client errors and partial
  answers. Narrow frozen-delta tests/review only. pQ separately repairs the
  pre-existing hook 600-byte diagnostic cut with a supported UTF-8-safe API;
  retain bounded hook summary semantics and prove strict Unicode JSON output.
- Dependency cand8 reviewed but NOT approved for canonical integration. pR owns
  a bounded public-vim.lsp restart comparison against removing purge hunks,
  retaining deps lock provisionally. Must include failed reload recovery,
  update/removal, in-flight request, and path-dep edits without config/lock changes.
  Count lifecycle changes as maintained code; whole-session 2.9 s is not an
  in-place restart measurement. Shared-name lag remains unresolved by restart.
  No new purge/compiler patch layers, canonical writes, or final bundle yet.
- pD dependency review closed; cleared for independent hook cand2 review via
  observed-limitations/hook-deadline/PEER_MISSION.md. pP/p1 continue full-index
  closeout. pS reviews only pQ's remaining deltas. Single integrator not assigned.

Earlier state entries below are historical where superseded by these dispositions.

- Hook cand2 frozen (b18da64a hook / 62fa26ee manifest), post-decode deadline and
  protocol edges covered; pD PEER_MISSION prepared, queued after dependency closeout.
  pS checkpointed/cleared (13828aaf) and activated independent freshness cand7b
  review (b22196f7). No canonical integration or upstream issue filing.

- Full workspace reindex ACCEPTED direction: e723c7bb replaces selective URI
  tracking (drop cand1), reuses worker, coalesces a build during indexing into a
  rerun, replaces completed results. Final pP/p1 gates: durable regression/tests,
  newly dead field removal, overlap crash control and async-index description.
  J validation GREEN; fold with pQ Lua compatibility changes at integration.

- Dependency cand7 cdc046ef main correction peer-approved: env/target, recovery,
  removal, umbrella, existing controls, warm Tips parity. Root asks one final
  required-app-name UPDATE discriminator: current code skips path purge for a
  retained shared-name dep, although removal safely purges project paths. pR/pD
  distinguish app-name from actual module collision; no by-design stale-current
  exception. No canonical build owner assigned yet; pD hook review follows this.

- cand7b frozen b22196f7: UTF-8 matrix 0/93 split (cand7 6/93), live partial
  answers preserved, Lua 25/25 and handler checks pass. Root reviewed CAND7B;
  pS remains on hook-candidate closeout before independent cand7b review.
  pQ should keep the bytes frozen, no extra broad testing.

- Freshness peer target moves to cand7b: pQ reproduced UTF-8 split at the 500-byte
  structured-error cap causing whole-response MessagePack decode failure. Root
  authorized one character-boundary cut using Neovim API, preserving cand7 red,
  with targeted UTF-8 matrix/live handler/boundary checks. No broader rewrite.

- Freshness cand7 reviewed by root for direction, awaiting narrow pS independent
  review after hook-candidate freeze/clear. Same-generation watcher-build stale
  current reproduced; build-end counter replaces invalid before/after inference.
  Candidate also preserves terminal states, current-document error qualifier,
  and structured per-client errors/partial answers. Five changed Lua files,
  no Rust yet; coordinate J and consolidate patch responsibilities at integration.

- Hook deadline cand1 root-reviewed direction: replace asynchronous SIGALRM/pynvim
  request with one msgpack-rpc socket exchange and absolute socket deadlines.
  pS closes decoded-response cutoff check and protocol evidence; pD queued as
  independent reviewer after dependency milestone. Keep pynvim/greenlet for probes;
  no upstream report sent. Frequency of injected Neovim crash is unmeasured.
  No canonical integration yet. Root unblocked pR routine source-base choice
  (pinned cached archive or disposable reverse-apply); dependency work resumes.

- Workspace milestone root dispositions: L/J text accepted, minimal invalid-path
  check authorized in existing vv-mcp context (pP/p1, coordinate pQ); D-app BEAM
  inventory accepted as candidate. D-race integration HELD: selective URI batch
  repair leaves persistent macro-dependent and module-set staleness. pP/p1 compare
  one existing full-reindex approach on Tips/5x fixture against cand1+2, including
  retaining a build received during indexing and removal of redundant URI state.
  Measure cost before rejecting simpler correctness on asymptotics alone; no
  second index/framework, canonical edits or full cohort.

- Freshness cand3 direction accepted, integration HELD: root challenged unchanged
  generation across watcher-only dependency builds wholly inside a request.
  pQ tests that boundary, preserves exit precedence, adds qualified document-symbol
  error handling and structured LSP error propagation in disposable candidates.
  pP/p1 own workspace_diagnostics uri-scope clarification. pS cleared from review
  to diagnose/repair pre-existing swallowed hook deadline (D3), with normal-budget
  control and bounded Stop delivery, no new supervisor/framework.

- Cursor/reference guidance CLOSED and accepted for combined integration:
  68eaaaf3 candidate, peer-reviewed, no mapping defect in Unicode/tab/CRLF
  controls, no universal empty/declaration claim. Upstream lexical string
  resolution remains qualified. p1 clears for workspace-symbol peer review;
  pS clears for pQ freshness-label peer review. No runtime/bundle edits.

- Root accepts references v2 scope text and cursor description-only direction,
  combined into one future vv-mcp patch/rebuild. Requested neutral empty-answer
  wording (verify position and scope, no statistical or declaration guarantee).
  pS settles the concrete combining-character mapping suspicion with one narrow
  probe and labels plain-string resolution as upstream lexical behavior; p1 peers
  this closeout before clearing for pP workspace-symbol review. No bounds-check
  machinery or canonical edits.

- Release-source remediation CLOSED: root accepted fail-closed harness exit change,
  verified r21 red exit 1 / r23 green exit 0 with preserved evidence and cleanup.
  pP cleared (ae1db49e), activated workspace-symbols/MISSION.md; p1 peer.
  No runtime/bundle change.

- pP maintenance final diff reviewed: docs/recipe provenance accepted. Required
  final gate correction: promoted first-touch harness must exit nonzero on
  failed assertions/version invariant or incomplete cleanup, after preserving
  evidence. pP verifies r21 red nonzero/r23 green zero, then workspace-symbol
  activation. No product change or new framework.

- References coverage reviewed: compiler-indexed files + queried file + optional
  declaration; opening other files does not expand scope. Accept minimal tool
  description warning and later R/AGENTS API-change text-search guidance; require
  explicit scope before broader rollout. No extra index. Wording must not claim
  untested config/config.exs exclusion. p1/pS combine with cursor text for one
  vv-mcp rebuild; candidate only until coordinated integration.

- pQ checkpointed audit/remediation peer review, cleared (95905a48), activated
  observed-limitations/freshness-labels/MISSION.md. Focus truthful per-operation
  status without weakening diagnostic version/late-burst protection. pP finishes
  final shell-safe test-doc corrections; root verifies that small final diff.

- cand6 reviewed and accepted as dependency correction candidate: replaces Mix
  cached-deps inventory with VM code paths; RED update/removal/repeated-failure
  cases GREEN, no new state, attempt 1 passed. Before integration pR/pD test
  effective-env exclusion changes (not safe merely because r23 also fails),
  tiny umbrella path safety, and paired warm Tips cost. Final patch consolidates
  existing dependency-reload patch, no extra layer; no canonical/r24 yet.

- User away at dinner; explicitly authorizes continued tests, triage, fixes and
  retests until wider-beta readiness. Keep root orchestration event-driven, no
  automatic Goal, no merge/push/trust bypass. Confirmed dependency false-current
  blocker stays with pR/pD. Idle p1/pS reassigned queued references/cursor
  investigations after clear; pP/pQ finish maintenance then workspace/freshness
  investigations. Disposable fixes may be prepared and tested; canonical
  integration stays coordinated and peer-reviewed.

- NEW correctness blocker: reviewed r23 env-split config failure + host dev
  dependency update + repair gives current/mix_compile_ok but old loaded dep
  value 3 (disk/manifest/fresh Mix test 4); restart recovers. Broader beta
  admission held. Shared-config broken path cannot update; control fresh.
  pR/pD continue same mission with removal-during-failure and repeated-failure
  RED controls, then smallest disposable correction (max two new attempts).
  Challenge inventory lifetime, not just nil handling; removed deps cannot be
  silently excluded. Preserve lock/incremental/server-app safety. No canonical
  patch edits or r24 yet. Queued refs/cursor work waits for this blocker.

- Reviewed patch-surface F1/F3 accepted for next necessary adapter change ONLY:
  remove always-on prototype mode flags and require bundled-server env instead
  of Homebrew fallback; remove three dominated activity writes. No r23 changes
  or rebuild solely for cleanup. Native watcher retained (only deps/ path).
  Correction accepted: per-call get_cursor_env fallback unreachable in current
  production AST path; withdraw timeout claim attributed to it, preserve
  independently observed malformed-location limits. pQ finishes pP peer review.

- Reviewed release-source audit accepted: pP now completes bounded F1 durable
  first-touch harness, F2 verified/documented patch regression commands, F3
  future recipe provenance/hash + CHECKS nit; pQ peers exact changes/evidence.
  No runtime/bundle rebuild, hook change, or commits. Existing research tests
  did run; the gap is durable documented/automated execution. Other tmp gates
  remain historical evidence unless promoted explicitly. Watcher removal HOLD:
  dependency changes with unchanged mix.lock may lose build liveness.

- User requested investigation of observed LSP limitations; queued explicitly in
  tmp/elixirls-v2/beta-team/observed-limitations/QUEUE.md. Owners after existing
  work: pQ freshness labels, pP workspace-symbol ranges/index, pR references
  coverage, pD cursor/empty-answer semantics. No interruption or implementation;
  checkpoint/clear and Astra activation before next task. p1/pS peer-review
  resulting milestones. Misleading output is a correctness concern, not merely DX.
- pD fresh session confirmed, assigned independent dependency-recovery review;
  pR knows reviewer is ready. Main-checkout handoff/Claude changes untouched.

- r23 real-agent acceptance complete and pS independently reviewed: all seven
  directed features usable; hook warning delivered and acted upon in controlled
  phase 2; spec hover updated generation 6 -> 7; normal checks pass. Final T6
  PASS: no session processes/lock holders, empty registry, only idle pane shell.
  All application edits preserved byte-identical to final archive; bundles
  unchanged. p1 consolidates report, pS peer-checks; no further cohort work.
- Idle agents: pP source/reproducible-check audit and pQ deletion/consolidation
  audit assigned (fresh sessions confirmed), read-only runtime, no rebuilds.
  pR/pD preparing bounded dependency-recovery probe/review; scope is the
  previously unverified failed-mix/config-load cache boundary, no patches yet.

- Phase 3 sent ONCE to same Sol session wH:pV after pS READY: small ProviderConfig
  typespec task explicitly exercising all seven operations. Directed coverage,
  not spontaneous tool choice. p1 records all calls/results/qualifiers and
  checks final code; pS independently reviews. No runtime changes or close.
- Phase 2 independently verified: warning delivered twice, guided targeted
  read/rg/MCP confirmation and repair before own Mix; cleared notice delivered.
  Agent-repaired synthetic function archived, then baseline restored (pS scope
  check); requested @doc retained, final checks pass.

- User requested same Sol agent continue with application tasks exercising all
  seven enabled LSP operations. p1 prepares one focused task, pS peer-reviews;
  label directed feature coverage separately from spontaneous hook evidence.
  Phase 2 is complete per pane, agent reports fixing the injected old call.
  Archive exact final edits first. Only if pS confirms SearchProbe differs from
  baseline solely by the synthetic function, restore baseline and verify hash;
  preserve the agent-repaired version in evidence. Keep requested @doc.

- r23 actual Sol phase 1 passed: module refs 8 locations/0.47 s, function refs
  2/0.34 s, agent used them. Agent checks plus p1 independent focused checks
  pass. No hook diagnostic in phase 1; controlled phase-2 fault and baseline
  saved by p1. Astra sent exact ordinary @doc prompt once. Await phase-2
  delivery/use evidence and pS review; session stays live until cleanup checks.

- pS startup identity OK (runtime-review/evidence/r23-accept-startup); r23
  runtime/adapter bytes and trusted hooks verified, generation 0 complete. Astra
  sent exact provider prompt once to wH:pV through normal approval. Phase 1
  running; p1 records evidence, pS independently reviews. No steering or close.

- r23 focused acceptance launched by Astra via normal approval in wH:pV, fresh
  /private/tmp/tips-lsp-r23-accept, GPT-6-Sol high, Codex 0.156.1. Update skipped;
  no folder-trust prompt appeared. pS approved PLAN; both hooks verified trusted.
  No workload prompt yet: waiting for pS read-only startup identity confirmation.
  Phase-2 attribution starts at the first tool call and compares all disclosure
  channels, not just Mix. Preserve changed and untracked files in evidence.

- User confirms both r23 hooks reviewed. p1 now verifies trusted/enabled hooks on
  the prepared acceptance worktree and reports exact launch; pS completes plan
  check. No agent launch yet. Astra will use normal approval for the prior
  p1-denied launch/prompt actions; user answers any new folder trust.
- Approved focused r23 actual-agent plan in runtime/r23-accept/PLAN.md, pending
  pS plan check and user hook trust before launch: fresh fd4e2da worktree, one Sol
  provider task, no steering/polling hints. Matched task, not latency A/B. If no
  compiler diagnostic is delivered in phase 1, one controlled tester warning
  inside SearchProbe plus normal doc task tests hook delivery/use. Preserve
  baseline/final bytes and all agent changes before removing injected fault;
  distinguish hook-first evidence from own compile output. Prep allowed now;
  p1's prior launch/prompt denial not retried, Astra uses normal approval path.
- Final r23 packet accuracy reviewed by pS and Astra; provider config is prepared.
  User receives packet and exact launch command to review the two r23 hooks in
  Codex /hooks, then quit. Old cleanup-risk authorization carries; no repeat risk
  approval. Bundle unchanged. After user confirms trust, verify it and perform a
  focused actual-agent r23 check; do not claim the r21 cohort ran on r23.
- Native scoped compiler guard accepted: clean source exits 0, missing-env mutant
  exits 1 through compiler status, then guarded umbrella build succeeds. Recipe
  change applies to future builds; r23's manual equivalent passed, bundle unchanged.
  Astra prepared provider .codex/config.toml with r23 configure --force/approve;
  byte assertion confirms ONLY bundle path r21 -> r23 changed. Backup and exact
  before/after in runtime/hook-review-r23/. Application edits and trust unchanged.
  Final packet awaits small p1/pS wording corrections: existing cleanup-risk
  approval persists; late-diagnostic timing not guaranteed; r23 passes separate
  from historical red controls. No user review prompt sent yet.
- Architecture challenge reviewed: coherent enough for isolated beta. Keep r23;
  defer F1's proposed timer/readiness runtime change because it weakens late-burst
  shielding and has no behavioral validation. Root policy critique retained.
  p1 corrects F7 records (stuck cost per edit-making tool call + Stop; actual
  first-read message; only tested dependency-update promises), F3 heuristic and
  workspace-symbol freshness limits, and adds compact pin/gate mapping to CHECKS.
  F4: prefer native scoped elixir_sense warnings-as-errors in future build recipe,
  with positive/negative compiler check, not a custom log filter/allowlist. No
  new runtime bundle solely for recipe check. Final r23 hook packet pending
  root/peer record review; no new broad performance/cohort/load runs now.
- r23 16330dc6 accepted as COMBINED CANDIDATE, not admitted beta. Reviewed paired
  live results fix the original timeout and seven function queries; one-run
  headroom (2.45 s slowest) sufficient to advance isolated beta assessment, no
  new timeout/performance machinery. User explicitly requests adversarial DESIGN
  review: fresh pQ session 2c03b750-b620-4270-a8ee-03eb392cc6fa owns
  `architecture-challenge/MISSION.md`. Challenge chosen contracts, tradeoffs,
  assumptions and combined complexity; no runtime edits. This replaces pQ's
  never-started dependency-cache probe. Admission/hook review held for milestone.
  p1 updates stale release records; pS closes only current-bundle fixture-noise
  verification with real source positive control, not obsolete probe porting.
- References B v4 accepted for integration TESTING after pR verifies delivered
  patches against reviewed source hashes. References-only scope retained;
  compiled alias filter has real Tracer/provider red-green coverage, legitimate
  module/function/declaration controls unchanged. Reported tests: references
  74/74, elixir_sense 1338/1338; golden 34/36 vs shipped 27, two shared misses
  retained as limits. Paired offline module query 40.5 s to 0.16 s, not a live
  speedup claim. p1 builds fresh r22-derived candidate, with relevant compiler
  warnings checks and approved consolidation, then live performance/cancellation/
  concurrent-edit/malformed and composition gates. No final admission yet.
- Accepted r22 b3144767 as verified first-touch/D1 candidate; beta admission still
  waits on references. Exact-bundle checks independently green; boundary 15/17
  versus 17/17 was a /var symlinked probe-output issue, not a product defect.
  For combined rebuild only: store bufnr at didOpen; consolidate opt-in send
  tracing into existing RPC wrapper and delete LspNotify/dead sent-observe path;
  retain/document 150 ms quiet window. TIPS_LSP_TRACE is inherited opt-in, not
  dead functionality: test enabled expected events and default empty trace,
  avoid vacuous historical probes. Preserve immutable r21/r22. p1 reminded that
  B references direction is already selected; coordinate live gates with pP/pR.
- References B v3 independent review supports request-local reuse of builder envs;
  no linearity claim (existing builder still scales superlinearly). Scope decisions:
  references only, not unexposed call hierarchy; no new shared framework. Align
  compiled-trace alias-event filtering with metadata path only after a red/green
  compiled-trace fixture, without changing stored trace format. Remove unused env
  default and document traced-field validity. Keep justified typespec and no-AST
  recovery. pP/pR finalize patch/checks then coordinate exact-bundle live MCP,
  cancellation, concurrent-edit and malformed-buffer gates with p1. Existing two
  subject-env misses remain explicit, not silently claimed fixed. Offline versus
  live timings must not be presented as a paired benchmark.
- After independently verified D1 text repair, p1 is authorized to build a fresh
  immutable diagnostics integration candidate through build_bundle.py and run
  relevant core checks, server, diagnostics, hook/Stop/budget and lifecycle gates.
  pS reviews exact-bundle results. Final beta admission/hook review still awaits
  references; no wholesale Sol rerun now. Resolve the boundary-test discrepancy:
  cand3 notes claim 15/17 on r21 versus the earlier recorded 17/17 release gate.
  Establish harness/prerequisite differences before classifying those failures.
- First-read cand3 independently passes 23/23 + V1 twice; r21 remains red.
  Wire revisions are normalized per URI/connection at RPC send; Neovim's internal
  version table is read, not written. Final acceptance requires D1 text correction:
  completed build plus missing publication must say document diagnostics pending,
  including Stop. Deadline alone must not imply disconnection/recommend restart.
  Keep budget, grace and lifecycle unchanged; p1 repairs text, pS verifies.
  Remaining stuck-publication wait cost (~5 s/edited turn) and first-hover pending
  are explicit limits, not claimed fixes. Final bundle must use reproducible
  source patches, not experimental build-directory copies.
- References root revisit: shipped get_cursor_env may reparse a different program
  or fall back to line context. Astra authorizes candidate B investigation: capture
  per-call lexical environments in one request-local builder pass. Correctness
  target is source-correct reference resolution, not preservation of demonstrated
  misparse artifacts. Independently review every changed location; verify prefix
  equivalence, macro/generated context and incomplete-code recovery. P4's coarse
  line environment is not the proposed per-call environment. pP prototypes, pR
  independently reviews; no integration yet. Parallel whole-file reparsing (A)
  is not the chosen direction: cost/scaling and multicore contention remain.
  Measure bounded scaling/memory; do not claim linearity before verification.
- pS found reload-only version bumps insufficient: deletion/recreation resets the
  buffer version. Candidate uses per-URI session-monotonic revisions before every
  didOpen plus parser-current publication gating. Review Neovim's subsequent
  on_lines/didChange updates for version regression as well. Test the full
  open/edit/reload/recreate/edit lifecycle and delayed old publications; pin the
  necessary Neovim 0.12.5 internal-table dependency with a canary. Candidate only,
  not accepted integration; p1 implements and pS independently checks.
- Diagnostics barrier revision: p1 proved version matching alone is insufficient.
  Neovim reopens disk-reloaded buffers with the same version; ElixirLS can also
  stamp empty build publications with that version before parsing. Astra authorizes
  a small server publication correction plus adapter revision handling for a
  tested candidate, not bundle integration. Open-document versioned publication
  must correspond to parsed current content; preserve qualified build diagnostics.
  p1/pS test reload/retry/reopen/old in-flight parse boundaries; no timing heuristic.
  Separately, pR's possible dependency-cache loss after mixfile/config failure is
  unverified. One bounded reproduction is planned with pQ after fresh context;
  pR moves to independent references review after its completed checkpoint.
- References scope decision: repair both module and function queries sharing
  the per-call full-reparse cost. Preserve shipped semantics including valid
  unformatted one-liners; no formatted-code-only waiver. pP may investigate S,
  but it is not approved for integration. Require a conservative, explainable
  fast-path boundary and exact fallback, not an accumulating list of exceptions.
  Keep lock and timeout contracts unchanged. pR proposed as independent reviewer;
  awaiting its current-work checkpoint before clearing context for a new task.
- Document-readiness evidence refinement (pS): another forced parse can publish
  an empty, null-version diagnostic set for a newly opened URI before its own
  parse. Only a publication matching the relevant document version may satisfy
  that readiness barrier. Test this counterexample, content/version changes and
  reopen semantics. Preserve unmatched/versionless diagnostics as qualified
  results; do not globally discard build diagnostics. p1/pS notified.
- User's two-attempt rule: after two unsuccessful fixes for the same issue,
  stop speculative patching and ask 7-15 whys. Record observed facts versus
  assumptions, why both attempts failed, the revised root cause and a
  discriminating test before another fix. Carry the attempt count across
  handoffs/compaction. Paired agents review the analysis; notify Astra through
  Herdr for ambiguity, scope changes or decisions. Do not fabricate answers.
  Then use first principles to establish the minimum correctness contract,
  Pareto to focus on the demonstrated failures, and Occam's razor to minimize
  new assumptions, state and mechanisms. Derive the simplest working fix.
  Finally apply inversion: identify how it could fail or mislead an agent,
  test plausible counterexamples and assess downstream effects with the paired
  reviewer. Simplicity does not waive known correctness failures.
- New beta blocker accepted: r21's first diagnostics read of an unopened file
  can return empty/current before ElixirLS parses it; pS reproduced a syntax
  error appearing on the next call. Build readiness is not document diagnostics
  readiness. p1 owns smallest source repair, pS independent review; r21 remains
  immutable. Preserve qualified results and pending state across immediate
  repeated reads until a relevant document publication (including empty).
  Test delayed/missing/stale publication, edit/reopen races and workspace scope;
  bounded waiting must share the request budget. First-read quiet-window noise
  is separate until measured fixed. pS refuted the clients:[] attachment theory;
  no attachment-wait patch based on that field. References repair remains pP's
  task. FEEDBACK_REVIEW needs pS's transcript/coverage corrections.
- Team entry-point gate G1-G6 is complete on immutable r21. Astra read pS's
  independent `runtime-review/evidence/team-gate-r21/SUMMARY.md`: startup,
  readiness and normal-exit cleanup passed; all 12 session pids gone, owner and
  compiler-group records removed, registry empty, locks free. User folder trust
  applies to the disposable repository root `/private/tmp/tips-team-gate`.
  This used the configured Astra lead with no workload, separate from the Sol
  cohort. Remaining: references blocker repair and feedback/first-read review.
- Team G4/G5 passed independently (pS 14:26:38): exact r21 process chain,
  owner/registry, locks and first-read current readiness. Astra inspected the
  sole Codex warning: weekly quota below 10%, not MCP startup. After closing
  that view, one Ctrl+C returned the client to its shell (06:27:55 UTC observed).
  pS now owns G6 cleanup. No workload prompt was sent.
- User personally selected team folder trust. Astra observed Codex 0.156.1 at
  its empty input prompt in wH:pV, correct team-gate worktree. p1 confirmed
  G2 generated config and G3 trusted/enabled hooks. pS is capturing G4/G5
  MCP identity and readiness before the single normal quit and G6 cleanup.
  This is a no-workload team entry-point check, not another Sol cohort.
- Team launch command exited 0, 60 dependencies seeded (deps.get 23.05 s,
  compile 43.28 s, seed 0.59 s). G1 passed. Astra dismissed only the update
  prompt with Esc, preserving Codex 0.156.1. wH:pV now waits at folder trust;
  the UI says trust applies to `/private/tmp/tips-team-gate`. User must answer.
  MCP/readiness/exit gates remain pending; p1/pS notified, no model prompt sent.
- Astra reviewed the completed FEEDBACK_REVIEW milestone: useful definition and
  symbols, provider references blocked, no observed false clean; no compiler-error
  messages occurred in the cohort. pS checks first-read attachment/readiness.
  Requested scope corrections: qualifiers alone do not establish freshness;
  lock-wait messages are not proven exclusive to the references defect; do not
  generalize test-file compilation behavior to every `.exs` file.
  Team startup gate is now running via Astra's normal approved execution path:
  disposable `/private/tmp/tips-team-gate/.worktrees/998-neovim-gate-r21`, pane
  wH:pV, unchanged r21, no workload. User answers any folder-trust prompt; pS
  independently verifies readiness and cleanup. p1 must not retry its denied launch.
- Independent r21 cohort disposition: all3task reruns, T1, T3 quiet-hook execution,
  T4/T5/T6/T7/T8 passed; actual-session T9 lock identity passed (pending leg not
  exercised). All3restarts and post-restart cleanup passed. No hook text occurred
  in workloads, so real-agent usefulness of error/pending/Stop messages is not
  established by this cohort; controlled r21 gates cover delivery. Team launch
  remains open. References remains a blocker: module cursor completed in83.6s,
  returning8locations; default cancellation releases lock, bridge responsive.
  An edit during longrefs waited85s;12hooks timed out with unavailable/stopped-session
  suggestion. No timeout increase; p1/pP preparing reviewed minimal Locator repair.
  pS separately examines first-file-read pending qualification (probable quiet-window
  effect, not yet reproduced). FEEDBACK_REVIEW must distinguish these observations.
- T7 update: user explicitly approved all three unchanged restart checks. Astra
  restarted provider/media via normal approval, then dismissed only their update
  prompts with Esc to retain Codex 0.156.1. pS verifies registration/readiness and
  cleanup; no workload prompts on restarts. Repo exited at 14:11:05; its restart
  waits for pS's T6/task rerun. Reference diagnosis now has discriminating evidence:
  at64:55 Locator alone 41.6 s CPU/1487 reparses vs68ms at64:58 (pP); p1 measuring
  full request and lock hold. Root/repair proposal still pending review.
- Cohort progress: repo completed in 14m25s and stays live for pS; media/provider
  task reruns and T6 passed per p1/pS. T7 relaunch remains pending: Claude auto-mode
  denied p1's launch (Create Unsafe Agents) and escalation message (Auto-Mode Bypass).
  Astra asked the user explicitly whether to perform three unchanged r21 restart
  checks through normal approval or leave manual starts to the user. No retry before
  that answer; no security changes. References repro continues on disposable worktree;
  pP's alias-cursor/Locator repeated parsing explanation is a hypothesis, not yet cause.
- Provider cohort found a references blocker: all three MCP calls at
  search_probe.ex:64:55 timed out (default, 20 s before edits, 15 s after); five
  diagnostics calls worked, agent fell back to rg. This does not pass T2. p1
  preserves original evidence and reproduces fresh after live checks/T6/T7;
  pP independently reviews after /clear (new session 01512025-23f4-425f-ac99-fb71edf7e778),
  mission/evidence in references-review/. Verify positions/source snapshots and
  trace bridge/Neovim/server/global-lock/Locator paths before proposing fixes.
  No timeout increase or runtime edits yet. pS continues remaining cohort gates.
- User added actual feedback-quality review: p1 writes
  runtime/cohort-final/FEEDBACK_REVIEW.md from MCP results and PostToolUse/Stop
  messages across the three workloads. Check correctness/freshness against build
  and compiler evidence, actionable details/hints, misleading or missing content,
  and what the agent did next. Use short exact examples with transcript references;
  distinguish observed benefit from inference and unexercised states from passes.
  pS independently checks consequential/disputed findings. No active-agent steering,
  invented polling steps or runtime edits; preserve T9/cleanup coordination.
- Cohort prompt delivery: after user skipped update prompts, p1's classifier also
  denied herdr agent prompt (Create Unsafe Agents). Astra obtained normal escalation
  approval for the exact three reviewed files and sent each once to pV/pW/pX;
  all returned agent_prompted. p1 must not resend. p1/pS own outcome capture and
  independent checks within their permissions; escalate any further denial.
  Sol panes show weekly quota 7% left; report any actual quota interruption as
  incomplete, never a passed workload. No agent security settings changed.
- Cohort launch: p1's Claude auto-mode rejected starting agents and did not notify
  Astra; user flagged the stall. Astra submitted the exact prepared launches via
  normal sandbox escalation, approved, and started provider wH:pV, media wH:pW,
  repo wH:pX in wH:t2. User personally skipped update prompts; all remain Codex
  0.156.1, GPT-6-Sol high, correct worktree. Host verify-hooks had passed all three.
  p1 now owns one-time prompt delivery and execution; Astra has not sent workload
  prompts. pS independently reviews. Any permission/decision blocker must notify
  Astra immediately rather than leave an idle final reply in its pane.
- Operator update: user reports hook review done and explicitly selected "Proceed
  with the isolated beta tests" acknowledging all four cleanup residuals. This is
  a scoped risk acceptance, not a passed no-surviving-writers gate. p1 now owns
  actual three-Sol cohort execution; pS independently reviews tooling/task gates.
  Astra's verify-hooks calls in the default sandbox failed at app-server initialize
  (30-second timeout) in all three roots, so trust is not yet verified. p1 diagnoses
  host verification before launch; no trust changes or bundle mutation. User still
  answers any new folder-trust dialog. Capture T9 without competing workload edits
  and record only needed environment fields, not full process environments.
- Final review state: r21 implementation checks and pS's 13-probe independent
  chain are complete. Astra verified manifest identity, doctor, the final audit,
  corrected harness reruns and review disposition. Three clean final cohort
  worktrees are prepared (60 deps seeded each), configured for read-only LSP
  approval_mode approve, and unlaunched. Operator hook trust remains modified
  from r7. HOOK_REVIEW_PACKET.md is ready; agents run verify-hooks, cohort, actual
  client lock T9 and team startup after required operator decisions. No remote CI,
  commits or pushes. The automatic Goal remains paused; no polling loop.
- The complete no-surviving-compiler-writers gate is NOT passed. Four measured
  residuals require operator disposition: unsampled group at Neovim death, both
  launcher and Neovim SIGKILLed, detached compile-time program, and a Neovim crash
  after failed group-record publication. Acceptance would be a beta risk waiver,
  not a passed gate. No further machinery is added without that decision.
- Worktree: `/private/tmp/tips-elixirls-codex-v2`, branch experiment/elixirls-codex-v2.
- Main checkout is on task/elixir-ls-claude with unrelated edits: do not modify it.
- Baseline beta-r7 passed three actual Sol workloads and controlled unprompted
  late-error delivery. BETA_IMPLEMENTATION.md records evidence and remaining limits.
- BETA_PLAN.md is the approved plan. COLD_START_REVIEW.md and the shared
  `tmp/review-design-performance/review.md` (through Codex round 3) cover cache/reload.
- Installed beta-r7 is immutable. Build/test new versions in separate paths.
- Uncommitted work predates this assignment; never reset it. `nvim.log` is unrelated.
- No main merge. No trust bypass. User personally reviews new hook trust when needed.
- Seven read operations only; ordinary writing tools; normal project Mix/PATH;
  private compiler only in LSP; independent worktree builds; retry retention;
  five-second feedback; continued long builds with explicit pending and later-tool/Stop
  feedback. Preserve these contracts while improving implementation.

## Ownership and finish lines

| Pane | Assignment | Exclusive edit scope |
| --- | --- | --- |
| wH:pD | Cold preparation: test G1b stable shared dependency sources, then implement the smallest correct preparation candidate. Same-worktree dependency reuse remains fallback; no unconditional donor copying. Test paths/native builds/assets/concurrency/identity and report honest timings. | New preparation module/its tests/docs/patches; tmp/elixirls-v2/beta-team/cold/**. Request integration into shared files from p1. |
| wH:p1 | Runtime hardening and release integrator: audit actual remaining beta gates, close concrete defects (including verified Python entry mismatch), integrate accepted preparation/performance candidates, final immutable bundle/config/checks and admission audit. | Existing maintained Python, team launcher/tests, check profiles/CI, release docs. No Lua/Elixir/Rust edits without coordination. |
| wH:pP | Warm implementation completed and accepted. Fresh task: independently review pR's dependency lifecycle F2 mechanism and candidate. | tmp/elixirls-v2/beta-team/dependency-lifecycle-review/**. Prior warm artifacts retained. |
| wH:pQ | Independent cold-preparation reviewer; verify pD's intermediate evidence and chosen implementation directly with pD. | tmp/elixirls-v2/beta-team/cold-review/**; no production edits. |
| wH:pR | Warm review completed. Fresh task: focused F2 dependency-removal mechanism probe and smallest candidate, reviewed by pP. | tmp/elixirls-v2/beta-team/dependency-lifecycle/**; no shared runtime edits. Prior warm-review artifacts retained. |
| wH:pS | Independent runtime reviewer; verify p1's fixes, release gates, packaging and setup directly with p1. | tmp/elixirls-v2/beta-team/runtime-review/**; no production edits. |

Astra owns this file and integration decisions. Agents own short STATUS.md and
TASKS.md under their assigned output subdirectories (p1: runtime/). Update with
current action, live process handle if waiting, changed files, blockers, evidence,
and next step. Put concise completed summaries in RESULT.md. No raw logs in messages.
Coordinate touching any other owner's file before editing. Reviewers check
intermediate conclusions against evidence and coordinate corrections directly
with their implementer. Astra reviews outcomes only at major milestones and
final admission. No self-approval of final release.

Escalate ambiguity, conflicting evidence or an unresolved design disagreement to
Astra. Send the concrete decision, competing evidence and each side's recommendation;
continue independent work while awaiting a tie-break. Routine intermediate review
stays within each pair. Coordinate timed benchmark windows across pairs, or label
concurrent-load measurements explicitly; do not attribute host contention to a patch.

## Decisions

- r21 implementation milestone received; Astra verified manifest
  d48deb6c0af6937ccb27dac972d4814f17bfb15c3ac5b506dbd5f4d56c3cca36 and
  independently ran doctor successfully. pS final review still pending. p1 must
  link corrected Stop/Luacheck reruns in a final summary while preserving failed
  harness runs; avoid blanket all-gates-pass wording with writer admission open.
  Prepare cohort worktrees/deps/config now, before operator approval, without
  launching agents or overriding existing paths. Only trust/folder and residual-risk
  decisions need the user; agents perform verification/cohort/T9 afterward. Keep
  dependency limits scoped to concurrent dependency mutations and untested update
  cases, not ordinary source edits or already exercised cold/native builds.
- Cand5 composition accepted on r21: pS ran A7 and pP independently checked all
  14 build-error steps against the reviewed candidate, plus dependency updates
  2/3/4 against normal Mix. Astra read the disposition and verified r21 build.ex
  still hashes to 227ae36bc68da59f77a8cee4c66da3d2ae62f9066fee8eb2d2afba302d510a72.
  This closes patch composition with cached prune and targeted invalidation;
  it does not close remaining runtime, actual-client identity, trust or cohort gates.
- Cand5 accepted for final integration following pP approval and Astra's evidence
  and identity check: patch SHA-256
  27b2b2c1c9b994865d404729456114a63398389fcd3f2ecd38d12a3d518f5822;
  resulting build.ex (also verified in r20)
  227ae36bc68da59f77a8cee4c66da3d2ae62f9066fee8eb2d2afba302d510a72.
  Independent controls passed dependency race, failed partial-load repair, removal,
  navigation, bidirectional lock waits, killed/failed holders and queued edits.
  Sandbox/outside lock contention proved both directions (9987 ms / 6859 ms).
  Warm ABAB n=30/arm: hook medians 0.920 / 0.922 s. Actual Codex-launched MCP lock
  identity remains inferred; close with one contention check when final session
  exists. Shared lock identity and cooperative-write boundaries remain documented.
  Final integrated build gates, F9 residual disposition and human trust/cohort stay open.
- Stop F10/F11: accept preserving fixes for r21 candidate. A repeated Stop must
  deliver the one-time disconnected notice rather than consume its marker silently;
  retain repeated stalled-RPC suppression. Pending Stop text states unfinished
  validation without promising an automatic later Stop check. pS final gate asserts
  actual notice output once, subsequent quiet, relaunch reset and no loop. r20
  (F9 hardening plus W2 v5) is superseded before gates; r21 adds F10/F11. Final W2
  independent approval and exact patch identity remain admission requirements.
- Dependency race decision: select cand5 (cand4 module purge plus existing
  Mix.Project.with_deps_lock around handle_reloaded_project), pending pP final
  independent approval. Cand4 permits host deps.get to change dependencies between
  purge and compile; deterministic and natural stale results rule out a docs-only
  restart-if-stale contract. Accept host deps.get/update waiting behind an LS build,
  potentially minutes; retain five-second truthful pending feedback. Require shared
  deps-path/TMPDIR lock identity with normal shell, locking enabled, safe lock order,
  failed/killed-holder release and queued-edit recovery. Review dependency state
  loaded before lock acquisition too. Direct writes/custom tasks bypassing the lock
  remain distinct boundaries. No custom lock manager. Final patch/hash and checks
  go to p1 after pP acceptance; cand3/cand4 are superseded candidates.
- F9 is a release blocker: r19 frees ownership after Neovim death while compiler
  port programs survive and write later, even with the launcher alive. Authorize
  p1's preserving Lua/Python repair using the existing sampler to publish owned
  groups for launcher cleanup; no new process. pS must verify atomic publication,
  current-session binding, old/malformed records, early-crash discovery window,
  peer isolation and relaunch, in addition to nvim_sigkill --keep-launcher.
  Known live writers must be gone before ownership release. Do not describe double
  SIGKILL as the only residual until the unsampled-child window is assessed.
  Correct INSTALL's false fail-closed claim; final lifecycle evidence must cover
  this resulting adapter, not only r17/r19 predecessors.
- F9 repair disposition: accept the recorded-group handoff for integration, retain
  250 ms sampling. pS verified recorded writers stopped before lock release,
  peer/decoy isolation, prior-record removal, atomic reads and relaunch. New groups
  can survive a Neovim crash before publication (measured up to 251 ms); double
  SIGKILL and detached compile-time programs also remain uncovered. Faster polling
  does not close these gaps. Do not mark the full cleanup guarantee passed: present
  these concrete residuals for operator disposition in final beta admission.
  Continue independent gates; retest final small publication/ID hardening. No BEAM
  shutdown patch or timer optimization added to this candidate by default.
- Final cohort: choose option (a), all three bounded Tips workloads through the
  final entry point after operator hook trust and verify-hooks. r7's cohort is
  historical regression evidence, not final admission. p1 prepares isolated configs,
  ordinary provider/media/repo task prompts and acceptance checks now; do not hint
  that agents should poll diagnostics. No new cohort launch before trust. Complete
  independent gates first, including late completion and repeated Stop on final
  feedback code; then present one concrete final hook-review packet to the operator.
- Runtime r17 milestone: pS independently passed F7's four-lock total deadline,
  partial-lock release, live duplicate isolation, immediate restart and stalled
  owner boundaries through actual Codex; F6 crash/orphan recovery also passed.
  Keep the three-second wait. Slower cleanup may safely refuse and require retry.
  F8 is fixed and accepted on r19, manifest
  f284cc5938cfad22a0e98cf669b5e49567495ce48a41bf087bfc74f8ce56d408.
  Build-time rebar3 3.25.1 is hash-pinned, installed by Mix's own local.rebar, and
  covered by the expanded mix-home manifest. Astra matched manifest/binary hashes
  and reviewed pS's online and unavailable-metadata-endpoint local-dependency runs:
  no runtime download or rebar mutation; changed/missing rebar fails doctor.
  r17 runtime mutation remains evidence. r19 includes cold preparation but not W2;
  final integrated admission remains open.
- Cold candidate accepted for integration: pQ approved exact artifacts and Astra
  verified hashes (module 931b8461, tests dc7fd0f0, patch 88de0b18, design c2e8c293,
  result 50e12d86). Same-worktree reuse only; no donor `_build` or shared build cache.
  R5-1 is a documented unsupported-input boundary: pQ verified supported
  provisioning never clones `_build`; recovery instructions stop the session first.
  R5-2 is fixed. Roughly 63–69 seconds total provisioning versus 98 seconds is
  separate from roughly three-second post-prep readiness; concurrent-load runs,
  not a paired benchmark. p1 must pass rebuilt-bundle doctor, codex launch, rollback
  and actual team --start gates. Add a 600000 ms Bash timeout for cold team launch
  in team-tpm.md; this does not change the five-second feedback budget. Final
  bundle admission and operator hook trust remain open.
- Cold entry-point gates accepted on r18 after pQ final disposition: prepare-deps,
  codex preparation/report preservation, and team --start preparation passed;
  timeout and recovery docs passed. Astra verified identical r18/r19 bundle.py
  (7361fd51) and preparation module (931b8461), so carry those checks through the
  F8-only rebuild. Actual team-launched MCP startup beyond the new-folder trust
  prompt remains unverified, not covered by the successful preparation command.
  Future launcher changes need focused cold-path diff review; no unchanged broad
  reruns. Cold reviewer fixtures removed, evidence retained, no live processes.
- Dependency review R1/R2: the :compile-only candidate failed on r17. pP reports
  that reset_apps_config unloads application metadata before purge_dep consults
  it, leaving old dependency modules loaded. Continue the small correction within
  existing purge_dep using modules loaded from the dependency ebin; pR implements,
  pP independently checks updates/removals and retained/server-module boundaries.
  O1 shares observed state but remains unproven until navigation recovery passes.
- Runtime F7: accept a bounded three-second ownership-acquisition wait for normal
  immediate restarts. A live duplicate is still rejected, now around 3.3 seconds
  including startup overhead, rather than immediately. Use one total lock-wait
  deadline; never disturb the current owner while waiting. pS verifies duplicate,
  cleanup/relaunch, partial-lock and peer-isolation boundaries. This changes
  startup timing only, not the five-second feedback budget or ownership contract.
- Dependency update W2: assign to the existing dependency-lifecycle pair, pR
  implementation and pP independent review. First test adding :compile to the
  existing dependency-purge cases with pS's dep_update_probe.py and r13 baseline.
  Verify loaded modules and compile-time dependents reach each new version, plus
  cold/unchanged/retained-dependency and failure/repair controls. Coordinate F2
  removal evidence in the same task, without assuming identical causes. If the
  small purge correction fails, escalate a concrete restart-required contract;
  docs alone cannot justify stale observed inputs reported as current.
- Cached-prune accepted: final patch SHA-256
  04c680dfb3ebdf49613b4f97651b79f7e1f71f7f7439c998a0b48aa706baa75a.
  Astra verified identity, equal hunks to the tested copy, and pR timing summary
  (n=30/arm, 1.423 -> 0.805 s median under concurrent load). p1 integrates after
  targeted-invalidation and includes provenance. Full reload/timers/budget stay.
  pP and pR completed their warm slices; after /clear, pR investigates dependency
  lifecycle F2 (false clean after dependency removal), pP independently reviews.
  New exclusive evidence areas: dependency-lifecycle/ and dependency-lifecycle-review/.
  O1 dependency-update navigation remains a known limitation pending mechanism
  evidence; do not conflate it with the accepted prune patch.
- Warm F1 (worker crash feedback): p1 implements terminal failed handling for
  build_error telemetry. End the failed build's wait without declaring diagnostics
  fresh/clean or dropping queued/newer work; keep useful qualified results. pS
  independently validates with the warm pair's cases. Also test narrow root
  mix.lock content-change recovery using the existing additionalWatchedExtensions
  setting and scanner before deferring it or adding server code. No Bash command
  parsing or new retry service. Escalate if the supported path cannot cover it
  with a small patch. Keep this baseline defect separate from cached-prune evidence.
- Runtime F4: first test cleanup in Neovim's existing exit lifecycle, including
  embedded stdin EOF. p1 may edit the runtime Lua for this repair; pS independently
  reviews/retests. Keep ownership until owned compiler descendants are gone and
  verify the real Codex termination path, immediate relaunch and peer isolation.
  Prefer this existing lifecycle to a helper process; escalate if it cannot meet
  the cleanup contract. Do not waive surviving build writers as a documented limit.
  pS confirmed VimLeavePre on stdin EOF, SIGTERM and parent-death pipe close (3/3),
  visible child enumeration and locks retained during the handler. Proceed with
  the Neovim-side repair; acceptance still requires real Codex exit and orphan
  probes on the resulting installed bundle.
- Warm milestone: decline G2b content-based reload skipping for this beta. The
  cached-prune candidate retains full reload and reports 1.433 -> 0.808 s median
  hook time in interleaved ABAB measurements (30 edits per arm, concurrent load).
  Complete independent correctness review of that smaller candidate before
  integration. Preserve existing batching/quiet windows and five-second budget;
  do not expand into timer optimization. PHASES.md contains the measurement scope.
- Hook trust across bundle versions: choose explicit review and verification, not a
  stable dispatcher or a new app-server launch dependency. Every upgrade/rollback
  requires normal /hooks review and a read-only hooks/list check proving both
  intended hooks enabled and trusted before admitting agent work. Review only the
  final bundle now. MCP/hook-command rollback evidence is not proof of Codex hook
  trust after switching. pS independently verifies p1's trust finding and the
  documented check; p1 documents this required switch step and evidence boundary.

## Completion gates

- [x] Baseline r7 actual agent workload and late-feedback evidence captured.
- [x] Initial runtime scope audit identifies required unfinished gates and concrete
      defects. Astra independently confirmed PATH Python in build_bundle.py:229
      and the stale default bundle in task_worktree.py:241-243. See runtime/STATUS.md;
      the final requirement audit remains open.
- [x] Cold preparation candidate implemented or rejected by boundary evidence;
      final chosen path has measured preparation/connection/navigation costs.
- [x] Warm path profiled; cached-prune candidate independently passed its change
      gates and was accepted for integration. Final-bundle gates remain open.
- [x] Maintained core passes scoped Ruff, strict Pyright, Python LSP, Luacheck,
      applicable Rust/Elixir checks and meaningful runtime integration tests.
- [ ] Final immutable bundle passes launch/config/ownership/crash/reconnect/cleanup,
      synchronization retry, isolation, overlap/resources, long-build feedback,
      read-only tool surface, rollback and relevant real Tips workloads.
- [x] Independent review of final changes and concrete user-facing setup/known limits.
- [ ] Final operator hook review if definition changes, then actual Codex validation.
- [ ] Astra verifies final evidence requirement by requirement; beta readiness
      remains unproven until the full objective is established.

## Coordination

User reminder: contact Astra explicitly through `herdr agent prompt wH:p9` before
waiting or ending a turn with a blocker, decision, conflict, impasse or completed
major milestone. A final reply only in your own pane is not a notification. If
permission review denies the message itself, preserve the exact denial at the top
of STATUS.md and state the communication block in your pane; do not work around it.

The operator has returned and approved isolated beta testing. The automatic
Goal loop is paused; coordination is event-driven through Herdr messages to Astra
wH:p9. Finish independent authorized work and paired reviews; send decisions and
major milestone reports promptly so Astra can integrate or assign the next task.
Do not wait for a routine status reply. Keep a concise durable report of verified
results, remaining blockers, exact bundle identity and next action. Normal final
hook trust still requires the operator's review: prepare definitions and all
independent checks first, never bypass trust or claim that admission gate passed.

Send brief completion/blocker notices to Astra in Herdr pane wH:p9; preserve full
facts in files. Keep working on independent authorized steps. Ask only if blocked
by missing decisions or destructive/external actions. No commits/push/merge without
coordinating with Astra. Six Opus agents is the concurrency ceiling; create no more.

Context: autocompact is now enabled. Keep current tasks, process handles, decisions
and changes in STATUS/TASKS files so work survives it; do not pause at 350K or
request routine manual compaction. Before assigning a different task, save results
and process handles, then use /clear for a fresh context.
Do not restart live experiments after an observation
or context timeout; inspect their actual handle first.

Monitoring: use completion/blocker notifications and short status files. Do not
read pane transcripts routinely. User has enabled autocompact and cancelled the
ten-minute context checks. The temporary context monitor is stopped; do not
restart it or manually compact based on the old 350K threshold.
Keep background build/probe handles through compaction; resume the same mission.
All three assigned sessions were verified working
after Astra's context compaction. p1 is fixing the two launch defects and owns
rollback, installation documentation and final-bundle admission checks.
The three fresh reviewers (pQ, pR, pS) confirmed Opus 5.5 at max effort in their
STATUS.md files. Their processes were verified working after mission dispatch.

## Post-admission milestone — broader simplification (user requested)

- Reduce the number of custom patches required by the Neovim + ElixirLS
  integration: fewer is better; the stretch goal is zero. Count distinct upstream
  modifications and patched projects, not merely patch files. Combining patches
  into one file does not count as removing ownership. Preserve the tested
  correctness, performance and lifecycle contract when removing or replacing them.

After packaging and admitting the beta, audit the whole maintained integration
against supported industry conventions, APIs and established implementations.
Prefer configuration/extensions/unmodified libraries over custom mechanisms and
upstream patches. Inventory each retained responsibility, state field and patch;
name its tested contract, supported substitute and upstream upgrade burden.
Prioritize opportunities that delete the most ownership with the least behavioral
risk. Remove/recombine redundant components and abstractions; do not merely move
complexity into the adapter, user workflow or another patch file.

Use the admitted immutable beta and acceptance tests as the baseline. Each change
must preserve correctness, truthful feedback, worktree isolation and lifecycle
behavior, with measured performance tradeoffs. Ship simplifications in bounded,
reviewed changes, with rollback; no broad rewrite or additional framework.
Finish with a before/after accounting of maintained mechanisms and upstream forks,
regression evidence, and explicit reasons for every patch that remains. This is
AFTER beta admission, not a new prerequisite or reason to reopen all settled work.

## Dependency restart comparison — peer gate

rs1b removes the two dependency purge hunks, retains deps lock, and adds public
Neovim restart orchestration (+73/-16 Lua). Reported fixtures match fresh Mix,
including path-dep source edits; actual warm Tips restart 2.34–2.54 s (n=5).
In-flight request can wait its full timeout. Hung shutdown and failed spawn remain
untested; shared-module collision remains unsupported. pP independent peer review
is being activated after workspace-symbol checkpoint/clear. No integration choice
until lifecycle failure behavior and trigger coverage are evaluated.
