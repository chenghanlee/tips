# Holistic adversarial review: backend

Date: 2026-09-20. Status: consensus after four rounds, including final acknowledgement.

## Agreed result

| Priority | Finding | Smallest agreed change |
|---|---|---|
| P1 | B-C5/B-F4: existing publication identity can erase unsaved values. | Return created/equivalent/different/unknown outcomes using the existing whole-content comparator; reconcile before upload/required-field validation and after key-conflict rollback. |
| P1 | B-C7/B-F1: renewal and logout do not share a browser-session boundary. | One indexed UUID family field on existing token rows; account-lock serialization; family deletion commits before disconnect. Preserve explicit 60-day Tips validity and seven-day renewal. |
| P2 | B-C8: recovered ready video targets the new-publication key, so editing its published item rejects it. | Claim-time target equivalence for the exact author/key/item/parent; retain all readiness, ownership, expiry and cleanup guards. No rebind endpoint. |
| P2 | B-C1: keyword zero-score nonmatches become positive fused ranks. | Filter negative lexical scores outside bounded keyword candidate subqueries before ranking/fusion; verify pinned extension plans. |
| P2 | B-F3: retag can accept an embedding computed for stale text. | One helper updates search text, freshness token, vector reset and retry cooldown. |
| P2 | B-C2: repeatedly uncertain expiry rows starve later rows. | One guarded per-row reconcile_after cooldown; static lifecycle index predicate, runtime due conditions. |
| P2 | B-C3: transaction-start now() can admit an expired resource after a lock wait. | Wall-clock checks at the guarded decision point; version stamps remain version stamps. |
| P2 | B-C4: a report can become open after target deletion resolves existing reports. | Reporter account then direct-target FOR SHARE before insertion; no unnecessary ancestor lock. |
| P2 | B-F5/B-F6: implicit confirmation and operational coverage leave gaps. | Explicit confirmed reporter guard, pre-auth limits, and one independent bounded job-progress observer including never-attempted eligible rows. |

Keep atomic bulk moderation pending a realistic capacity measurement (B-F2); speculative chunked jobs and ban coupling were rejected. Retain the existing context split, trigger invariants, provider calls outside transactions, cleanup identifiers and combined media slots.

**Evidence:** [reduced PostgreSQL checks](holistic-boundary-checks.py) reproduced the report/deletion and transaction-time failures, and passed both lock orders for the report-lock and session-family proposals. These are isolated SQL examples, not the full schema or application. Browser/auth, provider lifecycle, pinned search-extension queries and moderation capacity remain implementation gates. No application code exists here and no design contract was edited.

Uses the review agreement in holistic-architecture-review.md. Append attributed rounds and a joint disposition, maximum ten paired rounds. Scope: context contracts, schema invariants, transactions, concurrency, authorization, jobs, search and provider lifecycles. Preserve architecture conclusions and challenge their backend consequences.
## Codex Round 1 — backend and schema

Architecture conclusions apply. Primary question: does every operation preserve its facts across commit, provider uncertainty and a later read? The simplest solution is an ordinary transaction/operation with a clear decision point, not more contexts or a generic state machine.

### B-C1 — keyword branches rank nonmatches when PostgreSQL chooses standalone scoring (P2)

Evidence: data-model.md:720–746 orders BM25 scores without a match predicate, then assigns ranks; :759–764 gives every candidate a positive RRF contribution. backend-design.md:61 and frontend-design.md:92 promise keyword fallback and a genuine empty-result state. The extension's [README](https://github.com/timescale/pg_textsearch#querying) allows standalone scoring and notes that small or prefiltered tables can use it. Its [scoring implementation at commit a991f24](https://github.com/timescale/pg_textsearch/blob/a991f24d7254c7ee2da52353521b6a9283748f86/src/types/query.c#L990) skips absent terms and returns zero when nothing matches (return at line 1134).

Failure: a narrow setup filter or small seed corpus selects a sequential scoring plan; a query with no matching words gives each document zero distance, yet the SQL selects up to fifty and RRF turns them into apparently useful keyword hits. A review can then be described as the matching review despite no lexical match. Hybrid vector candidates remain a separate legitimate source.

Fix: require an actual lexical hit in each keyword branch before rank assignment/fusion; for the verified negative-score convention, exclude `d >= 0`. Keep the candidate cap and ranking, and test the exact pinned extension/query plan before choosing the best SQL placement. Do not add strict phrase syntax or require vector candidates to match keywords.

Effects: keyword-only no-match searches become empty; BM25 noise no longer boosts unrelated tips/reviews in hybrid fusion. Verify zero matches, stopword-only text, fewer-than-limit matches, filters, seq/index plans and labelled excerpts. **Evidence level: primary-source-based inference; the local PostgreSQL installation has neither search extension, so this exact extension query was not executed.**

### B-C2 — bounded expiry scans can repeatedly select an uncertain prefix and starve later assets (P2)

Evidence: backend-design.md:283 caps each expiry run at fifty due rows and defers uncertain provider outcomes; data-model.md:378 indexes `(expires_at,id)`; :782 preserves fixed business expiry and defers uncertainty. No rule advances an uncertain row's next reconciliation opportunity or makes selection fair across runs.

Failure: the first fifty overdue known-uid uploads repeatedly time out. Every tick can pick them again; a later ready upload whose 48-hour expiry is known never reaches cleanup. It can remain billed indefinitely even while expiry jobs finish successfully. Whole-job Oban uniqueness limits duplicate jobs, not starvation within their selected rows.

Fix requirement: later due rows must make progress despite a persistently uncertain prefix, without changing the user's expiry. Prefer existing Oban per-item retry eligibility or one narrow reconciliation cooldown if needed; do not repurpose `expires_at`, add a global readiness scanner, or rely on an in-memory cursor lost on every deploy. Ask Fable to choose the smallest concrete implementation against the schema's current no-extra-poll-state preference. This is a missing progress contract, not an assertion that all possible implementations necessarily starve.

Verify at least 51 overdue rows: the first 50 stay uncertain; later known-complete expired rows still enter cleanup within a bounded interval, including across restart. Check shared provider budget and cleanup-versus-claim serialization.

### B-C3 — deadline checks must use decision time, not transaction-start time (P2, reproduced)

Evidence: data-model.md:778 explicitly guards uid persistence with `created_at + interval '1 hour' > now()`; backend-design.md:198 says deadlines remain enforced through commit. PostgreSQL [documents](https://www.postgresql.org/docs/current/functions-datetime.html#FUNCTIONS-DATETIME-CURRENT) `now()` as transaction-start time and `clock_timestamp()` as current wall time.

Reproduction: [holistic-boundary-checks.py](holistic-boundary-checks.py) creates an isolated temporary database and crosses a deadline inside a transaction. Output: `now()` accepts, wall-clock comparison rejects (`t|f`). The scratch database was removed after the run. This is a reduced SQL check, not a full Tips test.

Fix: define the deadline's linearization point as the guarded claim/persist/verification decision after acquiring the applicable row lock. Read current database wall time there (for example `clock_timestamp()`), keep the transaction short and bounded, then hold ownership/lifecycle locks to commit. Do not promise literal future commit time remains before the deadline: time progresses even under a lock. A successful pre-deadline claim clears temporary expiry and makes later expiry inapplicable. Apply the same decision-time convention to staged-video attachment, initial uid handoff and seven-day registration confirmation/reclaim; retain generated token validity semantics rather than rewriting all auth timestamps.

Verify a lock wait that crosses the deadline, exact-boundary rejection, completion recorded before upload deadline but observed later, and claim racing cleanup. UI deadline/error wording follows the selected point.

### B-C4 — report insertion can follow the deletion transaction that resolved all reports (P2, reproduced; fix needs challenge)

Evidence: data-model.md:596 resolves open flags in author deletion, while :616–624 deliberately uses only a reporter lock and an insertion snapshot. backend-design.md:434 accepts edits overlapping reports but does not state what a late report of author-deleted content means for the queue. :626 requires deletion-first projection even for moderators.

Reproduction in the same script: pause report insertion after its live-target snapshot, commit author deletion and its report-resolution statement, resume insertion. Result: **one unresolved report on an author-deleted tip**. Foreign-key locking does not serialize this soft-delete predicate.

Do not automatically add target locks just to eliminate an accepted snapshot race. Two small policies are possible: serialize the report's eligibility check with deletion, or explicitly support the late report as a redacted tombstone case that moderators can dismiss. I prefer the latter if `get_moderation_case` and `dismiss_reports` admit it: hide/restore/file destruction remain unavailable, but dismissal changes only the reviewed report ids under current version/state checks. This preserves the current no-target-lock report path, creates no worker and never reveals deleted original text. Fable should challenge whether that extra moderator work is justified compared with a short target lock.

Verify the demonstrated schedule for both target kinds, a moderator opening the late case, successful dismiss, retained newly arriving report guards, and no original content/attachment leak. Do not conflate it with the deliberately accepted delayed retry after report resolution.

### B-C5 — implement the publication acknowledgement invariant inside Content (P1, architecture carry)

Keep `:created` and original identity/current state. On an existing key, recheck requested review parent as now. Return an explicit equivalence result based on current authorized normalized content using the existing whole-edit/no-op comparison, without side effects. Make **equivalent / different / unknown** distinct; unknown is a normal safe result for deleted originals or missing/new image identity. Recovered missing-image slots must not be treated as empty selections. Existing media metadata/positions alone cannot establish equality of new image bytes. Never re-upload images merely to answer whether an already-existing key identifies a publication.

`get_publication` returning identity/state alone cannot authorize local draft clearing. Provide a comparison path for recovered form input, or conservatively preserve the input; the frontend phase owns the screen. Do not introduce a request-log table, server drafts or publication edits disguised as retries. Existing whole-edit comparison must include image descriptions (backend:243), tag, explicit blanks, normalized text/setup, ordered media ids and the complete intended selection.

Checks: two tabs, reordered videos, description-only differences, text-only equal retry, new-image unknown identity, recovered image descriptors without bytes, moderator-hidden/deleted original, and stale original changed by an edit. Outcome must never imply that an unconfirmed draft's text was saved.

### B-C6 — inherited operational/authentication contracts

- **Sign-in destination:** web-owned allowlisted route carrier; Accounts never interprets redirects. Add explicit magic-link cross-browser test. This is a contract gap, not a new auth subsystem.
- **Pre-auth limits:** use existing limiter by normalized address and trusted client IP before token creation/delivery, including LiveView events. Throttle feedback must preserve form values and never imply delivery.
- **Background progress:** prefer one independently invoked read-only routine over existing `oban_jobs` and business rows. Expose a separate generic health response for external checking and the same release routine for operator diagnosis; choose one scheduled alert path. Bound checks with indexes/EXISTS, account for scheduled maximum runtime and deploy grace, ignore hidden/deleted embedding work, and keep detailed counts out of public responses. No per-row heartbeat fields. Pin the monitor's actual capability during deployment; no paid-plan assumption.
- **Session renewal/logout:** the official v1.8.14 generator still leaves old tokens valid (architecture source check). Fable should evaluate a complete adaptation, including concurrent renewals and cookie/disconnect ordering. Neither deleting only one old token nor merely retaining a 60-day orphan satisfies the stated logout requirement. Updating `inserted_at` in place changes token security/lifetime semantics, so it is not a neutral mechanical fix. Do not casually force every other device to log out instead.

### Retained backend choices

Keep narrow counter triggers because bulk writes bypass changesets; keep account→tip→review lock order including implicit trigger targets; keep provider calls outside transactions and durable cleanup identifiers independent of job retention. Keep report receipt honesty, independent review visibility, combined media slots and per-row embedding cooldown. Those choices are complementary, not contradictory. Historical SQL benchmarks remain historical evidence only.

### Codex Round 1 addendum — B-C7: a bounded alternative for renewal/logout

For A-F5, I propose evaluating one additional `session_family_id` on existing session-token rows, not a new session table. This is a Tips adaptation, not a claimed Phoenix generator feature. A family identifies the signed-in browser session across bearer-token renewals; it never authorizes by itself and is generated only on the server.

- New sign-in creates the family; same-account reauthentication/renewal carries it forward. A genuinely different browser session gets another family. Do not derive the family from user id or accept one from input.
- Renewal locks the user first, rechecks the predecessor token/context/expiry under that lock, then creates the successor with the same family. Retain generated token formats, token lifetimes, rotation and recent-authentication meaning. Do not advance `authenticated_at` merely because a cookie renews.
- Logout takes the same user lock and deletes every session token in that family, then uses a family-scoped disconnect topic. Token-row re-admission remains the authorization boundary even when broadcasts fail. Concurrent successors are all in that family; a renewal waiting behind logout finds its predecessor gone and cannot mint another token. A late cookie response may contain a revoked token but cannot restore access.
- Account-wide revocation still deletes all relevant tokens. Same-browser account switching must retire its prior family rather than strand its old LiveViews; an explicit new sign-in after logout is a new authenticated action, not continuation of a revoked renewal.

Why consider the extra field? The alternatives either invalidate unrelated devices, remove periodic rotation, or leave old tabs alive. One indexed grouping field plus existing account locking could absorb that complexity rather than making the user close every tab or sign out every device. It addresses the owner's stated principle without a separate authentication system. Validate pinned generated flow integration before adoption.

Tests: two simultaneous renewals, renew→logout, logout→renew, late Set-Cookie response, same-account sudo reauthentication, account switch, failed disconnect and separate-browser isolation. Source context: [OWASP session renewal/logout guidance](https://cheatsheetseries.owasp.org/cheatsheets/Session_Management_Cheat_Sheet.html) treats token renewal races and server-side logout invalidation as separate concerns; the grouping-field design above is our inference, not prescribed by that source.

B-C7 evidence update: `python3 docs/brainstorm/holistic-boundary-checks.py` now also exercises both renewal/logout lock orders in the isolated scratch database. In both orders the family has no surviving token; the other browser's family remains. This supports the database serialization argument only. It does not exercise generated auth, bearer validation, session cookies, simultaneous browser requests or disconnect delivery; those remain required integration tests.

## Fable (McCord lens) — Round 1: backend and schema

Written before reading Codex's backend Round 1 in full. Architecture invariants 1–10 are carried. Framework facts below were checked against the Phoenix v1.8.1 `phx.gen.auth` templates (`auth.ex`, `schema_token.ex`, `context_functions.ex`).

### B-F1 — P1: the session contract cites the wrong numbers, omits renewal, and the same-browser logout requirement needs one small schema fact

Evidence. backend:490 and data:339 state "session tokens after 60 days," citing the API-authentication guide, which describes a different token scheme. The generator at v1.8.1 has `@session_validity_in_days 14`, `@session_reissue_age_in_days 7`, `@max_cookie_age_in_days 14` for remember-me, stores session token bytes raw in `users_tokens`, derives the disconnect topic from the token bytes, and on reissue inserts a new row without deleting the old one. `log_out_user` deletes only the cookie's token and broadcasts only its topic. There is no token pruning and no rate limit in the generated context. The contracts never mention reissue or remember-me.

Consequences today. A user away 15 days is signed out, not 60. Re-admission "with the same validity definition" (backend:184) inherits 14 days whether or not that was intended. Every controller request through the browser pipeline, including each `<img src="/media/:id/thumbnail">`, can trigger reissue at the seven-day boundary, so concurrent reissues from one page are normal, not rare.

Full evaluation against the architecture requirement "after same-browser logout, no LiveView from that browser re-admits":

| Candidate | Same-browser logout | Concurrent reissues | Stale cookie | Rotation | Verdict |
|---|---|---|---|---|---|
| Stock (keep old row) | Fails: old row valid up to 7 more days; a LiveView mounted under it survives logout | Safe: every request still finds a valid row | Safe | Kept | Reject on the requirement |
| Delete old row at reissue | Closes the mounted-LiveView case | Breaks: a parallel request carrying the old token finds no row and renders anonymous; losing reissues still orphan fresh rows | Breaks the same way | Kept | Reject |
| Extend the row in place | Passes: one id for the browser | Safe | Safe | **Lost**: a leaked raw token stays valid while the user is active | Reject; Codex was right not to trade rotation |
| Superseded grace (`replaced_at`, old row valid a few minutes) | Passes after grace | Safe | Safe within grace | Kept | Works but introduces a time window and a second validity clause |
| Browser-session family: one indexed `session_family_id` on the existing token rows, copied on reissue; logout deletes and disconnects the whole family | Passes exactly | Safe: extra reissues join the family; nothing is deleted at reissue | Safe: an old cookie's row is still valid and still in the family | Kept | **Smallest complete design** |

Recommendation. Adopt the family column. Reissue is `INSERT … SELECT` from the old row so it happens only while the old row exists. Logout and reissue both take the user row lock first so a logout cannot miss a reissue committed under an older snapshot. Logout selects the family's tokens, broadcasts disconnect on each topic, then deletes them. Logging in as a different user from a browser that still holds a valid token deletes that prior token's family too, because `renew_session`'s non-matching clause is exactly that event. Copy `authenticated_at` on reissue so recent-authentication checks keep working. Add one maintenance step that deletes tokens past their context's validity, since the generator never prunes.

State the actual numbers in the contract and decide them deliberately: 14-day validity with 7-day reissue keeps an active user signed in indefinitely and signs out anyone absent two weeks. If 60 days is the product intent, change the constant and say so; do not inherit it by citation.

Checks. Reissue race: two requests at day 7 → two new rows in one family, one cookie wins, both rows valid, logout removes both. Logout with an editor open in another tab → editor disconnects and remounts anonymous. Stale cookie with the older row → still admitted, rotated into the family. Different user logs in → prior family gone. Expired login tokens pruned.

### B-F2 — P2: bulk hide and vote invalidation cannot complete for the accounts that need them under the request timeout

Evidence. data:806 sets `statement_timeout = '2s'` for request queries; data:610–612 bulk hide and invalidation lock subject accounts, discover all content, then update every row while triggers write every parent; backend:190 these are moderator request operations. A spam account with thousands of reviews produces thousands of review updates plus thousands of tip updates in one statement chain.

Failure. The moderator's bulk hide times out and rolls back every time, exactly on the accounts the tool exists for. Meanwhile the held tip locks make concurrent reader votes wait and time out.

Smallest fix (feature-preserving). The moderator action commits the ban or the intent and enqueues one `maintenance` job that hides in bounded chunks, each chunk a short transaction under the existing lock order, looping until discovery is empty. Rows missed between chunks are picked up by the loop; a banned account cannot add new ones. The queue returns progress, and the case page shows "hiding in progress" until the job completes. No new state beyond the job.

Checks. Ten thousand reviews across many tips: completes; no chunk exceeds the request timeout; concurrent votes on affected tips wait at most one chunk.

### B-F3 — P2: retag clears the embedding without moving the text version, so an in-flight scan can write a stale vector

Evidence. data:703 the worker writes only where `text_at` equals the value it read; data:586 the author edit sets `text_at = now()`; backend:444 and data:607 retag "rebuild its search text … clearing the obsolete embedding" and say nothing about `text_at`.

Failure. Scan reads tip text at `text_at = t`. Moderator retags: `search_text` changes, `embedding = NULL`, `text_at` unchanged. Scan finishes and writes the old-text vector where `text_at = t` still matches. The tip is searchable by a vector of text it no longer has, until the next real edit.

Smallest fix. One search-text writer used by publish, edit and retag that always sets `search_text`, `text_at`, `embedding = NULL`, `embed_after = NULL` together. Check: retag during a paused scan → the scan's write affects zero rows.

### B-F4 — P2: publication acknowledgement contract inside Content (architecture carry)

`publish_tip`/`publish_review` return `:created`, `:existing_equivalent`, `:existing_different` or `:existing_unknown`. The comparison runs on the key lookup before any image upload, and again after a submission-key conflict rollback, using the whole-edit comparator (text, tag, setup, staged video ids and order, image slot count and descriptions). New image files make the result `:existing_unknown` unless both sides have no images. Deleted or hidden originals are compared server-side against stored fields; nothing original is returned to the page, only the outcome and the projected state. `get_publication` accepts the same submitted fields optionally so the mount-time reconcile can return the same three-way answer without a publish attempt. This is the backend half; the frontend decides the screens.

### B-F5 — P2: report eligibility must include confirmation, or expired-registration reclaim can be blocked by a foreign key

Evidence. data:619 inserts a flag from `live_tips` with no reporter predicate; backend:478 reclaims an expired unconfirmed user row by deleting it; `flags.user_id` references `users` without cascade. data:804 lists reporting among actions needing a signed-in, unbanned user but not a confirmed one.

Failure. An unconfirmed account files a report; its registration expires; reclaim's delete fails on the foreign key and the handle stays blocked forever, or the reclaim path has to tolerate a failure it never expected.

Smallest fix. The report insert uses the same reporter predicate as votes: undeleted, confirmed, not fully banned, evaluated under the reporter lock. Reclaim treats a foreign-key failure as "not reclaimable" and returns the ordinary conflict.

### B-F6 — P2: name the pre-authentication limiter and the job-health thresholds (architecture carries)

Limiter. Data:805 names no mechanism. Use one in-process ETS counter (Hammer's ETS backend or equivalent) keyed by lowercased address and by client IP for magic-link, resend and email-change requests, checked before any token insert or mail. Single node makes this sufficient; no table.

Job health. Recency threshold per periodic worker = cadence + maximum run time (candidates × per-call timeout ÷ concurrency) + startup grace, not twice the cadence: fifty rows at a five-second timeout is over four minutes. Aging rows: `media` with `cleanup_at` older than 24 hours; search rows joined to live content with `embedding IS NULL AND embed_after IS NOT NULL AND text_at` older than six hours. One route and one release command, no in-worker alerting.

### Kept, after checking

Vote upsert with eligibility in the source select, `FOR NO KEY UPDATE` against notification key-share locks, review vote without tip lock (the review-count trigger returns early when liveness is unchanged), submission-key conflict resolution order, `has_earlier_reviews` from `edited_at`, media lifecycle constraints, deletion-first projection. No deadlock cycle found in the stated lock sets.

Codex: challenge B-F1's family design against account switching, stale cookies and lock cost, and whether B-F2's chunked job is smaller than a request-scoped timeout override.

### Codex Round 1 addendum — B-C8: preserving a divergent publication draft must preserve usable evidence (P2, consequence of B-C5)

Evidence: backend-design.md:309 binds staged uploads to either `{:new_tip, key}` / `{:new_review, parent, key}` or an edit content id; :313 requires matching target on attachment; :315 only discusses reusing uploads already prepared for an edit. Under B-C5, B's divergent new draft may contain a ready, unattached video targeting K after A has already published K. Merely linking B to Edit preserves the text in another browser record but gives the edit operation a video whose target is still `new_tip K`, not `edit_tip id`. A literal implementation refuses it and forces re-upload, despite the same user and same immutable publication identity.

Recommendation to challenge: let Media resolve a new-submission target to its immutable published content id through the same author/kind/key lookup. An explicit edit of that exact item may claim an owned, still-ready, still-unattached, unexpired upload originally prepared for its submission key. This is target equivalence, not permission to move an attached asset or rebind a video to another post/version. Keep the stored provenance target; no new table or rebind endpoint. Review parent must still match. Deleted originals cannot be edited; cleanup/expiry remain terminal.

Frontend consequence: the recovery screen must carry preserved input/evidence into the existing edit-conflict/reference workflow rather than merely tell the author to copy values between unrelated pages. Do not overwrite an already-existing edit draft. Details go to frontend, but the usable-media contract belongs here.

Checks: A publishes K without B's video; B's equivalent-key result preserves the video; explicit edit of original id can attach it once. Another content id, author, review parent or expired/cleanup row is rejected. No automatic edit or publication occurs. This small target-resolution rule may earn its complexity by preventing a repeated video upload; simply labelling re-upload an MVP tradeoff would push the integration problem onto the author.

## Fable (McCord lens) — Round 2: critique of Codex backend Round 1

Verdicts: **Accept** B-C1 (placement narrowed), B-C3, B-C5 (merged with B-F4), B-C6, B-C7 (with five additions). **Accept the gap, choose the implementation** for B-C2. **Reject the tombstone in B-C4**; a one-word lock fixes the reproduced race at the source.

### B-C1 — Accept; filter after the limited subquery

The zero-score behavior is source-verified and the failure is real for small or filtered candidate sets. Place the predicate outside the top-k subquery so the index still serves `ORDER BY d LIMIT 50`: `select … from (… order by d, id limit 50) x where d < 0`. Same for the 1000-candidate review subquery before `distinct on`. If the pinned extension's index path already excludes nonmatches, the filter is a no-op; keep it anyway because the plan can change with statistics. Check: zero-match query → empty keyword branches; fewer-than-limit matches → only matches ranked; stopword-only query → empty.

### B-C2 — Accept the missing progress contract; smallest implementation is the `embed_after` pattern

Rejected: random ordering (probabilistic, sorts the due set), per-row reconcile jobs (needs a way for the scan to know a job exists), advancing `expires_at` (changes the composer's shown deadline). Chosen: one nullable `reconcile_after timestamptz` on `media`, exactly as `embed_after` works for search rows. Due predicate: `expires_at < clock_timestamp() and (reconcile_after is null or reconcile_after < clock_timestamp())`; an uncertain provider outcome sets `reconcile_after = now() + 10 minutes`; a definite outcome clears it. Extend the `media_expiry` index predicate to match. This is per-row retry eligibility with no cursor, no scanner and no change to the user's deadline. Check: 51 overdue rows, first 50 uncertain → the 51st is cleaned on the next tick; uncertain rows retried after cooldown; survives restart.

### B-C3 — Accept in full

`now()` is transaction start; every deadline predicate evaluated after a lock wait must use `clock_timestamp()`: uid persist guard, staged-video claim, expiry retirement, registration confirm and reclaim. `text_at = now()` stays; it is a version stamp compared for equality, not a deadline.

### B-C4 — Reject the tombstone; take a share lock in the insert's own select

Root cause, stated precisely: the report insert's foreign key takes `KEY SHARE` on the tip; author deletion is a non-key update taking `NO KEY UPDATE`; those do not conflict, so the insert's snapshot is never rechecked. Codex's tombstone accepts the race and gives moderators a case they can only dismiss. That is work pushed onto moderators, plus projection and dismissal rules for a state that need not exist.

Smallest fix: `insert into flags … select $1, t.id, $3, $4 from live_tips t where t.id = $2 for share`. `FOR SHARE` conflicts with `NO KEY UPDATE`, so the select waits for the deletion or hide to commit and Read Committed re-evaluates the predicate on the new row version: `deleted_at` is set, no row, no report. The lock is held only for the insert transaction and follows the accounts→tips order (reporter first, then tip). Concurrent votes on that tip wait milliseconds behind the report's share lock; that is the entire cost. Same for the review variant. Check: Codex's schedule → zero reports; hide instead of delete → zero reports; ordinary report on live content unchanged; no deadlock with author deletion (different accounts, tip acquired second by both).

### B-C5 — Accept; one contract with B-F4

Outcomes `:created | :existing_equivalent | :existing_different | :existing_unknown`. Comparison before any upload and after a key-conflict rollback; recovered image slots without bytes are `unknown`, not empty; comparator covers descriptions, tag, explicit blanks, normalized text and setup, ordered media ids and the complete intended selection; `get_publication` takes optional submitted fields and returns the same three-way answer. Nothing original is returned for deleted or hidden originals. Checks as Codex lists.

### B-C6 — Accept; numbers in B-F6

### B-C7 — Accept the family design; five additions from the challenge

Concurrent renewals: both wait on the user lock; the second still finds its predecessor and mints another successor in the same family. That is correct and cheaper than detecting supersession; families are pruned by validity. Stale cookie: its row is valid and in the family, so it is admitted and renewed; after logout it is gone and fails closed. Account switching: `renew_session`'s different-user clause deletes the prior family before the new sign-in. Additions:

1. Family id = the first token's own `id` (bigint), so no second sequence; index `(session_family_id) where context = 'session'`.
2. Set `live_socket_id` to a family topic in `put_token_in_session`; then logout, email change and account deletion broadcast once per family, and the per-token topic list is unnecessary.
3. Successor creation is `INSERT … SELECT` from the predecessor row under the user lock, so a renewal that lost to logout inserts nothing and sets no cookie.
4. Same-account reauthentication (sudo) joins the current family; email-change confirmation deletes all session tokens and starts a fresh family for the confirming browser, matching backend:513.
5. Maintenance prunes tokens past their context validity; the generator never does.

Contract numbers must be stated: 14-day validity, 7-day renewal, 14-day remember-me, or a deliberate change. Integration tests as Codex lists, plus the thumbnail-burst renewal case (several controller requests from one page at day seven).

### Disposition

| Finding | Verdict |
|---|---|
| B-C1 | Accept; filter outside the top-k subquery |
| B-C2 | Accept gap; `reconcile_after` cooldown mirroring `embed_after` |
| B-C3 | Accept |
| B-C4 | Reject tombstone; `FOR SHARE` in the report's select |
| B-C5 | Accept, merged with B-F4 |
| B-C6 | Accept |
| B-C7 | Accept with additions 1–5; supersedes the table in B-F1 |

Open for Codex: B-F2 (chunked maintenance job versus a request-scoped timeout), B-F3 (retag and `text_at`), B-F5 (reporter confirmation predicate), and whether B-C4's share lock has a cost I have not counted.

## Codex Round 2 — challenge of Fable's backend findings

- **B-F1: accept the family design and the incorrect-default citation.** I independently checked both [v1.8.1](https://github.com/phoenixframework/phoenix/blob/v1.8.1/priv/templates/phx.gen.auth/schema_token.ex) and [v1.8.14](https://github.com/phoenixframework/phoenix/blob/v1.8.14/priv/templates/phx.gen.auth/schema_token.ex.eex): 14-day server validity, 7-day reissue, 14-day remember-me max-age. Current Tips docs explicitly select 60 days; preserve that product setting as an intentional adaptation rather than silently shortening it to the generator default. Configure the shared server validity and applicable persistent-cookie lifetime consistently; keep seven-day rotation and genuine-authentication recency separate. No user decision is needed merely to correct the attribution.

  **Correct the order in your proposed logout:** delete the family transactionally, commit, then broadcast. Broadcasting before deletion/commit can make an old socket reconnect while its token remains valid, and a failed transaction must not be presented as successful logout. My B-C7 uses a stable family disconnect topic; enumerating every existing token topic after commit also works, but choose one mechanism, not both. Family topics avoid repeatedly capturing an unbounded token list; token-row admission still enforces expiry/revocation. On account switch lock both involved account rows in id order, recheck the old family and new login proof, and never revoke an unrelated browser. Ordinary renewal copies recency; actual sudo authentication advances recency under generated semantics. Add expired-token pruning through existing maintenance, in bounded batches, without deleting valid siblings merely because an older token expires. The reduced SQL checks cover serialization only; cookie and LiveView integration remain unexecuted.

- **B-F2: reject the asserted inevitable failure and the automatic ban/chunk fix.** No timings against the revised schema establish that ten thousand rows exceed two seconds. This is a legitimate performance gate, not a reproduced defect. Bulk hide and ban are deliberately independent (data:34, backend:448); automatically banning to simplify the job changes product behavior. Chunking also changes atomicity, visibility and retry scope, and "until discovery empty" does not terminate for an unbanned active author. The suggested progress UI and job-only intent need their own pruning, stale-moderator and partial-failure contracts. Those are not a small implementation substitution.

  Keep the ordered atomic operation and measure realistic bulk hide/invalidation in the existing database acceptance gate, including concurrent ordinary votes. If measured limits require offloading, first evaluate the existing maintenance/release path or a single Oban transaction with a bounded maintenance timeout and explicit UI outcome; do not lift timeouts in the request pool. Adopt chunking only with a defined finite target set and explicit partial-progress semantics. For this review, classify B-F2 as a capacity check, not an accepted new job/state/UI requirement.

- **B-F3: accept as a contract clarification with a concrete stale-vector consequence.** All search-text changes, including retag, must share the same update of text, freshness token, vector invalidation and cooldown reset. The docs already intend refreshed embeddings; missing `text_at` here is an easy literal implementation error. A maintained lookup label change is another dependency: either treat labels as stable for MVP or rebuild affected documents through the same helper when changed. Do not create a new search context or job per edit. Pin and verify that text-version values distinguish committed changes used by the scan.

- **B-F4: accept three-way equivalence, reject comparison of author-deleted originals as normal success.** Deletion-first projection is stronger and simpler when a deleted original yields identity/state plus unknown equivalence, preserving local input. A hidden original may be compared only under current authorized author access; no privilege follows from possession of K. `get_publication` needs a submitted-intent variant or the same optional comparison input so mount-time recovery cannot clear from identity alone. Match all fields including descriptions; any unresolved recovered image slot makes equivalence unknown. The existing-key branch must still run before required-field/file validation that would prevent identity reconciliation.

- **B-F5: narrow to an explicit guard/acceptance test, not a missing product policy.** backend:474 says verification is required before contributions and data:9 says contributions require a confirmed account. The report SQL is explicitly after locking/checking the reporter (data:616); the abbreviated insert alone is not the whole operation. Nevertheless name confirmed status in the shared reporter predicate and test unconfirmed report/upload attempts against registration reclaim. Do not silently convert an unexpected FK violation into an ordinary handle conflict forever: that would hide a broken invariant and strand the registration. Expected confirmation races return not-reclaimable; unexpected dependent rows surface as an operational invariant error while preserving user input. No report table or reclaim cascade is needed.

- **B-F6: accept existing-node limiter and runtime-aware progress checks, amend the age query.** `embed_after IS NOT NULL` excludes rows never attempted when a scan silently skips one class or has insufficient capacity. Observe all currently eligible pending embeddings, separately diagnosing cooldown/failures and never-attempted backlog. Use bounded oldest-age/EXISTS queries rather than unbounded counts where an alert only needs a threshold. Six hours and 24 hours are tunable starting points, not established SLOs. Avoid alerting on normal first backfill/newly restored content solely from old `text_at`; include startup/backfill grace and progress across checks. Implement only one monitoring schedule with monitor-owned deduplication. Reuse the app limiter; an ETS-backed library is suitable for the single node, not a mandatory new abstraction.

Please disposition B-C1 through B-C8, especially fair expiry scheduling and the recovery-to-edit media identity rule. The user-cost principle also makes me receptive to a short report target lock in B-C4 rather than accepting permanent extra moderator queue work; choose based on actual lock order, not an absolute preference for fewer locks.

B-C4 follow-up evidence and preferred fix: the reduced script now tests a direct-target `FOR SHARE` eligibility lock in both report/delete orders. Report-first commits, then deletion sees and resolves it; delete-first commits, then the waiting report's live predicate rejects it. Both checks pass. I now prefer that short lock over the tombstone-queue policy: reporter account → direct target SHARE → flag, with no ancestor-tip lock for a review report because reporting has no counter trigger. No subsequent step acquires an ancestor or other account. This pays a small contention cost to avoid extra moderator cleanup and preserves the deletion invariant. Test the full schema/lock graph and request timeout during implementation; the reduced proof is not full deadlock verification.

## Fable (McCord lens) — Round 3: dispositions on Codex Round 2 and B-C8, convergence proposal

### My findings after Codex's challenge

- **B-F1 — accept all corrections.** Logout order was wrong in my Round 2: delete the family, commit, then broadcast on the one family topic; no per-token enumeration. Account switch locks both account rows in id order, rechecks the old family and the new login proof, and never touches another browser. Renewal copies `authenticated_at`; only real authentication advances it. Pruning runs in bounded batches by context validity and never removes valid siblings. On the lifetime: backend:490 presents 60 days as the generator's documented value, which it is not, so it is unclear whether 60 was chosen or inherited. That is the owner's call, not ours. Default recommendation: keep the generator's 14/7/14 unless the owner wants longer sessions; if 60, set server validity and remember-me together and say it is a customization.
- **B-F2 — withdraw the inevitability claim and the job.** I had no timings against the revised schema, and I did not intend to couple hiding to a ban; Codex is right that "until discovery is empty" is unbounded for an unbanned active author. Classified as a capacity gate: measure bulk hide and vote invalidation on a fixture of at least ten thousand reviews across many tips with concurrent votes. If measured over the request timeout, first option is one Oban `maintenance` transaction with a bounded maintenance timeout and an explicit UI outcome; chunking only with a target set fixed under the account lock and stated partial-progress semantics. Never lift the request pool timeout.
- **B-F3 — accepted as clarified.** One helper for text, freshness token, vector reset and cooldown reset. Curated labels are treated as stable for the MVP; a label change rebuilds affected documents through the same helper.
- **B-F4 — accept Codex's refinement.** Deleted original → identity, state and `unknown`, never compared. Hidden original compared only under current authorized author access. `get_publication` takes optional submitted intent. The existing-key branch runs before required-field and file validation so identity reconciliation is never blocked by an incomplete form.
- **B-F5 — accept the narrowing.** Confirmed status named in the shared reporter predicate and tested against reclaim. An unexpected foreign-key violation during reclaim is an operational invariant error that preserves the registrant's input; only the expected confirmation race returns not-reclaimable.
- **B-F6 — accept the amendments.** Observe all eligible pending embeddings, distinguishing never-attempted from cooling-down; bounded oldest-age or EXISTS queries; startup and backfill grace; thresholds are tunable starting points; one monitoring schedule with monitor-owned deduplication.

### B-C8 — Accept target equivalence; one predicate, no rebind

The failure is real: after `:existing_different`, B's ready video still targets `{:new_tip, K}`, and the edit of the published item X would refuse it and force a re-upload of the same file. Codex's rule is a pure function of stored facts: at claim time, an edit of X may claim an owned, ready, unattached, unexpired, non-cleanup upload whose stored target is a new-submission target that resolves, by author and key, to X (and for a review, whose parent equals X's parent). The stored target is never rewritten. The key resolves to at most one publication per author, so this cannot reach another post or version. Deleted originals cannot be edited, so nothing revives. Accepted as the claim-side companion to B-C5. Frontend owns carrying the preserved input and evidence into the edit workflow without overwriting an existing edit draft.

### Confirmations on my Round 2 choices

- **B-C2**: `reconcile_after` cooldown mirroring `embed_after`, index predicate extended, deadline unchanged.
- **B-C4**: `FOR SHARE` in the report's select. Lock order is reporter account then tip, matching accounts→tips; the counted cost is that concurrent votes and edits on that tip wait for the insert transaction, milliseconds. Codex indicated receptiveness; I take this as converged unless a lock-order counterexample appears.

### Proposed joint backend conclusion

1. Sessions: family id on existing token rows; renewal by `INSERT … SELECT` under the user lock; logout deletes the family, commits, then broadcasts the family topic; account switch locks both accounts in id order; sudo joins the family, email change starts a fresh one; bounded token pruning in maintenance; lifetimes stated explicitly with the 14-versus-60 choice routed to the owner.
2. Publication acknowledgement: four outcomes; comparison before upload and after key-conflict rollback; deleted → unknown; hidden compared only under author access; recovered image slots → unknown; `get_publication` with optional intent; existing-key branch precedes form validation; target equivalence lets an explicit edit of the published item claim uploads prepared for its key.
3. Search: keyword branches filter `d < 0` outside the top-k subquery; one search-text helper for publish, edit and retag; labels stable for MVP.
4. Deadlines: `clock_timestamp()` at every guarded decision after a lock wait; `text_at` remains a version stamp.
5. Reports: `FOR SHARE` on the target in the insert's select; confirmed status in the reporter predicate; reclaim distinguishes expected races from invariant errors.
6. Expiry: `reconcile_after` per-row cooldown; user deadlines untouched.
7. Bulk moderation: capacity gate with a stated fixture; fallback order fixed; no request-pool timeout change.
8. Operations: pre-auth limiter in-process by address and IP before token or mail; one independent job-health routine with runtime-aware thresholds and one monitoring schedule.
9. Retained: triggers, lock order with implicit trigger targets, provider calls outside transactions, cleanup identifiers independent of job retention, report receipt honesty, independent review visibility, combined media slots.

Routed to frontend: divergent-publication screen carrying evidence into edit; own-base conflict shortcut; re-admission failure that is really a renewal (one reload before "sign in again"); divergent-draft handling when an edit draft already exists.

If Codex accepts items 1–9, I consider backend at consensus.

## Codex Round 3 — convergence on Fable Round 2

- **B-C1:** accept negative-score filtering outside each bounded keyword candidate subquery and before rank/group/fusion. Verify actual indexed and sequential plans. The extension source supports the zero-score concern; the full query remains unexecuted here.
- **B-C2:** accept one `media.reconcile_after` cooldown as necessary state; it removes indefinite retained-media costs without changing author expiry. Correct two details: use current wall time after the attempt for a full cooldown, and **do not put `clock_timestamp()`/`now()` due predicates into a partial index** (time-dependent predicates are unsuitable). Retain a static lifecycle index predicate and apply the due/cooldown condition in the query; measure whether an expression/index on the effective next check is necessary. Guard cooldown writes against attachment/cleanup/state changes, and clear obsolete cooldown on definitive progress. No global readiness scanner is added. Update backend + canonical schema together.
- **B-C3:** accepted decision-time deadline checks, with the architecture's precise linearization point rather than a literal promise that commit occurs before time passes.
- **B-C4:** accepted SHARE lock. I withdrew my initial preference for tombstones after accounting for moderator effort and reproducing both fixed schedules. Avoid promising millisecond contention without measurement. Same lock order, no ancestor tip lock on a review report, no generic deadlock wrapper.
- **B-C5/B-F4:** accepted shared Content comparison, including optional supplied intent on recovery lookup, before uploads and after rollback. Keep different/unknown distinct internally; both preserve input. Author-deleted originals return unknown. No per-attempt request table or digest column.
- **B-C7/B-F1:** accepted one indexed family field and family disconnect topic. Prefer a server-generated UUID for a new family: it needs no new sequence and avoids bootstrapping a required family id from the row's identity. A bigint first-token id also works if it is just an opaque group label, has no root-token FK and is assigned transactionally before exposure; pruning the root must never revoke valid descendants. Pick one representation during migration, not two. Account locks precede predecessor/token checks; logout commits deletion before disconnect; switch locks old/new accounts in id order. Preserve the explicit Tips 60-day configuration and seven-day reissue, with generated-format/recency semantics. This is an adaptation needing browser integration, not an assertion that generated code already implements it.
- **B-C8:** please explicitly accept/challenge target equivalence for ready staged evidence when recovering an existing-key draft into an explicit edit. It closes the user-effort hole created by merely linking to Edit.

My dispositions of B-F2/B-F3/B-F5/B-F6 are in Round 2: capacity gate rather than speculative chunked/auto-ban workflow; shared search-text version updates; explicit confirmation guard without hiding FK defects; independently observed bounded job progress including never-attempted eligible rows. If accepted, these settle the backend phase. Frontend then tests their actual interaction and storage consequences.

## Fable (McCord lens) — Round 4: closure on Codex Round 3

Codex Round 3 and my Round 3 crossed; this reconciles them.

- **B-C8 — explicitly accepted** (stated in my Round 3): an explicit edit of the exact published item may claim an owned, ready, unattached, unexpired, non-cleanup upload whose stored new-submission target resolves by author and key to that item, with the review parent matching. The stored target is never rewritten; no rebind endpoint; deleted originals cannot be edited. It is the claim-side companion of the three-way acknowledgement and removes a repeated video upload from the author.
- **B-C2 correction accepted.** No time-dependent predicate in the partial index. `media_expiry` keeps its static lifecycle predicate; the due and cooldown condition lives in the query; cooldown is set from wall time after the attempt, guarded against attachment, cleanup and state changes, and cleared on definitive progress. Measure before adding any expression index.
- **B-C7 representation accepted.** Server-generated UUID for a new family, assigned transactionally before exposure; one representation chosen in the migration. Pruning by validity never revokes valid descendants.
- **Session lifetime settled.** The owner and Codex both keep the explicit 60-day server validity as a Tips customization, with seven-day reissue and remember-me configured consistently, and generated format and recency semantics retained. My 14-day default recommendation is withdrawn; the contract should state 60 as a deliberate setting and correct the citation.
- **B-C4:** contention is to be measured, not promised.
- **B-F2/B-F3/B-F5/B-F6:** Codex's Round 2 dispositions stand as accepted in my Round 3: capacity gate with fixture, shared search-text version updates, explicit confirmation guard without hiding foreign-key defects, independently observed progress including never-attempted rows.

### Final backend consensus

Items 1–9 of my Round 3 conclusion, amended: item 1 uses a UUID family and the explicit 60-day validity; item 6 keeps the static index predicate. Item 2 includes B-C8's target equivalence. Nothing else changes.

**Phase status: consensus.** Codex and Fable exchanged three numbered rounds each plus this closure. Accepted: B-C1 filter placement, B-C2 cooldown, B-C3 decision-time deadlines, B-C4 share lock, B-C5/B-F4 three-way acknowledgement, B-C6/B-F6 operational carries, B-C7/B-F1 session family with commit-before-disconnect, B-C8 target equivalence, B-F3 search-text version. Reclassified: B-F2 as a capacity gate. Narrowed: B-F5 to an explicit guard. Withdrawn: chunked bulk job, time-dependent index predicate, 14-day default. Routed to frontend: divergent-publication screen carrying evidence into edit, own-base conflict shortcut, renewal-versus-expiry re-admission handling, existing-edit-draft collision.

## Codex Round 4 — final two corrections for closure

I accept Fable Round 3 items 1–9, including B-C8, with two precise corrections already stated in my Round 3:

1. Keep the current explicit 60-day Tips value and document it as a customization; keep the existing seven-day generated rotation. This review corrects the false default attribution, not the product's recorded number. Nothing in the current user request authorizes or requires shortening sessions, and routing a routine interpretation back to the owner would leave the review unnecessarily unfinished. A later deliberate product change can choose another duration. Server validity and persistent-cookie configuration must agree with the recorded choice; genuine-authentication recency remains separate.
2. `reconcile_after` is a runtime due predicate. The partial index retains static lifecycle predicates; it must not contain `now()` or `clock_timestamp()` comparisons. Set cooldown from current wall time after reconciliation and guard it against lifecycle changes. This is a SQL correctness requirement, not an open preference.

No fixed millisecond contention or response-time claims are accepted without measurement. The family field can use a server-generated UUID with the existing UUID facility; no second sequence, root-row FK, or separate table is needed.

With Fable's acknowledgement of these corrections, the backend phase is at consensus. All retained and rejected findings remain in the transcript; the frontend phase must now validate the recovery handoffs and interaction consequences.

## Fable — acknowledgement of Codex Round 4

Agreed on both corrections, which match my Round 4: the recorded 60-day validity stays as an explicit Tips customization with the seven-day generated rotation, server validity and persistent cookie configured to match, and only the false default attribution corrected; `reconcile_after` is a runtime due predicate applied in the query, never in the partial index, set from wall time after reconciliation and guarded against lifecycle changes. UUID family id. No contention or response-time numbers claimed before measurement. **Backend phase: consensus.**
