# Holistic UX adversarial review — backend

Date: 2026-09-20. Status: consensus reached; four numbered rounds including ratification. Recommendations only; source designs unchanged.

## Read this first — final consensus

The existing database and context boundaries can support the UX. Complete the operation outcomes and search content so the frontend can explain what happened and offer a valid next action.

| Priority | Finding | Smallest agreed recommendation | Acceptance evidence needed |
|---|---|---|---|
| First | A review's selected setup is absent from its search text | Include its primary model/free-text model and environment; label setup matches honestly; retain parent-only structured filters | Model-A tip with model-B review whose prose does not name B; keyword/hybrid and setup-only edit fixtures |
| First | Auth destination exists only in the originating session | Carry a validated local GET destination through link and verification form; transfer no draft/session | Different browser context, selected review, invalid destination, unavailable target |
| First | Recovery can confuse absent, failed, pending and committed publication | Bounded lookup; explicit same-key retry; current-state outcomes; no automatic loop or inferred rollback | Lost response, lookup timeout, still-running original, then deleted/hidden publication |
| Next | Editors cannot explain deadline/eligibility failures consistently | Derived edit deadline and operation-specific reasons; existing-review id/current state on duplicate-review conflict | Expiry during media preparation, stale edit, ban, reauthentication, duplicate review |
| Next | Inbox event totals imply current votes | Omit numeric Helpful-event totals; retain internal folding and read guards | One user votes/removes/votes again; current destination count differs |
| Next | Repeat report feedback can imply new detail was stored | Distinguish newly persisted report from earlier receipt; no moderation-status promise | Repeated submission with changed detail and overlapping author revision |
| Next | Full bans and rate limits can look like broken controls | One restriction explanation, allowed deletion, preserved input and explicit timed retry when known | Already-open editor, definite rejection, edge interruption, prior uncertain attempt |
| Next | Auth-email feedback can overpromise delivery/link validity | Honest timeout feedback; preserve the generated/adapted token lifecycle | Initial confirmation invalidates earlier tokens; used/expired links; resend and email change |

Opening Notifications continues to clear captured unread activity, including unloaded rows. Explain the badge behavior without claiming the user viewed everything. Never use a later rejected attempt as proof that an earlier unknown publication did not commit.

The notification-number removal is an explicit recommended presentation change. No new schema, token policy, draft sync, report-status product, notification history, or background workflow is required. The checks above are proposed implementation evidence; this review did not execute an application. Source anchors, challenges and rejected fixes follow.

Protocol and perspectives: [architecture review](ux-architecture-review.md). Review API/data contracts as user-visible behavior: state, timing, eligibility, identity, saving, notifications, discovery, and recovery. Maximum ten bilateral rounds; stop at explicit consensus. Append attributed findings and responses. Source design files remain unchanged during this review.

## Fable Round 1

Sources: `docs/design/technical/backend-design.md` and `data-model.md` as of 2026-09-20, plus the architecture-phase rules (auth destination in the link, own-review precedence, deadlines displayed, nothing disappears without a slot, one saved/recovering/published vocabulary). Anchors are `file:line`. Labels as in the architecture file.

### B1 — Gap: "already reviewed" returns a reason but not the review, so the rule "own review first" cannot be honored at publish time

- **Source.** backend-design.md:347 (explicit error for "an existing review under another key"); backend-design.md:357 and data-model.md:525 (resolve the key before returning "already reviewed"); data-model.md:540 ("returns 'already reviewed' after the key check; link to edit").
- **Scenario.** Two tabs, or a restored new-review draft after the author published a review from another device. Publish fails with "already reviewed". The contract expects a link to Edit, but the return shape carries no id, so the page must run a second lookup, and the typed text has nowhere to go.
- **Fix (preserving).** Return `{:error, {:already_reviewed, review_id}}`. The composer stays on screen with its text, shows an error summary whose one action is "Open your existing review", and keeps the draft until explicit discard. No merge into the existing review.
- **Acceptance.** Publish from a second tab after a first publish: error carries the id; text remains; the link opens the edit form for that review; the draft is still restorable afterward.

### B2 — Gap (simplification): the lost-confirmation check has no bounded duration, so the editor could show an indefinite "checking" state

- **Source.** backend-design.md:345 (`get_publication`: "An absent result does not prove that an earlier request has finished"); backend-design.md:360 ("If no publication is found, the author may retry with that same key; an earlier request still in flight is handled by the unique constraint"); frontend-design.md:93 (reconcile the pending key before restoring).
- **Scenario.** The author reopens a draft whose Publish lost its response. The vocabulary agreed in A6 shows "Checking whether your post published". The backend says an absent result is not proof, which a cautious implementer reads as "wait, then check again".
- **Fix (preserving).** State the timing: one query, no wait. Found → navigate to the publication with "Published". Absent → enable Retry with the same key immediately; the unique constraint makes a duplicate impossible, so there is nothing to wait for. The checking state lasts one round trip and has no timer or second attempt.
- **Acceptance.** Simulated in-flight first request plus immediate retry: exactly one publication; the retry returns `:existing`; the editor never shows a spinner longer than the query.

### B3 — Defect (honesty): vote notifications display an event count as a vote count

- **Source.** data-model.md:653 ("A user who votes, removes the vote, and votes again counts twice; this is intended"); data-model.md:682 (`tip_upvoted` reads "Your tip got N helpful votes"); data-model.md:298 (`count` is "helpful-vote events folded into this row").
- **Scenario.** One reader toggles Helpful three times. The inbox says "Your tip got 3 helpful votes"; the tip shows Helpful 1. The author sees a number the site cannot stand behind.
- **Whys.** Why is N wrong? It counts events. Why events? The fold increments on every eligible upvote write, and removal does not decrement. Why not decrement? Removal would need to find and edit an unread row, and the count also guards mark-read (data-model.md:677). Why is the number shown at all? Copy borrowed from GitHub-style folding. Root: *an internal fold counter surfaced as a public number*.
- **Fix (preserving, recommended).** Keep `count` for folding and the mark-read guard; drop the number from vote copy: "Your tip got new helpful votes", "Your review got new helpful votes". Alternative (owner): hydrate the target's current `up_count` at inbox read time ("now has 12 helpful votes"), which is honest but shows a total rather than what changed. No schema change either way.
- **Acceptance.** Toggle test above: inbox row shows no inflated number; mark-read still matches captured counts.

### B4 — Gap: a repeat report while one is open returns "Report received", which is untrue

- **Source.** backend-design.md:424 ("A retry that finds the reporter's existing report also confirms receipt without creating another flag"); backend-design.md:426 ("While a report is open, another submission by that reporter returns the existing receipt").
- **Scenario.** A reader reports a tip, forgets, reports it again a week later with a different reason. The site says "Report received", implying a second report with the new reason exists. Nothing was stored.
- **Fix (preserving).** Distinguish the two return values: new insert → "Report received"; existing open report → "You already reported this; it is still open". Existing resolved report with no author edit since → "You reported this before; report again if the author changes it". The backend already knows which case it hit after the constraint rollback (backend-design.md:426).
- **Acceptance.** Three fixtures, three messages; no second flag row in the first two.

### B5 — Gap: authentication email timeout has no specified user copy or second-request semantics

- **Source.** backend-design.md:494 ("A timeout can leave delivery uncertain; do not claim that no message was sent. Allow another request"); frontend-design.md:144 (wait with a timeout, allow retry); backend-design.md:486 (15-minute magic links, generated token lifecycle).
- **Scenario.** Provider acceptance times out. The form shows a generic error; the user requests again; two links arrive. Which works? Both, under the generated flow, because each request inserts its own token and earlier tokens are not revoked. The docs never say so, and a "link expired" assumption leads users to request a third.
- **Fix (preserving).** Copy for timeout: "We may have sent your link. Check your inbox; if nothing arrives in a minute, request another." Contract line: every link requested in the last 15 minutes works; using one does not invalidate the others; the per-user write rate limit (data-model.md:794) bounds requests. Verify against the pinned generator.
- **Acceptance.** Two requests, use the first link, then the second: both sign in; the copy appears on a stubbed timeout.

### B6 — Gap: a fully banned account is never told, and the rejected-save message is unspecified

- **Source.** backend-design.md:521–523 (full ban blocks contributions; "The frontend hides unavailable contribution controls"; "An editor opened before a ban preserves its text when the backend refuses the save"); backend-design.md:432 (no removal notification or appeal).
- **Scenario.** A fully banned user signs in, sees no Write or vote controls and no explanation, then a save in an already-open editor is refused with an unnamed error. Silence reads as a bug. Reddit states a suspension on sign-in; Hacker News marks the account.
- **Fix (preserving; wording is the owner's).** The contribution-eligibility projection returns a `:full_ban` reason; every hidden control and refused write maps to one message: "This account can't contribute. You can still read, and delete your own tips, reviews or account." Shadow bans stay silent by design.
- **Acceptance.** Banned fixture: message on the tip page in place of the contribution control, on refused save with text preserved, and on vote attempt from an already-rendered page.

### Considered and not raised

- **Edit conflict caused by a moderator retag** forces the author to reapply text changes for a field they did not touch (backend-design.md:436). Rare inside a two-hour window; per-field resolution is a merge the design rejects. Record as a trial observation.
- **Video readiness latency** (five-second polling, minute-cadence scan, backend-design.md:275): set expectation with "usually ready within a few minutes"; no contract change.
- **Signed-out vote not replayed** and **inbox mark-all on open**: architecture consensus.
## Codex Round 1

### Why-chain

Why can a correct backend produce a misleading UI? It returns technical state without a settled user meaning. Why can't the frontend infer it? It lacks the facts for scope, deadlines, eligibility or uncertain outcomes. Why add explicit projection fields? They support the user's next action without new storage. Why not expose raw records? They mix privileged/internal facts with display permissions. Why not a universal state framework? Only a few operations need these facts. Why local projections? They reuse existing boundaries and keep meaning close to the operation. Why more abstraction? It would not change those facts. Why new tables? The facts already exist; no change to the root answer. Stop.

### B1 — High: free-text discovery is not a reliable escape from the model-filter limitation

Evidence: backend 85 says an unfiltered query may discover different-model reviews, but data model 195 and 540 define review search text as body, prompt and output only. The structured reviewer model/environment may never occur in that prose. Data model 758's generic “search_text includes ... model text” also needs explicit ownership to avoid different implementations.

Scenario: a model-A tip has a firsthand review using model B; the reviewer selects B but writes “This fixed scoped edits” without repeating B in the prose. A B filter excludes the tip by design. Removing the filter and searching for B cannot keyword-match the review's selected setup under the declared builder. Semantic retrieval is not a guarantee for omitted metadata.

Smallest recommendation: add the review's own primary model label/free-text model and environment label to its existing search document, and document the exact same builder for publish/edit. Tip document keeps its own setup. Keep parent-only structured filters unchanged; metadata text inclusion is not a new review filter or compatibility claim. Hydrated matches based on setup can use a “Reviewer setup: B” explanation instead of inventing a quotation from the body.

Local: search-text builder change, no new table or query branch. Downstream: setup-only edits invalidate review embeddings; rebuilding curated labels later needs the existing search maintenance path, not an MVP taxonomy service. E2E: unfiltered query for B plus task can find the A tip through the B review; active tip-model B filter still excludes it. Validate on the real keyword and hybrid fixtures, including a free-text model. This improves discoverability without promising every metadata match ranks in the bounded window.

### B2 — Medium: event counters look like durable endorsements

Evidence: data model 298/653 deliberately counts Helpful events, including vote → remove → vote again by the same person; 682 renders “Your tip got N helpful votes.” Backend 396/402 shows current counts on the destination. Self votes count on content but do not notify.

Scenario: the inbox says fourteen Helpful votes; the tip has three. A user infers lost votes or fabricated popularity. The count is neither current score nor distinct people. Backend behavior is intentional, but its user-facing number implies a stronger claim.

Smallest recommendation: retain folding/count fields and count-matched read logic, render “Your tip received helpful votes” (review equivalent) with the activity timestamp, omitting the numeric event total. The content page remains the place for current totals. Do not build distinct-actor aggregation, notification subtraction or vote-history storage merely to defend a confusing number.

Downstream: copy/render assertions only; fold and race tests unchanged. Acceptance: repeated vote/removal and later invalidation never produce a notification claiming N unique people or N current votes. Prior choice to show count is a presentation decision to reopen explicitly.

### B3 — High: edit eligibility must be usable before expensive preparation

Evidence: backend 305/311 allows video preparation in tip edits but gives no extension of the two-hour window; 378 get_edit_form returns fields/media/version; data model 574 mentions generic 403 for late/ineligible edits. Frontend preserves text on rejection but does not specify deadline feedback. An account, stale version, deleted target, and expired window have different remedies.

Scenario: with three minutes left, I select a large recording. It becomes playable after the edit window. Saving is correctly rejected; “Forbidden” or “Try again” wastes more effort and leaves me unclear whether my draft was saved publicly.

Smallest recommendation: get_edit_form exposes server-derived edit deadline when applicable and current allowed actions; operation results distinguish expiry, stale edit, reauthentication, unavailable target, ban, and pending/failed media. Show “Editable until [time]”; starting upload does not reserve saving time. At expiry preserve readable/selectable draft text, explain that this edit cannot be saved, and keep allowed deletion. No countdown tick, lease, extension, generic permissions matrix service, or persisted new deadline.

Local: derive deadline from creation; no new column. Downstream: same reasons across new/edit upload preflight and commit errors; restore can return preserved draft with noneditable saved state. Test expiry during upload and final commit. This is a projection/error-contract completion, not a permission change.

### B4 — Medium: magic-link return promises exceed session-local navigation

Evidence: frontend 23 stores intended editor return path in the Plug session; backend 462/466 promises return after verification. Browser drafts are account- and browser-scoped (315/482). No cross-browser continuation transport is defined.

Scenario: I start on desktop and open the email in my phone browser or an in-app email browser. That browser lacks both the original return path and its local draft. The promised “then the intended editor” does not follow from the declared mechanism.

Smallest recommendation, following the architecture review: carry a normalized, validated local GET return destination through the email link and verification submission; the web boundary validates it again and performs ordinary target authorization. Fall back safely if absent/invalid. This carries the destination, not the old browser session or local draft. The check-email screen should explain that returning to an existing draft requires the browser used to write it. Test desktop/default-mail/in-app browser paths. Do not encode draft text or account-private content into URLs; do not build synced drafts or device pairing.

Downstream: authentication copy/fallback integration test. Existing same-browser protected editor return stays. An explicit cross-browser destination is a small contract completion; cross-browser draft transfer remains out of scope. Review/selected-review parameters must survive canonical route handling.

### B5 — Medium: notification read-on-open must be described as clearing the inbox badge

Evidence: data model 651 marks every captured unread row read, including rows beyond the first twenty. Frontend acceptance 253 has one mark-read operation but no reader-facing meaning. This is an explicit global-read choice; the snapshot prevents later arrivals from being cleared but does not imply that earlier unloaded items were viewed.

Smallest recommendation: preserve the mechanism for MVP, describe the inbox as recent activity and avoid “you have read everything” or a seen/checkmark claim. One unobtrusive explanation can say opening Notifications clears the current badge. Do not add per-item seen tracking or unread filtering based on an inferred read guarantee. Test a 25-row inbox and a concurrent new arrival. The full cross-tab and remount behavior must retain the agreed snapshot boundary.

This overlaps B2: both favor truthful activity presentation over another notification subsystem. If user trials require an unread work queue, explicitly reopen read-on-open then.

## Fable Round 2 — response to Codex Round 1, plus one added case

Both rounds used B1–B5. Below, Codex's are `C-B1..C-B5`; mine in Fable Round 1 are `F-B1..F-B6`. Verdicts: **Accept** C-B1, C-B2, C-B4, C-B5. **Accept with amendments** C-B3. Overlaps: C-B2 = F-B3; C-B4 = architecture F1; C-B3's reason vocabulary absorbs F-B6.

### C-B1 — Accept

Checked: `review_search.search_text` is "body, prompt, and output" (data-model.md:195, :540); the tip builder includes model and tag (data-model.md:188, :761; Codex's ":758" is :761). backend-design.md:85's promise that an unfiltered query can discover a different-model review holds only when the reviewer typed the model name. Add the review's primary model label or free-text model and environment label to its search document; one builder for publish and edit; a setup-only review edit now invalidates the review embedding (today only text edits do). BM25's inverse document frequency keeps a common environment label from dominating. Excerpt source gains a "setup" case, shown as "Reviewer setup: B", not a quotation. No new filter, branch or compatibility claim. Acceptance as Codex wrote, plus a free-text model that differs only in case.

### C-B2 — Consensus with F-B3

Same finding, same fix: keep `count` for folding and the count-matched mark-read, drop the number from vote copy, show the activity time from `updated_at`. Owner may instead choose the hydrated current total; both are recorded. The reopened presentation decision is the number, nothing else.

### C-B3 — Accept the contract; amend severity and scope

- **Severity Medium, not High.** The three-minutes-left video case is rare; the durable value is architecture rule 2 (deadlines displayed) and one shared reason vocabulary.
- **Deadline field.** `get_edit_form` returns `editable_until` (tips only, `created_at + 2h`); the frontend renders it in local time. No countdown, lease or extension. Starting an upload reserves nothing (backend-design.md:311).
- **One reason list, not a matrix.** The same atoms across publish, edit, vote, report and upload preflight: `:expired_window`, `:stale_version`, `:reauthenticate`, `:target_unavailable`, `:full_ban`, `:media_pending`, `:media_failed`, `:already_reviewed` (with id, F-B1), `:rate_limited` (F-B7 below). This is an enumeration inside Content results, not a permissions service. F-B6's ban message maps to `:full_ban`.
- **At expiry.** Draft text stays readable and selectable, the message says this edit cannot be saved, and Delete remains available. Agreed.

### C-B4 — Consensus (architecture F1); one amendment

Already settled: destination in the link, validated at the web boundary on both the email URL and the verification form path, selected-review id preserved, no draft content in URLs. Amendment: the "returning to an existing draft requires the browser used to write it" line belongs only where a local draft exists for that destination, which is the expired-session re-sign-in case (backend-design.md:482), not every check-email screen. The hook knows whether a draft exists; the server does not.

### C-B5 — Accept; specify what the marking visit shows

Copy: opening Notifications clears the badge; the list is recent activity; no "seen" marks or "all read" claims. Add the rendering rule so both layers agree: rows in the marking visit render unread from the snapshot (data-model.md:663–673); rows fetched by Load more after the mark render their actual state, which is read. Test a 25-row inbox: five older rows appear read on Load more though never shown, and that is the accepted mechanism, not a bug.

### F-B7 — Gap: a rate-limited write has no user-visible contract

- **Source.** data-model.md:794 (one per-IP limit at Cloudflare and one per-user limit in the app on writes and uploads; deleting does not reduce the count); backend-design.md:347 (result shapes list validation, denied writes, uploads, unknown outcome; no rate-limit outcome); frontend-design.md:219 (known failures retain upload entries while the page lives).
- **Scenario.** A new contributor from the invited group writes three reviews in ten minutes and starts a fourth with two screenshots. Publish is rejected by the per-user limit. Nothing says why or for how long; if it is treated as an unknown outcome the composer enters the reconcile path; if as a validation error, the screenshots are still attached but the author does not know whether to wait or retry.
- **Fix (preserving).** `:rate_limited` with `retry_after` seconds in the reason list above; it is a known failure, so entries and text are retained and Publish re-enables after the interval. The Cloudflare per-IP limit returns a page the app does not render, so its copy is the edge's; document that it applies before sign-in flows too. Numeric limits stay implementation-tunable.
- **Acceptance.** Limit set to three in test; fourth publish shows the wait, keeps two image entries and text; publish succeeds after the interval with the same submission key and no duplicate.

### Open for Codex

F-B1 (already-reviewed carries id), F-B2 (one-query reconcile, no wait), F-B4 (three report receipts), F-B5 (timeout copy and multiple valid links; verify against the pinned generator), F-B7. C-B3 severity and reason list. Everything else above is consensus pending Codex's confirmation.

## Codex Round 2 — adversarial response to Fable B1–B6

Prefix identifiers with the reviewer name in summaries because both independent passes use B1–B5.

| Fable finding | Disposition and correction |
|---|---|
| B1 existing review identity | Accept an authorized existing-review id/state in the conflict outcome. Preserve the attempted new-review draft. Label the safe action “View your existing review”; offer Edit only when currently permitted. A full ban or intervening deletion can make an unconditional edit link wrong. This completes the data model's existing “link to edit” intent, rather than proving no compliant implementation could do a second lookup. No automatic transfer/merge of the new text. |
| B2 bounded reconciliation | Accept a bounded lookup and immediate same-key explicit Retry after a successful absent result. Reject “no wait”/“exactly one round trip” as a universal guarantee: lookup can time out, admission can fail, and retry may wait on an in-flight transaction. No endless automatic polling. Found means show the *current* committed state, including hidden/deleted, not unconditional “Published.” Lookup failure retains an unresolved state and offers an explicit check/retry or sign-in as appropriate; absence is not failure or cancellation. Values/key remain fixed. |
| B3 notification event count | Agree; same as Codex B2. Keep fold/count-matched read logic, omit the public event total. This is a recommended presentation change to an explicit prior choice, not an unchanged display. Do not add target-total hydration just to keep a number. |
| B4 repeat report receipt | Accept new-versus-existing receipt outcome; reject turning feedback into moderator-status promises (“still open”). Say “Your earlier report is already recorded; this submission did not add another report.” This remains true if the earlier receipt is for an older author revision with an open report. New insert alone says the new report was received. Do not imply that changed reason/detail were persisted. Preserve the explanation until the author understands the outcome; no status page, new resolution notification or re-opening. Existing stale-revision flow remains. |
| B5 email lifecycle | Accept uncertain-delivery copy, **reject the claim that every link within fifteen minutes works and using one does not invalidate others**. Phoenix 1.8.1's actual template consumes the used link for a confirmed user and deletes all existing user tokens on first confirmation. Account deletion/email change also invalidate tokens under this project's rules. Keep the generated/adapted lifecycle; don't redesign auth to satisfy proposed copy. Test both initial confirmation and returning-user sign-in. Offer request-another on invalid/expired/used links without promising whether other messages remain valid. |
| B6 full-ban explanation | Accept one page-level explanation plus action-specific rejected-save feedback; do not repeat a banner at every hidden button. Full ban stays distinct from silent shadow-ban presentation. Deletion remains available, with its existing reauthentication requirement. |

Verified source for B5: [Phoenix v1.8.1 authentication context template, login and token invalidation](https://github.com/phoenixframework/phoenix/blob/v1.8.1/priv/templates/phx.gen.auth/context_functions.ex#L195). Inspected the actual tagged source through GitHub/raw endpoints; this is stronger evidence than assuming all magic links behave alike. The implementation still must pin/adapt and test its chosen generator.

Also reject the unmeasured “usually ready within a few minutes” in Considered and not raised. Minute-cadence worker scheduling is not a completion SLA; use “Processing video; you can leave and return to this browser draft” when applicable, with actual expiry/readiness feedback. Real measurements may later justify a time estimate.

Local-to-end-to-end assessment: these are operation-result and presentation completions; no new entities or durable workflows. Each must be checked against authorization/current-state projection, then the editor/inbox/auth screen, then the interrupted mobile contribution journey. Waiting for Fable's challenge to Codex B1–B5 before closing.

## Fable Round 3 — corrections accepted, backend consensus

All six Codex corrections accepted. Retractions and amendments to Fable Rounds 1–2:

- **F-B5 retracted in part.** The generated v1.8.1 context consumes a used magic-link token for a confirmed user and deletes every token of the user on first confirmation (`update_user_and_delete_all_tokens`); my "every link within fifteen minutes works and using one does not invalidate the others" is false. Keep the generated lifecycle unchanged. Copy promises nothing about other messages: on timeout, "We may have sent your link; check your inbox, or request another"; on an invalid, used or expired link, "This link no longer works; request another". Test first confirmation and returning sign-in separately against the pinned generator.
- **F-B2 amended.** One lookup, then an explicit same-key Retry after a *successful* absent result. Lookup failure or failed admission is an unresolved state with an explicit check or sign-in action, never treated as absence, and never auto-polled. A found publication shows its current committed state, including hidden or deleted, not an unconditional "Published". Values and key stay fixed throughout.
- **F-B4 amended.** Existing-report outcome copy: "Your earlier report is already recorded; this submission did not add another report." No "still open", no status promise, no implication that a changed reason or detail was stored. New insert alone says "Report received". Stale-revision flow unchanged.
- **F-B1 amended.** Conflict outcome carries the authorized existing review id and state. Action label "View your existing review"; Edit only when currently permitted. Attempted draft preserved; no transfer or merge.
- **F-B6 amended.** One page-level explanation for a full ban plus action-specific rejected-save feedback; no banner per hidden control. Deletion keeps its reauthentication requirement.
- **Video readiness copy withdrawn.** No time estimate until measured; use "Processing video; you can leave and return to this browser draft" with actual expiry and readiness feedback.

### Backend disposition

| Item | Status | Outcome |
|---|---|---|
| C-B1 reviewer setup in search text | Consensus | Add primary model/free-text model and environment labels to the review document; one builder; setup edits invalidate embedding; "Reviewer setup" excerpt case |
| C-B2 / F-B3 notification count | Consensus, presentation change reopened | Omit the event total; keep fold and count-matched read; activity time shown |
| C-B3 edit deadline and reasons | Consensus (Medium) | `editable_until` on the edit form; one reason enumeration across publish, edit, vote, report, preflight; expiry keeps text and Delete |
| C-B4 / F1 auth destination | Consensus | Destination in the link and verification form; draft-browser note only where a draft exists |
| C-B5 inbox read-on-open | Consensus | Badge-clearing copy; marking visit renders unread from snapshot; later loads render read |
| F-B1 already reviewed | Consensus, amended | Id and state in outcome; "View your existing review"; draft kept |
| F-B2 lost confirmation | Consensus, amended | Bounded lookup; explicit retry on absence; failure is unresolved; found shows current state |
| F-B4 report receipts | Consensus, amended | Two truthful receipts; no status promise |
| F-B5 auth email | Consensus, corrected | Generated lifecycle unchanged; copy promises nothing about other links |
| F-B6 full ban | Consensus, amended | One page-level message plus rejected-action feedback |
| F-B7 rate limit | Pending Codex | `:rate_limited` with `retry_after` as a known failure that retains text and entries |

No substantive disagreement remains. Backend consensus is stated on Codex's confirmation of F-B7. Source documents unchanged. Waiting for the frontend handoff.

## Codex Round 3 — remaining amendments and proposed closure

Accept Fable Round 2's response to C-B1–C-B5, with these precision fixes:

- **C-B1 search:** setup-only edits already rebuild search under the broad whole-edit contract. Keep that invariant; extend the document contents, not claim a newly required lifecycle. Common labels can still affect ranking despite BM25 weighting; evaluate rather than guarantee they cannot dominate. Match-source “setup” is an explanatory projection, not proof of a filter match. Correct source line is data-model 761.
- **C-B3:** accept Medium priority and the small shared reason vocabulary where applicable. Operations need only reasons they actually produce; do not force every operation into a new universal response framework. Initial controls are advisory, commit eligibility remains authoritative.
- **C-B4:** accept context-specific same-browser draft guidance on reauthentication when composing/restoring; do not show a tutorial on every fresh signup. The browser can know its local state; successful auth in another context transfers no draft.
- **C-B5:** snapshot-unread presentation on the initial inbox and subsequently read older rows follows the accepted global mark. It indicates activity new to this visit, not proof of reading. No new seen semantics.
- **F-B7 rate limiting:** accept a known application rejection with a server-provided retry time when available; preserve input and page-owned entries, display when to try again, and require an explicit retry using the same submission key. No countdown or automatic resubmission is required. A rejected *retry* does not settle an earlier unknown publication: reconcile that key before declaring the publication failed/cancelled. An edge failure may interrupt a connected request/reconnect; do not presume a clean app-rendered 429 or infer rollback from a dropped connection. Only a definite pre-operation rejection is a known failure for that attempt. The task does not authorize expanding rate-limit policy to every sign-in route; verify the configured edge/app paths.

### Final backend recommendations proposed

1. Include reviewer setup in review search text and explain metadata matches honestly.
2. Carry safe auth destinations across browser contexts; retain generated token consumption and truthful email-delivery feedback.
3. Return specific actionable outcomes and existing-review identity/current state; expose the tip edit deadline.
4. Preserve a bounded, explicit publication-reconciliation path without spinning forever or treating lookup failure as absence.
5. Remove misleading numeric vote-event totals from inbox copy; retain folding and mark-on-open semantics.
6. Distinguish a newly stored report from an existing receipt without implying revised report text was saved.
7. Explain full-ban contribution restrictions once while keeping deletion available; preserve input on rejection.
8. Explain definite rate-limit rejection without automatic resubmission or resolving an earlier uncertain attempt by inference.

No new table, durable queue, moderation-status product, token lifecycle, notification history or draft sync is proposed. Numeric notification-copy removal is an explicit recommended presentation change. All other items complete user-visible contracts while retaining the current business rules. Subject to Fable's ratification of the Round 2 corrections and these amendments, this phase is ready to close.

## Fable Round 4 — ratification and closure

Accept Codex Round 3 in full: setup-only edits already rebuild search under the whole-edit contract, so C-B1 extends document contents only; BM25 weighting is to be evaluated, not guaranteed; reasons are emitted only by operations that produce them; same-browser draft guidance appears only on reauthentication while composing or restoring; F-B7 is Medium, a definite pre-operation rejection only, with explicit same-key retry, no automatic resubmission, and no inference about an earlier unknown attempt or about rollback from a dropped connection.

The eight final backend recommendations are ratified as written. Backend consensus reached in three rounds plus ratification. Source documents unchanged.

## Codex Round 4 — phase closure confirmation

Fable's Round 4 accepts all Round 3 amendments. Backend consensus reached in four numbered rounds including ratification. The final eight recommendations above supersede tentative alternatives and corrected claims in the debate. Source technical designs remain unchanged. Proceed to the frontend phase.
