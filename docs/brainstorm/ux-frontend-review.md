# Holistic UX adversarial review — frontend

Date: 2026-09-20. Status: consensus reached; four numbered rounds including ratification. Recommendations only; source designs unchanged.

## Read this first — final consensus

The missing work is a coherent set of screen transitions and action priorities. Existing components and browser drafts can support these changes; a new frontend architecture is unnecessary.

| Priority | Agreed recommendation | Concrete acceptance case |
|---|---|---|
| First | Preserve one unresolved rejected-edit reference alongside the current form in the same guarded browser draft | Conflict → explicitly load latest → reapply half → autosave → reopen; both the active edit and remaining reference survive when storage works |
| First | Specify tip-header action, selected/own/ranked review order, eligibility and deduplication | A selected review is also yours, lies outside filters, or belongs to a removed tip; show it once with valid actions |
| First | Preserve named missing-image slots and distinguish Leave editor from Discard draft | Mobile tab eviction; reselection/removal required; leaving resumes the draft, discarding starts a new one only after pending publication is reconciled |
| First | Use video-stage actions instead of a generic Retry | Resume a valid transfer; replace expired/failed assets; pending status never means failed processing; readiness never auto-publishes |
| Next | Make task search prominent and ensure headings/chips describe displayed results | Typing versus submission, blank no-op, Apply with pending text, stale task completion, failed Load more |
| Next | Separate title and review-excerpt destinations, with bounded labelled excerpts | Long result text and setup-only match on a narrow screen; links remain distinct and accessible |
| First | Build readable long-content layouts and usable forms with verified focus/status behavior | Long prompts, metadata and titles; 320 CSS-pixel reflow, zoom, keyboard, screen reader and mobile keyboard |
| Next | Give the old check-email tab an ordinary Continue link; use accurate empty/error states | Same/different browser session; unavailable target; empty Reviews tab; filtered-empty; inbox activity on tips and reviews |

**Important correction from the debate:** an on-screen conflict reference is not protected merely because the old draft once contained it. Once autosave replaces that draft, tab eviction loses the reference. Keep one bounded reference in the same draft record, using the existing revision guard. Explicit loading, manual reapplication, authorized attachment recovery and storage-failure feedback remain required. No automatic merge, second store, accumulating history or server draft is proposed.

Use the labelled Tips/home link as the browse exit. Preserve author-profile and review-permalink access. A header action/jump takes precedence over shorthand that places the only action below a long tip. “Selected review” works for any direct link; “Jump to review list” scrolls, while “View all reviews” clears review filters.

Do not hard-code a number of titles above the fold or claim a prototype is accessible without testing it. Comfortable touch targets, restrained chrome and native textareas are starting points to verify with real content. Media text alternatives remain the explicitly recorded limitation. Folding, Back notices, pagination and ranking retain their architecture-review classifications.

The table lists proposed implementation checks, not tests executed against a running app. Detailed source anchors, counterexamples, changes of opinion and ratification follow.

Protocol and perspectives: [architecture review](ux-architecture-review.md). Review coherent page journeys, mobile and keyboard use, navigation, information hierarchy, forms, feedback, and interruptions. Maximum ten bilateral rounds; stop at explicit consensus. Append attributed findings and responses. Source design files remain unchanged during this review.

## Fable Round 1

Sources: `frontend-design.md` as of 2026-09-20, with the architecture and backend consensus (auth destination in the link, own-review precedence, deadlines displayed, slots for anything lost, one saved/recovering/published vocabulary, Back-only notice removal as an owner cut, folding and depth deferred). Nothing below reopens those. Anchors are `frontend-design.md:line` unless stated. Labels as before.

### P1 — Gap: no first-screen budget for the home page at phone width

- **Source.** :58 (toolbar with sort dropdown and Filters button), :58–:60 (applied chips below the toolbar), :88 (search box, feed, clickable tags), :96 (tags on rows are navigation links), :102 (rows: title, tags/model, author, age, score, review count), :257 (responsive layout decided while building).
- **Scenario.** At 390 CSS px: site name, persistent search label and input (architecture rule 8), toolbar, applied chips, then rows of two to three lines each. Without a budget, the first tip title lands below the fold and the "task-first" entry becomes a page of chrome. Separately, each row contains a title link and one or more chip links (:96); on touch, a chip beside the title steals the tap and navigates to a filter.
- **Fix (preserving).** Two rules. Budget: on a 390×664 viewport with no applied filters, at least three tip titles are visible on first paint; chips row is rendered only when a filter is applied. Targets: the title is the row's only link across its full width; chips are separate targets of at least 44 px with 8 px spacing and sit on their own line on narrow widths; author, age, score and count are plain text. Nested interactive content inside a link is never used.
- **Acceptance.** LiveView test renders the page; a browser test at 390 px asserts three titles above the fold and no chip within 8 px of a title's hit area.

### P2 — Gap: the tip page has three special slots and two vote pairs but no action hierarchy

- **Source.** :126 ("Helpful N" and "Not helpful N" for the tip and each review), :130 (label the review action), :106 (selected review from a link, positioning owned by the frontend; backend-design.md:110), data-model.md:494 (own review has "its own slot"), :285 (unavailable selected review notices), architecture rule 5 (one contribution control near the header).
- **Scenario.** A reader arriving from a search excerpt sees: tip, vote pair, contribution control, their own review, the linked review, the ranked list with a vote pair each, Report somewhere. Which is primary and in what order is unspecified, so the linked review can end up below thirty ranked reviews on a phone, which defeats the excerpt's promise.
- **Fix (preserving).** Fixed order: tip content → tip vote pair → contribution control → linked review (labelled "From your search", rendered once, with "View all reviews" scrolling to the list) → own review (labelled "Your review") → sort/filter controls → ranked list. One primary button style on the page: the contribution control. Vote pairs, Report, Edit and Delete are secondary. Vote buttons keep their text labels; icons alone fail the "counts describe helpfulness" rule at :127.
- **Acceptance.** Test with a selected review outside the first batch: it renders once, above the list, and the anchor lands on it. Own review plus selected review being the same row renders once.

### P3 — Gap: the composer on a phone has unbounded text areas and a Publish button with no stated placement

- **Source.** :176 (Review, Prompt, Result in a single column), :185 (explain the readiness wait "next to Publish"), :203 (blur validation, focusable error summary linking to fields), :162 (video state per attachment), backend consensus (`:media_pending`, `:rate_limited` and other reasons are shown at the action).
- **Scenario.** A reviewer pastes a 6,000-character Result. If text areas auto-grow, Publish sits thousands of pixels down and the "waiting for video" status beside it is never seen. A blur error under the field just left is hidden behind the on-screen keyboard, so the author learns of it only from the summary at Publish, if they get there.
- **Fix (preserving).** Text areas have a maximum height of about forty percent of the viewport and scroll internally (native `textarea` behaviour; no auto-grow past that). Publish, its readiness or rejection status and the error summary are one adjacent group at the end of the form; on narrow widths the group is not sticky, to avoid the iOS keyboard overlap, but the summary receives focus on failed submit so the browser scrolls to it. Blur errors render inline as specified and are additionally announced via `aria-live` so keyboard-covered errors are not silent.
- **Acceptance.** Browser test at 390 px with a 6,000-character Result: Publish reachable within a bounded scroll; failed submit moves focus to the summary; the video "processing" status is visible whenever Publish is.

### P4 — Gap: the originating tab is left on "check your email" after the link is used

- **Source.** :27 (return to the intended editor after verification), :144 (auth forms wait for acceptance), architecture F1 (destination travels with the link; the originating tab's sign-in is not restored across browser contexts).
- **Scenario.** Common same-browser case on iOS: Safari → Mail → tap link → Safari opens a *new* tab with the editor. The first tab still says "check your email" and, when the user returns to it, looks broken. In the cross-context case it is genuinely still signed out.
- **Fix (preserving).** The check-email page carries one link, "Continue", to the intended destination. Same browser: the plug sees the new session and opens the editor. Different context: the plug redirects back here with the destination kept, and the page says so. No polling, no cross-tab messaging. Reload of the check-email page behaves the same way.
- **Acceptance.** Same-browser test: Continue opens the editor. Signed-out test: Continue returns to check-email with the destination preserved and a one-line explanation.

### P5 — Gap: a search row has two destinations and no excerpt bound

- **Source.** :88 (summary component with matching-review excerpts), :281 (excerpt identifies its source), backend-design.md:95 (title opens the tip; excerpt links to the specific review), backend consensus C-B1 ("Reviewer setup: B" as an excerpt case).
- **Scenario.** On touch, a row whose title and excerpt both navigate needs two clear targets; excerpts drawn from a 20,000-character Result can be arbitrarily long unless bounded, and a "Reviewer setup" excerpt reads like a quote unless typed differently.
- **Fix (preserving).** Excerpt is at most about 200 characters or three lines, ending with an ellipsis, prefixed by its source label ("Prompt:", "Result:", "Reviewer setup:"), and is one separate link target of at least 44 px placed below the meta line. The title link and the excerpt link never overlap. Setup excerpts render as a label, not in quotation marks or `<pre>`.
- **Acceptance.** Render tests for each excerpt source; a 5,000-character Result yields a three-line excerpt; touch targets do not overlap at 390 px.

### P6 — Gap: empty states for home, profile tabs and the inbox are unspecified

- **Source.** :41 (browse "empty results"), :98 (filtered no matches, specified), :54 (profile tabs), :122 (inbox), :261 (review filters "View all reviews", specified).
- **Scenario.** During the first trials the home feed, a new user's Tips tab and every inbox are empty. Blank lists read as failure on a phone.
- **Fix (preserving).** One line each, no illustrations: home "No tips yet"; own profile tab "You haven't published any tips" with the contribution link, other profiles "No tips yet"; inbox "No activity yet. You'll see helpful votes and reviews on your tips here." Empty is never the retrieval-error state (:70).
- **Acceptance.** Render test per empty list; error and empty states are distinguishable in markup.

### Considered and not raised

- **Filter panel as popover versus bottom sheet.** Owner decision from screenshots; at 390 px an anchored, viewport-bounded panel is full-width anyway.
- **Drag reordering on touch.** Move earlier/later buttons already cover it (:152).
- **Copying long `<pre>` blocks by touch selection.** Copy buttons deferred (:104); record as a trial observation.
- **Folding, Back notice, depth.** Settled in architecture.
## Codex Round 1

### Why-chain

Why could all correct operations still feel difficult? Readers must infer their current scope, place and next action. Why? The specification is rich in lifecycle mechanics and thin on information hierarchy. Why not solve with a tutorial? It asks users to memorize distinctions the screen should express. Why prefer labels and layout? They keep choices understandable at the moment of action. Why test a complete narrow-screen journey? Independent widgets cannot establish continuity. Why not add a design system first? Shared existing components are enough to test the hierarchy. Why more abstraction? It does not determine that hierarchy. Why more screens? Same root issue; stop.

### F1 — Medium: task-first discovery needs an actual primary action hierarchy

Evidence: backend 17–21 selects task-first search; frontend 55–75 describes a compact Hot/New feed toolbar, and the page inventory leaves the shell open. This is a layout gap, not proof the current unseen UI fails.

Recommendation: make the search field/explicit Search action visible above the feed, with a concrete prompt such as “What are you trying to do with AI?” Keep Hot/New and Filters attached to the browse results below. A normal Tips/home link returns to browse; search gets an explicit “Browse tips” path because blank submission intentionally does nothing. Shared navigation exposes Publish tip, Notifications when signed in, and account access. On mobile retain readable labels and a single-column flow; do not build a separate mobile navigation architecture or onboarding tour. Keep task categories, personalized feeds and autocomplete deferred.

Downstream: route/state tests for empty search and direct browse exit; no backend changes. Acceptance: a newcomer can start a task search, identify active scope, clear filters and return to Hot/New without guessing that blank Enter means exit.

### F2 — High: linked/own/ranked reviews need one explicit reading order

Evidence: backend 106–110 allows a separately fetched linked review; data model 478–495 removes the viewer's review from ranked results; frontend 261 requires out-of-filter own/linked items to be distinct, but positioning/focus is deferred. Long full evidence makes accidental placement expensive.

Recommendation: tip context/title and a “Jump to reviews” link; a clearly headed selected-review destination when present; “Your review” as an author-management slot; then the ranked/filtered list. If selected and own are the same review, render it once with both labels. If an item is also in the first ranked batch, choose one visible occurrence and retain the normal cursor. Explicitly identify a pinned exception that falls outside review filters. On a direct review link, make the destination heading focusable and navigate to it without hiding parent context. “Write a review” becomes “Edit your review” when an eligible undeleted review already exists; hidden own review follows the existing removal notice/permission rules. Zero results inside filters must not say the tip has no reviews.

Downstream: existing projections sufficient; add only ordinary ids/focus behavior. Acceptance: selected = own, selected in later batch, selected outside filters, removed selected review, and zero matching reviews while own review is visible. No duplicate controls or incorrect parent association.

### F3 — High: conflict recovery says preserve input but leaves reapplication undefined

Evidence: frontend 197/213 for local conflicts and 221 for server conflicts; backend 319/388. “Load latest” followed by “reapply your changes” is not usable if the only copy of those changes was just replaced. This is a missing transition, not evidence that current code loses data.

Recommendation: explicitly distinguish “View latest saved version” from replacement of the form. On server conflict, retain the rejected values in a selectable reference while the author explicitly loads the latest version for editing; preserve that reference until explicit dismissal or confirmed save. Manual reapplication, no automatic merge or blind new-version retry. A simple same-page read-only reference is sufficient, without persistent edit history or a diff engine. For local-draft reload, disclose replacement and let the author inspect/copy the current input first; do not conflate local draft revision with published version.

Downstream: small transient presentation state; keep original version until explicit latest-load, preserve staged-asset target and expiry, never automatically reattach destroyed media. Acceptance: two tabs with different text and attachments; the author can compare and reapply without relying on memory, and a banned/expired/deleted edit remains non-saveable.

### F4 — Medium: Cancel is indistinguishable from discarding a retained draft

Evidence: frontend 207 includes Cancel among ordinary exits; 215 says New tip resumes the sole local draft and starting another requires explicit discard. A safely autosaved exit has no warning by design.

Recommendation: label ordinary exit “Back to tip” or “Leave editor” as appropriate, with persistent local-draft status. Reserve “Discard draft” for the explicit destructive action and make its consequence visible before it runs. A resumed form says it is a recovered draft. Do not add leave prompts for safe autosaved input. Keep submission reconciliation before any discard is interpreted as cancellation.

Downstream: presentation only; preserve native navigation/conditional warnings. Acceptance: leave → reopen resumes; discard → new uses a new key; pending publication cannot be undone by either label.

### F5 — High: distinguish retrying transfer from restarting failed processing

Evidence: frontend 185 says failure offers “retry,” backend 231 excludes an author Retry control for failed jobs, and 277/307 uses a fresh asset after provisioning failure. The operation behind a retry depends on the failed stage.

Recommendation: per-attachment states and precise actions: unfinished valid transfer → “Resume upload” with original source where needed; terminal processing/provisioning failure or expiry → “Replace video” / “Remove”; a temporary status-read outage → keep pending/unknown feedback without calling it failed processing. Publish says “Waiting for video” with nearby explanation, then returns to enabled “Publish” after readiness and requires an explicit click. Never queue an automatic publish, reset expiry, or invoke an operator job retry. Avoid announcing every polling tick to assistive technology.

Downstream: map existing states/reasons to actions; no new worker. Acceptance: false readiness after browser transfer, provider timeout, real terminal failure, expiry, then explicit successful publication.

### F6 — High: responsive/accessibility acceptance needs real content and state changes

Evidence: frontend 13/257 leaves styling open; 117 shows all text; data model 360 uses pre blocks; frontend 63 uses an anchored panel, 150 omits substantive media alternatives. Retain those explicit product boundaries while testing the consequences.

Recommendation: readable heading hierarchy, wrapping metadata/chips, prompt/result soft wrap preserving copied text, contained overflow for layout-dependent code, bounded lazy media previews, and navigation between long reviews. Keyboard-operable controls with visible focus and names; Helpful buttons expose selected/pending states; feedback for saves/errors/results is announced without stealing focus; failed form submissions focus an error summary. Apply/Clear/Load more controls remain reachable with the mobile keyboard and zoom. Test 320 CSS-pixel reflow and 400% zoom; use WCAG 2.2 target sizing/spacing, contrast and focus checks. Do not imply these fix missing visual evidence alternatives or captions. Encourage descriptions in existing fields, explicitly retain the residual accessibility limitation for substantive media.

Downstream: component/CSS/browser checks, no rich editor or media schema. Full text remains visible; no Read more added under the guise of responsiveness.

References: [W3C reflow](https://www.w3.org/WAI/WCAG22/Understanding/reflow.html), [W3C status messages](https://www.w3.org/WAI/WCAG22/Understanding/status-messages.html), [W3C informative images](https://www.w3.org/WAI/tutorials/images/informative/). These support concrete checks, not a conformance claim for an unbuilt product.

### F7 — Medium: pending searches need truthful scope and focus

Evidence: frontend 67 leaves blank submission as a no-op and 87–107 separates typed versus submitted query; changed queries/filters run asynchronously, while retained rows and errors must remain associated with the request that produced them. Supersession prevents an old task winning; it does not define how the waiting screen is labelled.

Recommendation: a persistent results heading identifies the submitted query. Typing leaves that heading/results unchanged. On a changed submitted query or applied filter set, reset the old stream and show a loading state for the new URL scope; do not label old rows with new filter chips. Load more keeps the existing list while loading and preserves it on failure. An unchanged submission or blank no-op leaves results and scope intact. Loading/empty/error states are distinct, and accepted result count/status is announced without moving focus from Search, Apply or Load more unless a full page navigation requires a new heading destination.

Downstream: use the existing reset-versus-append mode and named task, no second result cache. Acceptance: type a different query without submitting, Apply filters with pending text, submit whitespace, race A/B responses, and fail Load more. The heading/chips always describe the displayed rows.

## Codex Round 2 — challenge of Fable P1–P6

| Fable finding | Disposition, including downstream effects |
|---|---|
| P1 mobile feed budget | Accept visible task search, minimal chrome and separate nonoverlapping links. Reject mandatory “three titles at 390×664,” 44px+8px as a universal standard, and making author/age plain text to meet that budget. Title length, font size, zoom and filters vary; useful profile/permalink navigation must not disappear to win a screenshot count. Use a comfortable touch-target design (44px is a useful design target), check WCAG target-size/spacing rules, and test representative long titles. Avoid nested links and inflated full-row hit areas overlapping chips. No gratuitous empty chips row. |
| P2 action and review hierarchy | Accept one primary contribution action, secondary voting/management/report controls, linked/own/ranked order and deduplication. Correct “From your search”: selected reviews also arrive from shared links, inbox and post-save navigation, so use “Selected review” or factual origin only if known; no new origin tracking. Put the contribution action or jump affordance near the header, not only after a potentially huge body. “View all reviews” already clears filters elsewhere: use “Jump to review list” for scrolling without changing filters. Existing own-review editing remains possible under a removed parent, subject to the author's eligibility. |
| P3 composer layout | Accept sensibly sized native textareas and adjacent Publish/status feedback; no unbounded auto-growth. Forty percent of viewport is a starting layout experiment, not an invariant. Keep fields usable with mobile keyboards, large text and supported manual resizing. Focus the summary on failed submission; inline blur feedback announces newly relevant errors once, not every rerender or five-second poll. Don't assume a browser always scrolls a focused summary clear of the keyboard; verify. |
| P4 originating auth tab | Accept a “Continue to [destination]” ordinary link plus explicit context. It reads the current session; it must not submit a contribution or resend mail. If still signed out, follow the normal sign-in route with safe destination and explain the different-browser case, rather than promise the plug returns to the same check-email screen or loops silently. No polling or cross-tab auth transport. Expired edit eligibility still rechecks on entry. |
| P5 excerpt size/destinations | Accept source-labelled bounded excerpts and independent title/review links. Pick one deterministic text bound plus responsive presentation; “200 characters or three lines” is not equivalent for all widths/characters, and CSS clipping must not hide the only accessible link label. Show an excerpt ellipsis, not a truncated full review. Preserve source text literally and escaped. “Reviewer setup” is metadata, not a body quotation or proof that a tip-model filter matched. |
| P6 empty states | Accept separate true-empty, filtered-empty, and retrieval-error states. Make Tips/Reviews copy match the selected profile tab. A Tips filter yielding zero must not say “No tips yet” for the whole site. Inbox also includes helpfulness activity on the user's reviews, so amend the proposed copy accordingly. Own-profile contribution links obey current permissions; don't give a banned account a dead-end publishing CTA. No illustrations or new onboarding flow. |

[WCAG 2.2 target size](https://www.w3.org/WAI/WCAG22/Understanding/target-size-minimum.html) provides a 24 CSS-pixel minimum criterion with exceptions/spacing provisions; 44px is a larger design target, not that minimum. [W3C status messages](https://www.w3.org/WAI/WCAG22/Understanding/status-messages.html) supports announcing status without stealing focus. Browser/layout verification remains necessary; a LiveView render test alone cannot prove touch spacing, scrolling, focus visibility or usability.

The local fixes above must survive the surrounding screen's other states: auth continuation cannot promise local-draft transfer; a pinned selected review cannot impersonate a filtered hit; an empty list cannot impersonate an error; concise mobile chrome cannot remove navigation needed later in the journey. These corrections retain the existing architecture and product scope.

## Fable Round 2 — response to Codex Round 1

Codex's findings are `C-F1..C-F7`; mine are `P1..P6`. Verdicts: **Accept** C-F2, C-F3, C-F4, C-F5, C-F6. **Accept with amendments** C-F1, C-F7. Overlaps: C-F1 with P1 and architecture rule 8; C-F2 with P2; C-F6 with P3 and architecture A5.

### C-F1 — Accept the hierarchy; amend the exits

Search above the feed with a task prompt, toolbar attached to the results, shared navigation with New tip, Notifications and account: agreed, and P1's first-screen budget applies to it. Amend: no separate "Browse tips" link on the search page. The site name is already the browse link and an ordinary anchor (:207); a second exit is duplicate chrome on a phone. The search page keeps the query in the field and the results heading (C-F7) so "what am I looking at" is answered without a new control. Wording of the prompt and of "New tip" versus "Submit" is the owner's.

### C-F2 — Consensus with P2; merged order and dedup rules

Order: tip content → tip vote pair → contribution control (architecture rule 5; label per own-review precedence) → linked review, headed "From your search" with a focusable heading and a "View all reviews" jump → "Your review" slot → sort and review filters → ranked list. Dedup: selected = own renders once with both labels; selected also in the first ranked batch renders in the special slot only, suppressed from the stream by id on insert, cursor unchanged; a special slot outside the active review filters is labelled as outside them; zero filtered results never says the tip has no reviews (:261 already). Accept Codex's acceptance cases as the test list.

### C-F3 — Accept; this is the strongest finding of the round

:221 says preserve the text and offer to load the latest version, and :213 says reload replaces the form. Together they can replace the only copy of the author's changes. Accept the transient read-only reference: on server conflict, the rejected values move into a collapsed read-only block above the form, the form loads the latest version and its `edit_version`, autosave stays paused until the author edits the reloaded form, and the reference persists until confirmed save or explicit dismissal. Manual reapplication only; destroyed media never reattach because the reloaded attachment list is the latest one. Local-draft conflict: reload is disclosed as replacement and the current input is already on screen to copy first. No diff, no history.

One clarification to record: the IndexedDB edit draft still holds the rejected values until autosave resumes, so the reference block is presentation, not a second store.

### C-F4 — Accept

"Leave editor" (or "Back to tip") for the ordinary exit with the local-draft status beside it; "Discard draft" as the one destructive action with its consequence stated before it runs; a resumed form says "Recovered draft, saved 10:42" (backend vocabulary). No leave prompt for safely autosaved input (:207 unchanged). Submission reconciliation precedes any discard.

### C-F5 — Accept the state-to-action map

Unfinished valid transfer → "Resume upload" (may need the original file); terminal provisioning or processing failure, or expiry → "Replace video" and "Remove", replacement is a new asset (backend-design.md:277, :307); status-read outage → pending with "still checking", never "failed". Publish shows "Waiting for video" with the explanation adjacent (:185) and needs an explicit click after readiness. Polling ticks are not announced; state changes are. No author-triggered operator retry.

### C-F6 — Accept; P3 sits inside it

The baseline as written, plus P3's composer rules: text areas capped at about forty percent of the viewport with internal scroll, Publish grouped with its status and error summary, focus to the summary on failed submit, inline errors announced via `aria-live` because the keyboard can cover them. Published text stays fully visible; text-area caps apply to inputs only, so this does not touch the deferred folding decision.

### C-F7 — Accept with one amendment

The persistent results heading names the submitted query and applied filters; typing changes nothing; a changed scope resets the stream and shows loading for the new URL; old rows are never shown under new chips; Load more keeps rows on failure; announcements do not move focus. Amendment: most of this restates :74–:84 and :94–:96, so the new rule is only the heading and the "chips describe displayed rows" invariant. Keep the severity at Medium and the acceptance list as Codex wrote it, adding P5's excerpt bound and separate targets.

### Proposed frontend rules for Codex's response

1. Home: search first with a task prompt; toolbar attached to results; three titles above the fold at 390 px; title is the row's only link; chips are separate 44 px targets. (C-F1, P1)
2. Tip page order and dedup as merged above. (C-F2, P2)
3. Server conflict keeps rejected values as a read-only reference; explicit load-latest; manual reapply. (C-F3)
4. "Leave editor" versus "Discard draft"; recovered-draft status. (C-F4)
5. Per-attachment video actions: Resume, Replace, Remove, or pending-unknown. (C-F5)
6. Responsive and accessible baseline including composer caps and focus rules. (C-F6, P3)
7. Results heading names the submitted scope; chips describe displayed rows; excerpts bounded, labelled and separately tappable. (C-F7, P5)
8. Check-email page has one "Continue" link to the destination. (P4)
9. One-line empty states, distinct from errors. (P6)

Open for Codex: P1, P3, P4, P5, P6 rebuttal; the C-F1 exit amendment.

## Fable Round 3 — corrections accepted, disposition

All six Codex Round 2 corrections accepted. Amendments to P1–P6:

- **P1.** Withdraw "three titles at 390×664" as an invariant and 44 px as a minimum. WCAG 2.2 minimum is 24 CSS px with spacing provisions; 44 px is the design target. The author handle stays a link (profile navigation is part of the journey); age, score and count are plain text. Keep: search first, no nested links, no full-row hit area overlapping chips, no empty chips row, representative long titles in browser tests.
- **P2.** Label the pinned slot "Selected review"; it arrives from permalinks, inbox and post-save navigation as well as search, and no origin is tracked. "Jump to review list" scrolls without touching filters; "View all reviews" keeps its existing meaning of clearing review filters (:261). Contribution action or jump affordance near the header. Own-review editing under a removed parent follows the author's current eligibility.
- **P3.** Forty percent is a starting layout, not an invariant. Manual resize and large text supported. Inline errors announced once when they become relevant, never per rerender or poll tick. Verify, do not assume, that a focused summary scrolls clear of the keyboard.
- **P4.** "Continue to [destination]" is an ordinary link that reads the current session and triggers nothing. Signed out: the normal sign-in route with the safe destination and a one-line different-browser explanation; no promised return to the check-email screen, no loop, no polling. Edit eligibility rechecks on entry.
- **P5.** One deterministic server-side bound (about 200 characters, escaped, ellipsis appended) plus responsive wrapping; CSS never clips the excerpt link's accessible name. "Reviewer setup" renders as metadata and never implies a tip-model filter match.
- **P6.** Copy per selected profile tab; filtered-empty distinct from true-empty ("No tips match these filters" versus "No tips yet"); inbox copy covers helpful votes on tips and reviews plus new reviews; the own-profile contribution link obeys current eligibility, so a banned account sees none.

### On the two points the owner asked us to settle

- **Transient conflict reference (C-F3).** No disagreement. The rejected values become a collapsed read-only block above the reloaded form; autosave pauses until the author edits; manual reapply only. It is presentation: the IndexedDB edit draft already holds those values until autosave resumes, so no second store exists.
- **Clear on new search versus append while loading (C-F7).** No disagreement. A changed submitted query or applied filter set resets the stream and shows loading under the new heading, because old rows under new chips misdescribe the results; Load more and its failure keep the rows; an unchanged or blank submission changes nothing. Accepted cost: a retrieval error on a changed scope shows an empty list with retry, and the previous scope is one Back away because the URL already changed.

### Frontend disposition

| Item | Status | Outcome |
|---|---|---|
| C-F1 / P1 discovery hierarchy | Consensus, amended | Search first with task prompt; toolbar attached to results; no nested links; comfortable targets; author link kept; no separate "Browse tips" link (site name is the exit) |
| C-F2 / P2 reading order | Consensus, amended | Tip → votes → contribution control → "Selected review" → "Your review" → controls → list; dedup rules; "Jump to review list" distinct from "View all reviews" |
| C-F3 conflict reference | Consensus | Read-only reference of rejected values; explicit load-latest; manual reapply; autosave paused |
| C-F4 exits | Consensus | "Leave editor" versus "Discard draft"; recovered-draft status |
| C-F5 video actions | Consensus | Resume / Replace / Remove / pending-unknown; explicit Publish after readiness |
| C-F6 / P3 baseline | Consensus, amended | Responsive and accessible baseline; capped text areas as a starting layout; announce once; verify keyboard scroll |
| C-F7 / P5 search scope | Consensus, amended | Heading names submitted scope; clear on changed scope, keep on Load more; bounded labelled excerpts as separate links |
| P4 check-email tab | Consensus, amended | "Continue to [destination]" link; sign-in route fallback with explanation |
| P6 empty states | Consensus, amended | Per-tab, filtered-versus-true empty, eligibility-aware CTA, inbox copy covers all three types |

No disagreement remains on my side. Frontend consensus is stated on Codex's confirmation of the C-F1 exit amendment and the P1–P6 amendments above. Source documents unchanged.

## Codex Round 3 — final integration challenge

Accept Fable's P1–P6 corrections, the merged reading hierarchy, clear-on-changed-search versus append-loading rule, and the smaller navigation amendment: use the clearly labelled Tips/home link as the browse exit, without requiring an extra Browse tips button. Preserve useful profile and review-permalink access; do not turn an existing navigation affordance into plain text merely to reduce hit targets. The compact header action/jump rule takes precedence over any shorthand table that places the only contribution action after a long body.

**One remaining recovery correction:** a page-only rejected-edit reference is no longer protected by IndexedDB once autosave resumes and overwrites the original draft. “The old values are in IndexedDB” is true only before that write. Example: conflict → explicitly load latest → manually reapply half the changes → autosave → mobile tab evicted. The un-reapplied half survives only in the proposed page reference and disappears on reopen. That contradicts the reference's promised lifetime and our no-silent-loss rule.

Smallest complete recommendation: keep **at most one unresolved rejected-edit reference alongside the active form in the same account/content-scoped, revision-guarded draft record** when browser storage works. This is one bounded local snapshot, not a new store, server draft, edit history, or merge mechanism. Capture only the text/selections and intended attachment descriptors needed for manual reapplication; recoverable media ids still require fresh authorization and expiry checks. Never save local file bytes or restore destroyed attachments. The same write/clear CAS applies to both form and reference. On storage failure, keep it on screen and report at-risk work under the existing leave-warning rule.

Load-latest remains an explicit action, not an automatic consequence of receiving a stale response. After explicit loading, only the editable form adopts the current authorized version. Keep the rejected reference clearly labelled, selectable, and available until confirmed save or explicit dismissal; an accessible disclosure is acceptable. Autosave may resume after explicit restoration settles (do not make an unrelated first keystroke a hidden permission change). A repeat conflict cannot silently overwrite the first unresolved reference: pause and require the author to resolve/dismiss that reference before capturing a replacement. No growing history of snapshots.

Acceptance: modify text and attachment order in two tabs; reject stale save; explicitly load latest; reapply only part; autosave; reopen in the same browser; current form and unresolved reference both recover. Verify CAS conflicts, disabled storage, removed media and expiry. A browser losing its storage still has the existing best-effort limitation; do not promise unconditional recovery.

### Proposed final frontend recommendations

1. Search-first home and clear submitted-scope headings; separate bounded excerpt links; current chips describe displayed results.
2. Compact tip-header action/jump, explicit selected/own/ranked review order, one visible occurrence, and current eligibility taking precedence.
3. Practical manual conflict recovery with one bounded protected reference and explicit load-latest; no automatic merge.
4. Distinguish leaving, discarding and recovering drafts; preserve named missing-evidence slots.
5. Map video failure stages to Resume / Replace / Remove and require explicit publication after readiness.
6. Responsive long-content and composer layouts, meaningful keyboard/focus/status behavior, and representative browser checks.
7. Ordinary Continue from the check-email screen with honest current-session fallback; context-appropriate draft guidance.
8. True-empty, filtered-empty and error states with correct content labels and eligible actions.

No additional product change to folding, pagination, ranking, notices or media text-alternative policy follows from these frontend rules. Those stay exactly as classified by the architecture review. Fable: please challenge the bounded same-record reference or ratify this final amendment and close the phase.

## Fable Round 4 — ratification and closure

Codex's recovery correction is accepted; my Round 2 claim that "the IndexedDB draft already holds the rejected values" was true only until autosave resumed. The partial-reapply-then-eviction scenario loses the un-reapplied half under my proposal, which breaks the no-silent-loss rule.

Ratified fix: at most one unresolved rejected-edit reference stored alongside the active form in the same account- and content-scoped, revision-guarded draft record, written and cleared under the existing compare-and-set (:197). It holds text, selections and intended attachment descriptors only; media ids are reauthorized and expiry-checked on restore; no file bytes, no destroyed-attachment restoration. Load-latest stays explicit; only the form adopts the current version. Autosave resumes after explicit restoration settles, which is the existing :93 rule, not on a first keystroke. A repeat conflict pauses and requires the author to resolve or dismiss the existing reference before a replacement is captured; no history. Storage failure keeps the reference on screen as at-risk work under the existing leave rule. Codex's acceptance cases are the test list.

Also ratified: the site name as the browse exit, author and permalink links retained, and the header action or jump affordance taking precedence over any table shorthand.

The eight final frontend recommendations are ratified as written. Frontend consensus reached in three rounds plus ratification. No product change to folding, pagination, ranking, notices or media text alternatives follows; those keep their architecture-phase classification. Source documents unchanged. Fable review complete for all three phases.

## Codex Round 4 — phase closure confirmation

Fable's Round 4 ratifies the complete frontend recommendations, including the recovery correction. Bilateral consensus reached in four numbered rounds including ratification. All three phases are complete below the ten-round-per-phase cap. This is a document-level adversarial review; application behavior, layouts and usability remain to be verified during implementation. Technical design sources are unchanged.
