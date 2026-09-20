# Fresh Elixir/Phoenix idioms review — frontend

Date: 2026-09-20. Status: consensus after two paired rounds.

## Review agreement

Review the current revised documents in `docs/design/technical/`, including `data-model.md` for cross-document consistency. The existing `idioms-*-review.md` records are prior history, not proof that a choice is correct. No Mix project, Elixir source or frontend implementation was found: this is a design and proposed-implementation review, not a runtime audit. Do not modify source design documents during this review.

Codex uses a José Valim-inspired lens: plain functions/data, explicit effects, justified process lifetimes and minimal mechanisms. Fable in Herdr pane `wJ:p1` uses a Chris McCord-inspired lens: Phoenix/LiveView conventions, framework facilities and complete browser/product behavior. Neither is the real person's analysis or endorsement.

Review phases sequentially: architecture, backend, frontend. Each phase ends at explicit bilateral consensus or ten paired rounds; record unresolved objections at the cap. Append under your own reviewer heading. Independently inspect evidence, then challenge each other's finding and proposed remedy. A recommendation must survive local correctness, direct/downstream effects and whole-system fit.

For each unusual/complex choice, ask 5–15 whys, stopping when two more do not change the root answer. Apply first principles, Occam's razor and Pareto's 80/20: identify the smallest working solution and the machinery it actually removes. Distinguish a convention violation, a justified exception, an implementation hazard and an optional product change. Product rules can be challenged, but label the behavior lost; do not call a scope cut equivalent. Use current primary framework/provider evidence for uncertain claims. Do not manufacture findings or consensus for round-count targets.


## Reviewed source snapshot

Same hashes as the architecture file, verified before this round: frontend `5719aec9…`, backend `e3261d49…`, data-model `c4d39dea…`, architecture `97d6cb9d…`. Reviewed under the phase-1 and phase-2 closures: private Stream assets with click-time signed redirects; no activation state. No source edits.

## Fable (McCord lens) — Round 1

### Verdict

Streams for lists, `handle_params` as the single retrieval owner, named `start_async`, function components with one page LiveView owning form state, built-in uploads for images and external uploads for video, `to_form` with blur-debounced validation and `used_input?`, plain anchors for editor exits: all conventional LiveView 1.x. The remaining complexity sits in the browser draft store, which is the only place the frontend implements its own concurrency control.

### F-F1 — Medium, preserving the guarantee by exclusion instead of detection: replace the IndexedDB compare-and-set scheme with a Web Lock per draft

Evidence: frontend :191 (inspect DOM before the asynchronous read, track typing during the read, do not disable the editor for the read), :193 (disable the fieldset during restore, ignore late results after hook replacement), :197 (`(draft_id, revision)` compare-and-set inside one IndexedDB transaction, same guard for discard and post-save clearing, missing record is a conflict, concurrent first creation must detect an occupied key), :213 (conflict UI: pause autosave, explain, offer reload), :253 (browser tests for discard/recreate at the same revision, stale post-save clearing, typing during restore); backend :320.

Whys:
1. Why compare-and-set on every autosave? A stale tab must not overwrite or clear a newer draft.
2. Why can a tab be stale? Two tabs of the same browser and account can hold the same draft, because the store is per account and form, not per tab.
3. Why detect rather than prevent? IndexedDB has transactions, so detection was the tool at hand.
4. Why is detection costly? Every write carries a revision, every clear carries a guard, a missing record must be classified, first creation must race, and the hook needs a conflict state, a reload action and tests for each stale path. The asynchronous read also forces the "typed before the read finished" protocol in :191 and :193.
5. What prevents two writers instead? The Web Locks API: `navigator.locks.request(key, {ifAvailable: true}, cb)` grants one tab an exclusive lock per origin for the lifetime of the callback's promise, and the browser releases it when the page is closed or its context destroyed. It is baseline widely available since March 2022 ([MDN](https://developer.mozilla.org/en-US/docs/Web/API/Web_Locks_API)).
6. Why does that shrink the store? With one writer per draft, the record needs no revision. A synchronous `localStorage` read in `mounted()` is sufficient, which removes the asynchronous-read protocol: read, compare with the rendered baseline, restore if pristine, done.
7. Why not `localStorage` alone with the `storage` event? That is detection again, with a weaker ordering guarantee.
8. Why stop? Two more whys land on "one writer per draft removes the need to version writes".

Smallest fix: the draft hook requests the lock for `account:form:draft_id` with `ifAvailable`. Holder: read `localStorage` synchronously, restore if pristine, autosave on `input` with debounce, clear on confirmed publish or explicit discard, all unguarded. Non-holder: compose normally with autosave off and a notice that the draft is open in another tab, with a "Take over" action that waits for the lock; on acquiring it, the draft is re-read before autosave starts. Storage unavailable or lock API unavailable: existing compose-without-autosave behavior. Behavior changed, stated plainly: two tabs cannot both autosave the same draft; the second tab composes without autosave until it takes over, instead of both autosaving with reload prompts on conflict. The guarantee that a stale tab never overwrites or clears a newer draft is preserved, by exclusion. Machinery removed: revision field, compare-and-set transactions, missing-record classification, occupied-key detection, stale-clear guard, the conflict-and-reload UI, the asynchronous-read typing protocol, and the matching browser tests. Machinery added: one lock request and one notice. Downstream: backend :320's "compare `(draft_id, revision)` atomically" becomes "one tab holds the draft"; frontend :199 "no second browser storage mechanism" still holds because IndexedDB is replaced, not supplemented. Prior closure listed last-write-wins as a phase-3 candidate; this is not that, because it keeps the no-overwrite guarantee.

### F-F2 — Low, product-visible choice carried from phase 2: what a video attachment looks like when assets are private

Evidence: frontend :106 (video previews open the watch page), :110 (attachment previews follow saved order), :279 (public playback links remain usable, now superseded). Under private assets a poster image needs a signed thumbnail URL, which reintroduces per-render tokens or a second redirect route.

Whys: (1) Why show a preview for a video? To indicate an attachment exists and where it sits in the saved order. (2) Why an image? Habit from public players; nothing in the design requires a poster frame. (3) Why is an image costly now? It needs a token, so either signing in the template, which expires on long-open pages, or a second `GET /media/:id/thumbnail` redirect. (4) Why not a text card? A card with a video icon, duration from `duration_s` and the accessible new-tab label carries the same information with zero tokens on the page. (5) Why stop? The next whys are visual design, which frontend :257 leaves open.

Recommendation: text card linking to the signed watch route; no thumbnail route, no signed image URLs in templates. Behavior lost: a poster frame on the tip page. If the owner wants poster frames, add the second redirect route with `private, no-store`, not template-signed URLs.

### Keep, with one wording note

- Search: `handle_params` ownership, same-name `start_async` supersession, offset-based DOM ids, `_mounts` reconnect signal. Note only: Back navigation within one live session is a `handle_params` call, not a remount, so the "Results refreshed" notice must key off the URL-versus-list mismatch, not `_mounts`; :86 already says to verify Back paths.
- Filter panel as a plain form with JS commands and native reset: idiomatic.
- Video transport: external uploads, tus adapter, preflight returns the media id, five-second Postgres poll: unchanged by the signed branch.
- Editor exits through plain anchors with conditional `beforeunload`: agreed earlier.
- Activation status wording in :187 is removed by the phase-2 closure; only its last sentence about cleanup-marked and expired uploads survives.

### Challenges requested from Codex

F-F1: whether the Web Lock's automatic release on page close is acceptable evidence without a browser test, and whether "second tab composes without autosave" is a loss the owner must approve or a routine implementation choice. F-F2: card versus thumbnail route.

## Codex (Valim lens) — Round 1

### F-J1 — Challengeable implementation choice: retained upload files do not inherently require blocking the LiveView process

Evidence: backend :264 and frontend :219 mandate a synchronous Content call for image validation, up to 50 MB of R2 upload and commit. Preserving file ownership is necessary; synchrony is a separate choice.

Whys: (1) Why synchronous? To keep temporary files alive through the attempt. (2) Why would any task lose them? Consuming the entry destroys its ownership boundary, but postponing consumption does not. (3) Why block the page process during network I/O? That prevents it handling other messages until the call returns. (4) Why durable background work? Nothing requires this attempt to survive the page. (5) Why not a LiveView-owned task? `start_async` already supplies that lifetime. (6) Why make that mandatory without an implementation? It adds completion handling and requires careful cancellation semantics; the form is intentionally disabled during a save. (7) Why stop? File lifetime and process responsiveness are different requirements, and measurement decides whether this extra mechanism pays for itself.

Primary evidence: [LiveView async operations](https://phoenix-live-view.hexdocs.pm/Phoenix.LiveView.html#module-async-operations) and the [upload channel's postpone/consume behavior](https://github.com/phoenixframework/phoenix_live_view/blob/main/lib/phoenix_live_view/upload_channel.ex). Candidate only: keep entries postponed in the page; send immutable submission values and paths to one page-owned task; refuse overlapping submission/attachment changes server-side; consume entries in the page only after confirmed success. Task exit is not proof of rollback. On page death, paths are unavailable and existing uncertain-publication/R2-orphan recovery still applies. No Oban job, detached Task, copied socket or reusable page-held R2 keys.

Proposed disposition for challenge: do not mandate async or claim a performance defect without an implementation. Clarify that page ownership is the invariant; retain the straightforward synchronous baseline unless realistic image submission demonstrates harmful message blocking. If it does, use the framework task above, not a new upload service. Test the pinned framework file lifetime before adopting that variant.

### F-J2 — Keep the small frontend units; complex draft behavior comes from the selected guarantees

Whys: (1) Why a draft hook? Browser storage and unload events are outside server rendering. (2) Why does LiveView recovery not replace it? It preserves DOM on reconnect, not a closed tab's unsaved text. (3) Why transactionally guard storage? Multiple tabs can share the same account/form slot. (4) Why not last-write-wins? It can erase newer work and changes an explicit requirement. (5) Why another client framework or stateful Result component? Neither removes the persistence races. (6) Why stop? A page LiveView, function components and a focused browser hook match the three actual owners. Reduce requirements only when the lost behavior is accepted.

Keep streams, native form/JS filter state, named search async work, one batched DB-only upload timer, two upload configurations for their genuinely different transports and server-validated durable media ids. No generic browser store, event bus or component framework. Browser tests remain necessary for custom hooks; simulated uploads do not execute tus.

### Counter-review of Fable Round 1

**F-F1 — reject as the selected replacement in its current form.** There are three concrete issues with the proposed simplification:

1. The exclusive key must be the stable **account/form slot**, not `account:form:draft_id`. Two different draft ids can otherwise hold distinct locks while writing/clearing the same storage slot; this recreates the discard/recreate stale-clear bug.
2. Lock acquisition is asynchronous even with `ifAvailable`. Synchronous localStorage inside the callback does not eliminate typing before acquisition or a later server restore reply. The existing pristine-DOM and restore-application safeguards still apply. On takeover, the second tab has already composed text; rereading and restoring the holder's saved text requires an explicit choice and conflict presentation.
3. A long-lived exclusive holder introduces lock lifetime/release, waiting/takeover and autosave-disabled second-tab behavior. The proposed removal of stale-clear protection also requires proving that no pending old submit completion can clear a new draft after release/reacquisition. The lock release guarantee alone does not prove that application protocol. Keeping the lock throughout the whole session avoids that race but can indefinitely exclude a second editor while the first tab sits idle.

This can be a valid **different product contract**, but it is not a demonstrated reduction of this contract to “one lock request and one notice”. Retain the current IndexedDB transaction and explicit conflict behavior. A stable-slot, single-editor policy may be an optional future product simplification; do not implement two storage strategies. Browser availability/release documentation cannot replace tests of Tips' takeover/save/discard behavior.

**F-F2 — keep the existing video preview by default; card-only is an optional visual reduction.** A poster conveys scene information that icon+duration does not. Existing text explicitly promises previews; “visual styling open” does not establish permission to drop them. A signed thumbnail redirect can reuse the same Content authorization/signing helper with a fixed server-chosen representation and `private, no-store`; it adds no persisted state, scheduler or renewal task. Use it for `<img src>` and the stable watch route for clicks. An already-loaded poster can remain in the DOM, as any already-seen content can; no promise of instantaneous revocation. A later image request passes through current authorization. This preserves the existing UI with a small ordinary controller branch. If owner later chooses card-only, that route can disappear. Composer browser-local file previews remain a separate path, with authorized restored previews using the same policy.

**Search wording note — narrow it.** A URL/list mismatch also occurs on ordinary forward navigation and Apply. It is not a reliable Back detector. Keep the current requirement and integration check without inventing a history subsystem or claiming `_mounts` proves Back. Do not expand this into a new review finding without a concrete implementation problem.

**Signed-playback frontend delta — accept.** Replace activation statuses with ordinary upload/processing/ready/failed states before publication, followed by a playable attachment once committed. Retain cleanup/expired-asset feedback in the composer. Use stable app watch links, preserving new-tab behavior; a provider-tab expiry is recovered by reopening the Tips link. No token refresh hook, public player component or author activation-retry UI.

Please counter-review F-J1/F-J2 and the rejected Web Lock simplification, and ratify or identify a remaining objection.

## Fable (McCord lens) — Round 2: concessions, counter-review, proposed phase-3 closure

**F-F1 — withdrawn as the selected replacement; recorded as an optional product simplification.** Codex's three points are correct on inspection. (1) The exclusive key must be the account/form slot: discard-then-recreate gives two draft ids in one slot, and per-draft-id locks would let both tabs write and clear it, which is the exact stale-clear bug the revision guard exists for. (2) `navigator.locks.request` resolves asynchronously even with `ifAvailable`, so the pristine-DOM check and the restore-application guard in frontend :191 and :193 survive under either store; what my proposal removed was the revision scheme and conflict UI, not the typing guard. (3) A second tab that composes without autosave, and a takeover that must choose between two texts, is not the contract in frontend :213 and :215, and architecture :172 lists weakening cross-tab draft protection as a product reduction. So this is a product cut, not an equivalent. Disposition: keep the IndexedDB `(draft_id, revision)` transaction and explicit conflict behavior as the selected contract. Record "single editor per account/form slot via a Web Lock held for the tab's life, second tab composes without autosave" as an optional product simplification with that loss named. Do not implement two storage strategies.

**F-F2 — accept the thumbnail redirect.** Same Content media-access function and signing helper as the watch route, one fixed server-chosen representation, `Cache-Control: private, no-store`, used as `<img src>`; the watch route stays the click target. No token in templates, no renewal, no state. Card-only is the optional visual reduction with the poster frame as the named loss. Composer-local file previews and authorized restored previews follow the same policy.

**F-J1 — accept the disposition.** Postponed entries owned by the page are the invariant; synchrony is a baseline, not a mandate. Two supporting facts for the measurement decision: the form is disabled during the attempt (frontend :219), so a blocked LiveView is invisible to the author until the attempt returns, and the channel transport, not the LiveView process, answers heartbeats, so a multi-second R2 upload does not drop the socket. The only cost of blocking is the five-second upload-status poll and any other message queued behind the attempt, which the disabled form already tolerates. If a realistic 50 MB submission shows harmful queuing, the page-owned `start_async` variant with immutable inputs and page-side consumption is the fix; no Oban job, detached task or R2 key staging.

**F-J2 — accept.** Page LiveView, function components, one focused draft hook, two upload configurations, one batched DB-only poll timer, no client framework or stateful Result component.

**Search note — accept the narrowing; withdrawn as a finding.** Neither `_mounts` nor a URL/list mismatch proves Back; the existing "verify Back and browser-cache paths" acceptance item stands without a history subsystem.

**Signed-playback frontend delta — agreed as Codex wrote it.** Upload/processing/ready/failed before publication, playable attachment after commit, cleanup and expiry feedback retained in the composer, stable app watch links in a new tab, provider-tab expiry recovered by reopening the Tips link. No token refresh hook, player component or activation-retry UI.

### Proposed phase-3 closure

1. Frontend structure unchanged: page LiveViews for browse, search, tip, editors, profiles, inbox and moderation; streams for lists; `handle_params` owns retrieval with named `start_async`; plain-form filter panel with JS commands; function components and one draft hook; plain-anchor editor exits (F-J2).
2. Drafts: IndexedDB `(draft_id, revision)` transactions, explicit conflict and reload behavior, pristine-DOM and restore guards, all as designed. Single-editor Web Lock recorded as an optional product simplification, not adopted (F-F1).
3. Video presentation under private assets: signed thumbnail redirect for the poster, signed watch redirect for the click, both through the one Content media-access function with `private, no-store`; no tokens in templates. Card-only recorded as an optional visual reduction (F-F2).
4. Image submission: synchronous Content attempt over postponed entries is the baseline; page-owned `start_async` with page-side consumption only if measured blocking is harmful; file ownership by the page is the invariant either way (F-J1).
5. Activation wording removed from the frontend; ordinary upload states before publication and a playable attachment after commit (phase-2 closure applied).
6. Existing acceptance items stand, including browser tests for hooks, tus, IndexedDB paths and Back navigation.

Source designs unchanged across all three phases. Unresolved from my side: none. Cross-phase reconciliation of the four design documents is the implementation task that follows Codex's ratification; it is not part of this review.

## Codex (Valim lens) — Round 2: ratification

Ratified all six closure items. Consensus after two paired rounds; no unresolved design objection. The synchronous baseline is justified by its small ownership model, not a claim that blocked message handling is universally invisible. Keep the measurement trigger as agreed. No browser/provider tests have been run in this design-only repository.

The owner has now explicitly requested revision of the three technical documents after all-phase consensus. That condition is satisfied. Codex will revise architecture/backend/frontend; Fable will reconcile the referenced data model to remove the obsolete amendment layer. Original snapshots above describe the reviewed inputs, not the forthcoming revised files.
