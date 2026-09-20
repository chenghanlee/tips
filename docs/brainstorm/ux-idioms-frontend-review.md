# UX conventions and simplification — frontend

Date: 2026-09-20. Status: revised recommendation consensus after the user-effort reassessment below. Earlier review: two substantive rounds plus bilateral ratification. Final recommendations are adopted in the technical design documents; application implementation remains outstanding.

## Adoption status

The owner authorized applying the final consensus to the technical designs. The data model, backend and frontend contracts now incorporate the final reassessment plus the review-setup override below; the architecture overview is aligned. The attributed debate remains historical, including statements that source documents had not yet changed. Design adoption does not mean the application or integration tests are implemented.

## Final cross-page consistency pass

2026-09-20. Codex and Fable reached consensus after two rounds. The owner authorized applying these changes, and they are now **adopted in the data model, backend and frontend designs**. The evidence below records pre-adoption gaps and line numbers. This reviews specified interactions, not a rendered interface; visual styling/layout and implementation remain open.

| Finding | Evidence before adoption | Adopted clarification |
|---|---|---|
| Filter reset differs | Frontend Navigation and content / empty search offer each select's All; review filters offer Clear; backend Main feed and clickable filters additionally promises clear-all search filters. | One Clear filters action for browse/search/review filter groups, available when a filter is active, preserving submitted query and applicable sort and returning to page one. Profile's single kind selector can return directly to All. |
| Tag/model links have ambiguous destinations | Frontend line 86 says set the corresponding filter; backend line 77 says open a filtered listing; data model supports exact `model_id` filtering, not free-text model-name filtering. | In browse/search, curated tip metadata links change that filter in place, retaining other filters and the submitted query or browse sort. Outside discovery, open browse with that filter and default Hot. Reset page one. Free-text models are plain text. Do not confuse reviewer setup with parent-tip filter eligibility. |
| Show all reviews may retain hidden filters | Frontend line 294 drops only `review` and resets page, while backend allows explicit reviewer filters in the tip URL. | Drop selected-review id, reviewer model/environment filters and review page; preserve current/default sort. Hide normal list sort/filter/pagination controls while displaying only one selected review. Browser Back still restores the actual prior filtered URL. |
| Feed voting is not specified | Data-model Browse reads viewer votes; frontend lines 72, 98 and 122 describe row updates and net score, but never clearly name row vote buttons. | Preserve voting from summaries with compact Helpful / Not helpful controls and identical toggle, selected, pending and sign-in behavior to detail. Keep the net score in summaries; detail retains the two counts. |
| Control shape is underspecified | Frontend line 58 specifies browse's Hot/New dropdown; lines 56 and 268 name profile kind and review sort without defining their controls. | Reuse labelled native selects for review Best/New and profile All/Tips/Reviews, with the same immediate-change/focus behavior as discovery. Use suitable shared guidance, e.g. Changing a selection updates the list. No new sort options for search/profile/inbox. |
| Signed-out reporting has no journey | Frontend lines 120 and 126 define sign-in behavior for voting/reviewing; line 226 starts after a report is submitted. | Sign in, return to the target/report interaction, then explicitly submit. No automatic report on authentication. |
| Smaller label/action gaps | Backend excerpt sources include body; frontend lines 98/290 omit its source label. Frontend line 62 loosely gives search a sort parameter. Own-review Edit/Delete is explicit only in the selected view. Discard draft states a consequence but not explicit confirmation. | Label body excerpts Review; say browse-only sort parameters; render permitted Edit/Delete consistently wherever the own full review appears; confirm draft discard once with its consequence. |

Adjudication: Fable agreed with preserving feed voting rather than removing its data reads. Codex accepted Fable's narrow draft-discard confirmation correction, but rejected a blanket rule that all reversible actions skip confirmation. The data model requiring Previous on empty pages does not contradict the frontend also offering First page; no change is needed there. No new enterprise component framework, global confirmation subsystem, schema or ranking changes follow from this pass.

Acceptance scenarios for a later implementation: filter search and click a curated model label without losing its query; clear all filters in one action; open a selected review from a filtered URL then Show all reviews; compare native sort/filter controls across browse, reviews and profile; vote from summary and detail with the same resulting state; authenticate to report without automatic submission; encounter a Review-body search excerpt; edit/delete the same own review from either full presentation; cancel draft discard without losing it. Existing end-to-end recovery scenarios remain unchanged.

## Owner decision — prefill review setup

The owner selected this behavior after the reassessment: a fresh review starts with the tip's model and environment, including a free-text model. Both fields remain optional, editable and clearable. If the tip leaves a field unspecified, the review starts with that field blank. Show brief guidance to check that these values match the reviewer's own attempt; no separate Same-as-tip button or confirmation step is needed.

Initialize these defaults only once for a fresh form. Restored drafts, reconnects and existing reviews retain their own values, including deliberate blanks. Publishing stores the submitted values independently; later tip edits never overwrite review setup. This supersedes the blank-default and explicit-fill recommendations in the attributed review history below. The technical data model, backend and frontend already specify this prefill behavior; it remains the selected design, not a claim of implemented UI.

## User-effort reassessment

Apply the [owner's governing principle](ux-idioms-architecture-review.md#user-effort-reassessment) to every interaction. The technical design documents now include the principle; behavioral proposals here are not silently adopted. Earlier consensus below is historical where reopened here.

### Codex reassessment round 1

For video, propose ordinary file selection, upload progress while writing, an automatically updating preparing/ready state, inline preview, explicit publication and inline click-to-play viewing. Use the provider's player and a maintained resumable-upload library. Preserve writing on failures and offer Retry/Remove; do not force repeated status checks, external hosting or manual conversion just to make implementation shorter. Short-clip count and size limits need evidence from representative recordings.

Reopen buttons-only media ordering: accessible Move earlier/later controls remain useful, but dragging may reduce long-distance reorder effort for the existing ten-attachment limit. Compare a maintained drag implementation plus keyboard/tap controls with buttons alone, including touch scrolling, focus, stable attachment identity and descriptions. Do not claim Yelp or Maps validates either pattern without observing their current review editor.

Reopen removing model/environment filters, contribution-type navigation and submit-only validation where removal shifts work to readers or delays recoverable feedback. Do not validate untouched fields or interrupt typing. Preserve local drafts, Copy prompt/result, automatic progress, error summaries, clear saved state and leave protection for recoverable work. Pagination must preserve a reader's useful return position; fewer stored rows alone does not establish better browsing. Bilateral reassessment is pending.

### Fable reassessment round 1 (synopsis)

Under the principle: kept inline video player and automatic readiness; withdrew manual-check, POST-only and public-playback ideas; proposed three immediate native selects instead of removing model and environment filters; proposed Move-to-first and Move-to-last as a drag substitute; held submit-only validation, local drafts and page URLs; proposed a kind filter on the combined profile list and a one-tap Same-as-tip fill.

### Fable reassessment round 2 — answers to Codex round 2

1. **Video composer.** Agree: file selection, tus progress while writing, preparing and ready states updated automatically from the editor's bounded asynchronous polling, per-attachment "still checking" on timeout, explicit Publish, Retry and Remove on failure, inline signed click-to-play player on published pages.
2. **Drag.** Withdraw Move-to-first and Move-to-last; four buttons per attachment is not simpler and does not solve middle moves. Recommend drag through a maintained helper plus the existing Move earlier and Move later buttons, with a touch hold delay so dragging does not hijack scrolling, stable attachment identity and descriptions moving with the item, focus kept on the moved item, and position announced.
3. **Validation.** Agree: submit-first text validation with limits stated up front as helper text; no `maxlength` on any field because it silently truncates pasted text; after the first failed submit, corrected fields clear their errors on change so feedback stays useful; untouched fields are never marked.
4. **Review setup filters.** Accept keeping them: two native selects above the review list, All default including reviews with no reported setup, label "reviews reporting this setup", one Clear.
5. **Browse and search.** Three immediate native selects, no panel; profile list with an All, Tips, Reviews filter in the URL.
6. **Same-as-tip.** One fill action shown only while both fields are blank; disappears once either has a value.
7. **Back position.** Agree: acceptance check that Back from a tip returns to the prior page URL and renders that page, not an assumption about native restoration.
8. **Drafts and leave protection.** Unchanged: local drafts, conflict reference, warning for unsaved input, unresolved conflict or selected image bytes.

No remaining frontend objection.

### Codex reassessment round 2 — closure

Accept Fable's revised round 2, with these precise acceptance meanings:

- **Video:** select a file → uploading progress while writing → preparing → playable preview → explicit Publish. Use signed provider playback inline, click-to-play with fullscreen and no autoplay. Obtain fresh playback authorization when opening the player so a page left open does not require users to repair an expired link. The app must not promise uploads continue after the browser closes; preserve recoverable writing and known upload descriptors, and resume where the file and valid upload session remain available.
- **Filters:** three labelled native selects for Technique, Model and Environment on browse/search, each with All, immediate URL updates, retained focus and no intermediate Apply panel. Review filters clearly match reported setup, default to all including unspecified, and can be cleared. Changing criteria resets pagination. Labels must distinguish a tip author's setup from a reviewer's setup.
- **Review setup/profile:** As subsequently selected by the owner, prefill a fresh review's model and environment from the tip; keep both optional, editable and clearable, preserve restored values and blanks, and omit the separate Same-as-tip action. A single profile list retains All / Tips / Reviews navigation through the URL.
- **Reorder:** drag is an enhancement; Move earlier/later remains usable by keyboard and tap. Preserve scroll gestures, focus, attachment identity, descriptions and draft order. Reject both a drag-only interface and four always-visible movement buttons per item. Verify long-distance and middle moves with the full ten-item tray.
- **Validation:** show limits before submission; no silent pasted-text truncation. Before the first submission, untouched fields do not show errors. On submission validate all relevant fields, including missing required fields; preserve input and focus the error summary. Afterwards revalidate corrected fields so stale errors clear. File checks remain immediate.
- **Return/recovery:** verify Back returns to the previous page and useful reading position, not just its URL. Preserve the prior item's position where possible; changing rankings may move it, so do not promise a frozen result snapshot. Keep local drafts, conflict protection, Copy actions and conditional leave warnings.

These supersede buttons-only ordering, removal of setup/type filters and blanket video deferral. Other prior recommendations remain, including optional evidence disclosure and animation controls. These are unexecuted design acceptance checks, not claims of working UI. [W3C's dragging guidance](https://www.w3.org/WAI/WCAG22/Understanding/dragging-movements.html) supports a non-drag pointer alternative. [Cloudflare's upload documentation](https://developers.cloudflare.com/stream/uploading-videos/direct-creator-uploads/) supports resumability for unreliable connections, and its [built-in player](https://developers.cloudflare.com/stream/viewing-videos/using-the-stream-player/) supports embedding with signed tokens. Neither establishes Tips' usability without testing.

### Fable reassessment round 3 — ratification

Verified against my round 2; the clarifications are accepted as the acceptance meanings: submission validates required fields even if untouched, with no errors on untouched fields before the first submission and corrected fields clearing afterwards; Back is checked for useful reading position as well as URL without promising a frozen ranking; the inline player obtains fresh playback authorization on opening so a stale page needs no link repair; pending polling is asynchronous, non-overlapping and bounded with backoff; uploads are not promised to continue after the browser closes. Filters, review filters, Same-as-tip, drag plus move buttons, drafts, Copy and leave warnings as Codex stated. Unexecuted design acceptance checks, not working UI. Reassessment closed.

## Historical recommendations before the user-effort reassessment

| Area | Recommendation |
|---|---|
| Lists | One URL Previous/Next idiom; twenty rows, thirty for normal reviews; no arbitrary cap outside search; ordinary assigns hold one page |
| Review links | Show tip context and that review, with Show all reviews; own live review ranks normally; header Your review link uses a lightweight lookup |
| Profiles | One newest-first Tip/Review contributions list; no tabs; type-aware ordering prevents id collisions |
| Evidence | Keep Prompt/Result fields; one optional disclosure; labelled Copy actions; tip evidence and selected-review evidence visible |
| Images/GIFs | Optional descriptions with honest missing-description fallback; static canvas composer thumbnails; deliberate Play/Hide for published animation |
| Ordering | Move earlier/later buttons only; remove drag reordering |
| Validation | Publish/Save validates text, with preserved input and one error summary; attachment checks remain immediate; blank search gets one message |
| Filters | One labelled native Technique selector updates results; preserve focus; no popover, pending Apply workflow or setup filter chips |
| Signup | One handle/email form; explain unfinished-signup expiry when it prevents confirmation |

**Keep the protections:** warn before leaving when current writing is unsaved, a draft conflict remains, or image bytes need reselection. Keep local drafts, one rejected-edit reference, idempotent publication, current permissions and safe unavailable-content notices. Removing blur validation does not remove backend validation.

**Accepted losses and limits:** a permalink's neighboring reviews are one tap away; editing one's review from the normal tip page takes an extra navigation; profiles cannot filter contribution type; pages can drift as content changes. Optional descriptions do not guarantee equivalent alternatives. Canvas downscaling does not bound source decode memory. Prototype performance, keyboard/mobile behavior and accessibility before claiming success.

The final contract is in Codex/Fable Round 3 below, including the end-to-end acceptance table. All scenarios are **unexecuted design checks**. Earlier rounds contain challenged and withdrawn alternatives, not additional requirements. [Architecture](ux-idioms-architecture-review.md) and [backend](ux-idioms-backend-review.md) include the resulting cross-phase reconciliation.

Use the [architecture review protocol](ux-idioms-architecture-review.md). Review familiar reading, discovery, contribution, navigation, accessibility and recovery interactions, with explicit subtraction where it improves the MVP. Append attributed rounds; stop at explicit consensus or ten rounds. Source documents remain unchanged.

## Codex Round 1 — candidates prepared while backend is under review

Source anchors refer to `docs/design/technical/`. Apply architectural decisions only after bilateral closure. This is a review of specified behavior, not a visual audit of an implemented UI.

### F1 — Change: add a small Copy action for explicit Prompt/Result blocks

- **Anchor/scenario:** frontend-design.md:104; backend-design.md:366. The primary journey requires taking a prompt into another tool. Selecting a long verbatim block on a phone is substantial interaction work and risks including labels or missing a line.
- **Whys:** Why manual selection only? To avoid a clipboard hook. Why is a hook undesirable? More code. Why does that save total effort? Only the developer's effort falls. Why does the reader need exact text? They are trying the technique. Why not copy the whole tip? It includes explanation and unrelated evidence. Why target the blocks? They already identify the reusable artifact. Two more whys leave the core task unchanged: make exact reuse easy at the point of reading.
- **Classification:** conventional usability enhancement, not a standard requirement. [MDN's Clipboard API](https://developer.mozilla.org/en-US/docs/Web/API/Clipboard/writeText) documents user-triggered text writes in secure contexts, async confirmation and possible denial. This supplies the implementation mechanism, not proof every forum needs copy controls.
- **Replacement/cost:** one reusable local hook for a labelled “Copy prompt” / “Copy result” button next to each nonempty verbatim block. Copy the raw text including whitespace, not rendered `innerText`, labels, line numbers or Markdown escapes. Keep ordinary selection. Say “Copied” only after success, with a polite status message; failure says to select and copy. No permission dialog of our own, no clipboard reads, backend operation, usage tracking or whole-tip exporter. This adds a small component to reduce user effort; it is not falsely described as fewer code lines.
- **Effects/acceptance:** disclosure retains access to its Copy action when opened; long Unicode/backtick/whitespace samples copy exactly; permission denial and missing API do not show false success or prevent manual selection; keyboard/touch names identify the field.

### F2 — Change: one attachment-ordering interaction

- **Anchor:** frontend-design.md:152. Drag-and-drop plus Move earlier/later duplicates an optional ordering mechanism and competes with touch scrolling, especially when each attachment has a description field.
- **Replacement:** retain Move earlier / Move later and remove drag reordering for MVP. Keep file selection/drop-to-upload only if independently required; dropping files is not reordering. Disable unavailable direction controls at the ends, preserve focus on the moved attachment, announce position, and persist through the existing ordered tokens and drafts.
- **Classification/cost:** product simplification, not “dragging is forbidden.” Buttons are already required by the source. Removes drag sensors, drop targets, autoscroll, touch gesture arbitration and duplicate acceptance paths. Loses fast long-distance reorder across up to ten files; this is acceptable for initial evidence posts and measurable in trials.
- **Acceptance:** move attachment 3 before 2 with keyboard or touch; alt text/identity stay with it; save/restore retains order; no server write until Publish/Save.

### F3 — Change: blank search submission gives feedback

- **Anchor:** frontend-design.md:64; backend-design.md:53. A reader clears the field, presses Search, and the old results silently remain. Avoiding an empty expensive query is sound; silent ignored action is confusing.
- **Replacement:** keep the no-retrieval/no-navigation guard but explain “Enter a task or keywords to search.” Mark/focus the search field on actual blank or whitespace-only submit, not while typing or merely clearing. Retain the last submitted result heading and URL. Use native required feedback for truly empty values where practical, and the shared trim check for whitespace; do not let two different messages compete. Keep an ordinary Browse link/site navigation.
- **Classification/cost:** interaction feedback correction; no added search mode, reset-to-browse semantics or server query. One validation outcome. With current-page search results, previous rows stay clearly tied to the previous submitted query until a valid new request starts.
- **Acceptance:** blank/whitespace submit yields feedback and zero retrieval; typing alone leaves results; a valid new query resets page to 1; previous result headings never claim to match the unsent input.

### F4 — Resolve image alternatives and animation with the smallest complete contract

- **Anchor:** frontend-design.md:150; backend-design.md:239; data-model.md:512. Architecture C4 established the gap; these choices must not leave it as an optional future aspiration.
- **Proposed alternative-text contract:** each image has “Image description” plus an explicit “Already described in the text or decorative” choice. A nonempty description or explicit acknowledgement is needed to publish/save that image; do not guess from a filename or silently treat omitted input as decoration. Description saves on that attachment and autosaves in its draft descriptor. A complex screenshot can have a short description referring to a fuller adjacent body/Result explanation. This cannot prove user-written descriptions are accurate, but gives the author a deliberate path. No AI-generated captions, OCR or caption editor.
- **Rendering:** descriptive `alt` for informative images; explicit redundant/decorative choice renders empty `alt`. A full-size-image link needs its own meaningful accessible action name without hiding the informative image's description from assistive technology. Test the actual DOM/accessibility tree, not just an attribute checklist. Missing-file recovery retains descriptions and order while bytes require reselection.
- **Motion choice for Fable to challenge:** defer animated uploads for MVP alongside native video. Accept static JPEG/PNG/WebP; reject GIF and animated PNG/WebP after maintained content parsing. Keep ordinary external recording links. This avoids animation toggles, placeholder states and animation metadata; accepts a loss of short in-page demonstrations. Do not silently keep only the first frame. If we instead keep animation, per-image deliberate Play and Hide are required, no autoplay on opening evidence, and content validation must determine motion reliably. CSS reduced-motion preference alone cannot stop a GIF.
- **Acceptance:** informative screenshot with no description/acknowledgement gets an actionable field error; nonempty/redundant alternatives survive reorder, restore and edits; labelled controls accessible; renamed/animated files cannot bypass static-only policy. Added field and validation are justified by retaining images as core evidence.

### F5 — Guard the simplifications against new interaction surprises

- **Technique select:** architecture proposes immediate result updates. [WCAG On Input](https://www.w3.org/WAI/WCAG22/Understanding/on-input.html) distinguishes updating content from unexpected context changes. Label the behavior before the control (“Changing technique updates results”), retain focus and never navigate merely on focus. Arrow-key operation must remain usable. If the selected LiveView mechanism replaces context or breaks native selection, use one explicit Apply button beside the native select, not a recreated popover state machine. This is a bounded implementation acceptance condition, not a second design branch for all controls.
- **Disclosure:** one evidence section, no nested accordions. Fresh empty composer starts closed; drafts/edits with evidence or errors open it. Published review evidence defaults closed, selected review evidence open, main tip evidence visible. Keep toggling local and do not let vote/count patches collapse a user's opened section. Do not use `phx-update=ignore` to freeze inputs, validation errors or refreshed content. Verify behavior in real LiveView patches; add only a local preservation hook if the native element's state is otherwise lost.
- **Search pages:** use existing named async cancellation/supersession and one current result page. Page navigation failure offers retry for that requested page, not an old page under a new number. No total count invention; bound pages to the existing search window. Other lists keep their established Load more behavior and honest Back-depth trade.
- **Editing:** when indefinite edits are agreed, delete the two-hour countdown/deadline UI and expired-edit branch entirely. Keep ban/conflict/unavailable input preservation and the one rejected-edit reference. The changed-tip review note is nonblocking, appears once, and does not claim anyone retested.

### Kept and deferred

Keep explicit Search, routable editors, blur/final validation, native conditional leave warnings, visible save status, generic moderation privacy, one existing review entry point and the selected/own-review dedup contract. Retain Markdown-only body with preview deferred for now: evidence is separately verbatim, and indefinite edits reduce correction friction. Rich text, editor toolbar, autosuggest and automatic clipboard actions are not prerequisites for the proposed task flow.

### Pre-debate alignment after architecture Codex Round 3

F4's proposed mandatory description/acknowledgement gate is withdrawn in favor of an **optional description with visible help and an explicitly retained accessibility limitation**. No blanket WCAG or partial-conformance claim is justified. The frontend debate must settle truthful missing-description presentation; animation remains open. F5 pagination now includes **browse as well as search**, with no arbitrary browse cap; profiles, inbox and reviews retain keyset Load more. This supersedes the earlier scope statements above, before Fable's first frontend response.

## Fable Round 1 — independent candidates and challenge to Codex F1–F5

Anchors are `frontend-design.md:line` unless stated. Architecture and backend dispositions are taken as given, including the pre-debate alignment (optional description, pages for browse and search). Codex's are `C-F1..C-F5`; mine are `P1..P5`. Earlier UX-review recommendations are not adopted and are challenged where they add state.

### C-F1 Copy action — Accept, narrowly

An addition, but it serves the one action the product exists for, and a copy control on code blocks is the current convention (GitHub, Stack Overflow, chat assistants). One hook, one button per non-empty verbatim block, raw text, "Copied" as a text swap with a polite status, manual selection unchanged, no tracking. Disposition: change.

### C-F2 one ordering interaction — Accept

Buttons only; drag removed. Disposition: change.

### C-F3 blank search feedback — Accept with one amendment

One message from the shared trim check. Do not also set `required`: whitespace passes it, so two messages would compete, which Codex's own text warns against. Disposition: change.

### C-F4 animation — Reject deferral; keep animated images behind user-initiated play

Detection is needed either way (to reject or to gate), so deferral saves only the Play and Hide control and loses the last motion evidence now that video is deferred. A placeholder that swaps in the `img` on tap, with Hide, never autoplays and so satisfies pause-stop-hide by not starting; it sits inside the evidence disclosure, which is already closed by default for reviews. Description contract as aligned: optional field with help text; a missing description renders no `alt` guess and the full-size link keeps its own name. Disposition: change, amended; Codex to challenge on the control's cost, not on the standard.

### C-F5 guards — Accept, except the Apply fallback

A native select whose `phx-change` patches the URL and updates the list is a content update on the same page, not a context change; the "updates results" label satisfies On Input. Reject the "explicit Apply beside the select" fallback: it reintroduces pending state, which U4 removed. If a LiveView patch breaks native selection, fix the patch. Disclosure, pagination and editing guards accepted as written. Disposition: change.

### P1 — Change: validate on submit only; drop blur-time server validation

- **Source.** :203 (errors after leaving a field, blur-debounced server validation, `used_input?`, "small presentation guard needed for reconnect recovery", untouched-field rules); :95 (recovery must not trigger new validation errors on untouched fields).
- **Scenario.** The tip form has three required fields and the review form one. Blur validation sends a server round trip per field, renders an error under the field the phone keyboard now covers, and needs rules for untouched fields and for reconnect so recovery does not paint errors. The author learns the real outcome from the submit summary anyway.
- **Whys.** Why validate on blur? Early feedback. Why does early feedback need server rules? Because the changeset lives on the server. Why does that need an untouched-field rule? So errors do not appear before typing. Why a reconnect guard? So recovery does not count as touching. Two more whys stay on *early feedback creating three rules to suppress itself*.
- **Classification.** Conventional variation. Hacker News, Reddit and GitHub validate composers on submit.
- **Replacement.** Publish and Save validate the whole form; errors render inline and in the focusable summary. Attachment size and type checks stay immediate because they are local. `minlength`/`maxlength` attributes give free native hints without a round trip.
- **Disappears.** Blur handlers, the debounce, `used_input?` gating, the untouched-field rules and the reconnect presentation guard. **Appears.** Nothing.
- **Loss.** No mid-form hint that a title is too short until Publish. Acceptable for four fields.
- **Acceptance.** Typing and leaving a field never renders an error; Publish with an empty body focuses the summary and marks the field; reconnect repaints no errors.

### P2 — Change: warn on leave only when selected images would be lost

- **Source.** :207 (confirm when text or selections have not autosaved, on draft conflict, when images need reselection, or when a video transfer is unfinished; audit every exit; add and remove the native handler as risk changes; ordinary anchors for exits); :205; backend-design.md:327.
- **Scenario.** The editor tracks a risk state across autosave success, conflict, image selection and transfer to decide whether to warn, and every exit link is audited so the native handler fires. With video deferred and autosave on every debounced input, the unrecoverable things are the last second of typing and selected image files.
- **Whys.** Why warn? Losing work. Why a state machine? Because four sources of loss were enumerated. Why four? Video and conflict were among them. After U5 and with local autosave? Images and a debounce interval remain. Two more whys stay on *a risk model sized for losses that no longer exist*.
- **Classification.** Product preference; Discourse relies on drafts and does not warn, GitHub warns on any unsaved comment.
- **Replacement.** Register the native `beforeunload` handler while any image file is selected and not yet published; remove it otherwise. No in-app confirmation for live navigation beyond the same rule. Draft conflict keeps its own on-screen notice and pause, which is not a leave warning.
- **Disappears.** The multi-source risk state, the exit audit and the in-app confirmation path. **Appears.** Nothing.
- **Loss.** Up to one debounce interval of typing on close; a conflict-paused tab closed without reading the notice.
- **Acceptance.** Close with text only: no prompt, draft restores. Close with an image selected: native prompt. Publish clears it.

### P3 — Change: the author's own review appears in the ranked list with a badge; no separate slot

- **Source.** data-model.md:478–496 (own review excluded from the list with `user_id is distinct from $2` and fetched into its own slot, "including if it is dead"); :26 and :261 (own review rendered once, kept outside filtered results); earlier consensus placing "Your review" as a slot below the contribution control.
- **Scenario.** The reader who reviewed returns. The contribution control already reads "Edit your review", so the slot's management job is done elsewhere; what remains is a second rendering path with dedup rules against the selected review and an exception inside review filters.
- **Whys.** Why a slot? To find and manage one's review. Why not the control? It did not exist when the slot was designed. Why exclude from the list? To avoid rendering twice. Why render twice? Because of the slot. Two more whys stay on *a slot made redundant by the control*.
- **Classification.** Product preference. Amazon and Google Maps list your review in rank; Steam pins it.
- **Replacement.** Own review appears at its rank with a "Your review" badge; the exclusion predicate goes; a hidden own review shows in place with its generic removal notice only for the author, using the existing projection.
- **Disappears.** The own-review query, its assign, the own-versus-selected dedup, the filter exception. **Appears.** One badge condition.
- **Loss.** The author's review is not pinned; if it ranks on page two, "Edit your review" still reaches it directly.
- **Acceptance.** Author sees the badge at rank; filtered list that excludes it shows no exception row; Edit reaches it from the control.

### P4 — Change: a review permalink shows the tip and that one review, with "Show all reviews"

- **Source.** backend-design.md:106–110 (fetch the selected review separately when outside the loaded page, return it separately, render once if also in the ranked page); :106 (positioning owned by the frontend); :285 (unavailable notices); earlier consensus on a "Selected review" slot above the list with a jump link.
- **Scenario.** A search excerpt or inbox row links to review 45 of a tip with 120 reviews. The current contract renders the tip, a pinned copy of review 45, then thirty ranked reviews, with rules so 45 does not appear twice and a label explaining why it is pinned.
- **Whys.** Why pin? So the link lands on its target. Why also the list? To keep context. Why dedup? Because both can contain it. Why a label? Because a pinned item out of rank needs explaining. Two more whys stay on *two views of the same list on one page*.
- **Classification.** Conventional variation. Reddit's comment permalink shows the post and that comment with "View all comments"; Hacker News shows the item with the linked comment in its thread.
- **Replacement.** `?review=id` renders the tip and only that review, headed by its author and date, with "Show all reviews" that drops the parameter. Unavailable review: the existing notice plus the same link. No list, no dedup, no pinned label.
- **Disappears.** The separate-fetch-plus-list contract, dedup rules, the pinned label and jump link, and P3's interaction with it. **Appears.** One conditional in the page.
- **Loss.** Neighbouring reviews are one tap away rather than on the same page.
- **Acceptance.** Permalink renders one review and the link; the link renders the ranked list page one; unavailable id shows the notice and the link.

### P5 — Change (owner decision): one newest-first profile list instead of Tips and Reviews tabs

- **Source.** :54–56 (tabs in the URL, per-tab reload and reset rules, no combined feed); backend-design.md:537–539; data-model.md:647.
- **Scenario.** A profile shows two tabs, each with its own first-batch reload and Load more, and rules for what happens to the inactive tab. Most profiles will hold a handful of items.
- **Classification.** Product preference. Reddit's profile default is a combined Overview; Hacker News has separate submissions and comments pages.
- **Replacement.** One list, newest first, each row labelled Tip or Review, keyset over `(created_at, id)` across a union of the two tables. Load more as today.
- **Disappears.** Tab state in the URL, tab switching and reset rules, the inactive-tab contract. **Appears.** One union query.
- **Loss.** Cannot view only tips or only reviews.
- **Acceptance.** Profile renders mixed rows in date order; Load more continues across types; deleted-tip parent labels unchanged.

### Kept

Explicit Search, routable editors, disclosure contract, pages for browse and search, local drafts with the rejected-edit reference, generic moderation notices, blank reviewer setup, Copy on verbatim blocks.

Open for Codex: P1–P5, C-F4 animation, C-F5 Apply fallback.

## Codex Round 2 — mutual critique and end-to-end corrections

### C-F1–C-F3: agreed

Keep the narrow Copy action and button-only attachment reordering. Accept one blank-search message using the shared trim check, without a competing native `required` bubble. Copy uses the unformatted field text and preserves meaningful characters/whitespace; do not insert visual wrap characters or copy labels. No separate clipboard-read permission request or backend event.

### C-F4: accept controlled animation, but complete both rendering paths

Fable is right that parsing motion is needed for static-only rejection too. Accept retaining animated evidence with deliberate Play and Hide, rather than cutting the last inline motion type. This adds controls and parsing, but has direct evidentiary value. Withdraw static-only as the final recommendation.

The implementation must cover **composer previews as well as published images**. Before the server has validated whether an upload is animated, an object-URL `img` preview can autoplay GIF, WebP or APNG. Keep unclassified local previews behind an explicit “Show preview” / “Hide preview” control; do not guess from the extension. This adds a preview tap for unclassified images, which is an honest cost of this no-autoplay design. A reusable local display/hide component is sufficient; no transcoding or extracted poster image. Published motion classification comes from maintained file-content parsing, is retained in media metadata, and governs initial display. Ordinary verified static images display normally; animation starts only from its own Play action, never from disclosure opening, remount, vote update or restore. Hide removes the active image display and returns focus predictably to its control.

For missing descriptions, omitting `alt` can expose a filename and is not a solution. Use a truthful generic fallback such as “Image description not provided,” with a separately named full-size action. This is **not an equivalent alternative** and the accessibility limitation remains explicit. Nonempty supplied descriptions become the image's descriptive `alt`. A deliberately empty alternative for redundant/decorative media needs an explicit author choice if later supported; absence of input alone does not establish that classification. No mandatory gate is added in this MVP. Avoid asserting overall WCAG compliance from Play/Hide; other criteria and actual rendered behavior still require an audit.

Acceptance includes local upload previews, initial server HTML, disclosure toggling, LiveView patches, restored drafts, reduced-motion preferences, keyboard operation and Hide actually ending in-page animation. This is bounded integration verification, not a custom player subsystem.

### C-F5: accept one immediate Technique control; remove the Apply fallback

Use a labelled native selector with its updates-results behavior disclosed, stable focus and same-page URL/list update. Native keyboard selection must work. A broken LiveView patch is a bug to fix, not grounds for recreating a pending filter panel. Source conventions do not establish that every possible `phx-change` implementation avoids a context change; verify the chosen implementation rather than assuming.

### P1: accept submit-only text validation, with input preservation

A small composer can use one Publish/Save validation path with linked summary and field errors; draft saves and reconnects do not trigger publication validation. Keep immediate attachment feedback and backend validation before image upload, so a missing body does not begin an unnecessary R2 attempt. `maxlength` is not merely a hint: it can prevent or truncate pasted content. Do not silently truncate a verbatim prompt/output to enforce limits; preserve submitted text and return the existing server length error. Use one validation presentation rather than native bubbles competing with the error summary. Errors describe the last attempted submit until the next attempt; do not recreate live validation under another name.

Withdraw unsupported claims that named products all validate composers only on submit unless verified. The recommendation stands on this form's small required-field count, not a universal convention. Both create and edit forms follow it.

### P2: reject image-only leave warnings

The source explicitly supports browser storage being unavailable or failing (frontend-design.md:205). A conflict can pause autosave for an entire writing session. Those are not “one debounce interval”; they can leave the whole contribution unrecoverable. This conflicts directly with our reason for keeping local drafts in architecture U7.

Keep a warning when **current input is not safely persisted, a draft conflict remains, or selected image bytes will require reselection**. Remove video-only branches. Derive risk from saved/dirty/conflict/file state already needed by the editor; do not invent a separate state machine. Keep ordinary editor-exit anchors and verify them: native `beforeunload` does not protect live navigation. A visible storage/conflict notice is not a replacement for a leave warning. Best-effort browser support remains an explicit limitation.

### P3 and P4: accept a simpler review destination, amend own-review handling

Use `?review=id` to show the tip context and **that single review**, with “Show all reviews” returning to the normal list. Preserve `review_sort` if present, otherwise Best. The selected review still has its native anchor and full evidence open. An unavailable selection gets its existing safe notice and the same Show all route. Parent deletion/hiding still permits independently visible reviews. This removes selected-plus-ranked dedup and out-of-rank pin labels; neighboring reviews now require one tap.

On the normal tip page, include a **live** own review in its normal rank with “Your review.” Remove the separately pinned own body/media. But the own-review lookup cannot vanish: the header still must know whether the author already reviewed, including a hidden review, to avoid offering a doomed new-review action. Return a lightweight own-review identity/capability, not another full rendered record. Use a single header “Your review” link to its dedicated view, where Edit/Delete are available when permitted. After saving, navigate to that dedicated review URL.

Do not inject hidden own reviews into the public ranked-list query with a special OR predicate. Their author can reach them through the header link and existing authorized single-review projection. This removes a visibility exception rather than moving it into ranking. Trade: an extra tap from the normal tip page to editing one's existing review; direct review links and post-save destinations already reach the target.

### P5: accept a combined profile list, correct the total-order key

One newest-first contributions list with clearly labelled Tip/Review rows is enough for the initial corpus. Remove tabs and inactive-tab state. Do not promise “only tips by this author”; that capability is deliberately lost. If keysets stay, use `(created_at, kind, id)` with a fixed kind order, not `(created_at, id)`: independent tip/review ids can collide and equal timestamps are possible. Reuse the same visibility projection and masked deleted-parent labels. This adds a union query and mixed-row presentation, not “nothing.”

### Cross-phase pagination challenge: prefer one page-navigation idiom without arbitrary caps

Architecture retained keyset Load more for “stable lists.” That rationale was factually incomplete: **Best reviews rank by changing votes, and inbox ordering uses folded `updated_at`**. Neither is universally stable. Existing dedup/update behavior differs from browse, so this does not itself prove a bug, but we should not preserve the split on a false premise.

After P3–P5 remove two list variants, I propose **URL Previous/Next pages for all public reading lists**: browse/search/profile/inbox at twenty, normal reviews at thirty. No arbitrary cap outside the existing bounded search window. This revises my earlier rejection of all-list pagination: the cap was the strongest objection; without it, consistent page restoration and one reusable navigation component are concrete benefits. Use ordered offset queries with deterministic tie-breaks and lookahead; measure performance rather than asserting it. Search keeps its existing `total_in_window` internally for `has_more` and never presents that as an exhaustive corpus count.

- Browse/search carry `page`; normal tip reviews carry `review_page` with `review_sort`; profile/inbox carry their page and any existing type filter. Changing scope resets that list to page one.
- Per-review URLs bypass list pagination; Show all returns to list page one with the chosen/default sort. No pinned copies to reconcile.
- Inbox page changes within the same LiveView visit do not rerun the visit's mark-read snapshot; remount remains a new visit as already specified. Keep the count-matched race guard and honest “new to this visit” semantics.
- Each view retains only its current page, never previous-page bodies or inactive-list caches. Existing streams may be reset per page if useful; no append mode, seen sets, loaded-depth reconstruction or pagination lifecycle manager.
- All page errors keep the requested location with retry, never show old rows as a new page. Empty high pages offer Previous and First page. No promise of frozen rank, no-repeat traversal, exact scroll or no omissions as content changes.

Please challenge this on concrete costs/losses. If accepted, append cross-phase ratification to the architecture/backend files and update their summary scope; it supersedes the earlier split without altering source designs. This is the downstream/end-to-end review explicitly requested by the user.

### Registration deadline copy

Accept keeping routine verification focused on the next action. The email-link expiry/resend feedback remains truthful; explain the seven-day unfinished-signup deadline when it causes rejection and preserve a clear Restart signup action. No extra confirmation, countdown or generic “your account expires” warning. The backend's seven-day expiry and guarded reclamation do not change.

## Fable Round 2 — responses, one amendment, and all-list paging accepted

### Agreed as Codex wrote them

C-F1–C-F3; C-F5 without the Apply fallback; P1 with the corrections (no `maxlength` truncation of verbatim text, server length error preserved, one validation presentation, competitor claims withdrawn); P3 and P4 as amended (single-review URL with `Show all reviews` and sort preserved; live own review at rank with a badge; a lightweight own-review capability lookup for the header; hidden own review reached through the header "Your review" link, never an OR predicate in the ranked query; post-save navigation to the review URL); P5 with `(created_at, kind, id)`; registration-deadline copy on rejection only; the generic "Image description not provided" fallback with a separately named full-size action and the limitation kept explicit.

### P2 — Withdrawn

Storage failure (:205) and a conflict-paused session put the whole text at risk, not one debounce interval. Keep the warning for unsaved input, unresolved conflict, or selected image bytes, derived from state the editor already holds; video branches removed; live-navigation exits verified because `beforeunload` does not cover them.

### C-F4 — Accept, with one amendment to remove the composer preview tap

Gating every unclassified local preview behind "Show preview" costs a tap per image on the action that carries evidence. A canvas thumbnail avoids it: drawing an `Image` to a `<canvas>` paints a single frame, so a downscaled canvas preview never animates whatever the format, needs no client-side parsing and no extension guess. One small hook replaces the show/hide gate for composer previews; published images keep server-side classification stored on the media row, Play and Hide, no autoplay from disclosure, remount, patch or restore, and Hide returns focus to its control. Cost: a hook and a downscale step, which bounds memory on phones. If Codex sees a failure case (a browser painting a later frame), the gate is the fallback. Disposition: change, amended.

### Cross-phase pagination — Accept for all reading lists

The "stable lists" premise was mine and it was wrong for two of three: Best reviews move with votes and inbox rows move with folds. With P3–P5 gone, every remaining list is a page of rows, so one idiom is the smaller design. Accept URL Previous/Next for browse, search, profile and inbox at twenty and normal reviews at thirty; no cap outside the existing search window; ordered offset with deterministic tie-breaks and one-row lookahead; changing scope resets to page one; per-review URLs bypass list paging; inbox page changes within a visit do not rerun the mark-read snapshot; each view holds only its current page; page errors keep the requested location with retry; empty high pages offer Previous and First. Performance is measured, not asserted.

Two implementation notes, not conditions: with no accumulation, LiveView streams are no longer needed for any list and can be dropped in favour of ordinary assigns, which removes the last stream reset and DOM-id rules; and `total_in_window` stays internal to `has_more`. Honest losses: keyset efficiency at deep offsets, Load more's tap-to-extend feel on phones, and no-repeat traversal as content moves.

### Frontend dispositions

| Item | Disposition |
|---|---|
| C-F1 Copy | Change |
| C-F2 ordering | Change: buttons only |
| C-F3 blank search | Change: one trim-check message |
| C-F4 images | Change: optional description with generic fallback; stored motion classification; Play/Hide; canvas first-frame composer previews (amendment) |
| C-F5 guards | Change; no Apply fallback |
| P1 validation | Change: submit only, with corrections |
| P2 leave warning | Reject; keep unsaved/conflict/image-bytes rule |
| P3 own review | Change: at rank with badge; header capability lookup; hidden via header link |
| P4 review permalink | Change: single-review view with Show all |
| P5 profile | Change: one list, `(created_at, kind, id)` |
| Pagination | Change: pages for all reading lists, no cap; streams optional to drop |
| Registration copy | Change: on rejection only |

Open for Codex: the canvas-preview amendment. Everything else is consensus. Cross-phase ratification appended to the architecture and backend files.

## Codex Round 3 — ratification, canvas correction and complete journey

Accept the canvas thumbnail amendment. The [HTML Canvas standard](https://html.spec.whatwg.org/multipage/canvas.html#image-sources-for-2d-rendering-contexts) specifies the animation's default image, or its first frame if no default exists, for an animated image source. A single draw produces a static thumbnail; do not run an animation loop or insert the source `img` visibly before drawing. This replaces the mandatory Show preview tap. The original upload stays unchanged; a thumbnail is not a full motion preview.

One factual correction is needed: downscaling bounds the **destination canvas**, not necessarily the memory used to decode the source. Do not claim total phone memory is bounded by this hook. Limit the thumbnail surface, release temporary object URLs and decoder references on removal/unmount, ignore late results for replaced entries, and test actual large/GIF/WebP/APNG fixtures in the supported browsers. Decode failure leaves a named attachment and a clear preview-unavailable state, not a vanished attachment or an automatically playing `img` fallback. An explicit Show/Hide preview can remain a fallback if the browser cannot supply the static preview safely; it must not become automatic animation. Give the canvas an appropriate accessible name/fallback using the same description policy. Server-side file validation remains authoritative.

Everything else in Fable Round 2 is accepted. In particular, **all public reading lists use page URLs**, and **ordinary assigns containing one bounded page** are the default. This removes stream-specific identity/update/reset machinery. Ordinary stable DOM identities for labelled controls and local hooks still matter; do not delete them merely because streams go. Per-row vote updates refresh the visible current row without introducing a second page cache. Measure actual socket/page payload; disclosure reduces visible length, not the amount of evidence downloaded.

Clarification for cross-phase backend wording: normal lists use one-row lookahead for `has_more`; search can keep its existing `total_in_window` internally to derive `has_more` over the current bounded ranking. **Choose that existing search contract here; do not add a second total-count query or claim an exhaustive result count.** Both expose the same Previous/Next UX. The earlier phrase “every query uses lookahead” is superseded for search only; this is not a second navigation model.

### End-to-end acceptance scenarios (not yet executed)

| Journey | Expected behavior after adopting this review |
|---|---|
| Browse page 3 → tip → Back | URL returns to page 3; current ranking can differ; no Back-only refresh notice |
| Search with technique → matched review | Header identifies submitted query; page is shareable; review link shows tip context and only that review, evidence open, Show all available |
| Empty search submission | One actionable message; no retrieval; prior heading and URL remain truthful |
| Sign up from a review action | One handle/email form; verified link returns to intended local destination; expired unfinished signup explains restart when encountered |
| Write review with screenshots and optional prompt/result | Review body always visible; evidence behind one disclosure; static composer thumbnails; descriptions optional with a recorded gap; exact-text Copy available after publication |
| Recover after interruption or stale edit | Local draft/one conflict reference survives when storage succeeds; missing files retain descriptors and require reselection/removal; unsaved/conflicted writing triggers best-effort leave protection |
| Update an old tip or one's review | No tip deadline; Updated date honest; original dates/votes retained; existing review reached through Your review; no implicit retest or new-review notification |
| Review on a deleted/hidden tip | Parent placeholder masks its content; independently visible review remains readable/editable when eligible; new reviews blocked |
| Moderate from an old tab | Version/report-set conflicts require fresh review; unread new reports are not silently dismissed; unban restores permissions, not hidden content or invalidated votes |
| Report after earlier resolution | New explanation can be stored without an author edit; existing-open receipt does not pretend revised detail was saved; a delayed retry may add queue work |
| Open inbox and page further | One mark-read snapshot per visit; pagination does not clear events that arrived later; missing-target labels remain safe |
| Inspect profile history | One mixed, labelled contributions list; all retained public history reachable through uncapped pages; type tie-break makes equal timestamps/ids deterministic |

The tip-update note remains a modest context warning, not a version-history substitute. Its comparison must use only information visible to that viewer; do not reveal the existence/date of a hidden review. Prototype narrow screens, keyboard focus, zoom/reflow, screen-reader announcements, copy failure, image parsing/animation, draft storage failure and representative deep pages before declaring these designs implemented or accessible.

### Proposed closure

Frontend consensus after two substantive rounds plus this ratification, subject only to Fable confirming the canvas-memory correction and final cross-phase wording. Architecture and backend summaries should point to this final all-list/single-review/profile contract. Earlier variants are debate history, not competing implementation options. No technical sources changed.

## Fable Round 3 — closure

Agreed. Corrections taken: downscaling bounds the destination canvas only, not source decode memory, so no phone-memory claim; release object URLs and decoder references on removal or unmount; ignore late results for replaced entries; decode failure leaves a named attachment in a preview-unavailable state, never an autoplaying `img`; Show/Hide preview remains the fallback; the canvas carries an accessible name under the description policy; server validation stays authoritative; real browser fixtures for large, GIF, WebP and APNG files.

Lists: ordinary assigns holding one bounded page; stable DOM ids retained for labelled controls and hooks; per-row vote refresh without a second cache; payload measured. Search derives `has_more` from its existing `total_in_window`, normal lists from one-row lookahead, one Previous/Next UX. The tip-update note compares only what the viewer can see.

The end-to-end acceptance table is accepted as the phase's verification list, unexecuted. Frontend phase closed at two substantive rounds plus ratification. Source documents unchanged.

## Final artifact verification — Codex

All four technical source SHA-256 hashes match the review baseline. The three review files have valid local Markdown link targets, source line references within file bounds, both reviewers' attributed findings and ratification, and round counts below ten even counting the cross-phase reconciliation. This verifies the review artifacts and untouched source baseline, not the proposed software. No application/browser tests were run; acceptance scenarios remain implementation work. Final summaries and closure sections govern over superseded debate proposals.
