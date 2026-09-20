# UX conventions and simplification — architecture

Date: 2026-09-20. Status: revised recommendation consensus after the user-effort reassessment below. Earlier review: four initial rounds plus cross-phase reconciliation. Final recommendations are adopted in the technical design documents; application implementation remains outstanding. This review is separate from `ux-architecture-review.md`.

## Adoption status

The owner authorized applying the final consensus to the technical designs. The data model, backend and frontend contracts now incorporate the final reassessment plus the review-setup override below; the architecture overview is aligned. The attributed debate remains historical, including statements that source documents had not yet changed. Design adoption does not mean the application or integration tests are implemented.

## Final cross-page consistency pass

2026-09-20. Codex and Fable reviewed the three technical documents in two rounds. The owner subsequently authorized these changes, and they are now **adopted in the data model, backend and frontend designs**. The findings below record the pre-adoption gaps; implementation and rendered UI verification remain outstanding.

The main interaction architecture is consistent. Keep these intentional differences:

| Surface | Ordering | Filters | Navigation |
|---|---|---|---|
| Browse | Hot / New | Tip technique, model, environment | Previous / Next, 20 rows |
| Search | Fixed relevance | Same tip filters; submitted query retained | Previous / Next, 20 rows in the bounded window |
| Normal reviews | Best / New | Reviewer model and environment | Previous / Next, 30 rows |
| Profile | Fixed newest first | All / Tips / Reviews | Previous / Next, 20 rows |
| Inbox | Fixed recent activity first | None | Previous / Next, 20 rows |
| Moderation | Fixed priority ordering | None specified | Previous / Next, 20 cases |

Rankings serve different tasks; uniform controls do not require uniform ranking algorithms. Keep open tip/selected-review evidence versus collapsed list-review evidence, net feed scores versus detailed helpfulness counts, and media-specific playback controls. Keep First page recovery on empty deep pages; the data model requiring Previous does not forbid that frontend control.

Accepted findings: inconsistent filter-reset specification; ambiguous tag/model-link navigation; ambiguous Show all reviews filter reset; undefined feed voting presentation; unspecified review-sort/profile-filter control shapes; missing signed-out Report behavior; smaller excerpt-label, own-review action-placement and draft-discard-confirmation gaps. Details and references are in the [frontend pass](ux-idioms-frontend-review.md#final-cross-page-consistency-pass) and [backend pass](ux-idioms-backend-review.md#final-cross-page-consistency-pass).

Use the existing shared components to settle these contracts, not a new design-system project. Consistent naming for repeated functions follows [W3C consistent identification guidance](https://www.w3.org/WAI/WCAG22/Understanding/consistent-identification.html); contextual differences can remain. Visual styles, responsive layouts and exact component placement remain open in the frontend document, so this pass cannot certify visual consistency.

## Owner decision — prefill review setup

The owner selected this behavior after the reassessment: a fresh review starts with the tip's model and environment, including a free-text model. Both fields remain optional, editable and clearable. If the tip leaves a field unspecified, the review starts with that field blank. Show brief guidance to check that these values match the reviewer's own attempt; no separate Same-as-tip button or confirmation step is needed.

Initialize these defaults only once for a fresh form. Restored drafts, reconnects and existing reviews retain their own values, including deliberate blanks. Publishing stores the submitted values independently; later tip edits never overwrite review setup. This supersedes the blank-default and explicit-fill recommendations in the attributed review history below. The technical data model, backend and frontend already specify this prefill behavior; it remains the selected design, not a claim of implemented UI.

## User-effort reassessment

2026-09-20 owner instruction: **Accept necessary complexity when it makes the user's experience simpler. Don't make the implementation look simple by pushing its complexity onto the user.** This instruction governs all three review phases and overrides code-count arguments in earlier recommendations. It is now recorded in AGENTS.md and all four technical design documents; their selected behavioral contracts have not been replaced by these review recommendations.

### Codex reassessment round 1

Reopen blanket native-video deferral: sending authors to another hosting service adds accounts, uploads, privacy decisions and link maintenance to the contribution journey. Explore managed native upload and inline playback, using existing provider/library capabilities. One short clip is a product hypothesis, not proof that most lifecycle safeguards disappear. Keep text recovery, resumable upload, automatic readiness feedback, private unpublished video and safe cleanup. No measured claim that one clip serves 80% of users is available.

Reopen removing exact model/environment filters: free-text search is not equivalent to selecting the setup a reader uses, particularly within reviews of one tip. Simplify the controls independently of the retrieval capability. Reconsider fixed handles, contribution-type navigation and pagination against actual task cost; do not automatically restore every control or add every convenience. Retain the justified keeps: one app/two contexts, explicit Prompt/Result fields, both helpfulness directions, publication idempotency, local recovery and conflict protection.

Decision test for every candidate: identify the user task and recurring friction, compare the smallest reliable alternatives, name what users gain or lose, then check local correctness, affected features and the complete journey. An MVP may omit a capability deliberately; an omission must not be called equivalent UX when it creates a workaround. Current prior consensus below is historical wherever this addendum reopens it. Bilateral reassessment is pending.

### Fable reassessment round 1 (synopsis of terminal assessment)

Applied the principle to my lean-video ideation and to prior consensus. Video: withdrew manual Publish-to-check, basic POST, public playback and the sweep-as-lifecycle claim; kept only the inline player as a clear win and one clip per item as a hypothesis. Prior consensus: reopened my own removal of model and environment filters (typed search is ranked and fuzzy, not exact), proposed three immediate native selects with no panel; proposed a kind filter on the combined profile list; proposed a one-tap Same-as-tip fill for blank reviewer setup; held submit-only validation, local drafts and page URLs; proposed reopening handle rename as a small operation. Reasoning per item is in the terminal record and restated where it matters below.

### Fable reassessment round 2 — answers to Codex round 2

1. **Video shape.** Agree: managed native video, tus, signed inline provider player, current caps pending evidence, lifecycle guards preserved. Inline player is the adopted UX win; one clip per item stays a hypothesis.
2. **Active-editor polling.** Agree it must be asynchronous and bounded: one async cycle per editor, concurrent reads across that editor's pending attachments with a small concurrency limit and one timeout each, results applied per attachment, next cycle scheduled only after the previous completes. A timeout is unknown, shown as "still checking", never failed.
3. **Publish.** Withdraw my mandatory provider read on Publish. Publish trusts committed ready state; it refreshes only still-pending attachments, and a provider outage leaves them pending rather than regressing ready ones. Ownership and eligibility locks at commit are unchanged.
4. **Status scan.** Agree: no global readiness scan. `checked_at` and its rotation index have no remaining job; the scheduled cleanup keeps its provider read to resolve deadlines on apparently unfinished known-uid rows.
5. **Discovery controls.** Agree: three immediate native selects on browse and search; All, Tips, Reviews as a URL filter on the single profile list.
6. **Review setup filters.** Accept Codex's pushback. My objection was that filters would hide reviews with no reported setup; All-by-default includes them, a "reported setup" label makes the narrowing explicit, and Clear returns to All. Keep opt-in review filters.
7. **Same-as-tip.** Agree: an explicit fill action offered only while both new-review fields are blank; no live inheritance.
8. **Handle rename.** Accept the deferral. The principle does not mandate every convenience; no measured rename problem exists. Recorded as a separate product option, not part of this review.
9. **Pagination and drafts.** Agree: local drafts stay; page URLs stay with an acceptance check that Back actually lands on the prior page rather than assuming native restoration.

No remaining architecture objection.

### Codex reassessment round 2 — closure

Accept Fable's revised round 2. **Current recommendation:** retain native managed video with resumable upload and signed inline playback; simplify readiness checking, not recovery guarantees. Retain exact model/environment filtering behind three immediate native selects on browse/search and opt-in reported-setup filters on reviews. Keep one combined profile list with All / Tips / Reviews navigation. As subsequently selected by the owner, prefill a fresh review's setup from the tip and let the reviewer change or clear either field. Restore drag ordering alongside accessible move buttons. Keep local drafts and URL pagination; handle rename remains deferred. These supersede the corresponding earlier removals, not every prior recommendation.

**Why:** the core job is finding, trying and sharing evidence with little avoidable work. Requiring another host, fuzzy search in place of exact matching, repeated status checks or repeated reorder clicks transfers implementation work to users. Managed services, established libraries and ordinary URL filters absorb that work without introducing separate business services. Keep the two-context monolith and the earlier simplifications whose documented user outcomes still hold.

**End-to-end checks, not yet executed:** find a tip for a selected setup; narrow its reviews with a clear route back to all reviews; copy a prompt; return to the previous reading position; write and recover a draft; upload a phone recording through a temporary network interruption; watch readiness update without touching Publish; preview and publish once; watch inline; edit/reorder evidence without losing descriptions; delete without a cleanup/publication race. Current limits remain ten total mixed attachments, three minutes and 1 GB per video pending representative-file testing, not an arbitrary new one-clip/200-MB cap. These are recommended product limits, not evidence of runtime capacity.

The principle is adopted in source guidance. This addendum is recommendation consensus; implementation choices and feature contracts still need coordinated adoption across the technical documents. No software or prototype has been implemented or tested in this reassessment.

### Fable reassessment round 3 — ratification

Verified Codex's round 2 closure against my round 2; no discrepancy. Ratified: native managed video with tus and signed inline playback, readiness simplified without weakening recovery; exact model and environment filtering behind three immediate native selects and opt-in reported-setup review filters; one profile list with All, Tips, Reviews; blank review setup with an explicit Same-as-tip fill while both fields are blank; drag plus move buttons; local drafts; URL pagination with a Back check on reading position as well as URL; handle rename deferred. Limits stay at ten mixed attachments, three minutes and 1 GB pending representative files. Recommendation consensus only; no feature adoption or implementation is claimed, and the principle is recorded in the technical documents. Reassessment closed.

## Historical recommendations before the user-effort reassessment

The biggest mismatch is between a small find → try → report product and the number of states its optional capabilities introduce. Simplify capabilities while preserving work and evidence. The attributed debate below records objections, concessions and withdrawn claims; this summary and the closure sections supersede earlier proposals.

| Recommend changing | Keep / acknowledge |
|---|---|
| Defer native video; accept ordinary recording links | Images/GIFs, controlled animation and cleanup; links can disappear |
| Replace the multi-field filter panel with one Technique selector | Compact Hot/New selector; setup metadata/search; exact model/environment filtering is lost |
| Use URL Previous/Next pages for every reading list | No arbitrary history cap outside bounded search; ranking can drift; measure deep offsets |
| Combine handle and email on one signup form | Fixed handle, server uniqueness and magic-link return flow |
| Permit tip edits beyond two hours | Updated date and earlier-review context note; no edit history or ranking boost |
| Put optional review/composer evidence in one native disclosure | Prompt and Result fields, full review body, visible linked-review evidence |
| Give review permalinks a focused single-review view; profiles one contributions list | Show all reviews is one tap away; per-type profile filtering is lost |
| Delete the Back-only refresh notice | Truthful reconnect/error feedback |
| Add optional image descriptions and help | Missing descriptions remain an accessibility limitation; no conformance claim |

**Deliberate keeps:** local drafts with conflict protection and publication idempotency; both helpfulness directions; one active review per person; monolith/two business contexts. Server drafts are deferred at acknowledged frontend cost because network-dependent persistence weakens interruption recovery. Richer architecture is not justified merely by copying a large social product.

**Related decisions:** [backend review](ux-idioms-backend-review.md) recommends removing shadow bans, dead-vote rows and report-specific author revisions, and starting reviewer setup blank. [frontend review](ux-idioms-frontend-review.md) specifies controlled animation, static composer thumbnails, submit-only text validation, Copy actions and retained leave protection. These recommendations reopen earlier selected choices; the technical design documents still describe the original choices.

## Brief

The user requests an adversarial senior UX/UI review of unusual choices and unnecessary complexity, using modern social/forum conventions, web standards and applicable best practices. Review the current four technical design documents and the earlier UX recommendations critically. Earlier consensus is evidence, not immunity from challenge. Source designs are unchanged since the previous review; recommendations are not yet adopted or implemented.

Codex's lens: coherent interaction conventions, accessibility, predictable state and end-to-end correctness. Fable's orthogonal lens: mobile-first product design, fewer choices and screens, progressive disclosure, and ruthless subtraction of implementation and cognitive complexity.

Three phases, each in its own shared file: this architecture file, `ux-idioms-backend-review.md`, and `ux-idioms-frontend-review.md`. Each reviewer appends attributed findings and challenges the other's proposed fixes. Stop at explicit bilateral consensus or ten rounds per phase; record any remaining disagreement at the cap. Do not edit technical sources during the review.

Each candidate needs: exact source anchor; user scenario; whether it is a standard violation, a conventional variation, or a product preference; evidence from primary sources where external claims matter; simplest replacement or removal; what complexity disappears and what new cost appears; local, downstream and whole-journey effects; an acceptance check; and a final keep/change/defer/reject disposition. Do not call competitor behavior universal or substitute backend convenience for usability. Five to fifteen whys should reach the root, stopping when two more do not change it. Apply MVP restraint and Rams' principles. No running product or layout has been supplied, so distinguish design findings from observed implementation failures.

Start with whole-product choices and constraints. Challenge additions from the last review as well as source decisions. Recommend explicit product changes when justified; do not reduce every issue to labels or defer it solely because it was previously selected.

## Fable Round 1

Written independently. Anchors are `file:line` in `docs/design/technical/`. Classification per candidate: **standard violation** (a web or accessibility standard), **conventional variation** (differs from what modern social/forum products do), or **product preference**. Each ends with keep / change / defer / reject and names any earlier UX-review recommendation that disappears with it, since those recommendations are also under review.

### Verdict

The four documents are correct about durability and wrong about size. Seven whole-product choices each pull a subsystem behind them: a handle ceremony at signup, a two-hour edit clock, a two-button vote, a three-dimension filter panel, a managed-video pipeline, a three-field composer, and a browser-side draft store that has grown its own concurrency control. Each was reasonable in isolation. Together they give a first-time phone user more screens, states and warnings than Reddit or Hacker News, for a corpus that will start at dozens of tips. Every candidate below removes more than it adds.

### U1 — Change: remove the handle step from signup; auto-assign and allow rename

- **Source.** frontend-design.md:27 (handle selection before email; "cannot be changed afterward"); backend-design.md:466–478 (suggestion does not reserve; conflict returns to handle selection; rename operation forbidden); data-model.md:348.
- **Scenario.** A developer taps "Write a review" on a phone and is asked to pick a permanent public name for a site they have used for ninety seconds, with a warning that it is forever. The safest move is to keep the suggestion; the design then spends copy explaining that even the suggestion is permanent.
- **Whys.** Why a handle screen? A public name is needed on content. Why before email? So the magic link lands in the editor. Why fixed? Reddit convention and handle release on deletion. Why does fixed need a warning? Because the choice is made before the user cares. Why is the choice made then? Because the design asks. Two more whys do not move: the root is *an irreversible decision placed at the moment of least commitment*.
- **Classification.** Product preference. Magic-link products collect only the email at signup (Slack, Notion, Substack); Bluesky, Instagram, Discord and Mastodon allow handle changes; Reddit and Hacker News do not. Neither side is a standard.
- **Replacement.** Signup is the email field. On first verification the account gets the generated handle; the user sees it once on the editor's author line with "Change" and can rename in settings later. Rename is `Accounts.rename_handle` under the existing uniqueness, reserved-name and rate-limit rules. Profile links resolve by user id with the handle as a slug, so old links survive a rename.
- **Disappears.** The handle screen, the suggestion-not-reservation conflict path, the "preserve handle across steps" rule, the irreversibility copy, and the previous review's rule that handle choice travels with registration. **Appears.** One settings operation and one profile-URL rule.
- **Effects.** Backend: registration takes email only and auto-assigns with server-side retry on collision. Data model: "fixed after signup" rule flips; `users_handle_unique` unchanged. Journey: sign-up is one field, and the link lands in the editor as before.
- **Acceptance.** Email-only signup reaches the editor; author line shows the handle with Change; rename keeps old profile links working; reserved names rejected.

### U2 — Change: drop the two-hour tip edit window

- **Source.** backend-design.md:372, :311 (upload does not extend the window), :434 (hidden tips editable "within the original window"); data-model.md:16, :574, :584; frontend-design.md:136. Reviews are already editable at any time with an "Updated" date (backend-design.md:372).
- **Scenario.** The product's stated gap is advice that goes stale (backend-design.md:19). The one person who can fix a stale tip is locked out after two hours. The previous review's answer was to display the deadline and route the author to a self-review, which is a workaround for a rule.
- **Whys.** Why a window? Reviews bind to the tip text and there is no edit history. Why does that need a window? So a review is not left describing text that changed. Why is that acceptable for reviews but not tips? Reviews have no dependents. Why is Reddit fine without it? Posts show "edited" and comments stand; readers cope. Two more whys stay on *a Hacker News comment rule applied to long-form posts*.
- **Classification.** Conventional variation. Reddit posts, Stack Overflow posts, Discourse posts and Google Maps reviews are editable indefinitely with an edited marker; Hacker News is the outlier, and its rule is for comments.
- **Replacement.** Tips edit like reviews: any time, "Updated" date shown, `edit_version` and `author_revision` unchanged.
- **Disappears.** The `created_at > now() - 2h` predicate, the `:expired_window` reason, `editable_until`, the deadline display, the upload-does-not-extend rule, the moderator-hidden-within-window clause, the self-review-as-update path, and previous findings F4 and C-B3's deadline. **Appears.** Nothing; the review edit path already exists.
- **Effects.** Backend: one predicate removed. Frontend: one control condition removed. Journey: the author who learns the technique stopped working updates the tip, which is the product hypothesis.
- **Acceptance.** Edit at t+3h succeeds; "Updated" shown; a review published before the edit still displays.

### U3 — Change (owner decision): remove "Not helpful"; keep one positive signal

- **Source.** backend-design.md:396–398 (separate Helpful and Not helpful counts; toggle semantics; `set_vote` with 1, -1, nil); data-model.md:206, :159–169 (Wilson lower bound), :124–127 (Hot uses signed net score); frontend-design.md:126–128 ("Counts describe helpfulness, not successes or failures").
- **Scenario.** A phone reader sees two buttons and two numbers on the tip and on each of thirty reviews, and the design needs a sentence to explain that "Not helpful" does not mean the technique failed. The thing that means a technique failed is a review, which the site already has.
- **Whys.** Why a negative vote? To let readers flag unhelpful content. Why not use reviews for that? Because a vote is cheaper. Why does the cheap signal need an explanatory caveat? Because it is ambiguous. Why is it ambiguous? It cannot say whether the content or the technique is unhelpful. Two more whys stay on *a second signal whose meaning the first signal already carries*.
- **Classification.** Product preference. Amazon, Google Maps and Yelp reviews show only a positive signal; Steam keeps yes/no; Reddit and Hacker News (comments) keep downvotes. No standard.
- **Replacement.** One "Helpful" button per item, count shown. Hot becomes `log(greatest(up_count,1)) + age`; Best becomes `up_count desc, id desc` (Wilson with p = 1 is monotone in n, so the ranking is identical to count order). `votes.value` stays a smallint or becomes presence-only; `set_vote` takes `true | nil`.
- **Disappears.** The three-state toggle, "Not helpful" counts, `down_count`, the Wilson expression, the helpfulness caveat copy, and the vote-notification honesty problem shrinks to one type. **Appears.** Nothing.
- **Lost capability.** Readers cannot register disagreement without writing. Reports still cover rule violations; reviews cover "this does not work". This is the real trade and the owner's call.
- **Acceptance.** Tip page shows one button per item; Hot order for a fixture matches the signed formula for positive scores; Best equals count order.

### U4 — Change: replace the filter panel and model/environment filters with single-select tag pills

- **Source.** frontend-design.md:58–70 (sort dropdown, Filters button, anchored panel, Apply, pending versus applied, six dismissal paths), :66 (filter carry-over into search), :96, :107, :261 (review-list model/environment filters with AND and "View all reviews"); backend-design.md:75–79, :85 (author's-model semantics); data-model.md:398 (three-filter measurements).
- **Scenario.** Nine tags, a short model list, a short environment list, and a corpus of dozens. The home page carries a sort dropdown, a Filters button, a panel with three selects and Apply, applied chips with remove buttons, and clickable chips on every row, and the previous review added a label explaining that the model filter means the author's model, not the reviewer's.
- **Whys.** Why a panel? To combine three dimensions. Why three? Model and environment were modelled as filters. Why filters rather than metadata? Because they are curated tables. Why does a reader filter by model? To find what works on their model. Why not search "opus"? The backend consensus already puts model and environment text into the search document. Two more whys stay on *structured filters for dimensions that search text already covers*.
- **Classification.** Product preference; the sort dropdown came from Reddit screenshots, the multi-field panel is a Tips addition. The convention for small tag sets is a single row of pills (Product Hunt topics, Stack Overflow tags, Reddit flair filter), single-select, in the URL.
- **Replacement.** One row of tag pills under the search field, single-select, `?tag=persona` in the URL; Hot/New as a two-segment control; search accepts `q` and optional `tag`. Model and environment stay as displayed metadata on rows and reviews and as search text. Review lists lose their model/environment filters; readers scan the setup line or search.
- **Disappears.** Pending versus applied state, Apply, panel dismissal and focus-return rules, applied-chip removal, filter carry-over rules, model and environment predicates in browse and all four search branches, the `tips_*_by_tag` row filters for model/environment, review-list filters and their empty state, previous finding A3 entirely, and P1's chip-target rules shrink to one pill row. **Appears.** Nothing.
- **Lost capability.** Exact structured filtering by model or environment. Search text covers the discovery case; a reader who wants only Claude Code tips on the new model types both words.
- **Acceptance.** Home renders search, pills, segment control and rows; `?tag=` filters; a query "opus scoped edits" finds a tip whose author selected that model without typing it.

### U5 — Change (owner decision): defer native video; MVP is images and GIFs

- **Source.** backend-design.md:259–331 (Stream, tus, one-hour and 48-hour deadlines, signed playback, minute-cadence worker, NULL-uid retirement); data-model.md:216–263 (media constraints), :767–779; frontend-design.md:156–170, :185–187; software-architecture.md:58, :138, :148 (deferring native video was "optional and not implemented").
- **Scenario.** The composer must show uploading, processing, ready, failed, expired, resume, replace and remove; Publish waits on a worker; the reader opens a signed redirect in a new tab. All for evidence that, per the docs, is images and pasted text first (backend-design.md:33–35).
- **Whys.** Why video? Recorded workflows. Why native? Common formats and automatic playback. Why not a link? Not considered as the MVP path. Why does native cost so much? Transcoding is asynchronous and private playback needs signing. Why private? Uploads are unattached until publish. Two more whys stay on *a managed-media pipeline for an unvalidated evidence type*.
- **Classification.** Product preference. Hacker News has no media; Discourse ships without transcoding and treats video as an optional plugin; forums accept a Loom or YouTube link in the body. No standard requires native video.
- **Replacement.** Remove video from the MVP. Authors link a recording in the Markdown body; links already render with `nofollow noopener`. Reconsider native video when trial reviews contain video links.
- **Disappears.** Stream, tus adapter, JOSE signing, watch and thumbnail routes, the status worker and both expiry branches, `stream_uid`, `state`, `duration_s`, `target`, `completed_at`, `expires_at`, `checked_at` and four constraints on `media`, the `media` Oban queue's provider work, five-second polling, `begin_video_upload` and its two siblings, the readiness gate on Publish, 48-hour draft-video recovery, and previous findings C-F5 and the video half of rule 3. **Appears.** Nothing.
- **Lost capability.** In-app hosted video evidence. Authors host elsewhere and the link can rot; that is the trade.
- **Acceptance.** Composer offers "Add images"; a review body with a Loom link renders as a link; the media table has image rows only.

### U6 — Change (owner decision): one Markdown composer; drop the Prompt and Result fields

- **Source.** frontend-design.md:138–140 (three sections), :148–183 (Result composer spec), :110 (Prompt and Result labelled sections in reading); backend-design.md:243–249; data-model.md:118–119, :154–155, :360 (`prompt`, `output` as `<pre>`); :281 (excerpt source labels).
- **Scenario.** A newcomer's review form is Review, Prompt, Result text, an attachment tray, model and environment. Developers already know how to paste a prompt: a fenced code block. The three fields exist to guarantee verbatim whitespace and to label excerpts, both of which Markdown fences provide.
- **Whys.** Why separate fields? Verbatim rendering and a clear evidence label. Why not fences? Not chosen. Why does the design need to explain "keep the account distinct from evidence"? Because the split is a design idea, not a user need. Why label excerpts by field? Because the fields exist. Two more whys stay on *structure that the text format already carries*.
- **Classification.** Conventional variation. GitHub, Stack Overflow, Discourse and Reddit use one Markdown composer; prompts and outputs go in fences. No convention has a separate prompt field.
- **Replacement.** One body per tip and review, Markdown with fenced code rendered in `<pre>` with wrapping. Attachment tray below the body. Helper text: "Paste prompts and outputs in code fences." Model and environment stay as optional setup.
- **Disappears.** Four columns, two text areas per form, the Result composer section spec, the verbatim rules for two fields, excerpt source labelling, the "output-only edit" search note, previous finding P5's source labels and A5's per-field wrapping rules. **Appears.** Nothing; the Markdown renderer is already required.
- **Lost capability.** Field-level identification of prompt versus result in search excerpts and reading. Authors label with a heading or a fence.
- **Acceptance.** Review form shows one text area and the tray; a fenced block keeps whitespace and wraps; search matches text inside fences.

### U7 — Change (owner decision): server-side drafts instead of IndexedDB with compare-and-set

- **Source.** frontend-design.md:191–219 (hook mount race, restore gating, CAS on `(draft_id, revision)`, cross-tab conflict UI, storage-failure branches), :213–217; backend-design.md:315–331 ("no account-synced draft or draft table in the MVP"); last frontend review C-F3 (a rejected-edit reference inside the same CAS record).
- **Scenario.** The choice to avoid one table produced, in the browser, a transactional store with revision guards, a two-tab conflict dialog, a typing-before-mount race, a restore fieldset lock, and now a second snapshot inside the record. A phone user who starts on the laptop cannot continue on the phone.
- **Whys.** Why local drafts? To avoid a server table. Why is a table costly? One more entity. Why did local grow CAS? Two tabs share one store. Why a conflict dialog? Because CAS detected a stale tab. Why not last-write-wins? Silent loss between tabs. Why is server last-write-wins acceptable elsewhere? Discourse and Reddit do it with a sequence and a "being edited elsewhere" note. Two more whys stay on *browser-local storage recreating server-side concurrency control*.
- **Classification.** Conventional variation with disproportionate cost. Discourse (`drafts` table with `sequence`), Reddit and Twitter keep drafts server-side; browser-only drafts are the unusual choice.
- **Replacement.** One `drafts` row per account and form key (new tip, new review per tip, edit per content id): `body jsonb`, `sequence int`, `updated_at`. Autosave is a debounced LiveView event that writes with `sequence = expected` and returns the new sequence; a mismatch shows "Edited in another window; reload to continue" and pauses. The row id doubles as the submission key. Images still need reselection; that limitation is unchanged.
- **Disappears.** IndexedDB, the hook mount and restore races, fieldset locking, storage-failure branches, the cross-tab dialog, `phx-auto-recover` identity checks beyond LiveView's default, the separate submission-key generation, C-F3's in-record reference (the server draft simply keeps the last autosaved values and a conflict reload is explicit), and half of frontend-design.md's acceptance list. **Appears.** One table, one autosave event, one cleanup rule (delete on publish or discard; sweep rows older than thirty days).
- **Lost capability.** Drafts survive without a network round trip; with server drafts an offline keystroke burst is recoverable only by LiveView's reconnect form recovery, which the design already relies on.
- **Acceptance.** Type on laptop, reopen on phone, draft restored; two tabs produce one conflict notice and no silent loss; publish deletes the draft; storage cost is one row per open draft.

### Whole-journey effect

Signup: one field. Home: search, pills, two-segment sort. Tip page: one button per item, one composer entry. Composer: body, images, optional setup. Recovery: reload restores from the server. The moderator, deletion, ban, report and notification contracts are untouched. Rams: as little design as possible; the remaining design is understandable without caveat copy.

### Kept on purpose

Magic-link auth, one review per user per tip, Hot/New for tips, curated tags, deleted and removed placeholders, in-app notifications with mark-on-open, submission-key idempotency (moved onto the draft row), signed-in voting, reports without status. Each is the convention or the smallest thing that works.

## Codex Round 1

Fable's Round 1 was available before this response. I challenge it directly and add candidates C1–C4. These are design recommendations, not implementation defects observed in a running product.

### Root problem and decision test

Why do individually sensible choices feel incoherent? Each feature introduces states. Why so many states? Evidence capture, mutable ranking, authentication and interruption are each optimized separately. Why does the reader pay for those internals? The presentation mirrors those mechanisms. Why is that wrong for this MVP? The core task is find → try → report, not manage uploads or learn query semantics. Why not remove every mechanism? Some protect the writing and the meaning of evidence. Why keep those protections? A simpler screen is not simpler if losing work forces the user to repeat it. Two further whys leave the same root: **remove optional capabilities before removing the safeguards needed by the capabilities we keep**. Rams' understandable, honest, useful and thorough principles constrain “as little design as possible.”

### Responses to U1–U7

- **U1: amend, not accept as written.** Remove the separate handle screen by putting suggested editable handle and email in one registration form. Keep fixed handles for this MVP. That removes a step without adding rename authorization, handle reuse/impersonation policy, user-id profile routes, slug canonicalization and settings UI. An automatic name is still public identity and should be visible before submission. No evidence yet that a rename subsystem is a net subtraction. Fable must source the competitor claims or remove them; collecting a name elsewhere is not proof of an email-only whole signup journey.
- **U2: conditionally accept indefinite author edits**, show the existing `edited_at` on tips as on reviews. This is a product trade, not “the normal rule”: Discourse edit limits are configurable, so “Discourse posts editable indefinitely” is not a valid universal precedent. Preserve original `created_at`, vote counts, review authorship and independent reviews; no reordering or new notifications on edit. Add a plain note above reviews when a tip has been edited after a review was posted: “This tip has been updated; earlier reviews may describe an earlier version.” Use existing tip `edited_at` and review dates, with no histories, version snapshots or automatic invalidation. This is a real loss of stable review context, not “nothing appears.” Never require delete/repost to refresh a tip. Acceptance includes a pre-edit review and stale editor conflict.
- **U3: retain two helpfulness directions for now.** This recommendation removes the only low-effort negative content-quality signal; a first-hand review is not an equivalent replacement for a reader's negative usefulness opinion. Helpful-only is viable, but is a product ranking experiment, not a correctness or conventions fix. Its notification ambiguity does NOT disappear: a user can still remove/re-add a positive vote. Existing omission of numeric event counts remains necessary. “Best” by popularity alone also needs a product decision. Simplify explanatory copy and visual treatment before eliminating the signal.
- **U4: accept removing structured model/environment discovery filters, amend tag UI.** Keep setup metadata and include both author's and reviewer's setup in search as previously recommended. Text search is NOT equivalent to exact filtering or AND semantics; state that loss explicitly. Retain one labelled native Technique select with All techniques, immediate URL navigation on deliberate selection, rather than nine potentially horizontally scrolling pills. Keep the owner-selected compact Hot/New dropdown; two-segment control is optional styling, not a necessary change. Delete the Filters panel, pending/apply/reset state, applied chips for deleted dimensions and corresponding review-list filter exceptions. The tag parameter still carries between browse/search. Prior A3 model-scope clarification disappears only where those controls disappear; setup labels and own/selected review dedup remain.
- **U5: accept deferring native video**, as an explicit MVP scope recommendation. Plain recording links preserve an escape hatch; no embed/import/preview service. Image/GIF handling, R2 cleanup, publication idempotency and text drafts remain. Do not delete the entire media state model merely because video goes: retain fields/constraints used by staged images and deletion cleanup, to be audited in backend phase. The “Discourse needs a plugin for video” claim is not needed and should be withdrawn unless verified. Adoption would supersede the old video-recovery recommendations.
- **U6: reject wholesale field removal for now.** A labelled optional Prompt field is a useful affordance for the core find → try task. Asking mobile authors to fence arbitrary AI output correctly creates work: nested backticks, accidental Markdown interpretation and author-specific headings. GitHub documents fences, but that proves the mechanism exists, not that one field is universally better. Reduce visible fields through native optional evidence disclosure; retain the structured data and verbatim rendering. Copying a prompt should not require reconstructing it from prose. Revisit single-body only if trial users routinely ignore these fields.
- **U7: reject the claimed simplification.** Server drafts need the same expected-sequence conflict protection, stale mount identity and input preservation. A stale edit's rejected values can be overwritten by the next autosave even if stored on the server. Deleting a server draft on publish also makes its row id insufficient for uncertain retry unless the id remains stable in the committed content and retry lifecycle. Offline writing + tab eviction loses the unacknowledged burst; reconnect form recovery cannot recover an evicted page. Therefore this removes IndexedDB but adds a draft table, retention/deletion privacy obligations, autosave writes, offline/acknowledgement states and cross-device conflicts. There is no demonstrated lower-cost complete contract. Keep browser drafts, CAS and one unresolved rejected-edit reference for now. Do not claim Twitter/Reddit universally synchronize all drafts without sources.

### C1 — Change: page search results instead of accumulating reranked pages

- **Anchor/scenario:** frontend-design.md:74–86; backend-design.md:118; data-model.md:700–761. Reader opens a result from the fourth loaded batch, returns to page one, and loads repeated tips again. Occurrence DOM ids accommodate duplicates instead of helping the user keep their place.
- **Classification/evidence:** conventional alternative, not a standard violation. [GOV.UK pagination](https://design-system.service.gov.uk/components/pagination/) explicitly supports forward/backward navigation through search results. This is not evidence that every social feed must paginate.
- **Replacement:** search uses a URL `page`, twenty results, ordinary Previous/Next links and current-page indication. Map pages to the existing bounded offset; retain ranking reruns and the 200-candidate ceiling. Browse, inbox and profiles can retain Load more. No snapshots, total-result count, numbered ten-page promise or server search session.
- **Removed/new costs:** remove accumulated search stream, occurrence ids, append state and lost search-page depth; add one bounded page parameter and an empty-page Previous action when results shrink. Latest accepted request still owns the display. Ranking may change and repeat/omit items between pages; do not promise frozen results or exact scroll restoration.
- **Effects:** same search function/budget; frontend retains one page; Back/share/remount restores the requested page. Changed query or technique resets to page one. No previously accumulated rows to reconcile under new scope.
- **Acceptance:** open a page-4 result and Back to `page=4`; no appended duplicates in the same view; stale async response cannot overwrite another query/page; deleted results leave a useful Previous route.

### C2 — Change: native disclosure for optional review evidence

- **Anchor/scenario:** frontend-design.md:110, :138–140, :176; data-model.md:486. Thirty full reviews can each expose 40,000 characters of optional prompt/output before the next review. Large blocks impede comparison on mobile.
- **Classification/evidence:** usability/product choice, not a WCAG violation. [GOV.UK details guidance](https://design-system.service.gov.uk/components/details/) supports optional information but warns against hiding information most readers need.
- **Replacement:** keep review body, setup, author/date and actions visible. Put the optional Prompt/Result bundle in one native `details` with a descriptive summary such as “Prompt and result · 2 images.” Keep a tip's main evidence expanded because trying the tip is its primary job. For a linked selected review, open its evidence so search/inbox links do not land on hidden matched context. In the composer, optional evidence may be disclosed, but restored nonempty values and validation errors must be visible.
- **Removed/new costs:** removes forced long-form scanning and any need for custom height measurement/Read more truncation; adds one native control and deterministic initial-open rules. Keep full server-rendered content and search indexing; do not add lazy fetch or changed schema.
- **Acceptance:** keyboard opens evidence; own/selected review still appears once; direct link exposes evidence; input error cannot remain in a closed section; body never requires expansion.

### C3 — Change: remove the Back-only refresh notice

- **Anchor:** frontend-design.md:86, :116; software-architecture.md:148. A LiveView mount does not identify browser Back, and changing rankings are already normal. Delete the Back-only “Results refreshed” requirement and any custom history detector. Keep truthful connection/retry messages when those events are actually known. No claim that Back preserves a snapshot. C1 makes search page location meaningful without a notice. Acceptance: ordinary navigation/remount does not emit a misleading Back announcement. This is a subtraction, not a deferred option.

### C4 — Accessibility correction required; mechanism in frontend phase

- **Anchor:** frontend-design.md:150; backend-design.md:239; data-model.md:512. Images have no equivalent-text authoring capability, and animated GIFs render as `img` without a specified pause mechanism.
- **Classification:** potential standards failure, dependent on content and animation duration. [WCAG non-text content](https://www.w3.org/WAI/WCAG22/Understanding/non-text-content.html) requires equivalent alternatives where applicable; a filename is not an alternative for a screenshot's information. [WCAG pause/stop/hide](https://www.w3.org/WAI/WCAG22/Understanding/pause-stop-hide.html) applies to nonessential automatically moving content lasting over five seconds alongside other content.
- **Direction:** add conventional alternative-description authoring for images and either control animation or defer animated uploads. Static-only must detect animated WebP/APNG as well as GIF; changing extensions alone is insufficient. Do not certify accessibility from this paper review. Backend/frontend phases must choose the smallest workable mechanism, including truthful validation and decorative-image handling.

### Keeps

Retain the monolith, two business contexts, task-first discovery, text-only feed, explicit Search action, dedicated routable editors, one active review per author per tip, idempotent publication and optimistic edit checks. These are coherent, defensible choices. Familiar products provide patterns, not a mandate to add chat, nested comments, typeahead or an SPA.

## Fable Round 2 — mutual critique

Codex's decision test, remove optional capabilities before removing the safeguards of what stays, is accepted and applied below. Competitor claims are corrected first because several of mine were overstated.

### Corrections to my Round 1 evidence

- **Discourse edits.** Withdrawn as "indefinite". Discourse's `post_edit_time_limit` is a site setting; the shipped default is measured in weeks, not hours, and admins can extend it. The precedent is "long and configurable", not "unlimited".
- **Discourse video.** Withdrawn as stated. Core Discourse accepts video files as ordinary uploads served without transcoding; the plugin remark was unnecessary and is removed.
- **Twitter drafts.** Withdrawn; app drafts are device-local. Reddit stores post drafts on the account; Discourse stores drafts server-side (`draft.rb`, already cited in the data model). Only those two stand.
- **Email-only signup.** Reframed. Slack, Notion and Substack put email on the first screen and collect a name afterwards; that supports "email first", not "email only".
- **Handle changes.** Mastodon withdrawn (display name changes, username does not). Bluesky, Instagram and Discord allow handle changes; Reddit and Hacker News do not.
- **Helpful-only.** Amazon, Google Maps and Yelp show only positive review reactions as observed today; Steam keeps yes/no. No primary document is cited, so treat this as observation, not standard.

### U1 — Accept Codex's amendment; rename deferred

One registration form with the editable suggested handle and the email field removes the extra screen, which was the subtraction that mattered. Fixed handles stay for the MVP. Rename is cheaper than Codex's list implies (the profile route can use the tip idiom `/u/{id}/{handle}` from data-model.md:458, uniqueness and reserved names exist, handle release already exists for deletion), but it is an addition, and my lens is subtraction. Disposition: **change** to one form; **defer** rename until a trial user asks.

### U2 — Accept the conditional form

Indefinite tip edits with `edited_at` shown, original dates, votes and reviews untouched, no reorder or notification. Accept the single note above the review list when `tips.edited_at` is later than the earliest visible review's `created_at`: "This tip has been updated; earlier reviews may describe an earlier version." One date comparison, no snapshot. Honest loss: readers cannot see what changed. Disposition: **change**.

### U3 — Withdraw for the MVP; record as a trial question

Codex is right that removing "Not helpful" does not remove notification ambiguity (remove and re-add still folds) and that helpful-only is a ranking experiment, not a conventions fix. Retract that claim. The subtraction still stands on states and caveat copy, but it is a product preference with no convention on either side. Disposition: **reject for MVP**; trial question: do readers use "Not helpful" to mean "the technique failed"? If yes, revisit.

### U4 — Accept the native select and the kept sort dropdown

A labelled Technique `<select>` with "All techniques" and immediate URL navigation is the right mobile control; nine wrapping pills spend the first screen. Keep the owner's compact Hot/New dropdown. Filters panel, pending and applied state, applied chips, model and environment predicates, review-list filters and their empty state are removed. Stated loss: exact filtering and AND semantics on model or environment are gone; search over setup text is fuzzy. Author's and reviewer's setup both enter search text per the backend consensus. Disposition: **change**.

### U5 — Consensus

Native video deferred as MVP scope. Keep the media fields and constraints images and cleanup use; audit the rest in the backend phase. Plain links in the body, no embed service. Disposition: **change**.

### U6 — Amend to a middle position

Codex's mobile-fencing objection holds: triple backticks on a phone keyboard are real friction, and a prompt is the artifact readers copy, so it deserves a verbatim field. Proposal: **keep Prompt, remove the Result text field.** Output goes in the body as prose or a fence, or as a screenshot, which the product already favors as evidence. Attachments sit below the body. Removed: `output` columns on both tables, the Result text area, the combined text-and-media Result composer spec, the "Result:" excerpt label, `output` in the search builder. Kept: `prompt` verbatim and its excerpt label. Honest loss: verbatim output has no guaranteed label or whitespace unless fenced. Reading uses C2's disclosure for the Prompt-and-attachments bundle. Disposition: **change, amended**; Codex to challenge.

### U7 — Withdraw

Codex's three points are decisive: server drafts need the same sequence guard; the rejected-edit reference is overwritten by the next autosave wherever it lives unless kept separately; deleting the draft row on publish breaks uncertain retry after eviction unless the row persists, which is more state, not less. Offline bursts and retention obligations are real additional costs. Browser drafts with compare-and-set and one unresolved reference stay. Disposition: **reject** my change.

### C1 — Accept, and extend to one pagination idiom

Page-based search with `page`, Previous and Next, twenty per page over the existing bounded offset removes the accumulated stream, occurrence ids, append and reset modes, in-flight Load more rules and depth loss on Back. Accept. Extension for Codex to challenge: use the same idiom for browse, profiles and inbox instead of keyset Load more. Hacker News pages its front page with `?p=2` over a changing ranking and accepts drift; that removes cursors, seen-id sets, the duplicate-only-batch rule and two pagination models on one site. Cost: offset over the index (trivial at MVP scale) and a page cap of, say, fifty. Reviews inside a tip page the same way with thirty per page. Honest loss: keyset's deep-page efficiency and exact no-repeat browse; both are HN's accepted trade. Disposition: **change** for search; **proposed** for the rest.

### C2 — Accept

Native `<details>` per review for the optional Prompt-and-attachments bundle with a descriptive summary; tip evidence open; selected review open; body, setup, author, date and actions always visible; in the composer, restored non-empty values and errors are never inside a closed section. Supersedes my earlier fold proposal. Disposition: **change**.

### C3 — Accept

Back-only notice deleted; connection and retry messages kept when the state is known. Disposition: **change**.

### C4 — Accept the alt-text mechanism; propose click-to-play for animation

Alt text: add one optional description field per image in the tray and a `media.alt` text column, not required to publish, matching Reddit and Twitter; empty alt renders `alt=""` only when the author marks the image decorative, otherwise the filename is not used as alt. Animation: rather than frame extraction or rejecting animated uploads, render any animated image (GIF, animated WebP, APNG detected by signature) behind a labelled "Play animation" control that swaps a placeholder for the `img`; no auto-play, no decoding, satisfies pause/stop/hide by never starting. Static detection is three chunk checks. Disposition: **change**; mechanism detail to the frontend phase.

### Proposed architecture disposition

| Item | Disposition | Trade recorded |
|---|---|---|
| U1 signup | Change: one form; rename deferred | Fixed handle stays; the warning moves into one form |
| U2 edits | Change: indefinite with edited note | Review context can drift; no history |
| U3 votes | Reject for MVP; trial question | Two directions and caveat copy stay |
| U4 filters | Change: technique select; model/env metadata only | Exact and AND filtering lost |
| U5 video | Change: defer | Hosted video evidence lost; links can rot |
| U6 composer | Change, amended: keep Prompt, drop Result text | Output loses guaranteed verbatim label |
| U7 drafts | Reject | Browser CAS and reference stay |
| C1 pagination | Change: pages for search; proposed for all lists | Drift and repeats accepted, as HN |
| C2 disclosure | Change | Evidence one tap away; selected review open |
| C3 notice | Change | None |
| C4 accessibility | Change: optional alt; click-to-play animation | Authors may leave alt empty |

Open for Codex: U6 middle position, C1 extension to all lists, C4 click-to-play.

## Codex Round 2 — resolve the remaining architectural choices

Accept U1–U5 as amended and U7's withdrawal. Accept C1 for search, C2 and C3. Three remaining proposals need narrower contracts:

1. **Keep Result text as well as Prompt.** U6's amended fix inherits the same mobile fencing problem for output that persuaded us to keep Prompt. A terminal error, indentation-sensitive result or model answer containing backticks is exactly the evidence a reader needs to inspect and search. It is not always suitable as prose or an inaccessible screenshot. With one optional evidence disclosure, keeping another plain textarea and column does not force another default-visible form section. The coherent reduction is fewer visible decisions, not forcing one class of verbatim data through Markdown. Final proposal: **reject U6 field deletion; accept C2 disclosure for optional Prompt, Result and attachments together**. Copyability is handled in frontend phase.
2. **Do not extend offset pagination to every list.** The proposed fifty-page cap makes older profile contributions inaccessible and is an arbitrary new product limit. Browse's Hot ranking and seen-id handling solve a different job from relevance search's explicitly reranked candidate window. Inbox/read cursors already exist and changing them is not needed to make search navigable. Keep current Load more outside search. Consistency means predictable actions within a task; it does not require a social feed and a targeted search to have identical navigation. Retain browse/profile/inbox Back-depth loss as an explicit trade to test, not a claim C1 fixes all lists. No cache, history ledger or second cursor system is introduced.
3. **C4 must produce meaningful alternatives, not just an unused optional field.** An optional description with no fallback for an informative image remains an acknowledged conformance gap. Frontend phase should choose description-or-explicit-redundant/decorative acknowledgement, not a filename. W3C's [image decision tree](https://www.w3.org/WAI/tutorials/images/decision-tree/) distinguishes essential information, redundant surrounding text and decoration. A short description can point to fuller accessible explanation in the body for complex screenshots. For animation I accept user-initiated display in principle, with a Hide animation control once displayed; opening optional evidence is NOT consent to start all animations. Do not write “three chunk checks” or “no decoding” as a validated implementation estimate. Detect GIF animation, APNG and animated WebP from parsed content using a maintained decoder/parser. Frontend/backend phase must choose between this small play/hide interaction and deferring animation, and account for processing costs. No standards-compliance claim until real browser/assistive testing.

**Evidence correction:** Fable's replacement “Discourse default measured in weeks” is still too broad. The [official trust-level description](https://blog.discourse.org/2018/06/understanding-discourse-trust-levels/) documents an editing limit for new users; defaults vary by trust level and site. Our proposed indefinite editing stands on Tips' freshness purpose and the honest loss of history, not an invented universal competitor rule. Likewise, unsupported “observed today” product assertions in Fable's history are not verified observations from this review. Withdraw them from the final rationale rather than treating absence of a citation as evidence.

### Provisional end-to-end and Rams check

Find with explicit search + one technique control → move between bounded result pages → read tip and its Prompt/Result → expand a review's evidence when needed → sign up on one form → publish text/images with existing recovery → author can correct stale guidance later, visibly marked. Video links remain ordinary links. These recommendations reduce controls and asynchronous upload states without discarding recoverable writing.

Applying [Rams' principles](https://www.vitsoe.com/us/about/good-design): useful/understandable = preserve the try-and-report task; unobtrusive/as little as possible = one technique control and optional evidence; honest = state editing, ranking and media limits; thorough/long-lasting = native controls and loss-safe saves. Avoid novelty for its own sake. Aesthetics require rendered layouts, and reduced media work is only a resource-saving direction, not a measured environmental claim. All ten principles are considered without inventing visual or sustainability findings from prose.

Please ratify these narrowed dispositions or identify a concrete remaining objection. Accessibility mechanism remains a bounded required decision for the later phases, not a silently waived requirement.

## Fable Round 3 — adversarial re-examination

The owner asked for pushback wherever facts support it. Re-reading Codex Rounds 1–2 against the sources, three of my concessions were too fast and two Codex claims are inflated. Evidence corrections first.

### Evidence

- **Discourse edit limits.** Withdrawn entirely; defaults vary by trust level and site and I cannot cite the numbers. U2 stands on Tips' freshness purpose and the honest loss of history only.
- **"Observed today" review-reaction claims** (Amazon, Google Maps, Yelp). Withdrawn from the rationale; U3 is already withdrawn.
- **U1 cost list.** Codex listed "handle reuse/impersonation policy, user-id profile routes, slug canonicalization" as new costs of rename. Two already exist: handle release on deletion (backend-design.md:478) and the id-plus-slug route idiom with redirect on a stale slug (data-model.md:458). Rename remains deferred, but its cost is one settings operation, not a subsystem. Recorded so the deferral is not mis-costed later.
- **Fences.** CommonMark fenced code may use tildes or a longer backtick run, so a result containing backticks is representable; nothing inside a fence is interpreted. GitHub mobile, Discourse and Reddit provide an insert-code-block control so authors never type three backticks. The mobile-friction objection is real for a bare textarea and solved by one toolbar button. This does not reopen U6 (below); it corrects the record.

### U6 — Accept Codex; keep Prompt and Result, both inside the disclosure

Not because fences fail, but because the product hypothesis names results as first-class (backend-design.md:19: "actionable explanations with optional prompts and results"), and dropping a named hypothesis field before trials is a cut without data. With C2's disclosure the composer shows one "Add prompt, result or images" control, so the visible-decision count is what my finding was about. Correction to Codex: a screenshot with C4's description is not "inaccessible"; the reason to keep verbatim text is search and copy, not accessibility. Disposition: **reject U6**; C2 governs presentation.

### C1 extension — Narrow, not withdraw: pages where rankings drift, Load more where they do not

Codex's profile objection is correct: a page cap on a stable, newest-first list is an arbitrary product limit. But Codex's claim that browse "solves a different job" from search does not hold on the sources. data-model.md:416 states the Hot keyset cursor has the same duplicate-or-skip behaviour as Reddit; keyset does not remove drift. The seen-id set, "advance past scanned duplicates", "distinguish exhausted from all-seen" and the duplicate-only-batch rule (backend-design.md:83) exist only because browse *accumulates* over a drifting ranking. Pages over the `tips_hot` and `tips_new` indexes with an offset remove that machinery; a repeat across a page boundary is HN's accepted behaviour on `news?p=2`, and offset cost on a 20k-row index is negligible at MVP scale. Profiles, inbox and a tip's reviews are stable orders with no seen-id logic, so keyset Load more costs nothing there and stays.

Revised proposal: **pages for search and browse; keyset Load more for profiles, inbox and reviews.** Removed: seen-id state, duplicate rules, browse cursor lifecycle, browse depth loss on Back (`?p=3` restores). Kept: everything Codex wanted for stable lists. Honest trade: visible repeats at browse page boundaries after votes move a tip. Disposition: **change, narrowed**; Codex to refute the drift point with a source, not a job description.

### C4 — Push back on "required acknowledgement"; accept the animation amendments

Facts: WCAG 2.2's conformance section defines a "Statement of Partial Conformance – Third Party Content" for user-contributed content the site does not control, provided the site would conform with that content removed. So an optional description field is not a site-level standards failure; it is the convention (Reddit, Twitter and Mastodon all make image descriptions optional; Mastodon offers a reminder setting, not a gate). A per-image "describe or mark decorative" gate is a product choice that adds one mandatory step to every screenshot on a phone, on the action that carries the product's evidence. Disposition: **optional field plus a one-line partial-conformance note in the launch checklist; the gate is deferred to a trial trigger** (authors leave descriptions empty on informative screenshots). The decision-tree guidance is the right helper text for the field. Animation: accept user-initiated display, a Hide control, and that opening the evidence disclosure starts nothing. Retract "three chunk checks" as an estimate; detection reads container headers (GIF image-descriptor count or NETSCAPE extension, PNG `acTL`, WebP `VP8X` animation flag or `ANIM`), not frames, and the implementation picks a maintained parser. Disposition: **change, amended**.

### U7 — Reopened with a side-by-side cost, since Codex asserted rather than costed

Codex's rejection rested on "no demonstrated lower-cost complete contract". Here is the demonstration from the sources.

Browser-draft mechanisms in frontend-design.md:191–219 and their tests at :253: an IndexedDB schema; a read-modify-write transaction with `(draft_id, revision)` compare-and-set; a hook `mounted()` that diffs the DOM against the rendered baseline before reading storage; an `input` listener that tracks typing during the asynchronous read; a fieldset lock during restore and a restore reply; late-result discarding after hook replacement; storage-unavailable and transaction-failure branches; a two-tab conflict dialog with explicit reload; account and form scoping of records; a separate submission-key generator; `phx-auto-recover` identity checks beyond LiveView's default; "flush pending local writes before navigation"; and, from the last review, a rejected-edit reference inside the same record. Browser tests: discard and recreate at the same revision, stale post-save clearing, typing before hook mount and during restore, reconnect before blur, account change, delayed and failed storage.

Server-draft equivalent: one `drafts` table (`id uuid`, `user_id`, `form_key`, `body jsonb`, `rejected jsonb`, `sequence int`, `published_id`, `updated_at`); one debounced `phx-change` handler that writes `where sequence = $expected` and returns the new sequence; one conflict notice that pauses autosave; restore is `to_form(draft.body)` on mount with no hook; publish sets `published_id` in its transaction so a mount after eviction navigates instead of showing an empty form, which answers Codex's retry objection; the draft id is the submission key; one sweep on the existing maintenance queue after publish acknowledgement or thirty days. Reconnect uses LiveView form recovery, which the design already relies on (frontend-design.md:95).

Equal on both sides: the sequence guard, the rejected-reference overwrite problem and its fix, image reselection. Server-only costs: stored draft text is user content subject to the existing deletion rules, and a burst typed while offline is recoverable only if the page survives to reconnect. Browser-only costs: everything in the first list. Cross-device continuation is a side effect, not the reason.

Disposition: **change, reopened as an owner decision.** Codex is asked to refute the list item by item or accept that the browser design is the larger contract. If the offline-eviction loss is judged disqualifying, say so as the reason; that is a real trade and a legitimate one to refuse.

### Everything else

U1 one form, U2 indefinite edits with the note, U3 withdrawn, U4 technique select, U5 video deferred, C2 disclosure, C3 notice removed: ratified as Codex stated them. The end-to-end and Rams check stands.

### Disposition after Round 3

| Item | Fable position |
|---|---|
| U1 | Change: one form; rename deferred, cost corrected |
| U2 | Change; Discourse evidence withdrawn |
| U3 | Rejected for MVP |
| U4 | Change |
| U5 | Change |
| U6 | Rejected; C2 governs |
| U7 | Reopened with side-by-side cost; owner decision |
| C1 | Change: pages for search and browse; Load more for stable lists |
| C2 | Change |
| C3 | Change |
| C4 | Change: optional description plus partial-conformance note; gate deferred; animation amendments accepted |

Open: U7 refutation, C1 drift point, C4 gate.

## Codex Round 3 — concessions and the actual draft trade

### C1: accept pages for browse as well as search, without a browse cap

Fable's narrower proposal is better. I never claimed Hot keysets freeze ranking, but I underweighted the cost of preserving accumulated rows and seen ids. Accept URL pages and Previous/Next for both Hot/New browse and search; retain keyset Load more for profiles, inbox and reviews. Search retains its existing 200-candidate bound; **do not copy that bound or introduce a fifty-page cap on browse**. Browse uses current live ordered results, twenty per page, deterministic id tie-breaks and one-row lookahead for Next. No accurate total-count promise. Empty/out-of-range pages offer Previous and First page. Invalid page syntax normalizes/rejects consistently. Votes can move items across browse pages, causing repeats/omissions; this is the explicit accepted loss of no-repeat accumulated browsing. Offset performance needs measurement with the target corpus; “negligible” is not established by a prose review. [HN's live page-2 URL](https://news.ycombinator.com/news?p=2) demonstrates the navigation idiom, not Tips' performance or ranking semantics. This deletes browse seen sets and scan-past-duplicates state and preserves URL page depth on Back for both discovery modes.

### C4: optional descriptions are a trade, not a conformance exemption

I accept an optional per-image description as the smaller launch interaction, with visible explanatory help and no mandatory checkbox/gate. Withdraw my required-acknowledgement recommendation. Missing useful descriptions remain an **accessibility gap**; this is not a complete C4 fix. The [WCAG partial-conformance provision](https://www.w3.org/TR/WCAG22/#statement-of-partial-conformance-third-party-content) describes a page that does not conform but would conform with specified uncontrolled content removed. It does not make inadequate alternatives conforming, and we have not established its conditions for Tips. Do not publish a blanket partial-conformance claim or say an optional field makes the site compliant. Final checklist records the limitation and requires an actual audit before any conformance statement. Frontend will settle missing-description rendering honestly and assess uptake in the first content trials. Animation is still a required next-phase choice, separate from alt text.

### U7: retain local drafts because offline/mobile recovery is worth this cost

Fable has demonstrated real frontend machinery, not a straw man. I accept that server drafts remove IndexedDB transactions, asynchronous storage-restore races, quota/failure branches and cross-tab local-store coordination, and can reduce frontend code. I do **not** claim local drafts are automatically the smaller implementation. My recommendation to keep them rests on the actual product loss: an offline or unacknowledged burst followed by mobile tab eviction cannot be recovered from a server draft. That is a material regression in writing recovery for this mobile-facing product. Both designs can lose input before a debounce flush; server-only persistence additionally depends on the network and server acknowledgement.

The side-by-side still needs these corrections so a later owner can compare honestly:

- CAS, draft identity/form/account scoping, stale editor admission, an unresolved rejected reference and explicit conflict reload remain necessary on the server. Their code moves; their contracts do not disappear.
- A server mount is simple for an acknowledged draft. Reconnect recovery must not let an old form resurrect a discarded/recreated/published draft or overwrite a new draft. Default LiveView recovery alone is not evidence those application identity cases disappear.
- `published_id` helps reconnect routing but publication must remain idempotent after draft cleanup. Durable content submission keys remain the authority; a missing draft row cannot mean “not published.” This is solvable and I accept the proposed persisted mapping as improvement over U7 Round 1.
- A real saved/unsaved indicator and leave-risk detection must distinguish keystrokes newer than the acknowledged server draft. A debounce handler is not the complete offline/dirty-state UI. Saving drafts for newly banned/revoked sessions also needs an explicit policy; local text protection does not depend on an allowed server write.
- Server-side retention/expiry and account deletion now apply to unpublished sensitive text and conflict references. These are ordinary implementable obligations, not an enterprise subsystem, but they are new to this design.

**Final proposed disposition: defer server drafts; keep local recovery deliberately, at acknowledged implementation cost.** If cross-device drafts later become a demonstrated need, reevaluate replacing storage with explicit acceptance of unacknowledged-text loss. Do not add both stores now. This is a product trade recommendation, not a universal standard or a cost comparison measured in code lines.

### Other corrections

Accept U6 closure. Verbatim output is useful for copying/search; a screenshot is not necessarily inaccessible when adequate alternatives exist. My earlier wording should have said that replacing text with screenshots *can* reduce accessibility. I agree rename cost should not be inflated: generation/uniqueness and handle release already exist. data-model.md:458 specifies id-plus-slug **tip** URLs; it offers a reusable idiom, not an already-specified profile rename contract. One-form signup remains the agreed smaller immediate change.

Please close architecture on these dispositions or identify a remaining objection. If closed, proceed to backend Round 1; the draft decision does not require item-by-item denial of costs we now explicitly acknowledge.

## Fable Round 4 — closure

Accept Codex Round 3 in full. Corrections taken: "negligible" offset cost is a measurement item for the target corpus, not established here; one-row lookahead for Next and no total count; the partial-conformance provision is not a blanket claim and the missing-description gap is recorded as an accessibility limitation pending an audit; data-model.md:458 is the tip URL idiom, reusable for profiles but not an existing profile contract.

U7: the offline or unacknowledged burst followed by mobile eviction is the material loss I named as a legitimate reason to refuse, and Codex refuses on it. Local drafts stay, at acknowledged cost; the corrected side-by-side (contracts move rather than vanish; idempotency stays on content submission keys; dirty-state indicator and banned-session policy are real server-side obligations) is the record a later owner should compare against. Deferred, not rejected.

### Final architecture dispositions

| Item | Disposition |
|---|---|
| U1 signup | Change: one registration form with editable suggested handle and email; fixed handle; rename deferred (one operation when needed) |
| U2 edits | Change: indefinite tip edits with `edited_at` shown and one "updated after earlier reviews" note; no history |
| U3 votes | Reject for MVP; trial question recorded |
| U4 filters | Change: one labelled Technique select, kept compact Hot/New dropdown; model and environment as metadata and search text; filter panel, chips and review-list filters removed; exact and AND filtering lost |
| U5 video | Change: defer native video; plain links; image and cleanup media fields retained pending backend audit |
| U6 composer | Reject field removal; Prompt, Result and attachments behind one native disclosure (C2) |
| U7 drafts | Defer server drafts; keep local recovery deliberately |
| C1 pagination | Change: URL pages with Previous/Next for search and browse, no browse cap, offset cost measured; keyset Load more for profiles, inbox and reviews |
| C2 disclosure | Change |
| C3 Back notice | Change: removed |
| C4 accessibility | Change: optional per-image description with help text, limitation recorded, audit before any conformance statement; animation choice (user-initiated with Hide, or defer) in the frontend phase |

Architecture phase closed at three rounds plus closure. Source documents unchanged.

## Codex Round 4 — closure

Ratify Fable Round 4 and its final dispositions. Architecture consensus reached in four numbered rounds (three substantive debate rounds plus bilateral closure), within the ten-round cap. Optional descriptions improve authoring capability but do not eliminate missing-alternative accessibility gaps. Animation will be resolved in frontend, with backend propagation; backend may make additional scope recommendations and must check their whole-product effects. This is consensus on recommendations, not authorization to treat them as implemented or adopted technical requirements.

## Cross-phase ratification — pagination (Fable, after frontend Round 2)

Supersedes C1's split. Browse, search, profile, inbox and a tip's normal review list all use URL Previous/Next pages (twenty rows; thirty for reviews) over ordered offset queries with deterministic tie-breaks and one-row lookahead. No cap outside the existing bounded search window; performance measured on the target corpus. Keyset Load more, seen-id sets, append and reset modes and loaded-depth rules are removed everywhere. The earlier "stable lists" rationale was incorrect: Best reviews and the folded inbox both reorder. Inbox mark-once-per-visit and the count-matched guard are unchanged. Codex proposed; Fable ratifies. Source documents unchanged.

## Cross-phase ratification — Codex, after frontend Round 3

Confirm all-list URL pagination and the simpler review/profile destinations agreed in frontend Rounds 2–3. This is one cross-phase reconciliation after the four initial architecture rounds, within the ten-round limit. All reading lists retain only their current page; no arbitrary history cap outside search. Normal lists use lookahead; search retains its existing internal bounded-window count for `has_more`. A review permalink shows tip context and only its selected review, with Show all; a lightweight own-review lookup feeds the Your review header link, and the live own review remains at normal rank. Profiles show a single labelled contributions list. Images/GIFs remain with optional descriptions, controlled published animation and static canvas composer thumbnails; native video remains deferred. Backend consensus additionally removes shadow bans, dead-vote rows and report-specific author revisions. The stronger save/moderation safeguards stay.

This final combination supersedes the earlier split-pagination, own-review pinning and selected-plus-ranked display proposals. It leaves explicit product losses: model/environment exact filtering, per-type profile filtering, immediate neighboring reviews on a permalink, keyset deep-page efficiency, server-synced drafts and hosted video. Those are accepted MVP trade-offs, not missing implementation details. Accessibility alternatives and offset performance require real validation; paper consensus is not proof of either.

## Final artifact verification — Codex

All four technical source SHA-256 hashes match the review baseline. The three review files have valid local Markdown link targets, source line references within file bounds, both reviewers' attributed findings and ratification, and round counts below ten even counting the cross-phase reconciliation. This verifies the review artifacts and untouched source baseline, not the proposed software. No application/browser tests were run; acceptance scenarios remain implementation work. Final summaries and closure sections govern over superseded debate proposals.
