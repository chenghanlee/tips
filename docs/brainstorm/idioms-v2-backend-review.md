# Fresh Elixir/Phoenix idioms review — backend

Date: 2026-09-20. Status: consensus after two paired rounds.

## Review agreement

Review the current revised documents in `docs/design/technical/`, including `data-model.md` for cross-document consistency. The existing `idioms-*-review.md` records are prior history, not proof that a choice is correct. No Mix project, Elixir source or frontend implementation was found: this is a design and proposed-implementation review, not a runtime audit. Do not modify source design documents during this review.

Codex uses a José Valim-inspired lens: plain functions/data, explicit effects, justified process lifetimes and minimal mechanisms. Fable in Herdr pane `wJ:p1` uses a Chris McCord-inspired lens: Phoenix/LiveView conventions, framework facilities and complete browser/product behavior. Neither is the real person's analysis or endorsement.

Review phases sequentially: architecture, backend, frontend. Each phase ends at explicit bilateral consensus or ten paired rounds; record unresolved objections at the cap. Append under your own reviewer heading. Independently inspect evidence, then challenge each other's finding and proposed remedy. A recommendation must survive local correctness, direct/downstream effects and whole-system fit.

For each unusual/complex choice, ask 5–15 whys, stopping when two more do not change the root answer. Apply first principles, Occam's razor and Pareto's 80/20: identify the smallest working solution and the machinery it actually removes. Distinguish a convention violation, a justified exception, an implementation hazard and an optional product change. Product rules can be challenged, but label the behavior lost; do not call a scope cut equivalent. Use current primary framework/provider evidence for uncertain claims. Do not manufacture findings or consensus for round-count targets.


## Reviewed source snapshot

Same hashes as the architecture file, verified before this round: backend `e3261d49…`, data-model `c4d39dea…`, frontend `5719aec9…`, architecture `97d6cb9d…`. Reviewed branch: always-private Stream assets with locally signed playback through a redirect route (phase-1 closure item 3). No source edits.

## Fable (McCord lens) — Round 1

### B-F1 — High, applies the owner decision: the exact activation delta

Phase 2 needs the concrete list so the reconciliation touches nothing else.

Remove from backend: the "Activate video playback" row (:220); the activation-status sentence in :228; :230 and :232 entirely; the activation clause in :238; in :270 everything after "Provider visibility changes happen outside the database transaction" through "Public projections continue to omit unavailable videos"; :272 ("no expiring public playback tokens") and its saved-link sentences; the activation enqueue in :448; the URL-construction sentence in :88. Remove from data-model: `activated_at` and `activation_job_id` (:220–:221) and their clauses in `media_storage_chk` and `media_lifecycle_chk` (:229, :244); the projection columns in :486; :759 and :761; the activation items in :969. Remove from frontend: :187 except its last sentence about cleanup-marked and expired uploads. Remove the Oban snooze reference (backend :568).

Add: `requiresignedurls` in the reservation `Upload-Metadata` at creation, which the design already implies for private drafts, so the visibility path has zero provider writes; one signing key from the Stream keys endpoint in release config; one controller route that resolves the media row, applies the shared Content visibility policy for the caller, signs a token with a short `exp`, and redirects. Provider interactions left in the whole design: create reservation, read status, delete asset.

Keep unchanged: `state`, `completed_at`, `expires_at`, `cleanup_at`, the readiness scan, "publish only when playable", author preview authorization, deletion and cache purge.

Whys, short because the architecture chain already ran: (1) Why a route rather than a token in the page? A token in HTML expires while the page is open and leaks into copied links. (2) Why check visibility at click? It is the only moment the app is asked, and it makes hide/delete effective without any provider write. (3) Why a short `exp`? A signed Stream URL copied from the address bar is the only expiring artefact; short is safer and costs nothing because the app link is stable. (4) Why not sign at publish and store the token? It would recreate a provider-synchronized visibility fact in the database. (5) Why stop? Two more whys return to "visibility is a database fact rendered on demand".

Hazard to verify in phase 2: the Stream watch page must accept the token form for the customer host in use; the docs list it, the integration test proves it. Downloads stay disabled.

### B-F2 — Medium, preserving: the smallest admission mechanism is the server-derived token row id

Evidence: backend :190–:192; architecture :50; prior ratification item 4 allows "a server-derived non-bearer session reference" and forbids only a client-supplied id.

Whys: (1) Why re-admit at each mutation? Revocation must hold even if the disconnect broadcast is lost. (2) Why not the raw session token in assigns? It is a bearer secret; the design then needs redaction rules for logs, inspection and error reporting. (3) Why not the user id alone? It cannot see token deletion. (4) What identifies the session without being a bearer? The `users_tokens.id` of the row the generated `on_mount` already loaded at mount. (5) Why is that safe? LiveView assigns never reach the browser; the id enters assigns from the server's own lookup, never from params or the client. (6) Why is it smaller? One primary-key lookup joined to `users`, filtered by `context = 'session'` and the generated validity window, returns a fresh scope; no redaction rule, no second token registry, no change to the generated plug. (7) Why stop? Further whys re-derive the generated lifecycle, which this keeps intact.

Smallest fix: after the generated `mount_current_scope`, put the token row id in a private assign; the admission helper runs `from t in UserToken, where: t.id == ^id and t.context == "session" and t.inserted_at > ago(@validity, "day"), join: u in assoc(t, :user)` and rebuilds the scope. Deleted token, deleted user, ban or role change all surface on the next mutation. Controllers keep the generated per-request plug. Behavior lost: none. Downstream: backend :190's "explicit redaction from inspection, logs and error reporting" shrinks to "no token in assigns".

### B-F3 — Low, preserving with a labelled loss: registration reclaim duplicates the cleanup job

Evidence: backend :479 ("Registration must also reclaim an expired unconfirmed row ... so the cleanup schedule does not extend a reservation"); data-model :334 ("Lock multiple conflicting identities in id order"); acceptance backend :550, data-model :970.

Whys: (1) Why reclaim inside registration? A handle or email held by an expired unconfirmed row should not block a new signup. (2) Why would it block? The maintenance job has not yet deleted the row. (3) Why not? Its cadence is unspecified. (4) Why not specify it? An hourly bounded delete is one cron line. (5) Why is reclaim costly? It puts a multi-row lock order, token deletion and a delete inside the registration transaction, the one path exposed to anonymous traffic behind Turnstile. (6) Why stop? Two more whys return to "reclaim compensates for an unspecified cadence".

Smallest fix: hourly maintenance cleanup; registration reports the handle or email as taken during the lag. Verification keeps rejecting expired registrations, so the security property is unchanged. Behavior lost: a handle can stay unavailable up to one hour past its seven-day expiry. Removes the reclaim path, the multi-identity lock ordering in registration, and the reclaim acceptance items.

### B-F4 — Keep, justified exception: counter triggers, with the write graph enumerated

Codex A-J3 asked for the whole write graph. Writers of `votes` and `reviews` that change a counter: publish tip (self-vote insert), publish review (review insert plus self-vote), `set_vote` (insert, update, delete), author review deletion (`deleted_at`), moderator hide/restore review (`dead_at`), shadow-ban bulk vote invalidation (`dead_at` on votes), unban (`shadowed_at` cleared on reviews). Seven paths, four set-shaped. `prepare_changes/2` covers three of them. Triggers keep one delta rule; the cost is the parent-prelock rule for bulk operations that the prior review's B-F1 already established and that Codex is clarifying this round. Keep.

### Not raised

Collapsing `author_revision` (prior B-J6, withdrawn as not worth a round); the retained Oban job for activation (moot under B-F1); webhooks (already removed); per-row embedding jobs (already removed).

### Challenges requested from Codex

B-F2: whether the generated `UserToken` query can be adapted by id without touching the generated plug, and whether ratification item 4's "server-derived reference" was meant to include it. B-F3: whether one hour of handle unavailability is acceptable, or whether the owner wants the reclaim path kept. B-F1: any provider interaction I missed that the signed branch still needs.

## Codex (Valim lens) — Round 1

### B-J1 — Medium simplification: no remote rediscovery for never-released upload URLs

Evidence: backend :278–282 versus :310. The latter persists the uid before releasing the endpoint; the former treats NULL uid as an unknowable completed upload. Those cannot both describe this protocol.

Whys: (1) Why rediscover a remote asset? Provisioning can time out after reservation creation. (2) Why assume uploaded bytes? Generic unknown-outcome reasoning omitted the browser handoff. (3) Why can the browser not upload here? It never received the endpoint before uid persistence. (4) Why retain a recovery query? Only if an endpoint escaped through another path, which should be forbidden. (5) Why distinguish a late provider response? It may race local expiry. (6) Why a new coordinator? One conditional row update already serializes the transition. (7) Why stop? The root is confusing reservation creation with transfer authorization.

Smallest solution: create one fixed-deadline row; provision with server-owned privacy/duration/expiry; persist the provider uid only when still NULL, not cleaned/expired, and before that original deadline; only a successful committed persistence permits returning the URL. Never clear a persisted uid. Disable automatic creation retries; an explicit fresh upload uses a new row. Expired NULL-uid rows fail locally, without provider lookup/deletion jobs that lack an identifier. Keep failed attachment feedback. Known-uid uploads still require trusted completion/readiness reconciliation and existing cleanup. Late responses that lose the guard never expose URLs. This removes an entire lookup/recovery branch without dropping uploaded data.

Provider basis: [direct creator upload metadata](https://developers.cloudflare.com/stream/uploading-videos/direct-creator-uploads/#upload-metadata-header-syntax) sets expiry on the initial request; [tus response guidance](https://developers.cloudflare.com/stream/uploading-videos/resumable-uploads/#get-the-video-id-when-using-tus) supplies `stream-media-id` rather than parsing the URL. The documented reservation-release guarantee is not a guarantee that all empty provider metadata disappears. Verify the configured one-hour tus expiry against the integration; do not infer numeric default/maximum values the API reference does not state.

### B-J2 — Medium clarification: a review visibility mutation must prelock its tip

Evidence: backend :194 includes implicit trigger locks, but :196 abbreviates author deletion to “account and affected content”; data-model :316–324 updates the parent tip whenever review liveness changes. Read literally as only the deleted review, the operation locks review then tip, reversing the stated order. This is an ambiguous implementation instruction, not a demonstrated runtime deadlock in absent code.

Whys: (1) Why lock a parent for review deletion? The counter trigger writes it. (2) Why can a local-looking delete deadlock? Its implicit tip lock can oppose a bulk tip-then-review writer. (3) Why lock every tip for every review operation? Unnecessary: count-only/text-only review changes return before the tip update. (4) Why a generic lock planner? The small write graph is already known. (5) Why remove the trigger? That spreads the same invariant across seven paths. (6) Why stop? Make actual write dependencies explicit, preserving one owner for the invariant.

Smallest fix: one short operation table: review insert/hide/restore/delete prelocks required accounts, then tip, then existing review; text/media edits and review votes need no ancestor lock when they do not change liveness; bulk operations prelock all actual trigger targets in id order after subject-account discovery guards. Moderator/author entry points use the same rule. A focused two-transaction integration test should cover opposing single-review visibility and bulk operations. Do not add retries or lock all ancestors indiscriminately.

### B-J3 — Keep submission keys and two revisions, using Ecto/Postgres

Submission-key whys: (1) Why UUID? A lost response must identify the original publication. (2) Why not body equality? Authors may intentionally post similar text. (3) Why not process memory? It dies on remount/restart. (4) Why a unique index? Concurrent retries must resolve to one committed row. (5) Why an HTTP-idempotency library? It introduces response caching/lifetimes unrelated to this durable business identity. (6) Why stop? A UUID plus named database constraint and authorized lookup is the minimal rule.

Revision whys: (1) Why edit version? Reject stale author/moderator changes. (2) Why author revision too? Only author edits permit a fresh report. (3) Why not one integer? Moderator retag/media removal changes edit state but must not reopen report eligibility. (4) Why full history? Neither rule requires storing past content. (5) Why a versioning library? It adds history and callbacks without removing these distinct meanings. (6) Why stop? Two integers encode two real facts with ordinary changesets/conditional writes. Keep Ecto optimistic locking where appropriate and the report uniqueness constraints.

### Counter-review of Fable Round 1

**B-F1 accepted**, including the click-time route, with concrete bounds. Use a plain controller calling a Content media-access function; load current visibility/ownership, reject cleanup-marked or ineligible assets, sign locally, redirect only to the configured customer host. Do not let the client supply a provider uid/redirect destination. Set the redirect response `Cache-Control: private, no-store` so browser/CDN caches do not bypass future authorization or reuse expired tokens. The signed provider URL is a bearer capability: already issued links can work until expiry even after hide; deletion remains asynchronous. A 1-hour token is a reasonable initial bound for three-minute videos; reopening the app link obtains a fresh one. No token table, renewal task, per-view Oban job or API call for each token.

Use the established [JOSE JWT signing API](https://jose.hexdocs.pm/JOSE.JWT.html#sign/3) with the provider's RSA key/RS256 claims. `Phoenix.Token` is not the provider's JWT protocol. Keep keys server-side; missing/broken key configuration returns an operational error, never a public uid URL. Tokens need not be stored in Postgres or browser drafts. Verify signed watch-page and thumbnail URLs in the real integration: the fetched provider examples clearly show iframe/manifest substitution, but did not conclusively demonstrate `/TOKEN/watch`. If that endpoint fails, choose the documented hosted-player destination in a new tab; do not rebuild an activation workflow. Thumbnail authorization also needs coverage so private assets do not become broken bare-uid previews.

**B-F2 accepted as a concrete implementation candidate already permitted by the contract**, with corrections. The generated scope query does not necessarily return a token row id; inspect/adapt the generated Accounts lookup once to return both authenticated identity and the trusted session reference. Keep one validity definition shared with generated authentication rather than copying `@validity` into a second module. Re-admission must bind the reference to its mounted user and retain context/expiry/revocation and current eligibility. A private assign is a convention, not a guarantee against application inspection/logging; session references still do not belong in client events or templates. No need for a bearer credential in long-lived assigns once this is implemented. Do not promise an unchanged generated hook/query.

**B-F3 is optional, not equivalent; keep inline reclaim as the selected contract.** Hourly scheduling does not bound lag to one hour: queue backlog, outages, failed sweeps and bounded batches can delay it further. The requirement explicitly says expiry releases the handle/email without waiting for cleanup. Removing reclaim relaxes that rule and changes signup feedback, including repeated “already registered” responses for an expired email. Record this product cut as an optional simplification only; no extra user question is needed to finish the review. Reuse one guarded expiry operation for reclaim and sweep rather than duplicating rules.

**B-F4 accepted**, with B-J2's targeted parent-prelock clarification. Trigger use itself is justified; no new counter library or process is warranted.

Please challenge these findings/remedies and ratify or identify the remaining disagreement. Signed playback supersedes activation-budget debates completely.

## Fable (McCord lens) — Round 2: counter-review, ratification, proposed phase-2 closure

**B-J1 — accept as written.** It matches the phase-1 guard. One addition: because the endpoint is returned only after the committed uid persist, the provisioning row needs no `checked_at` rotation and never enters the status scan; the scan's candidate predicate becomes `stream_uid is not null` in addition to the existing state and cleanup conditions. Prior backend Round 2 correction 1 (null-uid rows keep a correlation path) is superseded by this branch.

**B-J2 — accept.** The `review_counts` trigger (data-model :316–:324) writes `tips` on every liveness change, so any operation that changes a review's `deleted_at`, `dead_at` or `shadowed_at` acquires the tip lock implicitly and must take it explicitly first: accounts, tip, review. Text/media review edits and review votes do not change liveness and need no tip lock. The one-table remedy is right; the two-transaction integration test belongs in the backend acceptance list. Not a demonstrated defect, an ambiguous instruction; agreed.

**B-J3 — accept.** Submission keys and the two revisions stay; no idempotency or versioning library.

**B-F1 corrections — accept all.** Plain controller calling one Content media-access function; client supplies only the media id; `Cache-Control: private, no-store` on the redirect; JOSE RS256 with the Stream key, not `Phoenix.Token`; issued tokens are bearer capabilities that survive hide until expiry, which is the stated downside and needs a sentence in the reconciled design; one-hour `exp` initially; broken key configuration returns an operational error. On the `/TOKEN/watch` form: the securing-your-stream page I fetched in phase 1 lists it verbatim alongside iframe, manifests and downloads, so the integration test confirms rather than discovers it. Thumbnails: same route pattern or no thumbnail at all; I take that to phase 3 as a frontend choice because it decides what a video attachment looks like on the page.

**B-F2 corrections — accept all.** The generated lookup is adapted once to return identity plus the session token row id; validity is one shared definition in Accounts; re-admission binds the reference to the mounted user; no promise that the generated hook is untouched; the reference stays out of client events and templates.

**B-F3 — accept Codex's disposition.** Inline reclaim remains the selected contract; hourly-cleanup-only is recorded as an optional product simplification with the lag and signup-feedback losses named. One guarded expiry operation serves both reclaim and sweep.

**B-F4 — closed with B-J2.**

### Proposed phase-2 closure

1. Signed playback branch adopted: assets private for life via `requiresignedurls` at reservation; one controller route, one Content media-access function, JOSE RS256 with the Stream key, one-hour tokens, `private, no-store` redirects; issued tokens survive hide until expiry, stated as accepted behavior. Activation jobs, columns, status, snooze, budget, operator activation retry and unban/restore enqueues removed per the B-F1 line list. Readiness scan, 1-hour/48-hour deadlines, authorized previews, deletion and purge unchanged (B-F1).
2. Null-uid provisioning rows: fixed deadline, conditional uid persist before the deadline, URL returned only after committed persistence, uid never cleared, no creation retries, local failure at expiry with no provider lookup; such rows never enter the status scan (B-J1).
3. Lock sets by operation: review liveness changes prelock accounts, tip, review; non-liveness review edits and review votes take no tip lock; bulk operations prelock all trigger targets in id order after subject-account discovery; one focused two-transaction test (B-J2, B-F4).
4. Admission: generated lookup adapted once to return identity plus the session token row id; re-admission by that server-held reference under one shared validity definition; no bearer secret in assigns (B-F2).
5. Submission keys, `edit_version` and `author_revision` stay as designed; counter triggers stay (B-J3, B-F4).
6. Inline registration reclaim stays; hourly-only cleanup is an optional product simplification, not adopted (B-F3).
7. Video thumbnail presentation under private assets goes to phase 3.

Source designs unchanged. Unresolved from my side: none. On Codex's ratification, phase 3 begins in `idioms-v2-frontend-review.md`.

## Codex (Valim lens) — Round 2: ratification

Ratified the seven closure items. Consensus after two paired rounds; no unresolved design objection. Provider integration, generated-query adaptation and concurrency tests remain implementation evidence to obtain, not checks claimed to have run. Signed `/watch` support remains explicitly on that integration list despite our different readings of the provider page. Start phase 3.
