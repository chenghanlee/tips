# Holistic UX adversarial review — architecture

Date: 2026-09-20. Status: consensus reached; four numbered rounds including ratification. Recommendations only; source designs unchanged.

## Read this first — final consensus

The architecture can support the intended MVP. The main UX problem is that correct individual operations do not yet form complete journeys: returning from email, restoring selected evidence, deciding what can be edited, interpreting search scope, and finding changed advice. Complete these shared interaction contracts before implementation spreads assumptions across layers.

| Priority | Agreed recommendation | Design impact |
|---|---|---|
| First | Carry a validated local destination through magic-link completion, including the selected review | Return to the intended action across browser contexts; no draft or session transfer |
| First | Restore missing image/GIF selections as named slots requiring reselection or deliberate removal | No silent loss of intended evidence; no storage of file bytes |
| First | Define contribution actions by current eligibility and existing-review state | Existing reviews remain editable when their parent is removed; full bans still prevent editing; deletion stays available |
| First | Use truthful draft, media, checking, publication and edit feedback | A local draft save cannot imply that media or a post is durably published |
| Next | Make task search prominent and name tip-author versus reviewer filter scope | Keep parent-only discovery predicates, with comprehensible labels |
| Next | Show edit deadlines and the existing review/update path | Preserve the two-hour tip window and one-review rule |
| Next | Set an explicit Best review default, review-specific URL sort, and consistent Tip / Technique type / Review terminology | Complete navigation and presentation rules; no taxonomy redesign |
| Next | Show when the moderator's bounded queue has more cases | 51st-row detection and refresh; no new pagination subsystem |
| First | Validate long-content reading, keyboard use and narrow-screen layouts | Full delivered text, appropriate wrapping, section navigation and bounded media; substantive media alternatives remain unresolved |

**Product changes and risks:** recommend considering removal of the Back-only refresh notice. Evaluate folding long optional evidence only after testing wrapping and section navigation. Preserve current search pagination and Best/New semantics for now, while explicitly testing duplicate results, lost reading depth, and meaningful updates buried under old reviews. Cached query vectors do not guarantee stable ranking or retrieval mode. Deleting/reposting a review is not the recommended update path. No new snapshots, histories, reminders, analytics platform or permission service is proposed.

**Review boundary:** consensus is a recommendation, not owner adoption, a visual usability test, or implementation validation. Concrete backend outcomes and frontend transitions continue in the [backend](ux-backend-review.md) and [frontend](ux-frontend-review.md) reviews. Later corrections and ratification below supersede disputed assertions in early rounds. Rams' ten principles and checked primary-source conventions inform the review; no accessibility-conformance or visual-quality certification is claimed.

## Brief and protocol

Review the current `docs/design/technical/{software-architecture,data-model,backend-design,frontend-design}.md` as one MVP experience. This is a design review, not implementation or authorization to replace prior product decisions. Record proposed changes explicitly; do not silently rewrite the source designs.

Codex: senior forum/social UX designer, emphasizing coherent journeys, interaction contracts, trust, and accessible recovery. Fable: orthogonal product/UI perspective, emphasizing newcomer comprehension, mobile and attention constraints, information scent, and ruthless scope reduction. Challenge each other's claims and fixes; evidence and counterexamples outrank preference.

Three sequential phases use `ux-architecture-review.md`, `ux-backend-review.md`, and `ux-frontend-review.md` here. Each round consists of one analysis/response from each reviewer. Stop each phase at explicit bilateral consensus or ten rounds; record unresolved disagreements at the cap. Append attributed sections; never overwrite the other's contribution. Each finding needs source anchors, concrete user failure, smallest fix, local and downstream effects, end-to-end effect, and useful acceptance evidence. Distinguish defects, unspecified interactions, and optional product changes.

Use five to fifteen whys until two additional whys do not change the root cause. Apply established social/forum conventions, MVP scope, and Rams' principles where relevant. Preserve already agreed choices unless the review demonstrates a conflict or explicitly recommends reopening a product decision. Consensus is between reviewers, not user approval or usability validation.

## Phase focus

Trace discovery → reading → trying a tip → contributing → returning; authors' maintenance and safety; moderator interventions; and system interruptions. Decide the small set of experience rules the backend and frontend must share. Do not turn this into another infrastructure review.

## Codex Round 1

### Root cause: behavior was settled operation by operation

Why might these decisions conflict? Each operation optimizes its own correctness. Why does that hurt users? A journey crosses several operations and acquires different meanings for “model,” “new,” “saved,” and “more.” Why are those meanings not resolved by transaction correctness? Durable state says what happened, not what the reader reasonably understands. Why not add every missing feature? That multiplies states before the core discovery/trying/reporting loop is validated. Why is that the wrong unit of design? Product success is a completed useful attempt, not a collection of individually reliable screens. Why use journey contracts? They expose mismatched promises with fewer changes. Why not another architecture layer? The problem is semantic ownership, so an extra layer does not change the answer. Why further abstraction? It still would not settle those meanings. Stop: the last two whys leave the root cause unchanged.

The monolith and two contexts are compatible with a coherent UX. The architectural repair is a small set of user-facing contracts, not services, generalized state machines, or new tables by default.

### A1 — High: the freshness loop loses returning contributors' updates (product conflict)

Evidence: backend lines 19–29 prioritize current, actionable advice and repeat trials; lines 372 and 434 retain a two-hour tip window, one editable review, publication-time New ordering, unchanged vote counts, and no edit notification. Data model lines 473–475 derive latest-review date solely from creation; frontend 267–277 repeats those semantics.

Scenario: I reviewed a technique months ago, try it on a new model today, and change my account to explain why it now fails. The original tip cannot be corrected, my review stays deep in New, old Helpful votes remain, the latest-review date is old, and the tip author receives no signal. Each timestamp is literally correct; together the only update path is almost undiscoverable. A typo and a new test also share one Updated date.

Smallest proposed repair: retain one editable review and no test-history schema; give existing reviews a clear Edit your review entry point. Make the existing Updated timestamp visually present near setup and distinguish it from proof of retesting. Reopen one product decision: a review ordering called “Recent activity” by latest author edit/publication, plus “Latest review activity” on the tip. Do not call it New or Recently tested. Keep Best, no edit notifications, and no vote reset. This may promote cosmetic edits; test that tradeoff with Fable before accepting it. Do not add a separate retest button, version history, or update log by reflex.

Local/downstream: changed query/index/sort semantics across all three files; moderator-only edits must not appear as author activity; latest activity must apply current visibility. E2E check: a returning contributor can update and a reader can find it without deleting/reposting. Classification: requires reopening explicit product choices, not a silent bug fix.

### A2 — High: search Load more can spend attention on already-seen tips (product conflict)

Evidence: backend 83 suppresses browse duplicates; 118 explicitly appends duplicate search results; frontend 79–85 gives repeated search occurrences distinct DOM ids. Search is the first complete reader journey (backend 17–21).

Scenario: a relevance rerank or fallback change puts earlier tips onto the next page. Load more displays the same tip again, possibly with changed counts/excerpts, while other matches are skipped. The UI calls both actions Load more but only one means more distinct tips.

Smallest proposal: reuse browse's visible-id suppression for search presentation. Advance the backend offset using every returned candidate, not only newly displayed tips. No frozen ranking, persistent snapshot, offset based on visible count, or unbounded fill loop. A duplicate-only page needs explicit progress/end feedback and an actionable continuation when the backend window has more. This accepts omissions and changing rankings; it only removes repeat presentation. Backend can retain the ranking operation.

Local/downstream: frontend seen-id state and stable tip DOM ids replace occurrence ids; backend exposes scanned offset/end, and tests must cover empty-after-suppression pages and changes of query/filter/fallback. E2E: opening several distinct candidates does not require repeatedly scanning the same ones. Requires reversing an explicit design choice; challenge whether the UX benefit earns the state.

### A3 — Medium: discovery setup and review setup use the same vocabulary for different scopes (semantic gap)

Evidence: backend 85/89, frontend 63–73 and 103–117, data model 439/489–492. A discovery model filter means the tip author's setup; an excerpt can match a reviewer using another model; review filtering is independent. Existing prose recognizes the distinction, but control/chip labels do not prescribe it.

Scenario: I filter by model B expecting firsthand accounts using B. A useful B review on an A tip is excluded. A model B tip can show a matching model A review. Labeling both simply “Model” makes the database-correct result look wrong.

Smallest fix: explicit “Tip author's model/environment” in discovery filter labels/help; “Reviewer model/environment” in review controls; excerpt setup attached to its reviewer with no suggestion that it satisfies the tip filter. Unspecified setups do not imply universal compatibility. Preserve parent-only predicates and do not add OR-across-reviews semantics unless trial evidence shows task failure.

Downstream: presentation contract plus tests on mixed setups; no schema/ranking changes. Test with A-tip/B-review fixtures and ask readers what each filter promises. Do not add explanations to every row when one well-placed label suffices.

### A4 — Medium: navigation recovery optimizes remount simplicity at the reader's expense (validation risk)

Evidence: frontend 89–99 and 131; backend 118 resets to page one on Back/remount; all lists lose loaded depth. This is explicit, not an overlooked implementation detail.

Scenario: after loading sixty search results, a reader opens one, tries it, then goes Back to compare another and loses the place. A “Results refreshed” notice explains the loss but does not recover it. Mobile makes repeated reloading particularly costly.

Proposal: do not demand a snapshot/history subsystem in this review. Make a real mobile/back comparison trial a release gate and preserve native browser behavior wherever available; never proactively reset a still-mounted/restored DOM solely to normalize to page one. If the measured journey fails, reopen navigation preservation separately with the smallest in-session approach. Do not claim that a notice or keyboard-new-tab shortcut resolves the underlying task.

Downstream: browser-path verification, no new persistence by default. Keep URL query/filter/tab state. This is an accepted limitation pending evidence, not a must-build browser cache.

### A5 — High: accessibility is incomplete for the central evidence journey (gap and explicit tradeoff)

Evidence: frontend 117 displays up to 30 full review accounts/prompts/results at once; data model 175–179 allows 60,000 text characters per review and 360 uses pre blocks; frontend 150/backend 239 explicitly omit attachment text alternatives. Frontend foundation leaves responsive styling open.

Scenario: a phone user sees a long unbroken prompt widen the page; a keyboard reader traverses giant evidence sections to compare reports; a blind reader receives only an attachment action label for the actual evidence. Backend throughput does not establish readability.

Smallest baseline: wrap readable prompt/result text without changing copied bytes, contain intrinsically two-dimensional code/table overflow within its own region, clear headings and skip links between reviews/sections, bounded visual media previews and lazy loading. Keep full text and attachment order. Add brief author guidance to explain substantive visual findings in body/Result, using existing fields. This improves access but does not guarantee equivalent alternatives; absence of alt/captions remains a declared limitation. Adding attachment descriptions/captions requires explicitly reopening the prior product choice.

Downstream: responsive/keyboard/screen-reader acceptance examples; do not add text truncation, lazy text endpoints or schema changes in disguise. Check 320 CSS px and zoom with real long content, not empty wireframes.

### A6 — Medium: saved/recovered/published must have one coherent vocabulary (cross-layer contract)

Evidence: backend 315–331 differentiates local text, reselected images, expiring video, and unknown publication; frontend 183–219 has the states but no complete shared feedback language. An unchanged server editor draft is not a published update.

Proposal: small presentation vocabulary: “Draft saved in this browser,” “Draft couldn't be saved — keep this page open,” “Images need reselection,” “Video uploading / processing / ready,” “Checking whether your post published,” and confirmed “Published”/“Changes saved.” Scope a local-save notice to text/selections, not all attachment bytes. Show action-specific next steps and distinguish leaving from explicit discard. Never expose submission keys, version numbers, worker names or provider implementation to authors.

Downstream: shared form feedback patterns; preserve transactional mechanisms. Browser tests verify that recovery truth matches user copy after storage failure, expired media, uncertain publish and account changes.

### Rams and precedent

[Rams' principles, Vitsœ](https://www.vitsoe.com/us/about/good-design): useful and understandable support A1–A4; honest supports dates, helpfulness and A6; unobtrusive and as little design as possible favor labels/controls over new subsystems; thoroughness supports failure paths and accessibility. Aesthetic quality cannot be judged without screens. Durability favors stable user meanings. Environmental restraint supports existing no-autoplay/lazy-media choices; no footprint reduction is quantified. Innovation is justified only by useful task discovery, not novel controls. These are applications, not a compliance certification.

[Reddit scoped search](https://support.reddithelp.com/hc/en-us/articles/19696541895316-Available-search-features) supports making scope legible, not any particular Tips data predicate. [W3C form feedback](https://www.w3.org/WAI/tutorials/forms/notifications/) supports concise status/error text and field associations. These conventions are evidence, not proof that copying a large forum's full feature set helps this MVP.

## Fable Round 1

Written independently before reading Codex Round 1. Anchors are `file:line` in `docs/design/technical/`. Labels: **defect** (specified behavior fails a user), **gap** (interaction unspecified, both docs would guess differently), **optional** (product change; owner decides). Each fix is marked **preserving** (same product behavior) or **product cut**.

### Verdict

The four documents are internally consistent and unusually careful about durability and recovery. The gaps are almost all at the seams a newcomer on a phone walks through: arriving without knowing what to type, signing in through a mail app, reading a 20,000-character pasted output between two reviews, and losing screenshots on return. None needs new infrastructure. Most are copy, placement, or one URL parameter. One notice should go.

### F1 — Defect: the sign-in destination lives in the originating browser session, but the magic link opens somewhere else

- **Source.** frontend-design.md:25 (editor routes use the generated authenticated plug, "which stores a validated local GET return path"); frontend-design.md:27 ("return to the intended editor after verification"); backend-design.md:462 ("Preserve the intended local destination through authentication"); backend-design.md:394 (signed-out vote returns "to the same tip or selected review"). The generated plug stores `user_return_to` in the Plug session cookie of the browser that hit the editor route.
- **Scenario.** A developer on a phone reads a tip in Safari, taps "Write a review", chooses a handle, enters email. The link arrives in the Gmail app. Tapping it opens Gmail's in-app browser (separate cookie jar; iOS `SFSafariViewController` and Android Custom Tabs do not share the originating tab's session). The magic link signs in *that* browser, which has no return path, so it lands on the home page. Safari is still signed out and still shows "check your email". The newcomer has done the hard part and been dropped at the door. Desktop users who read mail in another browser profile hit the same thing. This is the majority path for magic-link signup on mobile, and the design's first success signal (backend-design.md:25) depends on that person reaching the review form.
- **Whys.** Why is the user not at the editor? The signed-in browser never knew the destination. Why? The destination is in a session cookie, not in the link. Why only the cookie? The generated plug's convention assumes the same browser completes sign-in, which holds for passwords and fails for email links. Why does the flow use the plug convention unchanged? The signup contract was specified for account rules, not for where the link is opened. Two more whys stay here: the root is *destination bound to the wrong carrier*.
- **Simplest fix (preserving).** Carry the validated local return path in the magic-link URL, validated again on verification with the same allow-list the plug uses. The "check your email" screen states that the link opens the editor in whichever browser opens it. Handle choice already travels with registration, so nothing else changes.
- **Effects.** Backend: one extra query parameter on the verification route and the same path validation, applied in Accounts. Frontend: the pending-verification page copy; the leave-confirmation rule is unaffected because no draft exists before the editor opens. No new storage. Slack, Notion and Medium magic links all carry the destination for this reason.
- **Acceptance.** iOS Safari plus Gmail app: tap link, land signed-in on the review editor for the intended tip in the in-app browser. Same for a vote return path. A tampered path in the link falls back to home. The original tab, on reload, is signed out and offers Sign in without losing the intended path.

### F2 — Gap: the home page does not tell a first-time developer what to type

- **Source.** backend-design.md:17 and :21 (first reader journey is task-first search: "a reader has something they want to do with AI"); frontend-design.md:88 (main page is a Hacker News/Reddit-style feed with Hot/New, search box and tag chips); frontend-design.md:283 (search help describes matching modes). Nothing specifies first-visit framing, search placeholder text or a one-line purpose statement.
- **Scenario.** A developer arrives from a shared link to the home page. They see a list of titles with chips like "Persona" and "Phrase" and an empty search box. Hacker News can afford no explanation because its audience already knows it. Tips cannot: the hypothesis is that readers search a *task*, and nothing invites that. The likely behavior is scrolling Hot, which is the secondary journey.
- **Whys.** Why no framing? The frontend doc inherits the HN feed pattern. Why? The owner asked for that style. Why is it insufficient here? HN's feed is the product; Tips' product is task search with the feed as fallback (backend-design.md:17). Root: the page pattern was borrowed without the entry copy that pattern lacks.
- **Simplest fix (preserving).** Two strings, no components: a search placeholder that models a task ("What are you trying to get the AI to do? e.g. stop editing files I didn't ask about") and one line under the site name on the home page only ("Techniques people have actually tried, with what happened"). The `noindex` period (data-model.md:799) makes direct links the only arrival path, so the home line matters more, not less.
- **Effects.** None on backend. Rams: understandable, honest. Remove the home line once trials show first sessions search without it.
- **Acceptance.** Five-second test in developer trials: describe what the site is for and what to type. Instrument the share of first sessions whose first action is a search submission versus a feed click.

### F3 — Optional (recommended): full verbatim prompt/result blocks between reviews make the tip page unreadable on a phone

- **Source.** frontend-design.md:110 ("show each review's full firsthand account, optional prompt, optional result text ... immediately. ... Do not collapse these sections or truncate their text behind 'Read more'"); data-model.md:175–179 (`body`, `prompt`, `output` each up to 20,000 characters); data-model.md:486 (30 reviews per page); data-model.md:360 (`<pre>` block, verbatim). The data-model history rejected only *fetch on expansion* (data-model.md:1062: "Truncate review prompts and outputs and fetch the rest on expansion. Full text remained"). The frontend rule goes further and forbids any fold. No why-chain for that extension is recorded in idioms-v2-frontend-review.md.
- **Scenario.** A review pastes a 6,000-character agent transcript as Result. On a 390-pixel viewport that `<pre>` is roughly forty screens. The next review's "this stopped working on the new model" sits below it. Readers on phones will not reach it; reviewers who paste evidence are punished by burying their neighbors. Stack Overflow, GitHub and Discourse all fold long code blocks or long comments client-side.
- **Whys.** Why is every block fully expanded? The rule says do not collapse. Why? To keep evidence visible and avoid a fetch operation. Why does a fold need a fetch? It does not: the text is already in the HTML. Why was "no fold" written? It conflated presentation folding with the rejected fetch-on-expand. Two more whys do not move: root is *a presentation rule inherited from a data decision it does not depend on*.
- **Simplest fix (product change to a presentation rule; keeps full-text delivery).** Prompt and Result blocks taller than about two viewport heights get a max-height with a fade and a "Show all N lines" control implemented as a Phoenix JS command. The review body is never folded. No server event, no extra query, no truncation of delivered text; copying via selection still works after expanding. Search excerpts are unaffected.
- **Effects.** Frontend only. It removes nothing from the reader's reach and adds one JS command. Owner decides because it changes an agreed presentation rule.
- **Acceptance.** Tip with three reviews, each with a 5,000-character Result, on a 390-pixel viewport: the third review's first line is reachable within roughly six swipes; expanding a block does not shift focus or scroll position; `<pre>` whitespace survives; a screen reader announces the control and the line count.

### F4 — Gap: the two-hour edit window is never shown to the author, and the after-window path is undiscoverable

- **Source.** backend-design.md:372 (tips editable two hours, reviews any time); data-model.md:16; frontend-design.md:136 (window mentioned only for moderator-hidden content); data-model.md:481 (`by_author` review of own tip is allowed and labelled). No line says the author sees the deadline or what to do after it.
- **Scenario.** An author publishes a tip at lunch, notices a wrong flag name at dinner, opens the tip and finds no Edit control. Nothing explains why. The design's own answer to "advice becomes outdated" (backend-design.md:19) for tips is that the author writes a labelled review on their own tip, which no newcomer will guess.
- **Whys.** Why is there no Edit? Window closed. Why a window? Reviews bind to the tip's content and there is no edit history (data-model.md:951). Why no history? Deferred until a dispute. So the window is the right guard; the root of the *user's* confusion is that a deadline exists without being displayed. The window itself is an owner decision and is not reopened here.
- **Simplest fix (preserving).** While the window is open, the author's own tip page shows "Edit · until 14:32" using the existing `created_at`. After it closes, the author's contribution control reads "Post an update as a review" and opens the normal review editor, which already supports author reviews. Copy only; the backend already computes eligibility.
- **Effects.** Frontend copy and one conditional. Backend unchanged. Ties into F8.
- **Acceptance.** Author view at t+1h shows the deadline; at t+3h shows no Edit and the update path; a non-author never sees either.

### F5 — Gap: a restored draft drops images silently, while videos keep a placeholder

- **Source.** frontend-design.md:183 ("reopening a draft requires selecting images again"; "For expired, missing, or failed videos, retain their place and offer re-upload or removal instead of silently dropping them"); frontend-design.md:199 (drafts store "recoverable attachment references; image/GIF files still require reselection"); frontend-design.md:201; backend-design.md:315. The placeholder rule is written for videos only.
- **Scenario.** On a phone, the reviewer attaches three screenshots, switches to another app, and Safari evicts the tab. The draft restores the text; the attachment tray is empty. The reviewer does not know which three screenshots they picked, or that any were picked. Screenshots are this product's primary evidence type (frontend-design.md:177).
- **Whys.** Why are images gone? They upload on submission (backend-design.md:257), so nothing durable exists. Why on submission? To avoid a staging lifecycle (frontend-design.md:219). That decision holds. Why is there no placeholder? The video rule was not extended when images kept a different transport. Root: *one recovery rule for two transports, written for one*.
- **Simplest fix (preserving).** The draft record stores each selected image's filename and position (already storing "selections"). On restore, render each as a disabled slot with "Reselect" and "Remove". Reordering and the ten-item count treat slots as occupied until removed. Publish validates that no unresolved slot remains, with the existing field-error summary.
- **Effects.** Frontend only; no backend or media-table change. Reuses the video slot presentation. Explains the reselection rule at the moment it bites instead of in a help page.
- **Acceptance.** Browser test: select two images, kill the tab, reopen; two named slots appear in order; Publish is blocked with a summary until each is reselected or removed; the shared ten-item count includes them.

### F6 — Optional (recommended cut) with a preserving alternative: the "Results refreshed" notice on Back

- **Source.** frontend-design.md:86 (rerun page one on Back or reconnect, reset the list, show "Results refreshed"; `_mounts > 0` is a reconnect signal, not a Back detector; "URL/list mismatch alone does not prove Back either"); frontend-design.md:116; backend-design.md:118; software-architecture.md:148 (omitting the notice "remains an optional product reduction"). idioms-v2-frontend-review.md:52 notes Back within a live session is `handle_params`, not a remount.
- **Scenario.** Search → open a tip → Back is the most frequent gesture on the site. Each Back shows a notice. Readers stop seeing it within a day, and then miss the one notice that matters, the retrieval error. On mobile it costs a line of the first screen. Reddit, Hacker News and Google re-render on Back without comment.
- **Whys.** Why a notice? Loaded depth is lost and order may change. Why is depth lost? Only page one reruns. Why only page one? To avoid a snapshot. Why does losing depth need explaining? Because a reader who pressed Load more twice and opened result 50 comes back to 20 rows. Why not rerun to the same depth? Nobody costed it: the search window is bounded at 200 tips and the SQL computes the whole fused ranking before `limit 20 offset $3` (data-model.md:755), so `limit 20·N offset 0` costs the same ranking work. Two more whys stay here: root is *a notice standing in for a cheap recovery*. Separately, the doc has no working Back detector (:86 rejects both candidates), so the notice cannot even be shown reliably.
- **Recommended (product cut, owner decides).** Drop the notice. Back and reconnect re-render silently, like every forum. Frontend removes the notice, its detector and its tests.
- **Preserving alternative.** Put loaded depth in the search URL: Load more patches `n=40`, `n=60` (validated multiple of 20, at most 200) and `handle_params` requests `limit n offset 0` through the same `search_tips` call. Back restores the rows; order may differ, as it does on every other site. Browse keeps its cursor rule and resets silently. Cost: one parameter, hydration of up to 200 summaries on a deep Back.
- **Acceptance.** No notice in first-connected, Back or reconnect renders. With the alternative: two Load mores, open the fortieth result, Back, forty rows shown, no duplicate DOM ids, the offset-based ids still unique.

### F7 — Gap: the default review sort on the tip page is not specified

- **Source.** data-model.md:410–411 (Best and New indexes and cursors); data-model.md:478 ("reviews, Best, first page"); frontend-design.md:107 and :261 (review filters and empty state); frontend-design.md:267 ("Keep the 'New' sort in original publication order"). No line names the default or says the sort is in the URL.
- **Scenario.** Backend assumes Best; frontend builds New first because "what still works" is recency. Two devs, two defaults, and the Back rule at frontend-design.md:116 ("Retain filters, sort ... from the URL") has nothing to retain.
- **Simplest fix (preserving).** Default Best (matches the Reddit and Steam conventions the model already cites, and the `reviews_best` index); expose the sort in the URL like profile tabs. Recency is already served by "Latest review posted N days ago" (data-model.md:475). Whether to default to New is an owner call; with one review per user per tip and small early counts the two orders barely differ, so decide on convention.
- **Acceptance.** Tip page without a sort parameter renders Best; `?sort=new` renders New; Back restores it.

### F8 — Gap: the contribution control on a tip page has five states and no specification

- **Source.** frontend-design.md:130 (label the review action around firsthand experience); :124 (signed-out vote starts sign-in); :134 (hidden tip disables new-review entry); data-model.md:494 (own review has its own slot); backend-design.md:523 (frontend hides unavailable contribution controls during a full ban); backend-design.md:410 (deleted tip blocks new reviews).
- **Scenario.** The reader who has just tried a technique returns to the tip. Whether they see "Write a review", "Edit your review", a disabled control with a reason, or nothing depends on five conditions spread over three documents. This control is the only bridge between the "try" and "return" steps of the first journey (backend-design.md:21).
- **Simplest fix (preserving).** One control, one placement (directly below the tip content, above the review list, before any review is read), one state table shared by both docs: signed out → "Sign in to review"; eligible, no review → "Tried this? Write a review"; has review → "Edit your review"; parent hidden or deleted → disabled with "This tip is not accepting reviews"; fully banned → absent; author → F4's Edit/update variant. `get_tip_page` already returns everything needed.
- **Effects.** Copy and a state table; no backend change beyond confirming the projection exposes viewer eligibility. Removes the risk that the CTA sits below thirty reviews.
- **Acceptance.** One LiveView test per state; the control is within the first two viewport heights on a 390-pixel screen for a tip with a long body.

### F9 — Gap: "tip" and "technique" name the same thing in user-facing copy

- **Source.** backend-design.md:17, :21, :33 ("technique"); frontend-design.md:88, :263 ("technique selector", "technique and model tags"); data-model.md:1020 (tags are technique *categories*: Phrase, Persona, System prompt ...). Helper copy at frontend-design.md:271 says "Explain when to use this".
- **Scenario.** A row shows "Technique: Persona" on a tip titled "Tell the agent it is a senior reviewer". Is the technique the tip or the tag? The review CTA says "tried the technique"; the site says "tips". Two nouns, one thing, on every screen.
- **Simplest fix (preserving).** "Tip" is the content unit everywhere users read; the tag axis is labelled "Type" (or the tag alone, unlabelled, as Reddit flair is). "Technique" leaves user-facing copy. Backend prose can keep it.
- **Acceptance.** Grep of templates and helper text for "technique" returns only the tag-axis label if kept.

### F10 — Gap: the moderation queue silently stops at fifty targets

- **Source.** data-model.md:404 and :414 (no pagination in v1); data-model.md:630 (grouped, limit 50); backend-design.md:421.
- **Scenario.** A spam wave creates sixty reported targets; the moderator clears the visible fifty and sees an empty queue that is not empty.
- **Simplest fix (preserving).** Query 51, show "More reports exist; resolve some to see them." No pagination.
- **Acceptance.** Fixture with 51 reported targets shows the line; with 50 it does not.

### F11 — Note, not a finding: the "return to review" step has no path

- **Source.** backend-design.md:21–27 (first journey and success signals); data-model.md:955 (email deferred); notifications reach authors only (data-model.md:682).
- Nothing brings a reader back after trying a technique: no saved tips, no reminder, no email. That is correct for an MVP that has not observed the problem; the fix is F8's placement and instrumenting return-to-tip visits in trials. Raised so the phase records that the loop is open by choice, not by omission.

### Proposed shared experience rules (backend and frontend)

1. The intended destination travels with the sign-in link, not only the originating session. (F1)
2. Every deadline a user can act on is displayed where it applies: tip edit window, one-hour upload, 48-hour draft video, seven-day registration. Only the first is missing. (F4)
3. Nothing the user selected or typed disappears without a slot and an action: applies to images as well as videos. (F5)
4. Back and reconnect re-render silently; notices are for failures only. (F6, owner decides)
5. One contribution control per tip page with the six viewer states above. (F8, F4)
6. Review sort defaults to Best and lives in the URL. (F7)
7. "Tip" is the unit; the tag axis is a type label. (F9)
8. The home page carries task framing in the search placeholder and one line. (F2)

### Considered and not raised

- **Filter panel with pending/applied state.** Heaviest browse UI, but the owner supplied the screenshots (frontend-design.md:60) and pending-then-Apply is the standard mobile filter pattern. Not a cut.
- **Handle before email.** Puts a permanent choice first, but it is what lets the magic link land directly in the editor. Keep.
- **No vote replay after sign-in.** Hacker News replays; Reddit does not. The simpler choice is fine once F1 lands the reader on the tip.
- **Mark-all-read on inbox open.** Instagram model; low stakes for three notification types.
- **Freshness in feed rows.** `last_up_at` was rejected (data-model.md:1063); review count is the scent for now.
- **Two-hour window itself.** Owner decision with a sound root (reviews bind to tip content, no history).

## Codex Round 2 — challenge of Fable's independent findings

Fable's mobile/newcomer lens exposed concrete gaps my operation-oriented pass missed, especially image reselection slots and contribution-control precedence. I accept the underlying findings with the corrections below. This is not yet closure; I still need Fable's response to A1–A6.

| Fable finding | Codex disposition and downstream challenge |
|---|---|
| F1 magic-link destination | Accept the carrier gap and recommend a validated local destination carried through the link. Qualify the browser claim: cookie sharing differs by platform, browser, mail app and configuration; “majority path” is unsupported. Do not claim every Android Custom Tab has a separate jar. Cross-browser completion restores a destination, not local drafts or the originating browser's sign-in. Decode/validate at consumption, fall back safely, authorize target normally, carry selected-review identity, and never transport draft text. Accounts verifies identity; the web boundary should own routing/return-path interpretation. Verify rather than assume other products' exact link internals. |
| F2 task framing | Accept. A placeholder disappears while typing and is not a field label: use a persistent “Search tips” label plus a short task example/helper. No invented verification guarantee from “actually tried”; these are authors' reports, not audited trials. Use observed first-session tasks/interviews already planned; a new analytics subsystem is unnecessary. |
| F3 folded evidence | Accept as an optional product reopening for a measured readability problem, not a proven defect in an unseen UI. Reject the unsupported forty-screen estimate and universal competitor-folding claim. Content structure, font and viewport determine height. The current source explicitly forbids folding: we cannot infer lack of authority from incomplete historical rationale. Evaluate wrap + section navigation first. If folding is chosen, use accessible disclosure semantics and full delivered content, not an arbitrary fade hiding focusable elements; code selection must remain practical. |
| F4 deadline/update path | Accept deadline and owner-labelled update path, but never offer a new review if one already exists: offer “Edit your review.” An author's review is another firsthand account, not a correction of the now-immutable tip text. It may remain buried by Best; this does not itself solve A1. No assumed automatic promotion. |
| F5 image placeholders | Accept as a required recovery clarification. Save lightweight filename/type/size/order descriptors, no image bytes, tokens, or provider keys. A restored local upload ref is not reusable: explicitly bind replacement to the chosen slot. Block publication until missing evidence is reselected or deliberately removed. Backend already validates received attachments; frontend must preserve intended slots. Reselection cannot prove identical bytes; do not claim identity from matching filenames. |
| F6 Back notice/depth | Agree notice removal is an optional simplification. Reject “cheap recovery” as established: ranking may be similar but hydration, HTML, media metadata and browser layout grow, and reranking forty rows does not restore the same items or scroll. The proposed n parameter changes established retrieval and URL history semantics; it is not a preserving fix. Keep A4's real navigation trial and cost the option only if needed. Do not erase native retained DOM merely to show a notice. No architecture mandate to build depth recovery. |
| F7 default sort | Accept explicit Best default plus review-specific URL parameter (avoid confusing browse Hot/New with review Best/New). Keep selected-review links compatible with sort/filter params. Best is an MVP default, not evidence of current effectiveness. |
| F8 contribution control | Accept with precedence correction. A hidden/deleted parent blocks *new* reviews, but existing reviews stay editable: existing-own-review permission must be resolved before the parent new-review rule. Signed-out users should not be sent through signup for a known-unavailable new-review action. Full ban blocks contributions but keeps author deletion. Author-update label must still obey own-review uniqueness. Placement below arbitrarily long tip content cannot guarantee first-two-viewports visibility: put the action/jump link near tip header and avoid duplicating long forms. |
| F9 vocabulary | Amend: “Tip” as content unit, “Technique type” as tag dimension, “Review” as firsthand report. “Type” alone is vague; banning the ordinary word technique from all copy is unnecessary and conflicts with “Other technique.” Keep natural explanatory language. No schema/table renaming. |
| F10 moderation cap | Underlying bounded-work visibility gap is valid, but the scenario is wrong: after resolving the first fifty, a fresh query exposes the next ten. It does not stay empty by definition. Recommend 51st-row has-more detection plus clear “Showing the first 50 reported items; resolve items and refresh to see more,” if the cap is reached, and a reliable refresh after action. Acknowledge that lower-priority cases may wait during sustained load. No pagination subsystem until volume warrants it. |
| F11 return loop | Agree no bookmarks/reminders/email requirement yet. Observe the real return task in trials. F8 makes the return action discoverable; it does not cause return visits. |

Sources for calibration: [Android Custom Tabs](https://developer.chrome.com/docs/android/custom-tabs/overview) describes browser-powered tabs and shared browser state; verify platform-specific behavior rather than assume a separate jar. [W3C informative images](https://www.w3.org/WAI/tutorials/images/informative/) supports substantive text equivalents; file labels alone do not provide them. [W3C reflow](https://www.w3.org/WAI/WCAG22/Understanding/reflow.html) supports narrow viewport checks while preserving layout-dependent content.

Pending challenge to my A1: “Recent activity” improves discovery of changed reviews but still cannot distinguish typo from retest; decide whether that is a net improvement now. I am willing to retain Best/New and explicitly record the stale-advice risk if we define a falsifiable trial instead of pretending timestamps or the author's update CTA solve it. Pending A2: a seen-id set is already accepted for browse; why should the product's primary search journey accept visible repeats to save that small amount of state?

## Fable Round 2 — response to Codex Round 1

Verdicts: **Accept** A3, A5 (baseline), A6, and the root-cause framing. **Reject** A1's sort and activity date and A2's suppression. **Amend** A1, A2, A4, A5 with cheaper fixes that address the same root. F1–F10 stand and are not covered by Codex's list; F1 is the most severe item on the board and needs Codex's verification. No consensus is presumed.

### Root cause — Accept

"Behavior settled operation by operation" is the same diagnosis behind F7, F8 and F9: correct operations, unshared meanings. The remedy we both propose is a short list of shared rules, not a layer. Merge Codex's contracts into the rule list at the end of this round.

### A1 — Reject the "Recent activity" sort and activity date; accept the entry point; amend the root

**The problem is real, the proposed fix is dishonest by adjacency and gameable.**

- **Timestamp honesty.** backend-design.md:372 already states "An edit timestamp records a change, not proof that the author retested." A sort keyed on that timestamp presents it as exactly that proof, whatever the label says. Codex concedes the typo and the retest share one Updated date; sorting by it rewards the ambiguity rather than resolving it. "Latest review activity" on the tip has the same defect at lower stakes.
- **Gaming.** An edit-driven sort is a bump button. Every forum that has faced this decided edits do not move content: Discourse updates `bumped_at` only on new posts and never on edits; Hacker News and Reddit ignore edits for ranking; Steam shows "Posted" and "Updated" separately and sorts by posted date. Codex's "test the tradeoff" would require an anti-bump rule (minimum change size, cooldown), which is the extra state the whys said to avoid.
- **Low value now.** One review per user per tip and a small trial corpus mean the three sorts barely differ (F7). Adding a third sort, a new index and cross-file semantics before any returning contributor exists is the pattern the root-cause chain warns against.

**Amend.** The honest paths already exist and are only undiscoverable:
1. Edit shows "Updated" (frontend-design.md:267). Accept Codex's placement: Updated sits next to the setup line, labelled as an edit date. Fold into F8's state table ("Edit your review").
2. A genuinely new attempt is a new firsthand report. The design already permits delete-and-re-review with a new key (data-model.md:183, backend-design.md:360); it surfaces at the top of New with an honest date and forfeits old votes, which is the honest cost of replacing a report.
3. Defer any sort change until a trial observes a returning contributor's update that readers could not find. If reopened, the honest option is multiple dated reviews per user (relax `reviews_one_per_user`), not an edit-driven sort. Owner decision, recorded.

Acceptance now: F8 states; Updated visible; delete-and-re-review reachable from the own-review slot without a new control (the existing Delete plus the CTA returning to "Write a review").

### A2 — Reject seen-id suppression; amend by removing the dominant cause of cross-page reranking

**What the state buys.** Suppression needs a seen set (bounded, fine), tip-id DOM ids (a simplification), and a new page state "Load more returned nothing new" with its own copy, tests and an end-of-window distinction. That last state is worse UX than a visible repeat: a reader taps Load more and nothing appears. It also hides the omissions Codex acknowledges it does not fix.

**Why repeats happen at all.** The fused score is pure reciprocal rank fusion over BM25 and vector branches (data-model.md:749–755); votes do not enter it, so votes between pages cannot reorder. Content publish/edit/hide between two Load mores seconds apart is rare. The realistic cause is a **retrieval-mode flip**: page one hybrid, page two keyword-only because the query embedding timed out (backend-design.md:57–59 chooses the mode per request). That produces a different list, and offset 20 into a different list repeats much of page one.

**Amend (preserving, cheaper).** backend-design.md:57 already permits reusing a successful query vector for the same normalized query and model version. Make that the continuation contract: page one's query vector travels with the submitted-query state (about 4 KB in the socket, passed to `search_tips` as an option, never the socket itself) and every Load more for that query uses it. No per-page embedding call, no flip, and rankings across pages then change only when content changes. Failure is still not cached; a new query embeds afresh. This does not freeze ranking or add a table, and it removes a provider call from every Load more.

Keep occurrence-based DOM ids and accepted repeats. Measure the duplicate rate in trials; adopt suppression only if repeats still appear after the flip is gone.

Acceptance: with the embedding provider stubbed to fail on the second call, Load more still returns the hybrid ranking; page two shares no tips with page one on a static corpus; a changed query embeds again.

### A3 — Accept

Labels: discovery filter help says "Tip author's model / environment"; review-list controls say "Reviewer's model / environment"; a search excerpt shows the reviewer's setup inline and never a chip that looks like a filter match. One placement each, as Codex says. Add as shared rule 9. Consistent with F9 (one noun per thing).

### A4 — Amend: adopt F6's URL-depth for search now instead of a trial gate

Agree on: no snapshot or history subsystem; never reset a still-mounted DOM merely to normalize to page one; drop the claim that the notice resolves anything. Disagree on gating: for search the fix is one URL parameter because the bounded window makes `limit 20·n offset 0` the same ranking work (F6). Browse, profile and inbox keep silent reset to their first batch, which is what Reddit does and what cursor pagination allows. The "Results refreshed" notice goes in all cases (owner decides; both reviewers now recommend removing it).

### A5 — Accept the baseline; amend on folding

Accept: `white-space: pre-wrap` on prompt/result so copied bytes are unchanged; overflow contained per block; headings per review and a skip link past the list; bounded preview sizes; lazy loading; author guidance to describe visual findings in text. Alt text stays a declared limitation.

Amend: F3's fold is not truncation. Every byte is in the HTML, selection and copy work after one tap, and the control is a JS command. Skip links serve keyboard and screen-reader users; the fold serves the sighted phone user Codex's own scenario opens with. They coexist. Codex should say whether the objection is to folding as such or to fetch-on-expand, which F3 also rejects.

### A6 — Accept, with two edits

Accept the vocabulary. Edits: "Draft saved in this browser" carries a time ("saved 10:42"); "Checking whether your post published" is a fixed-values state, not a notice, per frontend-design.md:95. Fold F5's image slots ("Images need reselection" becomes per-image slots) into this vocabulary. Add as shared rule 10.

### Items Codex did not raise

F1 (sign-in destination lost across browser contexts), F2 (task framing), F4 (edit window not displayed), F5 (image slots), F10 (queue limit). F1 needs Codex's verification against the generated plug: it stores `user_return_to` in the Plug session, and email links routinely open in a different browser context on phones.

### Consolidated shared rules for Codex's response

1. Destination travels with the sign-in link. (F1)
2. Every actionable deadline is displayed where it applies. (F4)
3. Nothing selected or typed disappears without a slot and an action. (F5, A6)
4. Back and reconnect re-render silently; search restores depth from the URL; notices are for failures. (F6, A4)
5. One contribution control per tip page with viewer states, including "Edit your review" with a visible Updated date. (F8, A1)
6. Review sort defaults to Best and lives in the URL; edits never move content. (F7, A1)
7. "Tip" is the unit; the tag axis is a type label. (F9)
8. Home page carries task framing. (F2)
9. Filter scope is named: author's setup for discovery, reviewer's setup in reviews. (A3)
10. One saved/recovering/published vocabulary with times and fixed-values states. (A6)
11. Search continuation reuses the page-one query vector; repeats are accepted and measured. (A2)
12. Long prompt/result blocks fold client-side; text is never truncated or fetched on expand. (F3, A5; owner decides)

Open for Codex: A1 deferral, A2 amendment, F1 verification, F3/A5 folding, F6 notice removal.

## Fable Round 3 — corrections accepted, A1/A2 answered, disposition

Read Codex Round 2 after writing Fable Round 2 above. Corrections below supersede the corresponding text in Fable Rounds 1–2.

### Corrections to my findings

- **F1.** Retract "majority path" and the blanket cookie-jar claim. Android Custom Tabs share Chrome's state; the failure applies only when the link opens in a different browser context (iOS in-app web views, a different browser or profile, a desktop mail client opening a non-default browser). The fix stands unchanged: a validated local destination in the link, interpreted at the web boundary, carrying the selected-review id when present, never draft text. What it restores is the destination only, not the originating tab's sign-in or its local drafts.
- **F2.** Accept: persistent "Search tips" label plus one task example as helper, not a placeholder that vanishes on focus. Drop "actually tried" from the tagline; these are authors' reports, not audited trials. Wording is the owner's.
- **F3.** Relabel: optional reopening, to be evaluated after A5's wrap and per-review navigation are in place and only against a measured readability problem. Retract the forty-screen figure and the "all competitors fold" claim. If adopted: disclosure semantics, full delivered content, no fade over focusable elements, practical code selection.
- **F4.** Accept: an author who already has a review on their own tip gets "Edit your review", never a second review. The update path is another firsthand account, not a correction of the tip; it may sit low in Best. Not a solution to A1.
- **F5.** Accept: descriptors are filename, type, size and order only; replacement binds to the chosen slot; publication blocks until each slot is reselected or removed; filename match proves nothing about bytes.
- **F6.** Withdraw the "preserving, cheap" label for URL depth; it changes retrieval and history semantics and grows hydration. It is an owner option recorded here, not recommended. Consensus position: remove the notice (optional cut, both reviewers recommend), silent re-render, never erase natively retained DOM, and A4's navigation trial before any depth work.
- **F7.** Accept a review-specific parameter (for example `reviews=best|new`) so browse and review sorts cannot collide, compatible with selected-review links. Best is a default, not an effectiveness claim.
- **F8.** Precedence corrected. Resolve the viewer's own existing review first: it stays editable even when the parent is hidden or deleted (backend-design.md:410, :434). Then: fully banned → no contribution control, deletion still available; parent hidden or deleted and no own review → disabled with reason for signed-in *and* signed-out viewers, no sign-in redirect to a dead end; signed out on a live tip → "Sign in to review"; eligible → "Tried this? Write a review"; tip author inside the window → Edit tip, plus the own-review rule above. Placement: an action or jump link near the tip header, one form, no duplicate.
- **F9.** Accept "Technique type" as the tag-axis label and "Review" as the firsthand report. "Technique" remains usable as an ordinary word, including "Other technique". No schema renaming.
- **F10.** Scenario revised: resolving the first fifty exposes the rest on refresh; the gap is only that the moderator cannot see more exist. Accept: 51st-row detection, "Showing the first 50 reported items; resolve items and refresh to see more," and a reliable refresh after each action.
- **F11.** Agreed: observe the return task in trials; F8 makes the action discoverable, not the visit.

### A1 — take Codex's offer: keep Best/New, record the risk, define the trial

Accept retaining Best and New with no edit-driven sort and no activity date. Record the stale-advice risk as an open product risk with this falsifiable trial: seed one tip whose most helpful review predates a newer model and whose one edited review reports failure on that model; give trial readers the task "does this still work on model X?" with a time budget; the design is falsified if fewer than half find the updated report. If falsified, the owner chooses between multiple dated reviews per user (relaxing `reviews_one_per_user`) and an activity sort with an anti-bump rule; both are recorded as product changes. Neither the Updated date nor the update CTA is claimed to solve this.

### A2 — answer to "why accept repeats in search when browse suppresses?"

Because the two mechanisms are not the same. Browse suppression is exact: the cursor is monotonic in a stable index, so a seen id can reappear only by crossing the cursor, and dropping it loses nothing. Search continuation is a position into a list that may have been re-ranked; dropping seen ids does not recover the tips that fell below the position, and it produces short or empty pages that need their own state and copy. The dominant cause of re-ranking between two Load mores is the per-request retrieval-mode flip, which vector reuse removes at no state cost (backend-design.md:57 already permits it). So: adopt vector reuse now (preserving), measure repeats in trials, and adopt suppression if repeats still exceed a threshold we set in advance (proposed: more than one repeated tip per twenty Load mores). If Codex accepts that trigger, this is consensus; if Codex wants suppression unconditionally, that is the one remaining disagreement.

### Final disposition

| Item | Status | Outcome |
|---|---|---|
| Root cause (Codex) | Consensus | Shared rules list is the remedy |
| A1 Recent activity | Consensus, amended | Keep Best/New; risk recorded; falsifiable trial; edits never move content |
| A2 search dedup | Open, narrow | Vector reuse now; suppression on a pre-set measured trigger. Codex to confirm the trigger |
| A3 scope labels | Consensus | "Tip author's" vs "Reviewer's" setup labels |
| A4 navigation | Consensus | No snapshot; silent re-render; keep retained DOM; navigation trial; notice removal is an owner cut |
| A5 accessibility | Consensus | Wrap, contain, headings and skip links, bounded previews, guidance; alt text a declared limitation |
| A6 vocabulary | Consensus | Saved/recovering/published copy with times and fixed-values states; F5 slots folded in |
| F1 sign-in destination | Consensus, narrowed | Destination in the link, validated at the web boundary |
| F2 task framing | Consensus | Persistent label and helper; owner wording |
| F3 folding | Owner option | Reopen only against measured readability after A5 |
| F4 edit deadline | Consensus | Deadline shown; update path obeys own-review uniqueness |
| F5 image slots | Consensus | Descriptor slots, bound replacement, publish blocked until resolved |
| F6 Back notice / depth | Owner cut + owner option | Notice removal recommended by both; URL depth recorded, not recommended |
| F7 review sort | Consensus | Best default, review-specific URL parameter |
| F8 contribution control | Consensus, corrected | Own-review precedence; header placement |
| F9 vocabulary | Consensus | Tip / Technique type / Review |
| F10 queue cap | Consensus, revised | 51st-row detection and copy |
| F11 return loop | Consensus | Observe in trials; no build |

### Shared experience rules (final for this phase, pending Codex's A2 confirmation)

1. The sign-in destination travels with the link, validated at the web boundary.
2. Every actionable deadline is displayed where it applies.
3. Nothing selected or typed disappears without a slot and an action.
4. Back and reconnect re-render silently; retained DOM is never erased to show a notice; failures get notices.
5. One contribution control per tip page, own-review permission resolved first, placed near the header.
6. Review sort defaults to Best in a review-specific URL parameter; edits never move content.
7. Vocabulary: Tip, Technique type, Review; author's setup versus reviewer's setup.
8. Home page carries a persistent search label and one task example.
9. One saved/recovering/published vocabulary with times and fixed-values states.
10. Search continuation reuses the page-one query vector; repeats are measured against a pre-set trigger.
11. Stale-advice risk is recorded with the A1 trial; no timestamp or CTA is claimed to solve it.

Remaining disagreement: A2 suppression timing only. Everything else is consensus or an explicitly labelled owner decision. Waiting for Codex's confirmation and the phase handoff.

## Codex Round 3 — corrected tradeoffs and proposed closure

I accept A1 deferral, with an important correction: **do not recommend deleting and reposting an existing review as the normal retest/update flow.** That destroys the prior report's stable link/context and votes and turns a safety operation into a ranking workaround. Keep Edit your review and honest Updated labels. The residual freshness/discovery failure remains real and belongs in trials. Multiple dated reviews and activity sorting are alternatives to assess then, not an agreed new design.

The claim “Discourse ... never [bumps] on edits” is false: [Discourse's cofounder explains that editing the last post normally bumps a topic](https://meta.discourse.org/t/no-bump-option-when-editing-last-post-in-a-topic/170012/11). We can reject automatic bumping for Tips on its own tradeoffs; no universal forum rule is needed. Also my initial A1 proposed replacing the recency option, not necessarily adding a third sort. Either change still merits deferral at this MVP stage.

A2's vector reuse is useful performance reuse but **does not remove retrieval-mode flips**. Backend 59 chooses hybrid/fallback per request; data model Search permits fallback after search SQL timeout as well as query-embedding failure. Page one can also be keyword-only with no vector to retain, then later recover to hybrid. Provider reuse cannot imply mode stability. A successful vector can be reused under the existing optional contract, but no new cached failure, pinned mode, cached ranking, or “no flip” promise follows.

To avoid replacing one isolated decision with another: I propose consensus to **retain current search repeat/omission semantics as an explicit validation risk**, while recording visible-id suppression as the smallest candidate remedy if repeats impair comparison. Neither caching nor a “results refreshed” notice solves duplicate presentation. In the trial inject a hybrid→keyword change, a keyword→hybrid change, and changed content; observe repeated results and returning from deep search. If we reopen dedup, advance by scanned offset and handle duplicate-only pages explicitly. Do not make the vector reuse amendment a prerequisite or claim that votes cause search reranking.

A4/F6: defer URL-depth recovery pending the measured comparison task. One parameter still entails larger hydration/HTML, URL history semantics and different result selection; no costless guarantee of old position. Both recommend **dropping the Back-only refresh notice** as an optional product simplification, while keeping an actual reconnect/reset notice if implementation can identify that state reliably and it helps explain disruption. “Notices are for failures only” is too absolute: confirmed saves and meaningful recovery deserve feedback. Existing contracts remain until a product change is adopted.

A5/F3: no principled objection to accessible client-side disclosure. The current explicit no-collapse choice must be reopened, and a working narrow-screen example should decide it. Recommend full text + wrapping/section navigation as baseline; retain folding long Prompt/Result as an optional experiment if that fails. Never fold the required firsthand body by default, never hide focused content, and never introduce a fetch-on-expand endpoint. No claimed swipe count before layout measurement.

Accept A3, A6 (save timestamp on successful local write only), and Fable F1–F10 **as amended in Codex Round 2**. F1's local-cookie gap is directly supported by the current frontend contract; implementation isn't present, so do not claim a reproduced generated-code bug. Validate a normalized local GET destination through both email URL and verification form submission, with safe fallback and ordinary target authorization. Cross-browser draft and session limitations remain.

### Proposed final architecture disposition

| Disposition | Items |
|---|---|
| Recommend completing before the first end-to-end implementation | Auth continuation; task-first framing with persistent label; visible edit deadline; missing image slots; contribution-action precedence; explicit Best default + review URL sort; tip/technique-type vocabulary; author/reviewer filter scope; truthful local-save/media/publish states; moderator has-more feedback; responsive and keyboard reading baseline. |
| Recommend testing as explicit product changes | Remove Back-only refresh notice; optionally fold long evidence when full expanded reading fails on mobile. Neither changes by implication. |
| Preserve now, expose residual risk in trials | Best/New by original publication, no edit notifications/history; search may repeat/skip across page requests; remount may lose depth; no bookmarks/reminders; missing media text alternatives remain an accessibility limitation. |
| Reject as current remedies | Routine delete/repost for recency; mandatory activity sort; mandatory search-depth reconstruction; vector reuse as a guarantee of fixed retrieval mode; brand-new snapshots, histories, analytics infrastructure or permission services. |

Trial cases must include a meaningful edit to an old review, an old high-voted review whose meaning changed, a mixed-model tip/review pair, long pasted evidence on a phone, auth in another browser, forced draft recovery with images, fallback changes during pagination, and Back from beyond page one. Observe comprehension and successful task completion; do not infer effectiveness from a Helpful vote. The cap of ten rounds remains; if Fable accepts this table and the prior corrections, this phase can close in round 3.

## Fable Round 4 — ratification and closure

I accept Codex Round 3's disposition table and close the architecture phase on it. Corrections to my earlier text:

- **Discourse.** Retracted: editing the last post does bump a Discourse topic. Tips rejects edit-driven ranking on its own tradeoffs (bump incentive, typo and retest indistinguishable), not on a universal forum rule.
- **Delete and repost.** Withdrawn as an update path. It destroys the prior report's link and votes. The only recommended update path is Edit your review with an honest Updated label; the residual freshness risk goes to trials with the A1 case.
- **Vector reuse.** Not a mode-stability guarantee. Fallback also follows a search-SQL timeout, and page one can be keyword-only with no vector to keep. Reuse stays the existing optional performance contract; repeats and omissions remain an explicit validation risk with visible-id suppression recorded as the smallest candidate remedy. Trial injects both flip directions and changed content.
- **Notices.** "Failures only" was too absolute. Confirmed saves and reconnect or reset get feedback when the state is reliably identifiable. Only the Back-only "Results refreshed" notice is proposed for removal, as an optional product simplification.
- **Depth and folding.** Both deferred to measured product choices: URL depth after the navigation comparison task; folding only if full text with wrapping and section navigation fails on a real narrow-screen example, and then with disclosure semantics and no fetch.
- **F1.** Supported by the frontend contract, not a reproduced generated-code bug. Validate the normalized local destination on both the email URL and the verification form path.

Shared rules 4, 10 and 11 in Fable Round 3 read as amended above. Phase closed at round 3 with consensus on all items and the labelled owner decisions in Codex's table.

## Codex Round 4 — phase closure confirmation

Fable's Round 4 ratification accepts the final amended disposition. Bilateral consensus reached in four numbered rounds including ratification, below the ten-round cap. Earlier references to closing at round 3 count only substantive debate and omit the separately numbered ratification. Earlier claims contradicted by the corrections/ratification are historical debate, not final recommendations. Small-sample trial thresholds suggested during debate are exploratory proposals, not validated success metrics or automatic product rules. The source technical designs remain unchanged.

Proceed to the [backend review](ux-backend-review.md), then the [frontend review](ux-frontend-review.md). Final recommendations will be summarized at the top of each file after all phases finish.
