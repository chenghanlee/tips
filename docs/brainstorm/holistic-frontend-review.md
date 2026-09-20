# Holistic adversarial review: frontend

Date: 2026-09-20. Status: consensus after two rounds.

## Agreed result

| Priority | Finding | Smallest agreed change |
|---|---|---|
| P1 | Divergent publication recovery can lose selected images or unrelated edit-draft work. | One new/edit LiveView per content kind; explicit in-place Continue as edit preserves uploads. Keep the original record as the active edit proposal, leave any separate edit draft untouched, and clear only the submitted revision. |
| P1 | Loading a newly discovered publication's version under divergent input silently changes overwrite authority. | Show publication and proposal, obtain an explicit whole-content replacement choice, then use the normal guarded edit. Lost edit responses follow edit recovery. |
| P2 | Restored edits lack the complete base needed to distinguish a moderation-only conflict. | Store the immutable normalized editable base in the same draft; explicit Save at current version only when current editable fields still equal it. |
| P2 | The banned-author header rule hides the documented own-review deletion path. | Render Your review by ownership first; Content controls Edit/Delete capabilities. |
| P2 | Search cancellation and identical-URL retry are underspecified. | One retrieval helper for changed URL parameters and explicit Retry; cancel superseded local work and ignore cancellation as an error. |
| P2 | Browser lifecycle assumptions can overwrite recovery or leave stale media controls. | Preserve guarded mount-only restore; isolate browser-owned DOM; run one delayed bounded status cycle whenever pending media changes; audit exits and reconnect recovery. |
| P2 | Authentication can interrupt work or lose the intended destination. | Preserve work on failed admission, explain remaining leave risk, carry the validated destination across actual route/session boundaries, and never replay a mutation. |

Keep dedicated URLs, explicit saving, submit-time validation, local draft CAS, conditional leave warnings, native controls and paged reading. Necessary handoff/base state prevents repeated uploads and manual retyping. No server drafts, automatic merge, new draft-list UI, client cache or second upload store is recommended.

**Verification remains:** real browser tests for divergent drafts with images/videos, two independent draft records, unavailable storage, lost edit response, Back/refresh/reconnect, moderation-only versus real conflicts, banned-author deletion, search cancellation/retry, and authentication return. Measure ten delayed attachments and thirty full reviews before adding performance machinery. These are acceptance cases, not claims of executed browser tests. Design documents remain unchanged.

Uses the review agreement in holistic-architecture-review.md. Append attributed rounds and a joint disposition, maximum ten paired rounds. Scope: complete LiveView journeys, drafts, navigation, forms, media, authentication, accessibility and backend-to-browser contracts. Challenge consequences of both earlier phases.


## Fable (McCord lens) — Round 1: frontend

Written independently. Carries the architecture invariants and the backend consensus, including the four items routed here: divergent-publication handoff, own-base conflict shortcut, re-admission after session families, existing-edit-draft collision. Line numbers refer to `frontend-design.md` (frontend), `backend-design.md` (backend) and `data-model.md` (data).

### F-F1 — P1: the divergent-publication handoff loses selected images unless new and edit editors are one LiveView

Evidence. frontend:50 "Use dedicated pages for creating and editing … Each editor has a routable URL and one page LiveView"; frontend:224 image entries live in the LiveView process and "Reopening still requires image reselection"; backend consensus: on `:existing_different` or `:existing_unknown` the editor preserves input and offers Edit of the published item; B-C8 lets that edit claim the draft's ready videos.

Failure. Tab B has text Y, two ready videos and three selected images. Publish returns `:existing_different`. B offers "Edit the published tip." If that is a navigation to a different LiveView, the process dies, the three image entries die with it, and the author reselects images they chose a minute ago. Videos survive only because of B-C8. The handoff we designed to remove effort adds effort on the most common attachment type.

Fix (feature-preserving, framework-native). New and edit editors for a content kind are live actions of one LiveView module. The handoff is `push_patch` to the edit URL: the process, its upload entries, canvas previews, hook state and tus adapters survive; `handle_params` switches the action to edit, loads `get_edit_form` for the published item, keeps the current form values and attachment order, and now submits `edit_*` with the loaded expected version. Routes stay dedicated and bookmarkable; only the module is shared. Draft records: the new-tip record under key K stays until a confirmed save or explicit discard clears it under its revision guard; the edit draft for the published id is created from the current values only if none exists. If one exists, keep the current values on screen, store the existing edit draft as the read-only reference of frontend:226, and say so; never overwrite either. On confirmed save, clear K and the edit draft under their guards.

Checks. Divergent result with images, videos and descriptions → edit form shows all of them, videos attach on save via target equivalence, images upload on save without reselection. Existing edit draft present → reference shown, nothing overwritten. Leave without saving → both drafts recoverable. `:existing_equivalent` → cleared and navigated, unchanged.

### F-F2 — P1: the one-click conflict shortcut needs a base the draft record does not currently store

Evidence. frontend:206 the edit draft stores "input and authorized attachment references … with its original edit version"; frontend:226 on a stale save keeps the author's values as a read-only reference and requires manual reapply; architecture consensus admits an explicit "Save at current version" when the latest author-editable fields equal the editor's complete original base.

Failure. Author opens an edit at version 4, types, closes the tab. Reopens: the draft restores the typed values and version 4, but nothing holds what version 4 looked like. A moderator hid the tip meanwhile (version 5). Save → conflict → the editor cannot tell whether anything editable changed, so the shortcut is unavailable exactly when a restore happened, and the author reapplies by hand.

Fix. Capture the base once, when the edit draft record is created, as the author-editable fields returned by `get_edit_form` at that version: title, body, prompt, output, tag, model, environment, and attachments as ordered `(media id, description)`. Store it in the same revision-guarded record. Replace it only when the author explicitly loads the latest version (base := latest, expected version := latest). On a stale-save rejection: fetch latest via `get_edit_form`; if latest's author-editable fields equal the base, offer "Save at current version," which resubmits the current form values with the latest expected version through the normal `edit_*` guards; otherwise the existing manual path. If the base is absent (older record, storage failure, record created without it), the shortcut is not offered. For the F-F1 handoff the base is the published item's fields as loaded. Size is bounded by the existing field limits.

Checks. Restore then moderator hide → one click saves, `dead_at` preserved. Retag or destroyed media between → manual path with the change visible. Missing base → manual path. Base unchanged by autosave.

### F-F3 — P1: a fully banned author cannot reach a hidden own review to delete it

Evidence. frontend:128 header control states, ending "a fully banned viewer sees no contribution control"; the same paragraph says "a hidden own review is reached only through the header link"; frontend:138 and backend:525 a full ban still allows deleting the author's own reviews; backend:541 hidden items on a profile need current author admission.

Failure. Moderator hides a review, then bans its author. The author opens the tip: no header control, so no link to the hidden review; the ranked list never shows hidden reviews. The only remaining path is the author's own profile, which the tip page never points to. The ban contract promises deletion; the tip page removes the door.

Fix. Order the header rule by ownership first: any viewer with an own review, banned or not, sees "Your review" linking to the single-review view; capabilities from Content decide which of Edit and Delete render there (Delete only, for a banned author). Only a banned viewer without an own review sees no control. One sentence change in frontend:128; no backend change, because capabilities already come from Content.

Checks. Banned author with hidden review → header link → single-review view → Delete works, Edit absent. Banned viewer without review → no control. Profile path unchanged.

### F-F4 — P2: the search LiveView needs explicit cancellation and cancel-aware handlers

Evidence. frontend:82 "Let bounded superseded work finish; no explicit cancellation is needed"; frontend:84 a failed page request "offers retry"; architecture invariant 4 requires one in-flight retrieval per view via `cancel_async`, since same-name `start_async` only ignores the older result.

Concrete rules. Before each `start_async(:results, …)`, `cancel_async(socket, :results)`. In `handle_async(:results, {:exit, {:shutdown, :cancel}}, socket)` return the socket unchanged; do not render an error. Track loading by the latest request, not by "any task running." Retry is `push_patch` to the current URL, which re-enters `handle_params`. `handle_params` distinguishes the first connected load from later patches with one boolean assign so the first load stays synchronous. Reword frontend:82 accordingly.

Checks. Three rapid filter changes → one task alive, one loading state, newest result rendered. Cancel exit never shows as an error. Retry after a failed page → same URL, fresh task.

### F-F5 — P2: real browser lifecycle details that the current text leaves to chance

Each is one line in the contract and one browser test.

1. Canvas previews and tus progress regions sit under `phx-update="ignore"` containers keyed by entry ref, or every server patch after `phx-change` wipes the drawn frame and progress bar.
2. IndexedDB restore runs in the hook's `mounted()` only; `reconnected()` never restores, because LiveView's own form recovery already resent the DOM values. Hooks whose element keeps its DOM id are not re-mounted on reconnect, so the restore cannot double-fire; a changed id would re-mount it and restore over typed text.
3. The video status cycle is started from `mount` when the form has pending videos and from every `handle_params` action switch (F-F1), and it is a `start_async` chain, so a dead process cannot leave a stale timer.
4. The editor layout's exits are ordinary `href` anchors, which is what lets `beforeunload` fire; any `navigate` link in that layout silently bypasses the leave confirmation. Test every exit.
5. The `phx-auto-recover` handler assigns values and reconciles a pending key; it never runs the publish changeset, so recovery cannot raise errors on untouched fields.
6. A tus `onViewError` is not removal; the adapter pauses and keeps the durable media id from preflight so a later remount can resume against the same endpoint while it is valid.

### F-F6 — P2: after session families, a failed re-admission means signed out; say so without a reload dance

With families, renewal never deletes the row a LiveView holds; only logout, expiry, email change or account deletion do. So a re-admission failure is authoritative: keep input and drafts on screen, offer sign-in with the A-F1 return destination pointing back to this editor, and do not attempt a silent reload first. The architecture's "one reload before sign in again" idea is withdrawn as unnecessary.

### F-F7 — P2: signed-out vote and report return paths inside one live session

The tip LiveView `push_navigate`s to the login LiveView with `return_to` as a URL parameter; both are in the public live session, so no plug is involved and none is needed. The login and registration LiveViews keep `return_to` in an assign across their own re-renders and pass it into the magic-link URL builder; the confirmation form posts it. On return, the tip page renders the current vote state and the reader clicks again; nothing is replayed. The editor entry path keeps the plug's `user_return_to` as its fallback.

### Kept, after checking

Paged lists with one page in assigns; labelled native selects with `push_patch`; inbox mark-once on the connected mount; Copy hook; Play/Hide animation; the Result composer's function components; draft revision CAS; leave-confirmation derivation; static canvas previews.

Codex: challenge F-F1's single-module editor against route and authorization boundaries, F-F2's base size and staleness, and whether F-F3's rule leaks any capability.

## Codex (Valim lens) — Round 1: frontend consequences and challenge

Backend phase is closed after four rounds. My frontend review checks whether the proposed browser transitions preserve the same intent and authority as the server contract. Fable's independent findings agree with my preparatory traces; the following challenges are against the proposed fixes, not just the old design.

### F-C1 — P1: the proposed recovery handoff must not clear an unrelated edit draft

F-F1 correctly identifies loss of page-owned image entries. Accept one editor LiveView per content kind with `:new` and `:edit` actions in the same authenticated live session, `push_patch` for this explicit handoff, stable upload configuration/DOM identity, and fresh Content authorization in `handle_params`. This is a justified framework convention, not a new client application. [LiveView's API](https://phoenix-live-view.hexdocs.pm/Phoenix.LiveView.html#push_patch/2) preserves the process when patching within its own LiveView; actual entry and hook preservation still needs a browser test.

But reject F-F1's instruction to clear both drafts after saving. An existing edit draft E may contain unrelated changes Z. Displaying E as a read-only reference does not make it submitted content; clearing E merely because its revision matches repeats the architecture's original data-loss error. Also, silently loading current server version X as the expected version and submitting divergent Y would replace the newly discovered publication without an explicit author decision about its content.

Proposed minimal contract: show the current publication and the preserved proposal; the author explicitly chooses Continue as edit, understanding that saving replaces the whole editable content with this proposal. Keep the active new-draft record K as the handoff record, with the exact published target, its loaded base/version and edit mode; autosave it under its existing CAS. Do not create or mutate E when E already exists. The edit route can discover K through the already bounded account/new-form slot (for reviews, the parent slot). If both K and E exist, offer an explicit choice of recoverable work; loading either must not destroy the other. Saving K clears only K's submitted revision. E stays recoverable and, if stale afterward, follows normal version conflict handling. Discard also affects only the chosen record. No new draft list, third record or cross-record copying transaction is required. Once K is cleared, normal edit drafting uses the ordinary edit slot.

Reopening loses image bytes under the existing documented limitation, but the in-place handoff must retain current image entries and ready videos. Storage failure keeps the active proposal and handoff state on screen, marks it at risk and does not block an explicit save. A CAS failure after confirmed publication must preserve any newer local work, not label it published. Deleted originals cannot enter edit; lost admission preserves text but stops privileged work. A URL alone never proves permission or associates an upload with a different target.

Checks: K contains Y, E contains Z, original contains X; recover K, save Y, reopen E → Z still exists with its original version. Cross-tab CAS failure, no storage, hidden/deleted original, review-parent mismatch, and image/video handoff all receive explicit scenarios. Fable: simplify this further if you can without losing either record.

### F-C2 — P2: complete immutable edit base, with explicit conflict consent

Accept F-F2's same-record baseline and F-F3's ownership-first Your review rule. These close actual cross-document gaps. The baseline must include every editable field, explicit blanks, and full ordered media identities/descriptions using the backend's canonical normalization; it excludes counters, timestamps and moderation state. Do not implement a second conflicting browser comparator. An absent or incomplete base makes the shortcut unavailable. The original base does not change on autosave, restore or a failed save. The explicit Save at current version uses a freshly authorized version and the normal edit guard; another race can still reject it. No silent retry and no restoration of destroyed media. The handoff's base is the current publication the author explicitly chose to edit, not the divergent new draft.

Ownership-first navigation conveys no extra mutation authority: Content still controls Delete and Edit. Keep the single-review URL/profile path usable when the parent is deleted or hidden; mask parent content according to the existing rule. A ban cannot erase the author's documented deletion path.

### F-C3 — P2: same-URL retry must bypass the normal unchanged-query no-op

Accept F-F4's cancellation and cancellation-aware handler, but a blind same-URL patch is not a complete retry contract. frontend:84 explicitly skips unchanged query/filter submissions. A retry must deliberately rerun the requested page even though normalized parameters are identical. Prefer one `begin_results` helper called by changed `handle_params` and explicit Retry, using the current normalized URL state, cancellation and the same named task. Submit/filter handlers still only patch. This is one retrieval implementation with two intentional triggers, not two competing owners, and needs no fake query nonce/history entry. Alternatively prove a same-URL patch plus an explicit retry flag on the pinned framework; the helper is simpler.

Local cancellation is not proof that an upstream provider call was stopped; backend concurrency/queue/deadline bounds remain necessary. Verify rapid changes, canceled task exits, old responses after cancellation, identical-query ordinary submit (no fetch), failed-page Retry (fresh fetch) and Back. No synchronous initial-load redesign is required by this finding.

### F-C4 — lifecycle proposals must be conditional, not blanket framework claims

- F-F5.1: stable hook IDs and an isolated browser-owned preview/progress subtree are sound. `phx-update="ignore"` is appropriate for that subtree, not the whole attachment control: otherwise readiness, authorization, removal and error updates can remain stale. A patch does not invariably erase a canvas unless the relevant node is replaced. Specify ownership and test actual replacement rather than asserting every `phx-change` destroys it.
- F-F5.2: agree no IndexedDB restore on `reconnected()`. But a mount can still happen on a remount or changed identity; retain the existing pristine-DOM/typing guard and stale callback checks even with stable IDs. A reconnect is not always continuation of the same server process.
- F-F5.3: pending videos can arrive through draft restore or new preflight after mount. Start/restart one bounded status cycle whenever the pending set changes, including those paths; avoid duplicate cycles on action patch. A `start_async` chain still needs the existing polling delay, stop conditions and cancellation; it is not permission for a tight provider loop.
- F-F5.4–6: accept editor exit audit, quiet `phx-auto-recover`, and durable-video-id recovery. An upload adapter may need reselection to resume after remount; promise recovery of the durable reservation, not unavailable local file bytes.
- F-F6: accept signed-out feedback without forced reload. Preserve on-screen work. An explicit sign-in action should explain any remaining image/unsaved-work risk under the existing leave policy; authentication in another tab can reduce disruption, but it cannot silently switch ownership or revive revoked admission.
- F-F7: accept explicit validated return carrier and no automatic vote/report submission, but do not assume login, registration and public content already share one live session. Route layout is not implemented. Use live navigation only if the actual router/session boundaries permit it; otherwise ordinary navigation carries the same allowlisted destination. Editors still cross the authenticated plug boundary.

### F-C5 — performance checks, not speculative redesign

Ten attachments with provider delays, and thirty maximum-sized full reviews, are legitimate early browser fixtures. Measure editor message responsiveness, initial HTML/connected-render sizes, memory and reading/focus behavior. Current docs already permit one page-owned async publish attempt if synchronous work proves harmful. Do not invent a second upload store, discard full review content, add a client cache, or replace the agreed disclosure pattern on an unmeasured claim.

All frontend recommendations retain current dedicated URLs, form validation, one record's revision CAS, conditional leave warnings, accessible native controls and explicit save. Remaining questions for consensus are the draft handoff's active record, Retry's intentional trigger, and the lifecycle amendments above.

## Fable (McCord lens) — Round 2: critique of Codex Round 1 and convergence proposal

Verdicts: **Accept F-C1's objection**; my "clear both drafts" line repeated the identity-versus-content bug and is withdrawn. **Accept** F-C2, F-C3, F-C4 as narrowings, F-C5 as fixtures. One simplification offered on F-C1, one clarification on F-C4.

### F-C1 — Accept; K is the handoff record, E is never touched

Codex is right twice. Clearing E after saving K destroys Z, which was never submitted; and loading X's version under divergent Y without a decision would silently replace a publication the author has only just learned exists. Converged contract:

- On `:existing_different` or `:existing_unknown`, the editor shows the current publication and the preserved proposal side by side and offers **Continue as edit**, stated as "saving replaces the whole editable content of this tip with your proposal," plus the existing Discard and a link to the published item. Nothing happens until one is chosen.
- Continue as edit is a `push_patch` to the edit URL within the same LiveView. K stays the active record: it gains the published target, the loaded base and expected version and `mode: edit`, autosaved under its existing CAS. E is neither created nor read for writing.
- The edit route discovers K through the bounded new-form slot (parent slot for reviews) by target match, and E through the edit slot. If both exist, offer an explicit choice; loading either leaves the other intact. Saving clears only the submitted record's revision. Discard affects only the chosen record.
- Consequence to state: while K is in edit mode, "New tip" resumes it as "an unfinished proposal to edit tip X" with Continue and Discard, not as a blank tip. That is the existing one-draft-per-account rule applied, not a new list.

Simplification I considered and rejected: moving K into the edit slot when E is absent. It saves one discovery lookup but adds a second path and a cross-slot IndexedDB transaction. Codex's single path is smaller.

Checks as Codex lists, plus: K in edit mode survives reopening and reappears under New tip with its target named; saving Y clears K only; E's Z and version untouched; deleted original → no Continue.

### F-C2 — Accept in full

Base = every editable field, explicit blanks, ordered media ids with descriptions, normalized by the backend's canonical rules; excludes counters, timestamps, moderation state; immutable except on explicit load-latest; for the handoff, base = the chosen publication as loaded. Save at current version goes through the normal guard and can still be rejected. Ownership-first Your review conveys no capability; Content decides Edit and Delete; the single-review and profile paths stay usable under masked parents.

### F-C3 — Accept the helper

One `begin_results` implementation with two intentional triggers: changed `handle_params` and explicit Retry. It cancels the named task, starts the new one with current normalized URL state, and owns the loading flag. Submit and filter handlers only patch; the unchanged-query no-op of frontend:84 stays for ordinary submits. Local cancellation claims nothing about the provider; backend bounds remain. Checks as listed.

### F-C4 — Accept the conditional forms

1. `phx-update="ignore"` on the browser-owned preview and progress subtree only; readiness, authorization, removal and error rows stay server-rendered. Test node replacement rather than asserting destruction.
2. No restore on `reconnected()`; the pristine-DOM and typing guards and stale-callback checks remain for any mount, since a reconnect may be a new process.
3. One bounded status cycle, restarted whenever the pending set changes: restore, preflight, action patch. Dedupe by cancelling the existing chain first; keep delay, stop conditions and backoff.
4. Exit audit, quiet auto-recover and durable-id recovery accepted; resumption may need reselection of local bytes and promises only the reservation.
5. F-F6: sign-in action explains remaining image and unsaved-work risk under the leave policy; no ownership switch.
6. F-F7: the `return_to` carrier is the same whether the login page is reached by live or ordinary navigation, so the route layout decides the mechanism; editors still cross the authenticated plug.

### F-C5 — Accept as early fixtures

Ten attachments with provider delays; thirty maximum-size reviews; measure message responsiveness, render sizes, memory, focus. The existing permission for one page-owned async publish attempt is the only escape hatch.

### Proposed joint frontend conclusion

1. One editor LiveView module per content kind with `:new` and `:edit` actions; handoff by `push_patch`; entries, previews and adapters retained; fresh Content authorization in `handle_params`.
2. Divergent publication: side-by-side proposal and publication; explicit Continue as edit with whole-content replacement consent; K is the handoff record with target, base, version and mode; E untouched; both discoverable; only the submitted record is cleared; New tip surfaces an edit-mode K by its target.
3. Immutable complete base in the edit record; Save at current version only when latest editable fields equal it, through the normal guard; unavailable when absent.
4. Ownership-first Your review; capabilities from Content; banned authors keep Delete.
5. Search: `begin_results` helper, explicit cancellation, cancel-aware handler, first-load flag, unchanged-query no-op retained for submits.
6. Lifecycle: ignore-subtree only for browser-owned nodes; mount-only restore with guards; one status cycle restarted on pending-set change; plain-anchor exits; quiet auto-recover; reservation-only resume promise.
7. Re-admission failure is authoritative sign-out; preserve work; explain risk; return carrier back to the editor.
8. Return carrier independent of live-session layout.
9. Fixtures: ten attachments under delay, thirty full reviews.
10. Retained: dedicated URLs, validation on submit, revision CAS, conditional leave warnings, native controls, explicit save, paged lists, mark-once inbox, Copy and Play/Hide hooks.

If Codex accepts 1–10, the frontend phase is at consensus and the three-phase review is complete.

## Codex Round 2 — acceptance and final frontend consensus

I accept Fable Round 2 items 1–10 and its explicit withdrawal of clearing both records. The fixed contract preserves both authorship intent and storage identity. No remaining design disagreement requires another round.

Three integration cases make the agreed handoff testable; they do not add a second recovery system:

- **Lost edit response after handoff:** K's persisted `mode: edit`, target and expected version select the existing uncertain-edit recovery contract, not the original new-publication key lookup. A found original publication is never proof that the later edit succeeded. Keep unresolved submitted values fixed until reconciled, and preserve work when equivalence cannot be established.
- **Hook identity during action patch:** retain upload entries and browser-owned nodes through this explicit same-account, same-proposal transition, while updating the hook's logical form target/mode. A normal unrelated target/account change must not reuse those values. Stable DOM ids are not authorization. Test patch, refresh, Back and reconnect; each must resolve the stored mode/target consistently and must not turn an edit proposal back into a new publish attempt.
- **Two records and storage failure:** K is the sole autosave/clear target while recovering K. E remains untouched even if displayed as another recovery choice. A failed handoff autosave preserves on-screen work and the risk warning; a successful server save does not justify clearing an unsubmitted or newer revision. Browser refusal or loss of storage does not prohibit an explicit server save.

The backend's B-C8 target-equivalence predicate, frontend's process-preserving action patch, and the active-record rule form one end-to-end fix. Each alone would leave repeated upload work or a data-loss path.

**Phase status: consensus after two rounds.** Accepted F-F1/F-C1 with corrected draft ownership and explicit replacement consent; F-F2/F-C2 complete base; F-F3 ownership-first deletion access; F-F4/F-C3 bounded cancellation and intentional retry; narrowed F-F5/F-C4 lifecycle rules; F-F6/F-F7 admission and return navigation; F-C5 performance fixtures. Rejected: clearing an unrelated edit draft, implicit whole-content replacement, silent reload for admission failure, blanket ignored attachment controls and unmeasured frontend redesign. No unresolved disagreement remains.

### Fable closure acknowledgement, recorded by Codex

Fable confirmed through pane `wJ:p1` after reading Codex Round 2: "No substantive contradiction in the three cases" and "All three phase files stand as written." Fable clarified that Back to the new-form URL must surface the stored edit-mode proposal and its target rather than initialize a blank new publication; route action alone must not discard the handoff state. Content authorization remains authoritative. Both reviewers therefore explicitly accept the final verification cases as well as the decisions above.
