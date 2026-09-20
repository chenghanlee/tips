# Tips implementation planning review

Status: review history; Codex and Fable reached consensus in rounds 4–5. The [implementation plan](../implementation/implementation-plan.md) is authoritative. Earlier proposals below remain as review history, including rejected sequencing, ownership and component-installation options.

Date: 2026-09-20. Roles: Codex is engineering manager/tech lead; Fable is technical program manager. N worker agents implement. Planning only; no design-document edits and no code until the owner approves the plan.

Inputs: `AGENTS.md`, `docs/design/technical/software-architecture.md`, `backend-design.md`, `frontend-design.md`, `data-model.md` (all dated 2026-09-20, holistic consensus applied).

## Fable TPM proposal, round 1

### Starting facts that shape the plan

- The repository contains only documents. No Mix project, no git repository, no CI, no provider accounts are visible. Milestone 0 is therefore serial: one agent creates the skeleton before anyone else can work.
- The three technical contracts already name the first slices (backend "Runtime and integration checks", frontend "Holistic consensus acceptance", architecture "Implementation sequence"): text publish/edit with lost confirmation and browser recovery; one image retained across a known rejection; one private video through its lifecycle; another-browser magic-link return; the pinned ten-query search gate. The plan orders work around those, not around screens.
- The data model is frozen and cross-cutting (lock order, triggers, deferrable slot constraints, session family, media states). Greenfield with no compatibility requirement means the whole schema lands once, early, from one owner.
- The four documents carry roughly 60 acceptance bullets. Every one maps to exactly one slice below. A gate is "acceptance items executed and green", not "code merged".

### Milestones and gates

| # | Milestone | Parallelism | Gate to pass |
|---|---|---|---|
| M0 | Skeleton: git init, `mix phx.new` pinned Phoenix 1.8.x/LiveView 1.2.x, `phx.gen.auth` magic-link (no passwords), Oban, Docker Compose dev DB on a pinned Postgres 18 image with pg_textsearch and pgvector, CI running migrations and tests on that image, merged agent guidance (`AGENTS.md` plus generated Phoenix guidance), `Req.Test` seams, fixture helpers | 1 agent (+1 on ops track, see H) | G0: CI green; migrations run on the extension image; generated auth tests pass; Oban starts. |
| M1 | Canonical schema and Accounts adaptation: every table/view/trigger/constraint/index from the data model in migrations; Ecto schemas with `Ecto.Enum`; `users_tokens.session_family_id`, 60-day validity/7-day reissue, family logout, account switch, email-change revocation, token pruning; handle/ban/deletion/7-day confirmation reclaim; single admission helper returning identity plus session-row reference; `return_to` carrier through registration, magic link, confirmation and redirect; router live-session boundaries (public / authenticated / moderator); shared `Content` visibility policy and projection skeleton | 2 agents max (schema; Accounts+web auth) | G1: data-model constraint/trigger/lock-order fixtures; both renewal/logout schedules; concurrent successors; late cookie; another-browser confirmation returns to destination; revoked-token admission with failed disconnect delivery. |
| M2 | Risk slices (the four named slices plus the search gate) | 4 to 6 agents | G2: the five slice acceptance sets below, executed against the real providers for video and embeddings. |
| M3 | Remaining screens and operations | up to 7 to 8 agents | G3: the remaining acceptance bullets from all four documents. |
| M4 | Launch readiness | 2 agents | G4: deploy from image with migration and readiness check, restore drill, Sentry and uptime monitor alerting, job-health check, noindex and Turnstile in place, seed content published through the normal forms. |

### Critical path

M0 → M1 (schema + admission + `return_to`) → Slice A (text publish/edit/recover) → Slice D (images in the editor) → Slice E-front (video in the composer) → G2 → M3 fill-in → G4.

Everything else hangs off that spine. The search gate and the ops track run beside it from M0/M1 and must finish before G2 and G4 respectively; they are not on the spine unless the hosted embedding candidate fails, which adds a third container to the deployment (see owner decision 1).

### Slices and ownership at M2 and M3

Each slice owns its context functions, its LiveViews/controllers, its hooks and its tests. Vertical, not by layer.

| Slice | Scope (contract sections) | Owns | Depends on |
|---|---|---|---|
| A. Text publish, edit, recovery | `publish_tip`, `publish_review`, `get_publication` four-way acknowledgement, whole-intent comparator, `edit_tip`/`edit_review` with `optimistic_lock`, no-op detection, shared search-text writer (`search_text`, `text_at`, `embed_after`); editor LiveView per kind with `:new`/`:edit`, IndexedDB draft hook with `(draft_id, revision)` CAS, publication-to-edit handoff via `push_patch`, `phx-auto-recover`, leave confirmation | `Tips.Content` publish/edit, `Content.Comparator`, `TipsWeb.TipEditorLive`, `ReviewEditorLive`, `assets/js/hooks/draft.js` | M1 |
| B. Reading | `list_tips` Hot/New with filters, `get_tip_page` normal list and selected review, `has_earlier_reviews`, profile `UNION ALL`, paged lists, native filter selects, Clear filters, curated links, deleted/hidden placeholders, Copy prompt/result hook | `Content` reads and projections, `BrowseLive`, `TipLive`, `ProfileLive`, shared list/filter components | M1 visibility policy |
| C. Votes, notifications, inbox | `set_vote` with lock order and confirmed counters, fold-on-conflict notifications, inbox once-per-visit mark-read, signed-out vote return | `Content.Notifications`, vote component, `InboxLive` | M1; B for row rendering |
| D. Images/GIFs | built-in LiveView uploads on submission, `{:postpone, path}` consumption rule, bounded parser for `is_animated`, 10 MB/50 MB/ten-slot limits, R2 put, orphan sweep worker, canvas static previews, descriptions, drag and Move earlier/later ordering, missing-slot Reselect | `Content.Media` image path, result composer components, `assets/js/hooks/{preview,reorder}.js`, `maintenance` sweep | A (editor shell) |
| E-back. Video backend | `begin_video_upload`/`get_video_uploads`/`discard_video_upload`, conditional uid persist with `clock_timestamp()`, expiry worker with `reconcile_after`, cleanup job, JOSE RS256 signing, `/media/:id/watch` and `/thumbnail` routes with `no-store` | `Content.Media` video path, `MediaController`, `media` queue workers | M1 |
| E-front. Video composer | external uploads with tus-js-client adapter, preflight replaces provisional token with media id, page-owned bounded status cycle, state-to-action mapping, exact-item target equivalence on handoff, inline click-to-play iframe | composer video states, `assets/js/hooks/tus.js`, editor status cycle | D, E-back |
| F. Search | BM25 + HNSW four-branch RRF with filters in every branch, bounded window and final offset, keyword fallback within total deadline, bounded embedding client with concurrency/queue limits, singleton embedding scan with freshness guard, `SearchLive` with `begin_results`/`cancel_async`, ten-query gate harness and dev corpus | `Content.Search`, `embeddings` queue worker, `SearchLive`, `priv/repo/seeds.exs` (dev only) | M1; A's search-text writer (interface agreed in M1) |
| G. Moderation and accounts | `report_content` with `FOR SHARE`, queue/case pages, hide/restore, `dismiss_reports`, `destroy_media`, `retag_tip`, bans and `lift_ban`, bulk hide capacity fixture, account settings (email change with sudo), account deletion | `Content.Moderation`, `ModerationLive`, `SettingsLive` | M1; A's `edit_version`; B's projections |
| H. Ops | production Compose, release commands (migrate, retry job, recount, health), deploy script with readiness check, nightly `pg_dump` to R2 with lifecycle rule, Sentry SDK with sanitization, public health endpoint, independent job-health routine, Cloudflare proxy/origin restriction, Turnstile, ETS limiter, Oban rescue/pruning/shutdown grace | `rel/`, `config/runtime.exs`, `compose.prod.yml`, `HealthController`, `Tips.Health` | M0 |

File-collision rules: migrations belong to the M1 owner only; a slice that needs a schema change files a reconciliation request (doc ownership invariant) instead of editing migrations. `router.ex` is append-only within each slice's scope block. New components go in per-slice component modules, not into `core_components.ex`. Each hook is one file under `assets/js/hooks/` with a one-line import in the index. `config/*` belongs to H.

Realistic parallelism ceiling: five to six agents at M2 (A, B, E-back, F, H, plus D once A's shell exists), seven to eight at M3. Beyond that, agents collide on the editor, the composer and the router and coordination cost exceeds throughput. N above eight should be spent on verification, not implementation.

### Coordination roles versus N workers

- Tech lead (Codex): routine implementation decisions, unblocking, doc-reconciliation requests to the owner, code review of gate-critical slices (A, E, M1).
- TPM (Fable): dependency tracking, merge order, gate verification checklist, risk register, this file.
- Verification agent (one of N, rotating per gate): runs the acceptance fixtures across slices at each gate on the extension image and against real providers; owns CI health; does not rewrite slice code.
- Workers: one slice each, disjoint ownership as above. Handoffs happen only at gates.

### Sequencing mistakes to avoid

1. **Splitting by layer.** Backend agents and frontend agents on the same feature recreate the integration debt the contracts just removed. Every slice is vertical.
2. **Per-feature migrations.** Interleaved migration files from several agents break ordering and lock-order invariants. One owner, whole schema, M1.
3. **Fanning out at M0.** Nothing is parallel until the skeleton, schema and admission helper exist. Idle agents at M0 do H (ops) and the search-gate corpus/harness, nothing else.
4. **Building read pages first because they are easy.** Browse, profile and inbox are M3 fill-in. The risk is in publish, recovery and media. Start A before B.
5. **Deferring the Accounts adaptation.** Session family, admission helper and `return_to` are used by every mutation and editor. Retrofitting them into N LiveViews later multiplies work. They are M1.
6. **Treating the search gate as polish.** It decides whether a third container ships and needs a corpus and ten owner-supplied queries. Start the harness in M1; run the gate inside M2.
7. **Video before images.** E-front depends on the composer tray, slot identity and page-owned upload lifecycle that D establishes. Run E-back in parallel; hold E-front until D is green.
8. **Mock-only provider verification.** `Req.Test` covers logic. The gates require real Stream signed URLs, tus resume, upload expiry, and real embedding latency. Those need owner-provisioned credentials before M2 starts.
9. **Letting agents edit design docs to match code.** Deviations go to the owner as reconciliation requests. Code follows the contracts.
10. **A manual integration agent.** Integration is CI plus gate fixtures, not a person merging by hand.

### Owner decisions that materially change the plan

1. **Embedding runtime and off-box text.** Is sending eligible public document text and reader queries to Cloudflare Workers AI acceptable? If not, the self-hosted Qwen3 container is on the critical path from M0 (image, resources, deployment shape). If yes, the hosted candidate runs the gate first and the container is contingent.
2. **Provider accounts and secrets.** Cloudflare (R2, Stream, Workers AI, Turnstile, proxy), email provider, Sentry, VPS, domain, git hosting and CI runner. Agents cannot provision these. They are needed by M1 end for H and by M2 start for D, E and F real-provider checks.
3. **Visual system.** The frontend document leaves styling open. Recommendation: ship the Phoenix 1.8 generated Tailwind/daisyUI defaults for the MVP and adapt later. A custom design system before M2 blocks every LiveView slice on a designer.
4. **Seed material.** Ten developer task queries plus representative firsthand documents for the search gate (dev corpus, never presented as real), and the initial curated `models`, `environments` and `tags` rows. Without these, F cannot run its gate and A cannot publish a real tip.

### Questions for Codex before we lock the plan

- Do you agree M1 lands the complete schema in one pass rather than schema-per-slice?
- Should the comparator (whole-intent normalization) be built in M1 as shared infrastructure, or inside A with F and G consuming it later? I lean A, because its rules are publish/edit rules, with the interface fixed in M1.
- Which gate is the owner's first invited developer trial: G2 plus B and C, or full G3? This changes whether M3 is pre- or post-trial.

## Fable review of `docs/implementation/implementation-plan.md` (Codex draft), round 2

Read-only review. Codex owns edits. Verdict: the structure is right (skeleton → five boundary gates → expansion → rehearsal → trial), the single editor owner is correct, and P4 beside identity is correct. Seven actionable disagreements, one essential owner question, two owner records.

### Disagreements

1. **P5 does not depend on P2.** Media foundation (media rows, states, expiry/cooldown worker, cleanup jobs, R2 put, Stream creation, JOSE signing, watch/thumbnail access function) needs the schema and the scope struct declared in P1, not magic-link login. Tests use a user row and a scope. Make P5 depend on P1 so it runs beside P2 in every schedule. P6 keeps P2 because editor entry is authenticated.

2. **Search-text writer ownership contradicts the backend contract.** Draft: P3 "includes the minimal search-text writer" and P4 "replaces no independent writer". Backend design, agreed context boundaries table: `Tips.Content.Search` builds search text. P4 starts after P1, P3 after P2, so P4 needs `tip_search`/`review_search` rows before P3 exists and would have to write them anyway. Fix: P1 declares the writer signature; P4 (Search owner) implements it; P3 calls it. Same file owner for build, `text_at` and `embed_after` semantics.

3. **P13 is serialized behind M1 but M1 depends on P13.** P6's real R2 round trip, P7's real Stream lifecycle and M1's real hybrid search all need provider configuration and secrets loading, which the draft places in P13 after M1. Split: P13a (runtime secrets, provider configuration, production Compose baseline, Sentry SDK, health route, proxy/origin) depends on P0 and starts immediately; P13b (independent progress check, backup/restore/repair runbooks, selected-job retry, rescue/drain) depends on P5. Worker D in the N=4 "First boundaries" row is already doing P13a implicitly; name it.

4. **P9, P10, P11 and P12 gate on M1 unnecessarily.** None touches the editor, uploads or the draft hook. Their real prerequisites: P3 integrated (readable tip route, projections, `edit_version`) and P2 (admission). P12 is pure Accounts work and depends on P2 alone; it should stay with the P2 owner for continuity. Gating them on the video gate (P7) leaves workers B/C/D "closing gaps" for the whole media stage in the N=4 schedule. Keep M1 as the gate for P8 and P14 only. This still honours "complete the risk slices before expanding every screen" in spirit: the editor owner is untouched, and the expansions share no files with P6/P7.

5. **Pull minimal reading out of P3.** P3 currently carries readable tip/review routes and visibility projections alongside publish/edit/delete, receipts, draft CAS and lost-outcome recovery, and the same worker then owns P6, P7 and P8. That is the critical path at any N. Move "minimal readable tip page and visibility projections" into an early P9a (depends on P1/P2; owned by the discovery owner), leaving P3 as editor plus publish/edit/delete operations. Name the comparator owner explicitly: P1 declares the signature, P3 implements it (publish receipts, no-op detection), P8 reuses it for the complete-base shortcut.

6. **SearchLive should not have a temporary owner.** The `begin_results`/`cancel_async` lifecycle is one of the pinned framework behaviours and belongs with retrieval. P4 owns `SearchLive` permanently; P9 owns browse, tip, profile and the shared filter/list components. Delete the "temporary file owner" clause.

7. **Browser hook files are disjoint and need not be editor-owner work.** The editor owner keeps the LiveViews, upload configuration and `draft.js`. Canvas preview, reorder, tus adapter and Copy hooks are single files under `assets/js/hooks/` with a fixed interface to the page, so Media or other workers can own them during P6–P8. Without this, P8 is one worker regardless of N.

### Neglected gates and small omissions

- P0 exit criterion: the same pinned Postgres 18 image with pg_textsearch and pgvector runs in CI and in production Compose. If no published image exists, building it is P0 work and the first schedule risk. Native FTS remains a fallback only for a concrete extension blocker, per the data model.
- First moderator bootstrap: a release command or seed that grants `role = 'moderator'` by handle. Needed by P11 tests and by trial moderation. Add to P13b runbooks.
- Curated vocabularies: `models`, `environments` and `tags` rows are required before any tip can publish (P3). Owner-supplied; add to the prerequisite checklist with needed-by P3.
- Browser test tooling (Wallaby or Playwright driver) is a P0 decision because IndexedDB, tus and canvas tests need a real browser. Routine, Codex's call, but it belongs in P0's exit evidence.
- Deployment interruption measurement (architecture: "measure rather than promise") belongs in M3 evidence.

### Owner questions

**Essential:** Is sending eligible public document text and reader queries to a hosted embedding API (Cloudflare Workers AI) acceptable? The backend design leaves this judgement to the owner. If no, the self-hosted Qwen3 container joins P0/P13a and the deployment shape changes now, not after the gate.

**Record only (defaults proposed):** visual system defaults to the Phoenix 1.8 generated Tailwind/daisyUI components until after trials; the founder is the first moderator.

### Conclusion

Accept the draft with the seven changes above. Net effect: P5 and P13a start after P1/P0, P9a–P12 start after P3, P13b after P5, and only P8 and P14 wait for M1. The critical path becomes P0 → P1 → P2 → P3 → P6 → P7 → M1 → P8 → P14 → P15, with P4 as the alternate critical path if the hosted gate fails. Nothing here splits the runtime or adds a subsystem.

## Fable review of revised `docs/implementation/implementation-plan.md`, round 3

Agreement: P5 after P1, P4a Search-owned writer, P13a/P13b split, P9a, permanent P4b SearchLive, bounded hook delegation, moderator bootstrap, vocabulary tracking, P0 image and browser-driver criteria are all accepted as written. I also accept M1 as the gate for P9b–P12 given the technical documents' explicit early-slice rule, and withdraw the fixed agent ceilings. Remaining items are concrete and small.

### Required fixes

1. **Distinguish start-permitted from gate-required.** The table defines a dependency as "integrated and gate passed". Under that rule P3 cannot start until P9a and P4a are integrated, and in the N=4 schedule worker A idles while D builds P9a. P3 needs P2 to start; P9a and P4a are required for P3's gate (post-save destination, search rows). Same for P5: it starts on P1; only its real-provider evidence needs P13a. Add one sentence to the table preamble and mark those two rows.

2. **P8 depends on P7, not M1.** P8 is the editor owner's own continuation, not screen expansion. If P4b lags, the editor owner idles behind the search gate for no reason. Keep M1 for P9b–P12.

3. **N=2 order for worker B:** P13a → P4a → P5 → P4b. P6 needs P5 and sits on the authoring chain; P4b does not.

4. **Add the design package.** It is missing from the table, the graph and the schedules. Proposed row:

| ID | Package and primary ownership | Depends on | Required result |
|---|---|---|---|
| P16 | Visual baseline — Fable (worker slot) | P0 | shadcn design language expressed as Tailwind v4 CSS-variable tokens (background/foreground/primary/muted/accent/destructive/border/ring/radius), light and dark, and native HEEx function components with `Phoenix.LiveView.JS` for interaction; generated daisyUI theme layer replaced; layouts and shared components restyled; page compositions for the six areas in the frontend "Pages to design" table |

Rules for P16: no React, Radix or Node component runtime; the frontend contract's native `<select>`, `<details>`, canvas previews and server-rendered controls stay native, so shadcn Select/Accordion patterns are not ported. Owns `core_components.ex` (or a `TipsWeb.UI` module), `assets/css/app.css`, layouts. Soft gate only: P3, P4b and P9a ship on generated components; P16 integrates before P8 and P9b–P12 start so screens are built once. If P16 is late, screens proceed and restyle is accepted rework. P16 must never block M1. Existing LiveView shadcn ports (for example SaladUI) may be evaluated in P16 and adopted only if pinned, maintained and compatible with the native-control rule. In the N=1 schedule P16 runs during the Media integration stage, when the single worker is on P6/P7 and the design slot is the only free slot.

### Owner clarification (essential, already in flight)

"shadcn" as a design language rendered in HEEx is compatible with every current contract. "shadcn" as the React component runtime is not: it would add a Node build, a second component model and client state outside LiveView, contradicting the architecture's LiveView-only frontend and the frontend document's native-control decisions. P16 proceeds on the design-language reading; the runtime reading would reopen the frontend contract and needs an explicit owner decision, not a plan edit.

Record-level: any existing brand asset (name mark, colour, typeface) the owner wants kept. The `try-this-prototype.html` token set (ink/ground/accent, serif/sans/mono) is the only visual reference in the repository; P16 will treat it as input, not a constraint, unless the owner says otherwise.

### Conclusion

With fixes 1–4 the plan is complete and I have no further blockers. Longest authoring chain: P0 → P1 → P2 → P3 → P6 → P7 → P8 → P14 → P15, with P4b and P16 beside it.

## Fable final verification, round 4: consensus

Verified in `docs/implementation/implementation-plan.md`: start/finish split on P3 and P5, P8 after P7 in table and graph, N=2 worker B media-first (P13a → P4a → P5 → P4b), P16 in table, graph and all three schedules, and design consuming the single slot at N=1. I accept the N=1 correction: design and coding are sequential there.

P16 update to the owner's selection: the library is SaladUI (github.com/bluzky/salad_ui), not a selection exercise. Consequences for the package:

- P16 depends on P0 only; the runtime clarification is resolved (design language, native Phoenix components). Lines 11 and 79 still say "pending"; Codex records the decision.
- Add a P0/P16 smoke gate: pinned SaladUI version compiles with the pinned Phoenix 1.8/LiveView 1.2 and Tailwind v4 toolchain, its hooks register beside Tips hooks, and its components render in a LiveView test. Beta status means this is verified, not assumed.
- Use SaladUI's local-copy option so components are project files under P16's exclusive ownership; no vendored dependency edits another owner must coordinate.
- Preserve the frontend contract: native `<select>` and `<details>`, canvas previews and server-rendered controls stay native; SaladUI Select/Accordion patterns are not used for those. Editor LiveViews, upload configuration and the draft hook remain the editor owner's files; P16 supplies styled components and layouts only.
- No dark mode; no component catalogue. Tokens and shared controls for the six page areas, then visual QA on running journeys before P14.

No remaining blockers. The plan is agreed; implementation awaits the owner's go.

## Fable final clarification, round 5

Agreed: SaladUI in library/package mode first, pinned to an exact version or git revision, with a local copy only for a component that a concrete Tips customization needs. Vendoring everything upfront is maintenance we do not need; exclusive ownership of `app.css`, tokens, layouts and `core_components.ex` is enough. Two notes for the P0/P16 smoke gate, not blockers: Tailwind v4 must see the dependency's class sources (an `@source` entry for the package path, per the library's setup), and the generated setup changes are inspected and committed as P16-owned files. No remaining planning blockers.
