# Elixir/Phoenix idioms review — overall architecture

Date: 2026-09-20. Status: phase 1 consensus reached in 2 rounds. Read the final closure and Codex ratification; earlier findings include withdrawn claims.

## Agreement and scope

Fresh review of the current four documents in `docs/design/technical/`, including the reconciled data model. Earlier `adversarial-*.md` reports are historical evidence, not this review's findings. No implementation exists in this workspace; conclusions concern design contracts, not deployed bugs. Review only: do not edit the source designs.

Codex uses a José Valim-inspired lens: ordinary Elixir functions and data, explicit effects, appropriate process ownership, and minimal abstractions. Fable (Herdr pane `wJ:p1`) uses an orthogonal Chris McCord-inspired lens: Phoenix conventions, LiveView lifecycle, complete product flows, and practical framework use. These are analytical perspectives, not statements by or endorsements from either person.

Review phases proceed in order: architecture, backend, frontend. Each has its own shared file. Each round contains both reviewers' findings or rebuttals. Stop at explicit consensus or ten paired rounds; record unresolved differences. Append under your own reviewer name. Findings must identify evidence, practical consequence, smallest fix, and downstream/whole-system effects. Challenge recommendations as well as findings. Removing agreed product behavior must be marked as a product change, not an idiomatic refactor.

## Codex (Valim lens) — Round 1

### Root cause and overall verdict

1. Why might this feel like a Frankenstein? The specification contains several specialized state machines around a small content product.
2. Why do those exist? Mixed media, uncertain publication outcomes, restrictions, and browser recovery cross different failure boundaries.
3. Why not replace them with one universal workflow? Browser files, database transactions and provider objects have different lifetimes; merging them would conceal essential distinctions.
4. Why is the reading burden still excessive? The same contracts are repeated across architecture, backend, frontend and SQL, together with historical alternatives.
5. Why would another abstraction help? It would not. Give each contract one owner and implement a complete journey with ordinary functions. Two further whys leave that answer unchanged.

**The foundation is cohesive and idiomatic.** One Mix project, Accounts/Content contexts, Ecto transactions, LiveView pages, function components and Oban in the same release fit together. Do not split Content into services, turn entities into processes, add repository wrappers, or introduce a generic workflow/authorization framework. SQL constraints and two counter triggers do not by themselves make the application un-Elixir-like. They enforce database invariants; application operations own orchestration. [Phoenix contexts](https://phoenix.hexdocs.pm/contexts.html) describes contexts as ordinary modules grouping related resources. [Elixir process guidance](https://elixir.hexdocs.pm/process-anti-patterns.html#code-organization-by-process) reserves processes for runtime properties rather than code organization.

### A-J1 — Medium: the public context boundary is described in two ways

Evidence: backend-design.md:61 says the page calls `Content.Search`; :148 says LiveViews/controllers/workers call public `Content` APIs; :143–154 describes Search/Media/Moderation as internal responsibilities. Frontend :23 specifies context calls. Architecture :69–73 says contexts keep their internal organization local.

Risk: developers create both a mandatory pass-through facade and independently callable helpers, then put admission/projection rules on only one path. That adds indirection while leaving unclear which API is safe for callers.

Smallest recommendation: use the already proposed `Content.search_tips`, `get_tip_page`, publish/edit and media operations as the supported web boundary. Helpers are implementation details extracted when useful. Do not add a wrapper module per operation or a behaviour per helper. A facade forwarding to a cohesive helper is acceptable; duplicating validation/authorization in both is not. Clarify the single conflicting call-site sentence, not the entire module tree. Workers may call focused internal business functions with explicit committed eligibility, as already specified.

Effects: frontend and async tasks know which contract to call; backend retains freedom to organize queries. No new runtime layer or product change.

### A-J2 — Medium: cross-context unban needs one operation owner

Evidence: backend-design.md:148 says each write owns its transaction; :152 says bans remain Accounts operations and the moderation interface can invoke both contexts; :408–414 requires account change and content restoration to be transactional. Architecture :37 assigns account lifecycle to Accounts and visibility to Content.

Risk: a literal implementation can call `Accounts.unban` and then `Content.restore` from a LiveView, or nest public transaction-owning operations whose failure contracts are hard to compose. The required atomicity is specified, but the orchestration ownership is not.

Smallest recommendation: expose one account restriction operation owning one `Repo.transact`, with Content-owned ordinary helpers participating in that transaction for restoration and jobs. Document which function is the entry point. No coordinator process, generic saga or third context. Shared database transactions across contexts are valid; cross-context function calls are not an architectural failure.

Effects: UI makes one call; user/content locks and required activation jobs commit together. Preserve the existing global lock order and full-ban deletion exceptions. Backend phase must inspect the concrete API/return contract.

### A-J3 — Low: remove stale design status and duplicated normative prose

Evidence: architecture :137 calls upload lifecycle still under design, :147–150 says develop backend/frontend, while those documents now declare reconciled contracts. Backend and frontend repeat detailed search/recovery/media rules despite declaring ownership boundaries; data-model mixes current requirements and explicitly historical measurements.

Recommendation: update stale status, keep each detailed contract in its owning document, and use short cross-links elsewhere. Retain current cross-layer acceptance criteria; remove repeated explanation and obsolete next-decision text. Historical interview references can remain as rationale, not an extra framework prescription. This is editing work, not a reason to add a specification generator.

### Challenges for Fable

- Is a public Content facade useful here, or would documenting selected submodule APIs be simpler? Challenge the indirection cost.
- Does unban require an explicit owner now, or is the existing atomicity rule enough? Show the smallest call path that preserves both contexts' ownership.
- The most complicated subsystem is video activation/recovery. Which complexity is removable without changing already agreed draft privacy, visibility, retry limits and retention? Defer the detailed answer to phase 2; do not call accepted behavior a framework violation.

## Fable (McCord lens) — Round 1

Independent read of software-architecture.md, backend-design.md, frontend-design.md and data-model.md as of 2026-09-20. Framework claims below were checked against the current hexdocs pages and the `phx.gen.auth` 1.8.1 template. No implementation exists; every item is a design risk unless marked otherwise.

### Verdict

Agree with Codex: the foundation is idiomatic Phoenix. One release, two contexts, `Repo.transact` per write, Oban in the same release, LiveView pages with function components, browser storage for drafts. Nothing here calls for a new service, process, or context.

The remaining problems are the opposite of missing architecture. Three places add machinery on top of what Phoenix and the guarded SQL already provide, and one of them produces a product-visible defect. Those are the blockers. Everything else in this round is editing.

### A-F1 — High: per-operation token resolution duplicates the SQL eligibility rule and departs from the generated auth convention

Evidence: backend-design.md:170 ("At admission of every mutation and privileged read, resolve the current session with the generated Accounts token query and build a fresh scope"); frontend-design.md:29 ("Keep the session token server-side in socket assigns ... one helper resolves the session through Accounts and builds a fresh scope"); data-model.md:36; software-architecture.md:83 ("A scope supplies identity and context; current permissions and guarded database writes still enforce the rules").

What the generated code does (`priv/templates/phx.gen.auth/auth.ex`, v1.8.1): `on_mount(:mount_current_scope)` reads `session["user_token"]` once, calls `get_user_by_session_token`, and assigns `current_scope`. The raw token is never placed in assigns. Revocation puts `live_socket_id` in the session and `disconnect_sessions/1` broadcasts `"disconnect"` on that topic through the Endpoint, which closes every LiveView socket for that token.

What the guarded SQL already does (data-model.md:25, rule 11; :782 "Moderation statements check the actor's role in SQL"): every write locks the user row and rechecks `ban`, `deleted_at` and `role` in the transaction. Every privileged read joins `users` for the role. Those checks read the current row, not a cached flag.

So the per-event token query can only matter when (a) the token was deleted, (b) the user row is still eligible, and (c) the disconnect broadcast did not arrive. (a)+(b) is "logged out elsewhere" or "email changed", neither of which changes what that user id may do. (c) on the agreed single node is an Endpoint-local PubSub broadcast; it cannot be lost unless the node is down, in which case the LiveView is gone too. The design adds a query per event, a raw token in assigns (which appears in crash reports and LiveDebugger), and a "one helper at every mutation" rule to cover a case that does not exist at this deployment.

Smallest fix: build `current_scope` once in `on_mount` as generated; keep the generated `disconnect_sessions` on ban, role change, email change and account deletion; let the locked user-row recheck in each write and the SQL role check in each privileged read be the current-eligibility boundary. Delete "resolve the session at every mutation" from backend :170, frontend :29 and data-model :36, and delete "keep the session token in socket assigns". Architecture :83 already states this rule correctly; the other three documents over-prescribe it.

Effects: removes one query and one helper call from every LiveView event handler, removes the raw token from process state, and matches what the generator emits so agent guidance and generated tests stay valid. No product change. This revises item 5 of the earlier adversarial phase-1 closure; that closure treated disconnect as unreliable without stating why it would be on one node.

### A-F2 — High: activation snooze on hidden content leaks shadow bans and protects a window the design already gives up

Evidence: backend-design.md:204 ("While an attached, nondeleted asset is temporarily hidden, snooze the same job for one hour ... Retrying while its job is live (including snoozed)"); :206 ("Restore may enqueue a first activation only when it never had a job"); :412 (unban enqueues first activations); data-model.md:761, :763; frontend-design.md:161 ("A scheduled visibility-only snooze still shows Retrying and may resume up to an hour after restoration").

Defect, product-visible: `shadowed_at` is a hiding cause (data-model.md:15, rule 1). A shadow-banned author's tip is inserted hidden, so its video's activation job snoozes hourly and the author-only status reads "Retrying" indefinitely. Data-model.md:498 spends a paragraph making a shadow ban invisible to its author (own vote counted, own review counted). The activation status undoes that for any tip or review with a video. This is a design contradiction, not an implementation bug, but it is deterministic.

Machinery cost: the snooze rule, the "restore enqueues a first job only if never enqueued" branch, the unban activation enqueue at :412, the Ready/Retrying/Failed derivation that must know about snoozed state, and the "verify snooze accounting against the pinned Oban release" acceptance item at :515 all exist to keep a hidden video private at the provider. But the design already accepts at :200, :246 and data-model.md:763 that hiding does not revoke an in-flight activation or an already-public link, and rule 8 (data-model.md:22) keeps R2 images at their key on kill. The window being protected is the seconds between commit and the first worker run, for content that was hidden in that window. Reader-facing pages already omit hidden media regardless.

Smallest fix: activation admission checks only that the media row exists with `cleanup_at is null`. Drop the visibility check, the snooze, the restore/unban enqueue branches and the snooze wording in author status. Author status becomes: Ready if `activated_at` set, Retrying if the job is live, Failed otherwise. Unban and restore touch no media rows.

Effects: backend :204, :206, :244, :412, data-model :761–763 and frontend :161 each lose a clause; the phase-2 lock-order work for unban no longer touches `media`. Product note for the owner: a video attached to content that a moderator hides before activation runs becomes playable by URL at Stream, exactly as an image hidden at any time is fetchable by URL from R2 today. If the owner wants provider-side privacy for moderator-hidden videos, that is a new requirement and should be stated as one; it still must not apply to `shadowed_at`, or the leak above returns.

### A-F3 — Medium: search runs twice on load and the second run replaces readable results with a loading state

Evidence: backend-design.md:55 ("run the same bounded `search_tips` synchronously in the disconnected mount ... Connected mounts and interactions use async work. Accept duplicate retrieval on initial connection"); frontend-design.md:17, :126; software-architecture.md:109.

Lifecycle per the LiveView docs: `mount/3` and `handle_params/3` run for the disconnected render, then run again in the connected process, whose `render/1` output replaces the static DOM. If the connected mount starts the search asynchronously, its first render has no results. The reader sees results, then a loading state, then results, and the embedding call and hybrid query run twice.

The dual path (sync in one mount, async in the other) buys nothing at this scale: the bounded search already has a 2 s statement timeout and a bounded embedding timeout (closure item 6). Running it synchronously in `handle_params` on both mounts is one code path, no flash, and the URL is the single source of truth for query, filters and page, which is what `handle_params` is for. Async stays where it earns its place: a submitted search or Load more from a connected page, with the agreed generation counter.

Smallest fix: "`handle_params` runs the bounded search synchronously; `handle_event` for submit and Load more uses `start_async`." Replace the two sentences at backend :55 and frontend :17. Duplicate retrieval on connect remains (inherent to LiveView) but with no visible flash.

Effects: one less branch in the search LiveView; the "ignore superseded completions" logic applies only to events. No product change.

### A-F4 — Medium: video processing state has three readers, one of them on the request path

Evidence: software-architecture.md:50 (webhooks: "Video → Processing events → Web"); backend-design.md:252 ("Reconcile missed events through Stream status reads"); :275 (`get_video_upload`: "Media reconciles stale processing state with Stream"); frontend-design.md:144 ("one five-second polling cycle through `get_video_upload` with fresh admission ... use LiveView async work for slow reconciliation").

A webhook updates the row. The editor polls every five seconds and, per :275 and :144, that poll may itself call Stream to reconcile. The maintenance queue also reconciles before cleanup (:196). So a provider read can be triggered by an open editor every five seconds, per processing video, and the LiveView needs async work to keep typing responsive while it happens. That is the provider call leaking into the page lifecycle the architecture says should stay in contexts and workers.

Smallest fix: the editor poll reads Postgres only. Webhooks are the primary writer. One bounded Oban maintenance scan reconciles rows stuck in `uploading`/`processing` longer than a threshold with a provider GET. `get_video_upload` never calls the provider. PubSub is not needed; a five-second DB poll from an open editor is cheaper than subscription plumbing plus a missed-event fallback.

Effects: frontend :144 loses "async work for slow reconciliation"; backend :275 loses the reconcile clause; the maintenance scan gains one predicate. Phase 2 owns the threshold. No product change.

### A-F5 — Low: live_session boundaries are deferred but they decide the editor exit behavior the frontend spends a paragraph on

Evidence: frontend-design.md:48 ("remaining LiveView boundaries are still to be designed"); :66 (live navigation between browse and search); :181 ("Use ordinary anchors in the editor layout for exits ... so a conditional native `beforeunload` handler covers full-page navigation ... Audit these exits for accidental live navigation").

Per the `live_session/3` docs: "Redirecting between `live_session`s will always force a full page reload and establish a brand new LiveView connection." The generator already emits `live_session :current_user` and `live_session :require_authenticated_user` with the matching `on_mount` hooks. If editors sit in the authenticated session and browse, search, tip and profile pages sit in the public one, every editor exit to a public page is a full page load by construction, and the "audit exits" task disappears.

Smallest fix: name four live sessions in the architecture now: public (`mount_current_scope`), authenticated (editors, inbox, settings), sudo (email change, account deletion, `require_sudo_mode`), moderator (queue and case pages, role check in `on_mount`). Phase 3 designs inside them.

Effects: also settles where admission hooks live, which the earlier closure carried to phase 3. No product change.

### A-F6 — Low: the deployment diagram omits the Cloudflare proxy and Turnstile the defenses depend on

Evidence: data-model.md:780 ("one rate limit per IP at Cloudflare ... Use Turnstile on sign-up"); software-architecture.md:39–57 and :131 show R2, Stream, embeddings, email, and no proxy in front of the app.

If the app origin is proxied, the release needs `RemoteIp` or equivalent for real client IPs in logs and the app's per-user limit, the WebSocket rides through Cloudflare's idle timeout (LiveView's default heartbeat covers it, but say so), and the health endpoint for Sentry's uptime check should bypass the proxy or the check measures Cloudflare. If it is not proxied, the per-IP rate limit and Turnstile need another home.

Smallest fix: one sentence in Deployment stating whether the app is behind the Cloudflare proxy, and adding Turnstile to the external integrations table.

### A-F7 — Low (owner's call): research provenance inside the architecture document

Evidence: software-architecture.md:11, :33, :105, :111–115, :146–174. The document names its sources by person fifteen times, keys five decisions to timestamps in a transcript that is not in the repository (:164), and carries a sources table and a transcript table. The decisions themselves are sound and stand without this apparatus. Codex A-J3 covers the same ground from the duplication side.

Recommendation: move Sources and Interview transcript to docs/brainstorm, keep the decisions with a one-line rationale each. The owner asked for this material explicitly, so this is their call, not a blocker.

### Responses to Codex Round 1

- A-J1 (Content boundary): Accept. The fix is one sentence: backend :61 should say the page calls `Content.search_tips`. Do not document submodule APIs as public. The context module is the boundary because generated tests, agent guidance and the scopes convention all assume it; internal modules stay internal until a second caller needs them. A facade that forwards is fine; a facade that re-validates is the failure mode Codex names.
- A-J2 (unban owner): Accept the ownership question, narrow the fix. `Accounts.lift_ban(scope, user_id)` owns the transaction and calls `Content.restore_for_unban(user_id)` inside it, an ordinary function that runs in the caller's transaction. That is the smallest call path and it is common Phoenix practice for cross-context writes. With A-F2 accepted, that helper touches tips and reviews only, which shrinks the lock order Codex flagged for phase 2.
- A-J3 (stale status, duplication): Accept. Editing work. My A-F7 is a subset.
- Codex's third challenge (video complexity, defer to phase 2): partially reject the deferral. The shadow-ban leak in A-F2 is an architecture-level contradiction between two agreed rules, so it belongs in this phase. The retry limit, retention and draft privacy at upload are unchanged by the fix.

### Remaining blockers to consensus, as I see them

1. A-F1: agree that admission uses the `on_mount` scope plus SQL rechecks, or show a revocation case on one node that the locked user row does not catch.
2. A-F2: agree that activation ignores visibility; the owner decides separately whether moderator-hidden videos need provider-side privacy.
3. A-F3: agree on synchronous `handle_params` search for both mounts.

A-F4 through A-F7 and A-J1 through A-J3 are editing items; I do not consider them blockers.

## Codex (Valim lens) — Round 2

The user has strengthened the method: each complexity hotspot gets its own five-to-fifteen-whys chain, then first-principles, Occam and 80/20 analysis. Removing a product guarantee is permitted as a *recommendation*, but must be labelled; it is not silently equivalent behavior. The chains below incorporate and challenge Fable's findings.

### A1. Context facade and cross-context transactions (A-J1, A-J2)

1. Why expose contexts? Callers need a stable business operation rather than knowledge of storage steps.
2. Why name helpers? Search/media have cohesive details that can grow independently.
3. Why can a facade become wasteful? If it merely repeats policy already enforced by another public route.
4. Why does unban cross boundaries? One account transition changes content eligibility.
5. Why must one operation own it? Partial success strands content or clears a restriction without restoring its effects.
6. Why not a coordinator/service? All required records share one Repo; an ordinary function can own the transaction.
7. Why add more layers? No independent lifecycle or deployment requirement remains; the root answer is unchanged.

**First principles:** a business transition has one atomic durable result; module names are code organization. **Occam:** accept Fable's illustrative `Accounts.lift_ban(scope, user_id)` calling a Content-owned transaction participant, with one outer transaction. **80/20:** fix the ambiguous entry-point sentences; do not scaffold an entire helper hierarchy. A-J1/A-J2 agreed. Nested public transactions are not independently atomic; [Ecto recommends composing within one transaction](https://ecto.hexdocs.pm/Ecto.Repo.html#transact/2-nested-transactions).

### A2. Per-operation authentication (A-F1) — reject claimed equivalence

1. Why re-resolve a token? Revoked authentication must stop newly admitted privileged work.
2. Why is a current eligible user row insufficient? The account may remain active after this particular browser's session is revoked.
3. Why not rely entirely on disconnect? Database commit and the subsequent broadcast are separate effects.
4. Why can that fail on one node? The *request process* can exit after committing revocation but before broadcasting while another LiveView and Endpoint remain alive. A whole-node failure is not required. Token expiry also need not coincide with an account-row change.
5. Why does this matter? A still-connected old session otherwise gains continuing access despite revocation.
6. Why query at render time or twice per event? Neither is required; check once at operation admission, then apply business eligibility under locks.
7. Why introduce a new auth system? None is needed: reuse generated Accounts resolution. Two further whys would not alter the admission boundary.

**First principles:** authentication of a particular session and authorization of an eligible account answer different questions. **Occam:** keep one shared boundary helper and the generated query; avoid a second token registry, epoch scheme or delivery-time check. **80/20:** query only mutations/privileged reads, not ordinary renders/public reads; redact credentials in diagnostics. The overhead is real but unmeasured here. A token in private assigns requires explicit redaction; deleting the check does not preserve the agreed revocation guarantee.

Fable's assertion that a single-node disconnect cannot be missed is false because it assumes request-process survival between commit and broadcast. A-F1 can be offered only as an explicit weakening of the session guarantee, not a High correctness fix. I recommend retaining the current guarantee. Acceptance: simulate commit followed by failure before disconnect, then invoke a new operation from the old socket.

### A3. Video privacy, activation and snoozing (A-F2) — reject the stated leak; consider the real tradeoff

1. Why have activation separate from readiness? A prepared draft must remain private until eligible publication commits.
2. Why use a worker? The database and provider cannot commit atomically.
3. Why inspect current visibility? A never-public hidden publication must not release its private draft at the provider.
4. Why retain attempts while hidden? The product caps automatic provider attempts; restoration must not reset failures.
5. Why is this costly? It combines provider privacy, temporary visibility and retry-budget rules across two stores.
6. Why cannot public-page masking replace it? Page masking does not prevent access through a retained provider URL.
7. Why distinguish an in-flight release? The explicit admitted-call exception is a bounded concurrency compromise, not permission to release every never-public hidden upload. Further whys leave this boundary unchanged.

**Factual correction:** new shadow-hidden publications receive *no activation job* (backend :194, :206, :244; frontend :161 explicitly says never-enqueued hidden attachments are neither Failed nor Retrying). Setting a ban does not retroactively set existing content's shadow marker (data-model :30). Therefore the described inevitable hourly-snoozed-job leak is not established. Deliberately hidden already-enqueued media may snooze, but that is a different case.

**First principles:** private draft versus public attached asset is the real product boundary. **Occam:** under the existing promise, retain one media row and one retained Oban job; do not add a second activation state machine. **80/20 alternative, explicitly a product change:** making *every committed attachment* public regardless of hiding would remove visibility snoozes and restore-time activation. It also releases never-public shadow/moderator-hidden video links, which the current contract explicitly forbids. This is a legitimate simplification option for the owner, not an equivalent fix and not a newly invented requirement. Recommend preserving existing privacy for this review's default, and documenting the cost/alternative. Phase 2 may find a smaller equivalent lifecycle.

### A4. Search mount lifecycle (A-F3) — narrow the fix

1. Why search in the disconnected lifecycle? Direct URLs must contain readable results.
2. Why retrieve again after connection? The new LiveView process does not inherit the disconnected process's assigns.
3. Why async connected work? Slow inference must not block interactions on a running page.
4. Why can the initial connected render flash empty? The new task has not completed and that process has no result list yet.
5. Why not make every parameter change synchronous? URL patches are connected interactions too; blocking them removes the responsiveness requirement.
6. Why not search both in an event and `handle_params`? Submission also patches the URL, so this creates duplicate triggers and divergent state.
7. Why introduce a cache/SSR handoff protocol? A single parameter-owned retrieval path and a small initial-load distinction suffice; more machinery does not change the root problem.

**First principles:** one canonical query/filter state and one retrieval trigger. **Occam proposal:** route-derived retrieval lives in `handle_params`; initial disconnected and first connected loads may be synchronous and bounded, while later parameter changes run asynchronously. Submit/Apply only patch normalized URL state; Load more runs the page-owned async continuation. **80/20:** no HTML-result serialization, snapshot cache or separate first-render search mode. This preserves responsive subsequent searches while avoiding an async empty first connected render. Discuss exact callback shape in phase 3.

I reject Fable's literal synchronous `handle_params` plus async submit event recipe: an event followed by its required URL patch can run the search twice. The flash is a risk of the specified lifecycle, not an observed browser defect; no application exists.

### A5. Three paths to video reconciliation (A-F4) — accept with a latency condition

1. Why webhooks? Provider preparation finishes outside the request.
2. Why poll the app? The composer needs fresh status and the design defers upload PubSub.
3. Why also read the provider? A webhook may be missed.
4. Why let each open editor do it? This gives prompt recovery but couples browser count to provider traffic.
5. Why is a periodic scan sufficient? Outstanding upload rows already identify incomplete work independently of browsers.
6. Why another queue? Existing bounded maintenance/media work can own reconciliation.
7. Why more mechanisms? No additional state owner is needed; the root remains durable reconciliation plus cheap UI reads.

**First principles:** provider truth becomes application state once; views read that state. **Occam:** accept DB-only `get_video_upload`, webhooks and one existing bounded Oban reconciliation scan. **80/20:** fewer network calls and no provider-wait task in each editor; retain the five-second database poll. Backend phase must define active-row selection/cadence so a missed webhook does not leave a ready upload waiting for the 48-hour cleanup horizon. This has a recovery-latency tradeoff, not a guaranteed zero-impact rewrite.

### A6. Auth route groups and editor exits (A-F5) — reject four prescribed sessions

1. Why use `live_session`? Routes can share mounting/authentication policy and live navigation.
2. Why full-page editor exits? Native leave warnings cover potentially lost local work.
3. Why would a session boundary help? Crossing it forces a new HTTP load.
4. Why does it not solve every exit? Editors, inbox and settings share Fable's proposed authenticated session; links among them can still live-navigate.
5. Why four sessions now? The actual grouping has not demonstrated a need for four; sudo checks do not inherently require a distinct session.
6. Why not explicit `href` for risky exits? That already covers cross- and same-session targets without more route groups.
7. Why add architecture to enforce it? A shared editor layout and a browser test are smaller; further whys do not change that.

**First principles:** admission policy and unsaved-work warnings are different concerns. **Occam/80–20:** start with generated route/auth conventions; add moderator/sudo hooks where required by operations. Keep intentional normal editor exit links and test them. Do not mandate four sessions or claim that doing so eliminates exit auditing. Exact route groups belong in phase 3.

### A7. Deployment edges and document drift (A-F6/A-F7/A-J3)

1. Why name the proxy and Turnstile? The abuse controls depend on them.
2. Why do they disappear from the overview? Requirements were added in lower-level documents.
3. Why does that matter? A release may satisfy the diagram while omitting a dependency.
4. Why not copy every deployment detail into every document? That created the current drift.
5. Why keep one ownership point? Implementers need one current operational contract with short links from defenses.
6. Why a new configuration framework? None is needed.
7. Why further prose? It cannot replace testing the actual deployment; the root answer is unchanged.

Accept one deployment clarification for Cloudflare proxy/origin reachability and Turnstile, plus stale-status editing. Do not require proxy bypass for the primary uptime probe: the public path is what visitors need to work, and the endpoint's database probe is already uncached by contract. A second direct-origin diagnostic is optional. The per-user limiter does not require real client IP; trusting forwarded IPs requires an explicit trusted-proxy boundary if those IPs are used. Turnstile also works on sites without Cloudflare proxying. These corrections narrow A-F6 rather than expanding scope.

Keep the explicitly requested research provenance accessible; moving it is optional document organization, not a blocker or a defect.

### Proposed phase-1 disposition

Agree A-J1/A-J2/A-J3, A-F4 with prompt bounded reconciliation, and the narrow deployment clarification. Reject A-F1's equivalence claim, A-F2's claimed deterministic leak and A-F5's four-session prescription. Carry A-F3's single retrieval-owner solution to frontend. Please rebut the concrete counterexamples, then explicitly ratify or identify remaining disagreements. These are disagreements about recommendations, not evidence that the monolith is incoherent.

## Fable (McCord lens) — Round 1 addendum: why-chains per hotspot (user steering, 2026-09-20; appended after Codex Round 2)

Method: one chain per hotspot, stop when two further whys leave the root unchanged, then first principles, Occam, Pareto. Each solution is tagged **preserving** (same product behavior) or **product cut** (owner decides). Root requirements are questioned, not only mechanics.

**H1. Token re-resolution at every mutation (A-F1).**
Why re-resolve? A long-lived LiveView could act on a revoked session. Why is that a risk? Ban, deletion or role change after mount. Why does that not hurt? Every write locks the user row and rechecks it; every privileged read checks role in SQL (data-model :25, :782). Why re-resolve anyway? Token deletion without a row change: logout elsewhere, email change. Why must that take effect before the next page load? Only if the generated disconnect broadcast fails. Why would it fail? Multi-node without a PubSub adapter, or the node is down. Why is that relevant to Tips? It is not: one VPS, one node (architecture :91, :131). Two more whys do not move this. Root: a rule written for a deployment Tips does not have.
Solution, **preserving**: scope once in `on_mount`, generated disconnect, SQL recheck. Root requirement check: "immediate revocation" is only required for bans and deletion, and SQL already delivers it.

**H2. Video activation with visibility snooze (A-F2).**
Why snooze when hidden? Keep a hidden video private at Stream. Why private at Stream? The draft-privacy contract (backend :244) was extended to hidden content. Why extend it? A hidden video's URL could be shared. Why does that matter when hidden images stay at their public key (data-model :22) and an in-flight activation is already allowed to finish (:763)? It does not; the policy is inconsistent. Why does activation exist at all? To flip Stream from signed-URL-only to public after commit. Why do drafts need signed URLs? So an unpublished video is not fetchable. Why is that needed when unpublished images are not even uploaded until submit, and the uid is a random identifier only the uploader holds? Only to protect against the uploader sharing their own draft link. Two more whys stay there. Root: activation is a second publication state machine whose only job is provider-side privacy for drafts, and that privacy has one beneficiary, the uploader, who already controls the link.
Solution A, **preserving** (A-F2 as written): activation ignores visibility. Removes snooze, unban/restore enqueue, snooze accounting test. Keeps `activated_at`, the job, statuses, operator retry.
Solution B, **product cut, owner's call**: drop draft video privacy. Create Stream uploads with `requireSignedURLs: false`; videos are playable by uid from upload, like images by key. Delete activation entirely: no `activated_at`, `activation_job_id`, Ready/Retrying/Failed status, ten-attempt budget, seven-day retention rule for that job, operator retry path, or the "omit until activated" projection rule. Public pages still omit unattached, hidden and deleted media; expiry cleanup still deletes unattached assets. What changes for the product: a video the author uploaded but never published is fetchable by anyone the author gives the uid to, until cleanup. Pareto: this is the largest single removal available in the design (backend :204–:212, :244, parts of :412; data-model :759–:763; frontend :161) for a privacy guarantee that protects the uploader from themselves. Recommend B.

**H3. Sync search on dead mount, async on connect (A-F3).**
Why async on connect? Keep the mount responsive. Why does that matter? Search may take the bounded 2 s plus embedding. Why is that acceptable on the dead mount? Readable initial HTML is required (architecture :119). Why is async worse on connect? Its first render has no results, so the readable list is replaced by a loading state, then restored. Why not sync on both? The dead render already paid the latency; the connected mount pays it once more either way. Two more whys unchanged. Root: async-on-mount solves a latency the design had already accepted.
Solution, **preserving**: synchronous search in `handle_params` for both mounts, async only for submit and Load more.
Root requirement check, **product question, owner's call**: is the embedding branch required at launch? The stated value is paraphrase matching for task-first queries (backend :17–:21), which BM25 alone will miss, so the requirement is real. But the embedding server is the only extra runtime container and the only unverified extension path (data-model :14). The acceptance list already demands a ten-query evaluation on the Docker image; make that evaluation the gate for shipping the container, not an afterthought. Keyword-only launch is a deferral, not a design change, because the query and fallback path already exist.

**H4. Three readers of video processing state (A-F4).**
Why poll from the editor? Publish is disabled until every video is ready. Why also reconcile with Stream inside the poll? A webhook may be missed. Why missed? Delivery is not guaranteed and the app may be down at delivery. Why fix that on the request path? So the author is not stuck at "processing". Why not fix it in the maintenance scan that already reconciles before cleanup? No reason; one predicate. Why have webhooks at all if a scan reconciles? Webhooks are push and give sub-second readiness. Why is sub-second readiness needed for a three-minute video that takes Stream on the order of a minute to encode? It is not. Two more whys unchanged. Root: two fallbacks for one failure mode, plus a push channel whose latency benefit nobody asked for.
Solution, **preserving** (latency only changes): no webhook endpoint. One Oban maintenance job every 30 s reads Stream status for rows in `uploading`/`processing` (a handful at MVP scale) and writes trusted `uploaded`, duration and state. The editor polls Postgres only. This deletes the signed-callback route, signature verification, and the duplicate/out-of-order callback rules at backend :250–:252, :280, :298 and data-model :753–:755. Worst case an author waits 30 s longer for Ready. If the owner wants webhooks later, they add a second writer to the same row; nothing else changes.

**H5. Submission key for publish retries.**
Why a key? A lost response must not double-post. Why not detect by content? Same text may legitimately be posted twice by one author across tips; a review is already unique per user per tip. Why a UUID column and unique constraint rather than a request log? One column and one constraint is the smallest idempotency mechanism there is. Two more whys unchanged. Root requirement stands. **Keep** as designed.

**H6. Three Oban queues, cron singleton for embeddings.**
Why three queues? Provider work, embedding inference and cleanup scans have different concurrency needs. Why not one queue? A stuck provider call would delay embeddings. Why does that matter at MVP volume? Marginally; but queue names are configuration, not code. **Keep**; zero machinery cost.

**H7. Preview for phase 3, recorded here so the chain is not lost: cross-tab draft conflict detection (frontend :171, :187).**
Why revision compare-and-set in IndexedDB? A stale tab could overwrite a newer draft. Why would it write? Autosave on input. Why does that lose work? The stale tab writes what the user currently sees in it, so the loss is text typed in the other tab. Why two tabs on the same editor? Rare and self-inflicted. Why not last-write-wins keyed by account and form? Discourse uses server sequence numbers because drafts sync across devices; Tips drafts are same-browser only. Two more whys unchanged. Root: an enterprise draft-sync guarantee applied to a single-browser convenience feature.
Solution, **product cut, owner's call**: last-write-wins per account and form; no revision, no conflict notice, no pause-autosave state. Phase 3 decides; noted now because it changes what the architecture promises about browser storage.

**Challenge to Codex's chain.** The Round 1 chain is global ("give each contract one owner") and stops at ownership. Ownership fixes duplication; it does not remove state machines. H2 and H4 show that two of the specialized machines Codex lists in why 1 exist for requirements that dissolve under questioning. I ask Codex to run per-hotspot chains on its own three findings and to take a position on H2 solution B and H4, since both change the backend surface Codex will review in phase 2.

**Revised blockers.** A-F1 (H1), A-F3 (H3), and a position from both reviewers and the owner on H2 (A or B) and H4. Everything else is editing.

## Fable (McCord lens) — Round 2: rebuttals, concessions, proposed closure

Rule applied: accept a Codex rebuttal only where the cited line or my own re-analysis confirms it. Per-hotspot chains are re-run where a concession changes the root.

### A2 / A-F1 — concede the overstatement, keep a narrowed finding

Codex is right that a request process can commit token deletion and exit before `disconnect_sessions/1` runs; single-node PubSub does not make the two effects atomic. My "cannot be lost unless the node is down" was false. Re-run chain from why 6: why would the window matter? A still-connected socket keeps acting under a revoked session until its next mount. Why is that bad? Email change and account deletion promise revocation of other sessions (backend :478, :500). Why not close the window by broadcasting inside the transaction? It narrows the race to client-reconnect versus commit but does not eliminate it. Two more whys leave the root: the design promises session revocation, and a promise needs a check at admission, not a probabilistic ordering.

Disposition: **withdraw A-F1 as High; accept the admission helper at mutations and privileged reads.** Retain one narrow amendment, **preserving**: do not keep the raw session token in socket assigns (frontend :29). The generated code never does; assigns appear in crash reports and debugging tools, and a session token is a bearer credential. Keep a non-secret identifier for the session row and resolve the user through it, or redact the assign explicitly. Phase 2 picks the query; phase 1 records the rule "no bearer secret in LiveView state." Not a blocker.

### A3 / A-F2 — retract the leak claim and Solution B; propose a preserving candidate for phase 2

Codex's factual correction holds: backend :194 enqueues only for an eligible publication, :206 and :412 give a never-enqueued attachment its first job on restoration or unban, and frontend :161 shows such an attachment by processing readiness, not Retrying. A shadow-banned author therefore sees a ready private preview, not a snoozed job. **The deterministic leak I claimed does not exist; A-F2 High is withdrawn.**

My H2 chain also stopped one why short. Why does draft privacy matter beyond the uploader's own link? Stream bills per minute stored and delivered; a public-by-default unpublished video is free hosting for any verified account until cleanup. That is a cost and abuse requirement, not self-protection. **Solution B (drop draft privacy) is withdrawn**, and Solution A is a product change, not preserving, because it would release never-public shadow-banned videos. Codex's labelling is correct.

What remains is the mechanism cost Codex's why 5 names: retry budget, temporary visibility and provider privacy tracked across the media row and a retained Oban job (snooze, `activation_job_id` surviving pruning, Failed derived from missing history, backend :204–:206, data-model :761). Re-run from first principles: the durable facts are "activated or not", "attempts used", and "permanently failed". All three fit on the media row. Candidate, **preserving**, for phase 2: an `activation_attempts` counter (and a terminal failure marker) on `media`; every transition to live enqueues an activation job unique on media id; the worker exits without a provider call when the content is not live, exits terminal when attempts are exhausted or the failure is permanent, and otherwise increments the counter before calling Stream. No snooze, no job id on the row, no dependence on job retention for author status, operator retry resets the counter. Same guarantees: private until live, ten attempts total, no budget reset on restore. Phase 2 checks it against the lock order and the crash-on-last-attempt case. Not a phase 1 blocker.

### A4 / A-F3 — accept the narrowing

Confirmed against the design: submit must patch the URL (frontend :66, :70), so an event that also retrieves would double-run. Frontend :126 requires responsive controls during a submitted search, which a synchronous `handle_params` on a connected page would violate. **Accept Codex's proposal**: retrieval is owned by `handle_params`; the disconnected load and the first connected load run synchronously and bounded; later parameter changes start async work from `handle_params`; submit and Apply only patch normalized URL state; Load more is the page-owned async continuation. This keeps one trigger, no empty first connected render, and the agreed responsiveness. The flash was a lifecycle consequence, not an observed defect; agreed. Callback shape to phase 3.

### A5 / A-F4 — agreed; one open choice for phase 2

Agreed: provider truth becomes application state through workers; `get_video_upload` reads Postgres only; the editor keeps its five-second database poll. My addendum H4 goes one step further and drops the webhook endpoint in favour of a bounded scan every 30 seconds over rows still in `uploading`/`processing`. Codex's A5 keeps webhooks plus the scan. Both satisfy phase 1. Phase 2 decides on evidence: count the paragraphs that exist only for signed callbacks, duplicates and ordering (backend :250–:252, :280, :298; data-model :753–:755) against the readiness latency a 30-second scan adds. My recommendation stands; it is not a blocker.

### A6 / A-F5 — concede

Correct: editors, inbox and settings would share a session, so the boundary does not cover those exits, and sudo is an `on_mount` hook, not a session. Withdraw the four-session prescription. Phase 1 records only: editor exits use plain anchors and a browser test (frontend :181 already says so); route groups and hooks are phase 3.

### A7 / A-F6, A-F7 — accept the narrowing

Agreed: one sentence on proxy and origin reachability plus Turnstile in the integrations table; uptime probe through the public path; per-user limiter needs no client IP; forwarded IPs need a trusted-proxy boundary only if used. Provenance placement is optional.

### Challenge to Codex's chains

Codex's A3 chain stops at "a never-public hidden publication must not release its draft" without naming why. The root is metered delivery cost and hosting abuse; naming it matters because it decides that shadow-banned uploads must stay private while a moderator-hidden-after-publish video may already be public. That distinction is what the phase 2 candidate above relies on. Otherwise the Round 2 chains are sound and I have no further objection.

### Proposed phase 1 closure

Consensus reached at round 2, subject to Codex's ratification. Later phases refine but do not contradict.

1. One Phoenix release, `Tips.Accounts` and `Tips.Content`, `Repo.transact` per write, Oban in the release, LiveView pages with function components, browser-only drafts. No new service, process, context, facade layer, workflow or authorization framework.
2. The public `Content` functions already named in the backend design are the web boundary; helpers are internal until a second caller needs them. Backend :61 is corrected to call `Content.search_tips`.
3. `Accounts.lift_ban(scope, user_id)` owns the unban transaction and calls a Content-owned participant inside it. No coordinator.
4. Admission: `current_scope` from the generated `on_mount`; one helper re-admits mutations and privileged reads through the generated session query; public reads unchecked; no bearer secret kept in LiveView assigns.
5. Video activation keeps draft privacy, ten total attempts and no budget reset on restore. Phase 2 evaluates the row-held attempt counter as the replacement for snooze and job-id retention.
6. Search retrieval is owned by `handle_params`: synchronous and bounded for the disconnected and first connected load, async for later parameter changes; events patch the URL; Load more is an async continuation.
7. Video processing state is written by workers only; `get_video_upload` reads Postgres; phase 2 decides whether the webhook endpoint stays or a bounded scan replaces it.
8. Route groups, `on_mount` placement and editor-exit mechanics are phase 3; plain-anchor exits and a browser test are already agreed.
9. Architecture states whether the app origin is behind the Cloudflare proxy and lists Turnstile; uptime probe uses the public path.
10. Editing: stale status lines, duplicated contract prose and optional provenance relocation.

Product questions for the owner, none blocking: gate the embedding container on the ten-query evaluation before launch (keyword-only otherwise); last-write-wins for same-browser draft tabs (phase 3).

Unresolved: none from my side.

### Fable Round 2 addendum — corrections requested by Codex

Read Round 2 before writing the section above; the F1 and F2 equivalence claims are withdrawn there, not repeated. Three points needed more precision.

**H4 scan-only option, made concrete.** Open-source `Oban.Plugins.Cron` schedules at minute granularity; a 30-second tick is not a supported cadence. Revised option: one `* * * * *` cron job in the `media` queue, unique on active states so ticks cannot stack, `max_attempts: 1`. Each tick selects at most 50 rows in `uploading` or `processing` with `cleanup_at is null`, oldest `created_at` first, and skips rows whose `reconcile_after` is in the future. One bounded provider GET per row; a failed or timed-out GET sets `reconcile_after = now() + 5 minutes` on that row and the tick continues. Trusted `uploaded`, duration and terminal state are written with the same row guard as a callback would use. **Tradeoff, labelled**: readiness appears up to about 60 seconds after Stream finishes, instead of sub-second with webhooks; with 50 rows per minute the scan covers MVP volume many times over, and a backlog beyond that only delays readiness further, never loses it. Recommended default: scan only, because it deletes the signed-callback route, signature verification and the duplicate/out-of-order rules. Alternative, labelled: keep webhooks as a second writer of the same rows for faster readiness. Either satisfies closure item 7.

**Draft video privacy, reclassified.** Making unpublished videos public by uid removes confidentiality for everyone, not only for the uploader who shares deliberately: any leak of the uid, including from logs, a screenshot or a browser history, exposes content the author never published. It is a **scope cut** with a confidentiality and a metered-cost consequence. Recommended default: keep draft privacy (closure item 5). The cut is recorded as an alternative only.

**Cross-tab draft conflicts, cost assessed.** Loss scenario under last-write-wins: tab A holds an older copy; the author types in tab B; returning to A and typing one character autosaves A's full form values over B's additions, silently. The guard that prevents it is one integer revision compared inside the IndexedDB transaction the hook already runs, plus one paused-autosave state and one reload notice. That is tens of lines against silent loss of written work. Recommended default: keep the revision guard as designed (frontend :171, :187). Last-write-wins is recorded as a labelled scope cut, not recommended. My H7 chain undervalued the loss; corrected.

**Closure list amendments.** Item 7: recommended default is the minute-cadence scan above, webhooks as the labelled alternative. The two "product questions for the owner" become: recommended default keep the embedding container, with the ten-query evaluation as the launch gate; recommended default keep the cross-tab guard. No owner decision is required to close phase 1.

## Codex ratification — phase 1 complete in 2 rounds

I accept Fable's Round 2 concessions and the ten-point closure with three wording corrections that follow the preceding debate:

- Item 4: the requirement is preventing credential disclosure, not mandating a second session lookup architecture. Fable's preceding text allowed an explicitly redacted private token **or** a server-derived non-bearer session reference. Phase 2 selects the smallest mechanism preserving generated expiry/revocation semantics. Never accept a client-supplied row id as session authentication.
- Item 7: Media owns durable processing state; the editor reads Postgres only. Whether updates arrive through a verified callback or only worker polling remains the explicit phase-2 comparison. Calling it "workers only" before making that choice would prematurely exclude callbacks.
- The search deployment evaluation is required validation. Launching keyword-only is an explicit product-scope alternative if hybrid search is not viable, not automatic permission to discard the agreed search capability. Likewise last-write-wins drafts are only a phase-3 candidate.

Confidentiality of unpublished drafts is sufficient reason for private media; reduced abuse is an additional consideration, not a proven sole historical requirement. Signed playback alone does not eliminate upload/storage abuse. Retain the existing privacy default while testing the simpler activation candidate.

**Consensus:** the architecture is cohesive. Clarify public operation ownership and unban transaction ownership; give search one parameter-owned retrieval path; remove provider reads from editor status polling; state deployment dependencies once. Keep session revocation enforcement. No architecture rewrite is recommended. Backend and frontend choices listed above remain scoped work for their phases, not unresolved phase-1 disagreement.

Source designs were not changed. This is a design review, not implementation or runtime validation. Read this closure and Fable Round 2 together; withdrawn Round 1 claims must not become implementation tasks.
