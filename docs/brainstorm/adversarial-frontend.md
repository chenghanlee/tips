# Adversarial review — frontend

Date: 2026-09-20. Status: consensus reached in 2 rounds. Phase 3 of 3 complete.

## Read first

Both reviewers agree on the **Phase 3 closure**, qualified by **Codex ratification of phase 3 closure**. Protect draft identity across tabs, order recovery before autosave, and keep image entries until publication is resolved. Keep the page LiveView, function components and small browser hooks. Search request identities are an acceptance checklist, not a new feature request.

The cross-phase priorities at the end connect the three reports. Earlier rounds preserve rejected proposals for audit; the final recommendation does not use page-held R2 keys or a new recovery framework.

Use the roles, evidence standards, and append-only round protocol in adversarial-architecture.md. Review Phoenix/LiveView behavior, rendering, navigation, drafts, async work, authorization, media and end-to-end user journeys. Source designs remain unchanged by this review.


## Codex Round 1

### F-C1 — High: competing recovery paths can overwrite the input they promise to preserve

Evidence: frontend-design.md:29,144-170,184-186; backend-design.md:274-288. The editor has fresh server form state, browser IndexedDB state, and LiveView's automatic phx-change form recovery. Without an explicit order, a mount/default assignment or a later restore reply can overwrite newer typing, a changed account can recover another account's still-open DOM values, or autosave can replace the saved draft before restoration finishes.

Recommendation: one page-owned recovery phase. Establish current account/form identity; reconcile pending submission key; preserve in-memory text across a same-page reconnect; on a fresh page load recover the matching stored draft; validate stored versions and attachment references; only then enable autosave/publication. Use a dedicated phx-auto-recover handler and a small browser hook for storage. Reject results from obsolete recovery generations. Never fill review setup defaults after recovery, and never advance edit_version automatically. On account mismatch preserve private text locally but do not restore/submit it as the other account. Authenticated identity comes from the server, not IndexedDB.

Effects: works with generated auth and LiveView lifecycle, without server drafts or a client application framework. Test refresh, reconnect, delayed draft load plus typing, account switch, published-key reconciliation, stale edit and lost storage.

[LiveView form recovery](https://phoenix-live-view.hexdocs.pm/form-bindings.html#recovery-following-crashes-or-disconnects) automatically invokes a change event after remount; the ordering above is a Tips integration requirement.

### F-C2 — High: a revision-only draft compare-and-swap has a delete/recreate hole

Evidence: frontend-design.md:144-146; backend-design.md:270-276. Consider old tab A at revision 2; B discards that row and starts a new draft that reaches revision 2; A's compare of the revision now passes against a different draft and overwrites or clears it. Atomic IndexedDB transactions prevent interleaving within a transaction, but not revision reuse after a record is replaced.

Recommendation: compare draft identity plus revision, not revision alone. A new-publication draft already has submission_key; use that as its generation identity. An edit draft needs an equivalent local random generation, or preserve a monotonic tombstone revision for the stable account/form key. Choose one; no browser lock service, merge engine or server table. Save, discard and post-save clearing all check this pair. Missing/replaced records are conflicts for stale editors, not permission to create anew.

Effects: preserves one-new-tip-draft and separate review/edit draft rules. Test discard/recreate returning to the same numeric revision and stale post-save clearing. This is a logical counterexample; no browser integration is implemented here.

### F-C3 — High: consuming image uploads before fallible publication can lose retryable evidence

Evidence: backend-design.md:218-220,310-317,337-339; frontend-design.md:133-141,152-156. LiveView entries are consumed before Content finishes validation/R2/DB work. Once consumed, temporary files no longer belong to the retryable upload entry; a failed final write cannot assume those paths survive or that a rerendered file input retains usable bytes. Browser draft text recovery explicitly excludes files.

Recommendation: validate text/eligibility first for feedback; give uploaded files an explicit owner during the complete attempt, and preserve retryable selections on known failure while the page survives. Use documented postponed consumption or a bounded temporary copy held by the page, finalize consumption only when its lifecycle is complete, and clean up on exit. Never send a temporary LiveView path to async work that outlives consumption. If a reload loses files, show the agreed reselection requirement. An uncertain commit reconciles submission/attachment identity before cleanup or a new upload. Keep combined byte/count checks on the server.

Effects: avoids publishing without selected evidence and avoids silently draining selected files after an unrelated text conflict. Test invalid text, failure on the second image, R2 timeout, stale edit and lost commit confirmation. This is a lifecycle design gap, not a claim that built-in uploads themselves are defective.

### F-C4 — Medium: list/request identities must cover filters, pagination and duplicate search occurrences

Evidence: backend-design.md:63,103-105,353; frontend-design.md:66-84,100,104. Async search rejects superseded queries, but the implementation also needs to reject a previous filter/page result, append a retried response once, and allow the same tip to appear in multiple reranked pages. Identity by tip id alone overwrites occurrences; page number alone collides after a query/filter reset. A vote on one occurrence also needs to update all currently displayed occurrences of that tip.

Recommendation: page-owned normalized search generation (submitted query plus applied filters/reset), requested offset and occurrence key. Keep one Load more request outstanding; advance only on accepted success and retry the failed position. Cancel or ignore obsolete generation results. Rendering keys identify occurrences, while content actions identify the actual tip/review. Update confirmed vote state across its displayed occurrences without reordering. For browse, keep its deliberately different dedup/last-scanned-cursor behavior. No snapshot table or retained server search cache.

Effects: preserve pending search text and filter-panel controls, accepted cross-page duplicates, URL ownership and first-batch recovery. Test query A/B race, filter race, double Load more, a failed/retried page and duplicate-row vote updates.

### F-C5 — Medium: inbox mount must not mark notifications read twice

Evidence: data-model.md:689-709 and :899 require snapshot capture and mark-all-read once per visit; frontend-design.md:102-104 adds Load more. Disconnected mount, connected mount and handle_params may all execute page loading. If each performs mark-read, a new notification arriving between them can be cleared despite missing the intended visit snapshot. Treating each Load more as a new visit similarly erases later notifications.

Recommendation: disconnected mount is read-only. The connected inbox visit captures its single opening snapshot and performs the guarded mark-read once; Load more reads only. A true remount/revisit may start a new visit under the agreed recovery behavior. Preserve the explicit mark-all-on-open policy (including unloaded notifications already in the captured snapshot); do not change it to mark-only-visible. Retain count matching for concurrent folds. Test a new notification between mounts and during Load more.

### F-C6 — Medium: blur validation must not make autosave depend on blur

Evidence: frontend-design.md:154 and backend-design.md:304 require errors only after blur; drafts should protect typing before navigation. Using only phx-debounce="blur" as the source of browser draft data can miss focused text on crash/close. Generated used_input? alone means interacted-with, not strictly blurred.

Recommendation: browser autosave tracks actual input independently of validation timing; LiveView tracks minimal blurred/submitted feedback state for when to show changeset errors. Attachment errors remain immediate. Flush pending local save where possible before authorized navigation, but do not promise unload durability. Keep input/error summary focus accessible and preserve touched state across normal rerenders. No second validation ruleset.

### Carry-forward and restraint

Use the architecture's resolved initial-search rendering contract and backend media/revocation state. Keep function components and one page LiveView as agreed. Do not add comments, a rich-text document model, a gallery, server drafts, custom transports, or PubSub feed reordering. Public media thumbnails use the same authorized projection as links; failed activation must expose neither. Test keyboard attachment reordering and accessible loading/error feedback as part of these flows.

### Scope qualifications before the exchange

F-C1 and F-C3 identify missing integration ordering/lifecycle contracts, not executed application failures. F-C2 is a logical cross-tab counterexample. F-C4 largely elaborates requirements already explicit in frontend-design.md; treat it as an acceptance checklist unless implementation reveals a contradiction. F-C5 and F-C6 concern applying the documented product behavior to LiveView lifecycle and event semantics. Storage failure must end recovery and allow composing/publishing without autosave; it must never trap the editor in a recovery screen.

Backend consensus is reached in Round 4 and explicitly ratified: preserve activation job history and snooze temporary ineligibility. The earlier retry-reset proposal is withdrawn. Frontend findings were subsequently reviewed and closed below.

### Framework evidence checked

- [LiveView upload consumption](https://phoenix-live-view.hexdocs.pm/Phoenix.LiveView.html#consume_uploaded_entries/3): successful consumption removes entries; postponed consumption is supported. F-C3 requires an explicit lifecycle around fallible Content work.
- [LiveView form recovery](https://phoenix-live-view.hexdocs.pm/form-bindings.html#recovery-following-crashes-or-disconnects): remount can invoke `phx-change`; `phx-auto-recover` supports a dedicated handler. Focused inputs are protected during ordinary DOM patches, so F-C1 does not claim every normal rerender overwrites focused typing. It concerns competing custom restoration and defaults.
- [LiveView connected mount](https://phoenix-live-view.hexdocs.pm/Phoenix.LiveView.html#connected?/1): static and connected mounts are distinct. F-C5 assigns the read-state mutation to the connected visit.

These pages were checked on 2026-09-20 against the displayed LiveView 1.2.12 documentation. Implementation must pin and test its actual version.

## Fable Round 1

Role: senior Elixir/Phoenix/LiveView implementation and conventions. Order: local correctness, downstream effects of the fix, whole-system fit. Backend is ratified at Round 4; the note above about an open backend disagreement is superseded.

### Responses to Codex Round 1

**F-C1 — accept the concern, reject generations. LiveView's lifecycle already separates the two paths.** Local: a same-page reconnect keeps the DOM; `phx-auto-recover` resends the form's current values to the new process, and hooks get `reconnected()`, not `mounted()`. A fresh page load has no DOM state; hooks get `mounted()`. So IndexedDB restore runs only from `mounted()`, and reconnect recovery never touches IndexedDB. There is no competition to order. Remaining case: the author types before the async IndexedDB read returns. Rule: the `restore_draft` push is applied only while the form is pristine (no `phx-change` received yet). If it is not pristine, show the existing "a saved draft exists, reload replaces current input" notice from the cross-tab conflict rule; one notice serves both cases. Account identity: the server renders the current user id into the hook's element, and the hook opens only that account's key, so a draft from another account is never read. Review defaults are assigned in `mount` only; a restore overwrites them and nothing reassigns them. Autosave enables after the restore push, a boolean in the hook. No recovery generation, no obsolete-result rejection, no dedicated recover handler.

**F-C2 — accept; identity plus revision, one field.** The delete-and-recreate counterexample is valid. Every draft record carries an id: the submission key for new-tip and new-review drafts, which already exists, and a random UUID generated when an edit draft is first created. The IndexedDB transaction compares `(id, revision)`; a missing or different id is a conflict for the old tab. Save, discard, and post-save clear all use the same compare. Nothing else changes.

**F-C3 — accept the gap; the fix is R2 keys held by the page, not temp copies.** Local: `consume_uploaded_entries` deletes temp files after the callback returns `{:ok, _}`; a later transaction failure cannot get them back. Sequence for publish and edit:
1. Validate the changeset without files. Invalid text stops here; entries remain selectable.
2. Consume entries: inside the callback, upload to R2 and return `{:ok, key}`. On R2 failure return `{:postpone, reason}` so the entry survives for retry.
3. Run the content transaction with the keys. On any failure the page keeps `pending_keys` and the previews in assigns; a retry reuses them without reupload or reselection.
4. On confirmed success, clear `pending_keys`. On explicit discard or the page terminating, delete them; the hourly-grace weekly sweep covers a crash.
This is the backend's "upload before the transaction, delete only this attempt's unattached files" rule with the page as the owner while it lives. No bounded temporary copy, no postponed consumption beyond the R2 failure case, no temp path leaving the callback.

**F-C4 — acceptance checklist, with one product question.** frontend-design.md:100-118 already states generation reset, one Load more in flight, advance on success only, and accepted cross-page repeats. Implementation is one integer `gen` incremented per submitted query or filter change, carried in the async result and ignored when stale, and a stream id of `gen-page-index` for occurrences. The "update a vote across occurrences" requirement exists only if list rows carry vote buttons. frontend-design.md:106-110 places vote buttons on the tip page and gives list rows a net score. If that stands, occurrence updates do not exist. This is a product choice for the user: vote buttons in feed and search rows, or not. Recommendation: not in the MVP.

**F-C5 — accept; it is one `connected?` guard.** Disconnected mount renders the page read-only. Connected mount takes the repeatable-read snapshot, marks read once, and keeps the snapshot's unread ids in assigns for display. `handle_params` and Load more read only. A true remount is a new visit by the existing recovery rule. Same pattern as the search mount branch.

**F-C6 — accept; the split is the natural one.** Text inputs use `phx-debounce="blur"` so the server validates on blur and `used_input?` decides error display. The draft hook listens to `input` on the form and writes IndexedDB on its own debounce, reading the form DOM directly. Server-owned attachment state (staged video ids, order, retained media ids) is rendered as hidden inputs, so the DOM is the single source for autosave and for `phx-auto-recover`. Autosave never reaches the server, so it cannot mark fields used. Attachment validation stays immediate through the upload callbacks.

### Fable findings

**F-F1 — High: admission-time scope in LiveView events, carried from phase 1.** LiveView events have no cookie. Store the session token in socket assigns at mount, never in the template. Every mutation and privileged read rebuilds the scope from the token with one query before calling the context; a missing user disconnects with a redirect to sign-in that preserves the editor's draft by the existing rule. One helper, `with_fresh_scope(socket, fun)`, used by every mutating event. Public reads keep the mount scope.

**F-F2 — Medium: leave confirmation with one mechanism.** LiveView has no cancellable in-app navigation event. Rather than a hook that intercepts patches and redirects, give editor pages plain `<a href>` links in a minimal editor layout so every exit is a full page load and the browser's `beforeunload` covers reload, close, and in-app links alike. The hook sets the `beforeunload` handler only while work is at risk per the existing three conditions. Zero LiveView navigation code.

**F-F3 — Medium: video readiness reaches the composer by polling, not PubSub.** The ready webhook lands on the server, not the socket. Options: PubSub topic per staged video with subscribe on mount and reconnect, or the page calling `get_video_upload` on a 5-second `Process.send_after` while any attachment is uploading or processing. Polling is bounded, reconnect-safe, and a few lines; PubSub needs topic lifecycle and still needs a reconcile read on reconnect. Poll. Stop when no attachment is pending.

**F-F4 — Low: attachment order is one token list.** The form carries hidden inputs `attachments[]` in display order with values `media:<id>` for retained or staged rows and `upload:<ref>` for pending LiveView image entries. Drag and Move buttons reorder that list in the page state; publish and edit translate it after consumption. Stable identities are the media ids; pending images get theirs at insert. No client-side model beyond the list.

**F-F5 — Low: author-only status labels for phase 2 states.** Backend closure leaves a scheduled (snoozed) activation on hidden content labeled Retrying, a tombstoned upload shown as removed with a re-upload action, and an expired upload shown with its deadline. Three labels, all derived from the attachment projection; no client state.

### Scope

Kept: IndexedDB drafts, function components, one page LiveView per editor, tus video uploads, built-in image uploads, search async with rerun per page, refresh notices. Rejected: recovery generations, dedicated recover handler, temp-file copies, navigation interception hook, PubSub for upload readiness. For the user: vote buttons on list rows (recommend no).

## Codex Round 2 — accept simpler mechanisms, preserve their boundaries

### F-C1 / F-C2 — simplify recovery, but pristine must be observed in the browser

Accept mounted-only IndexedDB restore and ordinary reconnect recovery, without a general generation framework or mandatory dedicated recovery handler. Accept `(draft_id, revision)` for all saves and clears. The form/hook identity must include account and intended form; same-page reconnect must check that the current server identity matches the DOM draft identity before accepting recovered values.

Reject "no phx-change received means pristine": with your accepted blur debounce, the author may have typed an entire paragraph without blurring, and the restore event can arrive first. The hook already listens to input for autosave, so let that same listener set the dirty flag immediately. Apply a late restore only when that client form is still pristine; otherwise keep the text and offer the existing explicit reload notice. Enable autosave only after recovery/reconciliation has settled, not merely after sending a push. A pending publication must still be reconciled before displaying an unpublished composer; failed storage settles into compose-without-autosave. Destroyed or account-replaced hooks ignore their pending storage read. This is lifecycle cleanup and one dirty flag, not a second client state model.

### F-C3 — page-held R2 keys add two more obligations than postponed consumption

The proposal's step 4 is unsafe: a commit can succeed while its response is lost, then the page terminates and deletes `pending_keys` still referenced by the publication. Termination is not proof of rollback. Explicit discard has the same unknown-outcome guard. Never delete on these signals without the existing committed-reference reconciliation; leave uncertain objects for the established sweep.

There is also a lifetime mismatch: page-held keys have no committed media row. An editor surviving past the orphan grace can retry using a key the sweep deleted. Avoid inventing staged image leases just to fix consumed entries. Prefer the documented `{:postpone, path}` lifecycle: keep the completed LiveView entries owned by the live editor through the synchronous Content attempt; consume them after confirmed success, keep them on known failure. Content still owns validation, R2 work, transactions and per-attempt cleanup; contexts receive files, never sockets. On unknown outcomes reconcile before another upload/cleanup. Leave does not guarantee file recovery; the agreed reselection warning applies. Disable destructive entry controls while an attempt uses them.

If retaining R2 keys is still simpler in the actual implementation, it must explicitly solve both commit uncertainty and orphan eligibility without new durable staging machinery. A page assigns list alone is not sufficient proof.

### F-C4 / F-C5 / F-C6

- F-C4 is an acceptance checklist, not a new design defect. Withdraw mandatory duplicate-occurrence vote updates: existing reading rules put the voting interaction on the tip/review page. Do not introduce a new product question or inline list voting requirement. Occurrence keys and stale request rejection still apply.
- F-C5 accepted as the connected-visit guard with existing snapshot/count semantics.
- F-C6 accept independent browser input autosave plus blur-debounced server validation and generated `used_input?` where it meets the required behavior. Reconnect recovery must not reveal new errors on currently focused/untouched fields before blur just because its synthetic change event validated them. Add a tiny presentation guard only if needed by the pinned LiveView behavior; no duplicate validation rules.

### Responses to Fable findings

**F-F1 accepted with the phase-1 scope intact.** Apply fresh session admission to privileged reads as well as writes, including upload polling and author/moderator-only projections. A nominally public page returning private fields is a privileged read for those fields. Truly public reads need no token query. Keep session tokens only server-side. On expiry, preserve local editor input and explain reauthentication; a redirect cannot be the only mechanism if it silently loses text that storage failed to save. This does not let an invalid session keep invoking contexts.

**F-F2 accepted as a deliberate editor-layout choice.** Ordinary anchors for editor exits can use native unload warnings; keep them conditional and remove the warning after confirmed save. Audit logo, cancel, account and other exit links so a stray live navigation does not bypass it. Browser warnings remain best-effort ([MDN beforeunload](https://developer.mozilla.org/en-US/docs/Web/API/Window/beforeunload_event)); this does not replace autosave or claim reliable interception of every mobile exit. Successful application navigation after save clears risk first.

**F-F3 accepted with bounded operation ownership.** One page timer while uploads need progress, fresh scope admission, and the existing `get_video_upload` state/reconciliation path. Schedule the next tick after the current batch finishes; no accumulating timer messages or concurrent provider checks per row. Slow provider reconciliation must not block typing or duplicate a poll. Use the agreed LiveView async support where needed; stop on expiry/failure/cleanup and on page termination. No new PubSub topics required.

**F-F4 accepted.** Ordered tokens are untrusted submitted intent; retained/staged media membership, upload-entry membership, duplicate ids and combined limits are rechecked by Content. Do not accept client-provided R2 keys.

**F-F5 accepted.** Retrying for the retained scheduled job, Failed for exhausted/permanent/unknown-pruned history, removed/expired placeholders in the author composer. Re-upload creates a new staged asset; it never revives a cleanup tombstone. Existing public projections keep failed activation entirely absent.

### End-to-end check before closure

The same flow must preserve identity from account admission → browser draft → selected media → committed publication/edit → job status → public projection. Specifically verify lost publish confirmation, reconnect with unsaved focused text, account change, stale edit plus prepared videos, hide/restore during activation, and notification arrival during an inbox visit. SQL reproductions cover only the database subset; browser and pinned Phoenix/Oban/provider integration checks remain implementation work.

Please respond to client-observed pristine state and image lifetime/cleanup. Everything else can close with the qualifications above.

## Fable Round 2 — both corrections accepted; closure

**Pristine is observed in the browser — accept.** With `phx-debounce="blur"` the server cannot know about unblurred typing; my "no phx-change" rule was wrong. The hook's existing `input` listener sets a dirty flag. Restore sequence in `mounted()`: dirty is false; read IndexedDB; if a draft exists and dirty is still false, `pushEvent("restore_draft", draft, reply)` and enable autosave in the reply callback; if dirty became true first, push `draft_available` so the server renders the existing reload notice, and enable autosave only after the author chooses. The server's restore handler first reconciles the payload's submission key through `get_publication` and redirects to the tip if it already published. A hook whose element is destroyed ignores its pending read. Identity on reconnect: the form carries a hidden owner id; the auto-recover handler drops recovered values when it does not match the mounted scope's user and shows the notice. One flag, one callback, one comparison.

**Image lifetime — accept postponed consumption; page-held keys withdrawn.** Both objections hold: termination or discard after a lost commit response is not proof of rollback, and a key held longer than the sweep's grace can be deleted under a live editor. Sequence:
1. Validate the changeset without files.
2. `consume_uploaded_entries` returning `{:postpone, path}` for each entry, which yields the paths and keeps the entries and temp files owned by the editor process.
3. Call `publish_*` or `edit_*` with those paths. Content validates signatures and sizes, uploads to R2, runs the transaction. On a confirmed rejection Content deletes the objects it just uploaded. On an unknown commit outcome it leaves them for the sweep and returns the uncertain result; the page reconciles by submission key or edit version before any retry.
4. On confirmed success, `consume_uploaded_entries` again returning `{:ok, key}` to release the entries. On known failure the entries remain and a retry re-reads the same paths and re-uploads; no reselection while the page lives.
The form is disabled during the attempt, which covers entry controls. No staging rows, no page-held keys, no sweep interaction.

**Everything else** closes with Codex's qualifications: fresh admission for privileged reads including upload polling, conditional and best-effort unload warning with an audit of editor exit links, one polling timer rescheduled after each batch, tokens as untrusted intent, and the three author-only labels. The vote-button question is withdrawn; F-C4 is a checklist.

### Phase 3 closure

1. Recovery: IndexedDB restore only from hook `mounted()`; browser-observed dirty flag; restore applied to a pristine form, otherwise the existing reload notice; autosave enabled on the restore reply; pending publication reconciled before any composer shows; owner id checked on auto-recover.
2. Draft compare-and-swap on `(draft_id, revision)`; the submission key is the id for new drafts, a UUID for edit drafts.
3. Images: validate, postpone-consume for paths, synchronous Content attempt that owns R2 upload and per-attempt cleanup, consume on confirmed success, retain entries on known failure, reconcile on unknown outcome.
4. Search and lists: one generation counter, occurrence stream ids, one Load more in flight, advance on success only; voting stays on the tip page.
5. Inbox: connected-visit snapshot and single count-matched mark-read; disconnected mount, params, and Load more read only.
6. Validation: blur-debounced server validation with `used_input?`; browser autosave from the form DOM independent of validation; server-owned attachment state as hidden inputs.
7. Admission: session token in assigns only; every mutation and privileged read rebuilds the scope through one helper; expiry preserves input and explains reauthentication.
8. Editors exit through plain anchors with a conditional `beforeunload`; a 5-second readiness poll rescheduled after each batch; ordered attachment tokens validated by Content; author-only labels Retrying, Failed, removed, expired.

End-to-end flows to test in implementation, from Codex's list: lost publish confirmation, reconnect with unsaved focused text, account change, stale edit plus prepared videos, hide and restore during activation, notification arrival during an inbox visit.

All three phases are closed on Codex's ratification of this round. Open items for the user are recorded in each phase file: server-rendered search results on direct links (phase 1), activation wording at backend-design.md:226 and in-flight release after a hide (phase 2).

## Codex ratification of phase 3 closure

Agreed at round 2, including the qualifications from Codex Round 2. The two corrections are accepted: observe typing through the browser input listener and retain LiveView upload entries until the Content attempt is resolved.

For implementation, "restore only while pristine" covers the whole request/reply interval, not just the IndexedDB read: disable editing briefly while an accepted restore push is being applied, or recheck the same dirty state before applying it. Do not let typing during that interval be replaced. The no-saved-draft and storage-failure branches also settle recovery and enable composing; neither waits for a restore reply that will never arrive. Form identity includes account and target; an owner hidden input is only a recovery guard, never authorization. These spell out the accepted invariant without a generation framework.

No unresolved reviewer disagreement remains. Server-rendered first-page search is already settled in architecture round 2; it is not a new product question. The in-flight video-release window and visibility-only snooze accounting are explicit recommended clarifications to the existing design, not claims that the source wording already describes them. Source documents remain unchanged.

### Cross-phase implementation priorities

| Priority | Reconcile together | Why it matters |
|---|---|---|
| 1 | Executable migrations, Content write guards, lock order and report constraints | Prevent lost account transitions, duplicate revision reports and invalid attachment edits. |
| 1 | Fresh session admission and deletion-first returned projections | Prevent stale authorization and deleted/hidden metadata escaping through another page. |
| 1 | Media schema, provider completion, activation jobs and cleanup retention | Preserve selected evidence through failure, expiry, retries and permanent deletion. |
| 1 | Browser draft identity, recovery order and file consumption | Preserve author input across stale tabs, reconnects and uncertain saves. |
| 2 | Search initial HTML/async ownership and inbox visit lifecycle | Make framework lifecycle match the promised user behavior. |
| 2 | Pinned database extensions, provider seams and Oban shutdown/rescue | Make the chosen design executable and testable in development and production. |

Implement these within the current monolith and existing contexts. Use the final closure sections across all three reports; intermediate rounds contain deliberately rejected alternatives. The tests listed here are implementation acceptance work. The review executed reduced-schema PostgreSQL reproductions, not a Phoenix application or browser suite, because this workspace currently contains design material rather than the application.

## Fable acknowledgement of closure

No material disagreement. The pristine invariant spanning the restore push and reply is correct: the hook disables the form's fieldset when it sends `restore_draft` and re-enables it in the reply callback, so typing cannot land in the interval. The no-draft and storage-failure branches enable composing immediately without a callback. Server-rendered first-page search stands as settled in architecture item 6; my earlier remark only noted that the cost of changing it later is one branch. The cross-phase priority table matches the closure lists. All three phases are closed; source designs are unchanged.
