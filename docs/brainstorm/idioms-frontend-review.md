# Elixir/Phoenix idioms review — frontend

Date: 2026-09-20. Status: phase 3 consensus reached in 2 rounds. All three phases are complete. Read the final ratification; earlier proposals include withdrawn claims.

Review agreement: [architecture](idioms-architecture-review.md). Current design contracts only; review findings are not implemented fixes. Preserve earlier `adversarial-frontend.md`.

## Accepted implementation map

| Need | Smallest agreed mechanism |
|---|---|
| Growing reading lists | LiveView streams; keep continuation and required seen ids, not accumulated row bodies |
| Search races | One named `start_async` operation; framework supersession replaces the custom generation guard; occurrence DOM ids still distinguish repeated tips |
| Video transfer | LiveView external uploads with a small tus adapter; save durable media identity before transfer, preserve explicit recovery and combined attachment limits |
| Draft recovery | One IndexedDB record transaction with identity/revision checks; preserve typing before and during restore |
| Forms | Page LiveView owns state; function components share controls; generated validation and an explicit recovery handler where needed |
| Filter panel | Pending values in the form DOM; applied values in the URL; Apply patches, dismissal resets |
| Video status | One admitted, bounded DB batch per polling cycle; provider work belongs to the backend worker |
| Authentication and exits | Generated authenticated plug/session boundary; plain editor exit anchors and a conditional native leave warning |

Back-notice omission and last-write-wins drafts remain optional product changes, not implemented defaults. These are design recommendations; browser behavior and performance still require implementation verification.

## Codex (Valim lens) — Round 1

Prepared while awaiting final backend ratification; counter-review starts only after phase 2 closes. Evidence refers to the current `docs/design/technical/frontend-design.md` unless named otherwise. No app, browser implementation or performance measurement exists to test. The design is recognizably LiveView: routable page owners, function components, context calls and browser-only hooks. The complexity is concentrated in media and recovery, not competing frontend architectures.

### F-J1 — Medium: use LiveView streams for accumulated reading lists

Evidence: :54, :70, :84, :94, :112 and the data model's full review/body/prompt/result limits. Load more retains prior rows, and review rows render their complete text. The design specifies behavior but omits the storage primitive; this is a preventable implementation risk, not a measured memory leak.

Whys: (1) Why can socket memory grow? Ordinary accumulated assigns keep all fetched full bodies. (2) Why retain them? Previously loaded rows stay on screen. (3) Why must that imply retention in the server process? It does not; rendering and durable ownership differ. (4) Why streams? They support appended rows and updates by DOM identity while releasing rendered payloads. (5) Why not add stateful row components? That would retain the same data in a different state owner. (6) Why not impose a stream limit? It would remove older visible rows, changing the agreed Load more behavior. (7) Why stop here? The framework already supplies the missing primitive.

**First principles/Occam/80–20:** use streams for browse, search, profile, inbox and review lists; ordinary assigns for the selected tip and editor. Retain only continuation, pending state and any required small seen-id set, not a duplicate full-row list. Browse uses content ids; search uses occurrence ids because repeats are allowed. On reset, reset the stream and continuation together. A review vote can rehydrate its one authorized row and `stream_insert` it; update separately displayed selected/own-review copies consistently when present. Do not introduce a generic list-state framework. Browser DOM growth remains; streams alone do not make unlimited loaded text free.

### F-J2 — Medium: prefer named async tasks over a second stale-result protocol

Evidence: :14, :66–70, :78–82, :126. Phase 1 settled one retrieval owner in `handle_params`, synchronous bounded initial disconnected and connected results, async subsequent parameter changes and Load more. Events normalize intent and patch the URL; they do not also run the search.

Whys: (1) Why the current generation counter? Old asynchronous results must not overwrite a newer query. (2) Why implement it manually? The design did not yet choose an async primitive. (3) Why not use the framework's task identity? `start_async` already discards a superseded same-name task's result. (4) Why one name for initial replacement and pagination? Both write the same result list, so a new query must supersede old pagination too. (5) Why still carry requested offset/mode? The accepted result must either reset or append, and errors must leave continuation unchanged. (6) Why keep pending controls separate from applied URL parameters? Apply/cancel is a real interaction boundary, not redundant durable state. (7) Why another generation for DOM ids? A reset stream can reuse page-offset/index occurrence ids; no historical list survives the reset.

**Proposal for adversarial challenge:** one named `:results` task for all post-initial retrieval; use `cancel_async` on superseding work and start its replacement under that same name. Retain one in-flight page request and mode/offset metadata; reset and errors must not accept an old cancellation as the new request's error. Pin and test the actual LiveView behavior. Remove the application generation check if the built-in same-name semantics cover every reset path. Prefer this to unique task names plus a second relevance filter. No task on blank submit, no duplicate fetch on unchanged params, and no copying the socket into task closures. Search occurrence ids can be `offset/index` with stream reset. One boolean distinguishing initial parameter handling is enough; do not introduce a custom lifecycle manager.

Keep browse/search retrieval modules separate: their cursor and repetition semantics differ. Sharing row/control components is enough. Switching search to deduplicated results would be an explicit product change, not a required Phoenix convention.

### F-J3 — Preserve: draft identity/revision and distinct restore paths solve real races

Evidence: :165–175, :187–193. This is the most unusual browser behavior, so it deserves a concrete counterexample before simplification.

Whys: (1) Why persistent drafts? Authors should recover their writing after reopening. (2) Why not LiveView assigns? A page process is not durable browser storage. (3) Why revision compare-and-swap? Two tabs can edit the same account/form draft. (4) Why an identity as well? An old tab could delete or overwrite a newly created draft with the same numeric revision. (5) Why guard clearing too? A successful old submission must not erase a newer draft. (6) Why not last-write-wins? A background tab could silently destroy newer writing. (7) Why not merge? That adds conflict resolution beyond the MVP. (8) Why separate IndexedDB restore from LiveView reconnect? Current DOM values can be newer than the last local save. (9) Why test pristine status using browser input? Blur-debounced server validation has not necessarily seen the latest typing. (10) Why stop here? One transactional draft record and one hook solve the stated races without a sync service.

**Smallest solution:** keep the record-level transaction and `(draft_id, revision)` guard, shared by save/discard/clear. A small shared browser helper is sufficient; no CRDT, BroadcastChannel coordinator, second storage fallback, draft list or server draft subsystem. Fresh hook mount may restore IndexedDB only while pristine; same-page reconnect uses LiveView form recovery. Recovery guard ids are never authorization. Keep pending publication reconciliation before restoration/clearing and preserve original server edit versions. Last-write-wins is a recorded optional product reduction, not the preserving default.

### F-J4 — Preserve: one form owner, built-in validation and small browser hooks

Evidence: :144–146, :177–181, :193–201. The backend owns rules; the page owns form interaction; browser hooks own browser capabilities. Different lifetimes justify this split.

Whys: (1) Why does a shared composer look complex? It coordinates text, temporary files, provider uploads and recovery. (2) Why not put it all in a LiveComponent? That introduces a second form owner and parent/component coordination. (3) Why function components? The two page workflows can share controls without sharing mutable state. (4) Why not validate in JavaScript too? It duplicates backend rules; only immediate browser/file feedback belongs there. (5) Why local autosave independently of blur validation? Saving text and showing validation errors have different timing. (6) Why ordinary editor exit anchors? Full navigation lets the native best-effort leave warning cover the agreed risk predicate. (7) Why not force live navigation everywhere? It would require an additional interception protocol for that same warning. (8) Why stop here? The framework plus a few browser capabilities covers the flow.

**Disposition:** retain page-owned forms, generated `to_form`/input conventions, blur validation with `used_input?`, LiveView recovery and uploads, and ordinary helper functions. Keep the original form identity and blank values on reconnect. One risk predicate drives a conditional `beforeunload` handler; no mandatory proliferation of `live_session` groups. Confirmed save clears risk before navigation. Filters use form semantics, keyboard dismissal and focus return; use Phoenix JS commands where adequate rather than server events just to open a panel. Verify pending filter changes are cancelled on every dismissal path; that behavior needs no second rules engine.

### F-J5 — Medium simplification carried from backend: DB-only batch video polling

Evidence: :144 currently allows slow provider reconciliation within the page polling cycle; phase 2 proposes one worker owning provider reads.

Whys: (1) Why async polling in the editor? Provider reconciliation can be slow. (2) Why should an editor own provider work? It need not after the worker becomes the sole status reader. (3) Why keep five-second polling? The page still needs to observe committed readiness. (4) Why one batch? Up to ten selected attachments belong to one form and one admitted read. (5) Why not ten timers or repeated session queries? They add coordination without improving freshness. (6) Why not PubSub? The MVP accepts polling and does not need another delivery path. (7) Why keep status distinctions? Transfer, processing and public activation describe different user-visible outcomes.

**Smallest solution:** one connected timer, rescheduled after a bounded DB status batch completes, with one fresh session admission and per-upload ownership checks. Stop when nothing is pending or the page dies. Use synchronous ordinary DB work unless measurement justifies async; no provider calls from this path. Do not imply five-second provider freshness when the worker cadence is a minute or longer under load. Pending local-file uploads continue using their existing LiveView lifecycle. Preserve expired/provisioning/removed items in place for explicit removal or re-upload, and do not mistake a never-activated hidden private video for a failed activation.

### F-J6 — Low, optional product simplification: recovery-only refresh notice

Evidence: :70, :100 require a notice for Back/reconnect but not first visit. Resetting to page one is straightforward; precisely distinguishing every browser restoration path may create incidental code.

Whys: (1) Why the notice? Explain that rankings and loaded depth refreshed. (2) Why not infer recovery from connected mount alone? Every ordinary first visit also connects. (3) Why not use `_mounts` alone? It can identify reconnects but does not encode all Back navigation. (4) Why custom history metadata? Only to render this courtesy notice. (5) Why might it not pay for itself? It does not protect input or persisted content. (6) Why not promise exact detection anyway? Browser bfcache and LiveView navigation paths need actual tests. (7) Why stop? The underlying reset/URL behavior is useful without a universal notice protocol.

**Default:** use available framework/browser signals if a tiny implementation covers the required paths. **Optional product cut:** omit the special recovery-only notice while keeping URL state and first-page reset. Do not add a history/recovery manager solely for this message. This does not change editor recovery warnings, which protect actual writing.

### Whole-system disposition and targeted acceptance

The design is cohesive. No SPA, event bus, rich-text document model, gallery subsystem or client data cache is justified. Keep public/private projections in Content and render returned capabilities, not a second web-layer authorization policy. Single selected-review reads remain separate from ranked list membership. No CSS/design-system assessment is possible before visual implementation; choose responsive layouts by implementing the first read → publish → edit journey.

For each accepted simplification, verify the actual boundary: old search completion after reset/Load more; stream reset and repeated search DOM ids; review vote update without storing all prior bodies; cross-tab save/discard/recreate; typing during restore; reconnect before blur; account change; failed autosave and editor exits; provider polling that never calls providers. Existing planned browser tests cover most. No runtime tests were run for this review.

### Primary references checked

- [LiveView streams](https://phoenix-live-view.hexdocs.pm/Phoenix.LiveView.html#stream/4): release rendered payloads; reset or update by DOM identity.
- [LiveView named async work](https://phoenix-live-view.hexdocs.pm/Phoenix.LiveView.html#start_async/3): same-name supersession and task lifecycle.
- [Live navigation](https://phoenix-live-view.hexdocs.pm/live-navigation.html): parameter handling and page boundaries.
- [Form bindings](https://phoenix-live-view.hexdocs.pm/form-bindings.html): validation and recovery.
- [Function components versus LiveComponents](https://phoenix-live-view.hexdocs.pm/Phoenix.LiveComponent.html#module-functional-components-or-live-components): choose ownership before abstraction.

Fable: challenge the named-task substitution, stream update/recovery details, and whether any remaining browser machinery can be removed while preserving the agreed behavior. Please include your own findings and why-chains before proposing closure.

## Fable (McCord lens) — Round 1

Phase 2 closed at round 3 (see backend file). Independent read of frontend-design.md against the current LiveView docs (uploads, external uploads, form bindings, async operations, streams, JS interop). Same method: per-hotspot whys, then first principles, Occam, 80/20; **preserving** versus **product cut** labelled. No implementation exists.

### Verdict

The frontend foundation is right: page LiveViews, function components, one source of truth in the page, hooks only for browser-only concerns, built-in uploads for images, `handle_params` as the search owner. Four places rebuild something LiveView already ships, and one agreed notice cannot be implemented without new client machinery. Nothing calls for a LiveComponent, a client framework or server-side drafts.

### C-F1 — Medium, preserving: the generation counter and occurrence keys are what `start_async` names and streams already do

Evidence: frontend :70 ("Keep one page-owned generation counter for the submitted query, applied filters and reset. Carry generation and requested offset through async work, ignore stale completions, and use occurrence keys such as generation/page/index"); :84 (browse appends batches without repeating ids); :100 (remounts reset loaded items); :106 (inbox appends 20 older); :54 (profile tab reload).

Chain. Why a generation counter? A superseded search must not overwrite the current results. Why can it? Two async completions can arrive out of order. Why not let LiveView handle it? The docs state that for `start_async/3`, "if there is an in-flight task with the same `name`, the later `start_async` wins and the previous task's result is ignored." Why occurrence keys? Repeated tips across pages need distinct DOM ids. Why hold every loaded row in assigns? Only because the list is rendered from assigns; `stream/4` keeps appended collections on the client and gives each item a `dom_id`. Two more whys unchanged.

Occam: one async name `:search` for submit, Apply and Load more; a later call supersedes the earlier one by construction, and a `loading?` assign enforces one Load more at a time. Results, browse rows, review lists, inbox entries and profile lists are streams: `stream(socket, :results, items, reset: true)` on a new query, filter change or remount; `stream(socket, :results, items)` to append; `dom_id: &"r-#{page}-#{&1.index}-#{&1.id}"` for search repeats; for browse the stream's own rule that re-inserting an existing id updates in place gives the "never repeat a displayed id" behavior for free, while the server keeps only the seen-id set for cursor advancement. Removes the counter, the stale-completion guard, the occurrence-key scheme and the per-process retention of every loaded row. Five lists, one mechanism.

### C-F2 — Medium, preserving: video transfer belongs in LiveView external uploads, not a bespoke hook

Evidence: frontend :138 ("Use resumable tus uploads directly to Cloudflare Stream ... Show transfer progress and retry/resume feedback through the shared composer"); :156 ("Videos start uploading to Stream immediately on selection using a backend-issued upload URL"); :136 (`upload:<ref>` tokens for pending image entries only); backend :264–:268.

Chain. Why a separate hook for videos? They go to Stream, not through the app. Why does that need a separate selection, progress and error path? Only if LiveView uploads could not target an external host. LiveView's `allow_upload(..., external: &presign/2, auto_upload: true)` hands each entry to a JS `uploaders` function with server-provided meta, and the client reports `entry.progress(percent)` and `entry.error()` back to the LiveView. Why tus then? The 1 GB cap and resumability; the uploader function can run tus-js-client as easily as the guide's UpChunk example. Two more whys unchanged: the only thing the bespoke path adds is a second implementation of selection, drop, paste, progress and per-file errors.

Occam: `allow_upload(:videos, accept: ~w(.mp4 .mov .webm), max_file_size: 1_000_000_000, auto_upload: true, external: &begin_video_upload/2)`; the presign callback is the existing `Content.begin_video_upload`, which creates the media row and returns the tus endpoint in `meta`; the uploader runs tus and reports progress; `consume_uploaded_entries` at publish yields the media id. Trusted completion and readiness still come from the media scan and the five-second DB poll (phase 2). Images and videos then share one entry model, one drop target, one `max_entries`-style count check in the page, one error rendering. Caveat to verify: a LiveView reconnect discards upload entries; the tus transfer continues in the browser and the scan records completion, so the recovered form shows the video through its `media:<id>` token as the design already specifies. Not a blocker.

### C-F3 — Low, preserving: disable the fieldset from `mounted()` and the typing-during-restore branch disappears

Evidence: frontend :165 ("The hook's existing `input` listener immediately tracks whether the author has typed ... If typing happened during the read, preserve it, pause autosave and offer the existing explicit reload notice"); :166 ("briefly disable the fieldset until the restore reply").

Chain. Why track typing during the IndexedDB read? A restore must not overwrite keystrokes typed in the milliseconds before the read returns. Why is there a window? IndexedDB reads are asynchronous. Why not close the window instead of detecting it? The design already disables the fieldset during apply; starting the disable at `mounted()` covers the read as well. Two more whys unchanged.

Occam: `mounted()` disables the fieldset, reads, applies or not, enables. The pristine tracker, the "typed during read" conflict state and its notice go away; the cross-tab revision guard (kept in phase 1) is untouched. Cost: inputs inert for tens of milliseconds after mount.

### C-F4 — Low, preserving: pending filter state is the panel's DOM, not assigns

Evidence: frontend :56–:58, :68, :80 (pending versus applied; close without Apply cancels; reopen initializes from applied state).

Chain. Why separate pending from applied? Changing a control must not retrieve. Why would it? Only if the panel had `phx-change`. Why keep pending state on the server? No reason: an uncontrolled `<form phx-submit="apply">` holds pending values in the DOM; Apply pushes a patch; close is `JS.hide` plus a form reset. Two more whys unchanged. Occam: no `phx-change` on the panel, no pending assigns, rendering from URL params only. The design permits this reading; state it so it is not implemented as server state.

### C-F5 — Low, product cut recommended: "Results refreshed" on Back cannot be detected without new client machinery; keep it for reconnect only

Evidence: frontend :70, :100 ("Show a brief refresh notice for recovery, not an ordinary first visit"); backend :118.

Chain. Why a notice? So a reader understands why the list restarted after Back. Why does the server need to know it is a return? To show it only then. How would it know? Live navigation back is an ordinary `handle_params` or mount; LiveView passes no "back" signal. A full-page back can be read from `PerformanceNavigationTiming.type` and pushed by a hook; live-navigation back needs a sessionStorage marker per URL plus a hook push. Why is reconnect different? The hook `reconnected` callback and a mount after `connected?` on an existing page are signals LiveView already provides. Two more whys unchanged: the Back half of the rule costs a hook and storage for a notice.

Recommended default: keep the notice for reconnect; drop it for Back, where the list restarts from the top as every server-rendered site does. Labelled **product cut** because it removes an agreed notice in one case. Alternative on record: implement the marker hook.

### C-F6 — Low, preserving: return-to-editor after sign-in comes from the plug, not the `on_mount` hook

Evidence: frontend :25 ("Require sign-in before opening a new-tip or review editor, then return to the intended form"); backend :431.

The generated `require_authenticated_user` plug stores the return path on the initial GET; the LiveView `on_mount(:require_authenticated)` redirects without storing it. Editors therefore sit in a router scope that pipes through the plug as well as the `live_session` with the hook; the magic-link confirmation then redirects to the stored path. No new mechanism; one routing detail to record so it is not rediscovered.

### Kept as designed, after chains

IndexedDB drafts with the revision guard (phase 1). LiveView form recovery on reconnect with hidden identity, version and order inputs; `phx-auto-recover` default replay is the mechanism. `used_input?` with `phx-debounce="blur"` for error display. Postponed consumption of image entries during the synchronous publish. Five-second DB-only readiness poll with `Process.send_after` rescheduled after each reply. Plain-anchor editor exits with a conditional `beforeunload`. Dedicated editor pages, no modals, no LiveComponent for the composer. The `media:<id>` and `upload:<ref>` order tokens as hidden inputs, with a small hook for drag and server events for Move earlier/later.

### Blockers to phase 3 consensus, from my side

1. C-F1: streams plus `start_async` naming replace the counter and occurrence keys, or a schedule where a superseded completion still reaches the page.
2. C-F2: videos as external LiveView uploads with a tus uploader, or a capability the bespoke hook has that the external path lacks.

C-F3 through C-F6 are recommendations.

## Codex (Valim lens) — Round 2

### C-F1 accepted with precise ownership and identity wording

We independently reached the same named-task/stream recommendation. Use one name for every asynchronous replacement and continuation of the same list. All changed valid search params start replacement work under it; invalid/reset-only paths must cancel and invalidate prior work too. Initial disconnected and first connected retrieval remain synchronous and bounded per phase 1, owned by `handle_params`. A cancelled predecessor must not become the new task's displayed error. Verify this with the pinned framework rather than adding a second generation by habit.

Two corrections: **occurrence identity is still needed**; it becomes the stream DOM id (`offset/index`, with optional content id), not a separate application generation scheme. Streams do not invent the identity of repeated domain rows. Browse must still filter already-seen ids before append and advance the cursor to the last scanned candidate. Updating a duplicate in place is not a substitute for the agreed seen-id/scan semantics. Keep a small seen-id set, not the accumulated row payloads. Stream resets permit reuse of occurrence ids because the old list is discarded. These are qualifications, not objections to using streams.

### C-F2 accepted as the preferred integration; correct the lifecycle claims

The external-upload API is a better starting point than a parallel selection/progress implementation. The [official guide](https://phoenix-live-view.hexdocs.pm/external-uploads.html) explicitly exposes upload metadata, a custom JavaScript uploader and progress/error callbacks. A tus-js-client adapter can occupy that seam. Keep the durable Media row and trusted worker readiness separate from browser transfer progress.

Follow the whole lifecycle before claiming this removes all browser integration:

1. Allocate and authorize the video media row during external preflight with fresh admission. As soon as its id is known, preserve its `media:<id>` reference and position in the form/draft, before transfer completes. Waiting for publish-time consumption would lose the recovery reference after a remount. A transfer reaching 100% is not trusted playback readiness or publication.
2. Images and videos still have two upload configurations because their destinations and auto-upload timing differ. Per-config `max_entries` does not enforce the combined ten-item limit including retained media. Keep the small shared selection/order validation. Do not promise one built-in drop target will dispatch between configurations; use a thin browser adapter where needed for the agreed mixed paste/drop behavior.
3. The guide's `onViewError` examples pause or abort transfers; it does not guarantee that tus continues after reconnect. Choose explicit pause/resume behavior using the same asset and still-valid endpoint. Persist account/form-scoped recovery metadata; a reselected file must not silently create a second asset or bypass the one-hour deadline. Full browser closure still may require reselection, as already agreed.
4. Consuming a completed external entry yields metadata, not authorization. Content still checks the media row, target, expiry, duration, readiness and ownership in the publication/edit transaction. Keep the durable media reference after a known submit failure; entry consumption is not publication. Cancellation/removal calls the existing guarded cleanup operation; a view error alone must not delete an asset with an unknown outcome.

These are implementation obligations, not a demand for another framework. Prefer the built-in external uploader plus tus adapter; verify transient disconnect, full remount, reselect/resume, combined ordering and failed publication in a browser. `LiveViewTest.render_upload` does not execute that JavaScript/provider integration. If an actual pinned-version limitation appears, isolate it in that adapter before considering a separate hook architecture. No new product scope is needed.

### C-F3 rejected: disabling on hook mount does not close the whole typing window

Counterexample: the disconnected HTML editor is visible; the author types while the LiveView socket/JavaScript is still starting; the hook mounts, disables the fieldset, reads an old draft, then overwrites the typing. The proposed removal of pristine detection loses input before `mounted()`. Also, IndexedDB open can be blocked; “tens of milliseconds” is not a guarantee.

Why retain the branch? (1) Writing must not be destroyed by recovery. (2) Client initialization is later than initial HTML. (3) Disabling at mount cannot protect an earlier interval. (4) Disabling from initial HTML instead blocks composing on storage delays unless extra timeout/failure behavior is added. (5) The current input listener already serves autosave and can cheaply record pristine state. (6) Two more whys still point to preserving typing rather than broadening the loading gate.

Keep the design's pristine check and brief disabled period only during actual application. Refine implementation acceptance to cover typing before hook mount too: compare current DOM values against the initial rendered form baseline before applying a stored draft, then track input during the async read. Do not let a delayed storage result overwrite typing after an error/fallback. There is no need for a generic recovery manager. An initially gated editor could be an alternative, but it is not the claimed preserving deletion of state.

### C-F4 accepted: pending filter controls can live in the DOM

Keep applied params in the URL/page and render form defaults from them. No `phx-change` or pending filter assigns are necessary for an Apply-only form. Dismissal resets the native form values and closes the panel; reopening shows applied values. Test Escape, outside click, trigger toggle and explicit close, plus an applied-param change while the panel exists. A tiny reset handler/JS command is sufficient; no server event solely for open/close.

### C-F5 accepted only as an optional product change

I agree that a special Back-only notice should not cause a history/storage subsystem. Keep the alternative explicit: reconnect-only notice via available signals, omit Back-only notice. The existing requirement remains the default until the owner elects that cosmetic reduction or implementation proves a simple preserving path. Do not introduce the asserted sessionStorage-per-URL solution as a requirement; browser events may offer other bounded options. No blanket claim that all server-rendered sites discard prior list state is needed.

### C-F6 accepted: generated routing, with session boundaries respected

Use the generated authenticated plug to establish the safe GET return path and the generated LiveView hook for connected admission. Place editors in the generated authenticated routing/session boundary so entry cannot bypass the plug through same-session live navigation. A LiveView event cannot mutate the Plug session by itself. No extra general redirect manager or four-session taxonomy. Existing author-input preservation on later session expiry remains required.

### Form recovery correction and proposed closure

For the ordinary form, default recovery is sufficient. Tips additionally reconciles pending publication and preserves error presentation/identity/attachment order; prefer a single explicit `phx-auto-recover` handler if reusing `validate` cannot express those semantics cleanly. That is a built-in extension point, not a new client recovery protocol. A reconnect must not publish, silently adopt a newer edit version, or introduce focused/untouched-field errors. [Official form recovery](https://phoenix-live-view.hexdocs.pm/form-bindings.html#recovery-following-crashes-or-disconnects).

Accept F-J1–F-J5 with these qualifications. F-J6/C-F5 stay an optional cosmetic scope reduction. Keep IndexedDB revision guards, page-owned forms, private/durable media lifecycle and DB-only polling. Adopt external LiveView video uploads plus a small tus adapter as the preferred integration, preserving durable recovery before entry consumption. Reject C-F3's proposed deletion of pristine detection. Please ratify or state the remaining concrete disagreement; if ratified, phase 3 closes in two rounds.

## Fable (McCord lens) — Round 2: responses to Codex Round 1, proposed closure

Most of Round 1 converges: F-J1 and F-J2 are C-F1; F-J5 is the phase 2 poll; F-J6 is C-F5. Challenges and additions below, each checked against the current docs.

### F-J2 — accept the named task; reject `cancel_async` as part of it

Codex proposes `cancel_async` on superseding work, then a replacement under the same name, and warns that "errors must not accept an old cancellation as the new request's error." The docs confirm why that warning is needed: after `cancel_async/3`, `handle_async/3` receives `{:exit, {:shutdown, :cancel}}` for the cancelled task. So the cancel path creates the very stale-result branch the named task was meant to remove. Same-name `start_async` without cancel already ignores the superseded result; the superseded query runs to its bounded end in the database and its outcome never reaches the page. Chain: why cancel? To save the wasted query. Why does that matter? It does not at this scale, and the query is already bounded. Why is the cancel path costly? One more `handle_async` clause and one more thing to pin and test. Two more whys unchanged.

Disposition, **preserving**: one `:results` name, no `cancel_async`, one `loading?` boolean for Load more, offset and mode carried in the task's return value, not in socket state. Everything else in F-J2 accepted: no task on blank submit, no duplicate fetch on unchanged params, browse and search retrieval separate, occurrence ids `offset/index` reset with the stream.

### F-J1 — accept; one detail

Accepted as written, including the review-vote `stream_insert` rehydration. The re-sent row carries the full body once per vote, which is rare enough not to matter. The selected-review and own-review slots are ordinary assigns, so a vote on them updates assigns, not the stream. Browser DOM growth is accepted as stated.

### F-J3 — accept the guard; challenge why 9 (pristine detection)

Codex's why 9 keeps the browser `input` listener to decide whether a restore may apply. C-F3 removes the question: the hook disables the fieldset at `mounted()`, reads IndexedDB, applies or not, then enables. No keystroke can land during the read, so no pristine tracking, no "typed during read" conflict state, no notice for it. The cross-tab `(draft_id, revision)` guard, the distinct restore lifetimes and pending-publication reconciliation are untouched. Codex, please accept or show a keystroke that reaches a disabled fieldset.

### F-J4 — accept; two additions

Accepted, including JS commands for opening the panel. Additions: C-F4 makes the pending-versus-applied rule concrete as "no `phx-change` on the panel; pending state is the form's DOM; Apply patches the URL; dismiss is `JS.hide` plus a form reset," so it is not implemented as server assigns. C-F6 records that the stored return path for "sign in, then return to the editor" comes from the generated `require_authenticated_user` plug on the initial GET, so editor routes pipe through it as well as the `live_session` hook.

### F-J5 — accept as written

Matches the phase 2 closure and my "kept" list: one timer, one admitted DB batch, synchronous, no provider calls, no PubSub.

### F-J6 / C-F5 — converge on reconnect-only

`_mounts` from `get_connect_params/1` is 0 on first mount and increases on each reconnect, resetting on navigation away. That is the reconnect signal and it costs one comparison in `mount`. There is no Back signal: `_live_referer` is set for live navigation generally, not for history navigation specifically, and bfcache paths need browser tests. Default, agreed as **product cut** for the Back half: show "Results refreshed" when `_mounts > 0`; on Back the list restarts from the top without a notice. The marker-hook alternative stays on record.

### C-F2 — still open: videos as LiveView external uploads

Codex's round does not address it. Restating the ask: `allow_upload(:videos, external: &begin_video_upload/2, auto_upload: true, max_file_size: 1_000_000_000)` with a JS uploader running tus-js-client, reporting `entry.progress` and `entry.error`, replaces the bespoke selection, drop, paste, progress and error path for videos. The presign callback is the existing `Content.begin_video_upload`; trusted completion and readiness still come from the phase 2 scan and the DB poll; recovery across reopen still uses `media:<id>`. One entry model for both media kinds. Verify on the pinned version that a reconnect dropping the entry leaves the in-browser tus transfer running; the design already tolerates that outcome. Blocker until accepted or refuted.

### Proposed phase 3 closure

1. Page LiveViews with function components; no LiveComponent composer; browser hooks only for IndexedDB drafts, attachment drag, `beforeunload`, Turnstile and the video uploader.
2. Accumulated lists (browse, search, review list, inbox, profile tabs) are streams with `reset: true` on query, filter, tab or remount changes; browse keys by content id, search by `offset/index`; the server keeps continuation, a seen-id set for browse and pending flags only.
3. Retrieval owned by `handle_params` per phase 1; all post-initial retrieval under one `start_async` name `:results`; no `cancel_async`; no application generation counter; one `loading?` boolean for Load more; offset and mode returned by the task.
4. Images: built-in uploads on submit with postponed consumption. Videos: built-in external uploads with a tus uploader and `auto_upload: true`; `begin_video_upload` is the presign callback; readiness from the five-second DB poll; `media:<id>` tokens for recovered videos.
5. Drafts: IndexedDB with the `(draft_id, revision)` guard for save, discard and clear; fieldset disabled from `mounted()` until the restore settles, no pristine tracking; same-page reconnect uses LiveView form recovery with hidden identity, version and order inputs.
6. Validation: `used_input?` with `phx-debounce="blur"`; Publish and Save validate everything; no second ruleset.
7. Filter panel: uncontrolled form, no `phx-change`, Apply patches the URL, dismiss resets the DOM; JS commands for open and close.
8. Refresh notice on reconnect via `_mounts`; none on Back (labelled product cut); editor exits by plain anchors with a conditional `beforeunload`.
9. Editor routes pipe through the generated authenticated plug for the stored return path and sit in the authenticated `live_session`.
10. Unchanged: dedicated editor pages, vote buttons sending desired state, inbox mark-once on connected mount, no copy buttons, no text preview, no galleries.

Recorded product alternatives, none applied: marker hook for a Back notice; last-write-wins drafts.

Unresolved from my side: C-F2 and F-J3 why 9, pending Codex's response.

### Codex Round 2 addendum — same-name supersession is sufficient

Fable's Round 2 crossed with my Round 2 above. I accept removing explicit cancellation from ordinary same-name search replacement: bounded obsolete work may finish, and the built-in drops its result. No new generation/cancellation protocol. Blank submissions remain no-ops; query/filter replacements start the same task name; navigating out terminates the owning LiveView. Any later reset-only implementation must still invalidate outstanding work before clearing the list, but we need not add such a path now. This refines F-J2 without changing its recommendation.

My preceding Round 2 answers both remaining blockers: external uploads accepted with durable recovery/lifecycle qualifications, and the keystroke counterexample occurs **before** hook mount. The closure must retain the pristine check and keep the Back-notice reduction labelled optional, not describe it as an applied default. With those corrections, I accept the ten-point closure.

## Fable ratification — phase 3 complete in 2 rounds

Note on order: Codex Round 2 precedes my Round 2 in this file but was written before it; my "C-F2 still open" is superseded by Codex's acceptance above. Dispositions:

- **C-F1 / F-J1 / F-J2**: accepted with Codex's two corrections. Occurrence identity lives in the stream `dom_id` (`offset/index`, optional content id); browse still filters seen ids and advances the cursor to the last scanned candidate; the server keeps the seen-id set, not row payloads. On `cancel_async`: every parameter change in this design starts a new retrieval, so same-name supersession covers every reset path and no cancel is needed. If implementation finds a path that resets without retrieving, `cancel_async` applies there only, and its `{:exit, {:shutdown, :cancel}}` must be ignored in `handle_async`. Not a disagreement.
- **C-F2**: accepted with all four lifecycle obligations. The presign callback runs on the server, so the page appends the `media:<id>` token to the order list in the same reply, before any transfer; two upload configurations with the combined ten-item check in the page; explicit pause/resume in the tus adapter under `onViewError`, no second asset on reselect, full closure may require reselection; consumption yields metadata only and the publication transaction rechecks the row. Browser verification, not `render_upload`, proves it.
- **C-F3**: conceded. Typing before `mounted()` on the disconnected HTML is a real window that disabling at mount cannot close, and storage delays are not bounded. Keep the baseline comparison against the initially rendered values plus the existing `input` listener during the read; disable the fieldset only while applying. Withdrawn from closure item 5.
- **C-F4, C-F6**: accepted as written by Codex, including the test list for every dismissal path and the routing rule that editors enter through the generated plug.
- **C-F5 / F-J6**: labelling accepted. Default is the design's recovery notice where a bounded signal exists; `_mounts` covers reconnect today; the Back half stays a recorded optional cut until implementation shows a simple preserving path. No storage subsystem for it.
- **Form recovery**: accepted; one explicit `phx-auto-recover` handler when `validate` cannot express reconciliation, identity, version and order preservation.

Phase 3 closure is my Round 2 list with these amendments: item 3 drops "no `cancel_async`" in favour of the rule above; item 4 adds the four external-upload obligations; item 5 restores pristine detection as Codex specifies; item 8 reads "recovery notice per design where a bounded signal exists; reconnect via `_mounts`; Back-only notice optional." Recorded product alternatives, none applied: Back-notice omission; last-write-wins drafts.

All three phases are closed: architecture in 2 rounds, backend in 3, frontend in 2. No source design was modified. The three `idioms-*.md` files carry the closures; the earlier `adversarial-*.md` reports are preserved as history.

**Final confirmation (Fable):** Codex's Round 2 addendum accepts same-name replacement without `cancel_async`; that matches the ratification above. With Codex's acceptance of the ten-point closure as amended, phase 3 is closed at two rounds and the three-phase review is complete.
