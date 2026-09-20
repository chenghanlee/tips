# Holistic adversarial review: architecture

Date: 2026-09-20. Status: consensus after three rounds. Backend/frontend details are recorded in their companion reviews.

## Agreed result

**Keep the architecture. Repair the boundaries.** One Phoenix application, Accounts/Content contexts, PostgreSQL, Oban and LiveView are sufficient. The main risk is mistaking one kind of acknowledgement for another across database, browser and provider state.

| Priority | Required change | Cross-layer consequence |
|---|---|---|
| P1 | A publication key proves identity, not that this draft's values were saved. | Backend compares authorized content; frontend preserves different/unknown work and clears only acknowledged revisions. |
| P1 | Carry one validated return destination through the entire magic-link flow. | Public LiveView actions and another-browser confirmation must reach the intended page without replaying a mutation. |
| P1 | Make same-browser logout revoke renewed sessions together. | Backend recommends one UUID family field; frontend preserves input when admission fails. |
| P2 | Bound search work and explicitly cancel superseded local tasks. | Keep provider concurrency, queue and deadline bounds even when old results are ignored. |
| P2 | Observe background progress independently of Oban. | A healthy web process is insufficient evidence of functioning cleanup or embedding work. |
| P2 | Preserve moderator version guards while reducing false author conflicts. | Store the complete editor base and offer an explicit guarded save only when editable fields are unchanged. |
| P2 | Limit pre-auth mail/token requests and prove risky journeys early. | Exercise authentication, publication uncertainty, drafts, images, private video and pinned search extensions as vertical slices. |

Rejected: microservices, mandatory vector caching, removing hide/restore version bumps, generic workflow/request-log infrastructure, and pushing routine recovery onto the author. Necessary state earns its place when it prevents lost work or repeated effort.

Read the [backend decisions](holistic-backend-review.md) and [frontend decisions](holistic-frontend-review.md) for the final implementation contracts; their later refinements supersede tentative options in this transcript. Apply changes by contract owner: schema/invariants in data-model, operations in backend, browser journeys in frontend; link instead of copying procedures. Design documents have not been changed by this review.

## Review agreement

Codex uses a José Valim-inspired perspective: domain invariants, data ownership, failure semantics and minimum necessary machinery. Fable uses a Chris McCord-inspired orthogonal perspective: complete Phoenix/LiveView journeys, framework conventions, user effort and delivery. These are analytical roles, not statements or endorsements by either person.

Review the current data-model.md, backend-design.md, frontend-design.md and software-architecture.md under docs/design/technical. Prior reviews are historical evidence, not proof that the current combination is coherent. This is a design review; no application implementation exists in this workspace and acceptance tests are unexecuted.

Proceed sequentially: architecture, backend, frontend. Each phase uses its own shared file. Maximum ten paired rounds per phase; finish early only with explicit agreement from both reviewers. Append attributed responses, challenge each other's findings and fixes, and distinguish accepted findings, rejected claims, implementation choices and unresolved questions. Do not edit the design contracts during this review.

For each material finding supply document/line evidence, a concrete failure journey, the smallest fix, local and downstream effects, and verification. Preserve owner-selected product behavior. Apply first principles, Occam's razor and the 80/20 rule; use proven conventions, avoid speculative enterprise machinery and backwards compatibility. Evaluate local correctness, affected modules/features/tests, then the full journey. Verify uncertain framework/provider claims against primary sources.

## Root question

Can one implementation honor all the contracts together without contradictory state, duplicated authority or pushing recovery work onto users?

## Codex Round 1 — independent architecture review

### First principles and root cause

1. Why can locally sound choices fail together? They act on the same publication, identity and media at different times.
2. Why do those times matter? A browser, database transaction and external provider cannot commit together.
3. Why is that difficult here? A failed response can mean either failure or success, while another tab or moderator can change state.
4. Why are the current safeguards not automatically sufficient? A safeguard protects one boundary: a submission key protects publication identity; a draft revision protects local storage; an edit version protects a stored edit. None substitutes for another.
5. Why does this create review risk? The lifecycle connecting those safeguards is repeated across documents rather than exercised as one implementation.
6. Why would adding more layers solve that? It would not; the missing evidence is executable journeys across existing boundaries.
7. Why change the service topology? There is no demonstrated need; the answer remains a coherent lifecycle inside the monolith. Stop: two further whys do not change the answer.

**Architecture verdict:** retain the single Phoenix release, Accounts/Content contexts, Postgres transactions and Oban. No microservices, per-entity processes, general workflow engine, API frontend or extra draft store. The existing distinction between database facts, browser recovery state and provider transport is sound. The risks below concern how the boundaries compose.

### A-C1 — search supersession protects display correctness but does not bound work (P2)

Evidence: frontend-design.md:78–84 deliberately lets superseded tasks finish; backend-design.md:55–65 reruns embedding and retrieval on each page/filter request; data-model.md:805 specifies IP/user limits for writes/uploads, not public search; software-architecture.md:160–170 keeps inference, requests and jobs within one deployment/provider budget. A per-call timeout limits duration, not simultaneous calls.

Failure journey: a reader changes three immediate filter selects while slow search calls run, then pages/backtracks. The newest result wins, but every superseded task can still call the embedding provider and database. Across readers, SSR plus connected retrieval multiplies the work. The same provider can also be processing document embeddings. Queue concurrency limits do not cap request tasks.

Smallest recommendation: define a finite total search-operation deadline and explicit search admission/provider concurrency budget shared by request inference and the scan. Use existing client/pool/edge facilities; do not add a search-job queue. On exhausted semantic budget use the existing keyword fallback, which must also be bounded. Consider ordinary `cancel_async` for replaced tasks if it releases meaningful resources; cancellation is not a promise to retract an already sent provider request. Keep readable SSR and agreed submit/filter behavior.

Effects: local result supersession stays unchanged; provider saturation cannot quietly defeat worker/request isolation. Verify rapid filter/page changes during a slow provider response, plus simultaneous embedding scan, measuring active calls and useful page response. This is a capacity-contract gap, not proof that normal MVP traffic is already overloaded. [LiveView's documented async semantics](https://hex.pm/packages/phoenix_live_view/1.1.22/files/lib/phoenix_live_view.ex) confirm result suppression and explicit cancellation are distinct.

### A-C2 — the highest-risk vertical slice comes too late in the written sequence (P2, delivery risk)

Evidence: software-architecture.md:164–170 calls for a read → publish → edit journey, search evaluation and real Stream checks; backend-design.md:259–329 and frontend-design.md:156–224 rely on LiveView file lifetime, custom tus preflight/resume, provider completion time, browser storage and publication reconciliation all agreeing. The docs correctly label these checks unexecuted, but do not order these dependency gates before completing the surrounding UI.

Recommendation: keep the product scope; make the first thin implementation prove (a) text publish/edit with lost confirmation and same-browser recovery, (b) one image surviving a known rejection, and (c) one private video through provision → transfer → completion → ready → publication → hide/delete. Run pinned search-extension/query evaluation alongside that foundation before building out all secondary pages. Reuse these tests as implementation acceptance, not a new prototype architecture or extra ceremony.

Effects: local provider/framework assumptions become evidence early; backend/schema and frontend feedback are adjusted together before repeated page implementations harden. Stream's official API describes `uploaded` as upload time, but the exact direct-tus completion/expiry boundary still needs the existing real-provider check; neither a browser progress event nor documentation examples prove it. Sources: [direct creator uploads](https://developers.cloudflare.com/stream/uploading-videos/direct-creator-uploads/), [video details](https://developers.cloudflare.com/api/resources/stream/methods/get/).

### A-C3 — repeated normative contracts invite another isolated decision cycle (P2, documentation ownership)

Evidence: software-architecture.md:13 names each document's owner, but the media lifecycle is fully restated in backend-design.md:263–329, data-model.md:774–790 and frontend-design.md:156–190; draft revisions/recovery appear in backend-design.md:317–337, data-model.md:574 and frontend-design.md:194–224. Current overlap is mostly consistent, so duplication alone is not a runtime bug.

Recommendation: use the stated ownership in practice. Backend owns lifecycle/operation outcomes; data model owns constraints/locking/query invariants; frontend owns rendering, interactions and browser storage. In a later reconciliation edit, replace duplicated procedural prose with short guarantees and direct anchors; retain layer-specific requirements. For each accepted review fix list all affected docs and the one integration test that proves the combined contract. No new registry, schema generator or governance document.

Effects: reduces future conflicting edits and implementation reading load while retaining necessary UX guarantees. Verify links and ensure no rule exists only in superseded brainstorm notes. Challenge requested: does Fable see a concrete contradiction that makes this more than maintenance cleanup?

### Retained tradeoffs, not findings

- Public R2 image URLs and short-lived private Stream links intentionally have different revocation guarantees; do not claim hiding recalls either saved copies or issued tokens.
- Live reviews surviving hidden/deleted parents is an explicit product rule; public search may still require a live parent.
- Changed rankings and offset pagination are accepted; no snapshot cache is justified by repeat/omission alone.
- Repeated authenticated admission and narrow ordered locks have different purposes; removing either to reduce apparent layers breaks the agreed security/concurrency boundary.

Backend round should examine expiry-worker progress under uncertain rows, notification/account interactions, report-delete races and canonical search building. Frontend round should examine banned-owner deletion discoverability and draft conflict/publish outcomes.

### Codex Round 1 addendum — A-C4: publication identity is not draft-content acknowledgement (P1)

Evidence: backend-design.md:321 guards draft clearing by local identity/revision; :353 distinguishes `:created` and `:existing`; :364 says the frontend clears the submitted draft on confirmed publication; :366 and data-model.md:525 deliberately return the original publication even when a reused key carries changed values. frontend-design.md:202 protects local revisions but :222 clears after confirmed publishing. These protections are individually correct and do not compose into a guarantee that a confirmation saved the current draft's values.

Concrete trace:

1. Tabs A and B share new-tip key K and draft revision 5. A has old text X.
2. B saves newer text Y to local revision 6. A has not attempted another autosave and has not detected the conflict.
3. A publishes X under K. Its revision-5 clearing fails, correctly preserving B's revision-6 draft.
4. B publishes Y under K. Content correctly returns `:existing` for X; it must not mutate the original publication.
5. If B follows the blanket success-clearing instruction, its revision-6 clear succeeds. Y disappears even though it was never published.

This does not require malicious input or a broken IndexedDB transaction. It follows the stated key and revision rules. A pre-submit local check is helpful but cannot atomically couple the browser transaction to the remote publication.

Smallest invariant: `:existing` confirms identity/current publication state, not that the current form values were saved. Reconciliation must preserve potentially divergent local input until it can establish equivalence or the author explicitly handles it. Reuse the existing saved-content read and manual edit/reference interaction; no server draft, request-log table or automatic merging. Even the `:created` path clears only the submitted local revision, as already required. Deleted/hidden originals retain their normal access rules and never get restored by recovery.

Backend phase should specify the response/read boundary; frontend phase should specify the smallest user flow for an existing publication plus different local work. Verification must cover this exact two-tab trace, including unavailable originals and unavailable browser storage. I request Fable's adversarial challenge of both the failure and the proposed invariant.

## Fable (McCord lens) — Round 1

Written independently before reading Codex Round 1. Line numbers refer to the current four documents (`software-architecture.md` = arch, `backend-design.md` = backend, `frontend-design.md` = frontend, `data-model.md` = data). Framework claims below were checked against the `phx.gen.auth` template at Phoenix v1.8.1 (`priv/templates/phx.gen.auth/auth.ex`).

Answer to the root question: the contracts are coherent on state ownership (Postgres owns business state, the page owns interaction state, Oban owns attempts). The failures are at seams where one document assumes a framework facility that the generated foundation does not provide, or where one shared mechanism serves two purposes and one of them pushes work onto a user. Six findings, one note. None needs a new process, table or dependency.

### A-F1 — High: the sign-in return destination has no carrier that survives the journeys the contracts promise

Evidence. arch:31 says the UX agreements "are incorporated into the technical contracts"; the [UX architecture consensus](ux-architecture-review.md) ranked first: "Carry a validated local destination through magic-link completion." The current contracts instead say the generated plug "stores a validated local GET return path" (frontend:27), "After magic-link verification, return to the intended editor" (frontend:29), a signed-out vote "starts sign-in and returns to the same tip or review" (frontend:122; backend:400), a signed-out Report preserves "a validated local return destination" (frontend:228; backend:420), and "Preserve the intended local destination through authentication" (backend:466). arch:88–90 selects the generated foundation unchanged.

Verified template behavior (v1.8.1): `maybe_store_return_to` matches only `%{method: "GET"}` and writes `user_return_to` to the Plug session; the LiveView `on_mount :require_authenticated` clause redirects to `/users/log-in` and stores nothing; `log_in_user` reads the destination from the session only. So the generated foundation covers exactly one origin: a full GET against a route behind `require_authenticated_user`.

Failure journeys.
1. Signed-out reader on a tip page (public `live_session`) clicks Helpful. That is a LiveView event, not a GET through the plug. The LiveView can `push_navigate` to the login page but cannot write the Plug session (frontend:27 says so). The magic link completes; `user_return_to` is nil; the reader lands on the home page. Same for Report. backend:400 and :420 are unimplementable as written on the generated foundation.
2. Editor entry does go through the plug, so the cookie holds the path. The link is opened in a mail app's in-app browser or another profile. That browser has no cookie; it lands on home. This is the case the UX consensus fixed and the contracts dropped.

Whys. Why is the reader not returned? The destination is in a session cookie that the completing request does not carry. Why a cookie? The plug convention. Why only for GET? The generator protects controller routes; LiveView events are not requests. Why did the contracts revert? The technical documents cite the plug's behavior as the mechanism and the UX fix was recorded only in the brainstorm. Two more whys stay at "destination bound to the wrong carrier."

Smallest fix (feature-preserving, no new storage). One `return_to` parameter, validated as a local path at the web boundary, that travels with the request the whole way: public LiveViews navigate to `/users/log-in?return_to=…`; the login and registration LiveViews carry it into the magic-link URL they build (`url(~p"/users/log-in/#{token}?return_to=…")`); the confirmation form posts it; the session controller validates it again and redirects to it, else to the signed-in path. Keep the plug's `user_return_to` as the fallback for editor entry. State in the architecture that editors and account settings live in the `require_authenticated_user` live_session and every public page in `current_user`, so editor entry is a full GET through the plug by construction (cross-`live_session` navigation reloads).

Effects. Accounts: none; it verifies identity and never interprets paths. Web: one param on two LiveViews and one controller action, one `local_path?` helper. Frontend: the vote, report and "Sign in to review" controls get a concrete mechanism. Drafts and sessions are not transferred; only the destination is.

Checks. Signed-out vote → magic link opened in a different browser → lands on that tip, vote state shown, no vote cast. Tampered or absolute `return_to` → signed-in path. Editor entry with cookies blocked → still returns to the editor via the link param.

### A-F2 — Medium: one `edit_version` serves author conflicts and moderator visibility, and the second use pushes manual reapplication onto authors for no protected state

Evidence. data:606 hide/restore "advance `edit_version` on a change"; data:610 bulk hide "Advance affected edit versions"; backend:390 "Moderator changes also use that version"; backend:436 moderator actions compare "the content version and relevant moderation/report state"; frontend:226 a stale save keeps the author's text as a read-only reference and the author "reapply[s] changes by hand"; backend:442 "Saving preserves `dead_at`", authors may edit hidden content.

Failure journey. An author is mid-edit on a wrongly hidden tip. A moderator restores it. The author saves and gets a conflict; the editor shows a reference copy and asks them to reload and reapply by hand. Nothing they could save would have clobbered anything: the edit statement (data:581) never touches `dead_at`. Bulk hide multiplies this across every open editor of that account. The version bump here protects no invariant; it only manufactures a conflict.

Whys. Why does the author see a conflict? `edit_version` changed. Why did it change? Hide advanced it. Why does hide advance it? To reject stale moderator actions. Why is that needed? A second moderator may act on state they did not see. Why is the version the guard? It is the one already there. Why is it the wrong guard for hide? The moderator contract already compares visibility (data:606), which is the state hide changes; the author's editable fields are untouched. Two more whys stay here.

Smallest fix (feature-preserving). Hide, restore and bulk hide change only `dead_at` and guard themselves on the loaded `dead_at` (already in their contract). Keep the bump for retag (changes the author-editable tag) and destroy_media (changes the attachment set), where a stale author save really could revert the moderator's change. backend:390 narrows to "moderator changes to author-editable fields also use that version."

Effects. Author edits: fewer false conflicts, no new path. Moderator stale-action protection: unchanged, because the author→moderator direction is still covered by author bumps and the moderator→moderator direction by the visibility compare. Dismiss reports already changes no version (data:608).

Checks. Two-transaction test: author holds v1 form; moderator hides; author saves → success, `dead_at` preserved. Moderator A hides; moderator B replays hide from a snapshot with `dead_at IS NULL` → rejected on visibility, not version.

### A-F3 — Medium: a stalled Oban is invisible to every observer the architecture installs

Evidence. arch:104 health = "Phoenix can serve a request and execute a bounded, read-only Postgres probe"; arch:100–102 Sentry receives exhausted jobs only; backend:222 and :237 the embedding scan is `max_attempts: 1`, classifies provider errors per row and "continue[s] past poison rows", so a provider failure is not a job failure; backend:61 keyword fallback is deliberately invisible to readers; data:706 "Count rows with NULL vectors to measure the backlog" names no consumer of that count.

Failure journey. After a deploy the cron plugin is misconfigured, or a queue is paused, or the embedding provider's key expires. Embedding, video expiry, media cleanup and registration reclaim all stop. Readers still get results (keyword fallback, by design silent). No job exhausts, so Sentry is quiet; the health check passes. Weeks later: no new tip has a vector, abandoned Stream assets accumulate, moderator-destroyed media still exists at the provider. Each decision is right alone; together they remove every signal.

Whys. Why no alert? Nothing reports on the scheduler. Why not? Health deliberately excludes providers. Why is that the wrong boundary? Oban is not a provider; it is the app's own scheduler on the app's own database. Why does the invisible fallback matter here? It converts a stall into a silent quality regression. Stop.

Smallest fix (feature-preserving, no new state). The health probe also asserts the three queues are running, using Oban's in-process queue check (`Oban.check_queue/2`; verify the name against the pinned version). The embedding scan reports once, as a Sentry message rather than an exception, when the backlog contains rows older than a threshold (one bounded count it already performs), and not again until the condition clears. Providers stay excluded.

Checks. Pause `media` → health fails through the public hostname. Stop the embedding provider for longer than the threshold → one alert, not one per tick; restore → alert clears.

### A-F4 — Medium: synchronous retrieval on both mounts doubles the one cost the architecture cannot bound

Evidence. arch:126 and frontend:19 run the same bounded retrieval synchronously on the disconnected and first connected load; backend:57 "Initial connection may retrieve twice"; backend:59 the query vector "may optionally be reused"; backend:61 timeout follows keyword fallback; arch:150 hosted inference is the first candidate.

Failure journey. Provider degraded (timeouts, not errors). A reader searches. Dead render waits the embedding timeout, falls back to keywords, renders. Connected mount repeats both. Time to a usable page ≈ 2 × timeout + two queries. In the healthy case every search landing is two billed inference calls for one result set.

Whys. Why twice? LiveView runs `handle_params` on both mounts and the design wants readable dead HTML. Why not skip on connected mount? Assigns must hold the results or the DOM is replaced. Why is that costly? The embedding call is the only step with unbounded external latency. Why "optionally" reuse? It was recorded as permission, not a requirement. Stop: the root is that the cost of the accepted double retrieval was priced as two Postgres queries, not two provider calls.

Smallest fix (feature-preserving). Make query-vector reuse required: one supervised ETS table keyed by (normalized query, model version) with a short TTL and a size bound. This is not the rejected search-snapshot cache (arch:114): it stores no ranking or order. Set the embedding timeout low (about one second, tunable) because the keyword branch exists. Defer a "skip embedding until T" window until measurement shows it is needed.

Checks. One provider call per search landing. Provider timeout: results visible in ≈ one timeout, not two. Cache miss after TTL or model change.

### A-F5 — Low, verify: session reissue leaves the old token row valid, so a LiveView admitted under it survives the logout the user performs

Evidence. arch:88 re-admission "shares generated context, expiry and revocation rules"; backend:490 "Retain generated session renewal behavior"; data:50 the LiveView holds `users_tokens.id` from mount. Verified template (v1.8.1): after seven days the plug reissues via `create_or_extend_session`, which generates a new token and does not delete the old row; `log_out_user` deletes only the current session token and broadcasts disconnect only on the current `live_socket_id`.

Failure journey. Shared machine. Editor tab A mounted under token T1 (day 8). A page load in tab B reissues T2. The user logs out in tab B. Tab A is not disconnected (subscribed to T1's topic) and re-admission by T1's row succeeds until the row ages out at 60 days or the socket drops. Stock gen.auth has the same latent exposure with no per-action check at all, so this is not a regression; but it contradicts the stated claim that re-admission enforces revocation.

Smallest fix (feature-preserving, one adaptation). In the adapted `create_or_extend_session`, delete the superseded token and broadcast disconnect on its topic. Open LiveViews remount under the new cookie; form recovery and browser drafts cover the remount, which is the same event a deploy causes. Cost: one reconnect per session per seven days.

Checks. Reissue → old row gone, old LiveView remounts with the new token id. Logout after reissue → no LiveView can re-admit.

### A-F6 — Low: magic-link requests are outside every named protection

Evidence. arch:140 Turnstile "in the agreed signup flow"; data:805 rate limits apply "to writes and uploads"; backend:496–498 direct Swoosh delivery with retry feedback. Requesting a login link for an existing address is neither signup nor a content write.

Failure journey. Anyone can flood a registered address with Tips sign-in emails and burn the delivery provider's quota; the victim's inbox fills with valid links.

Smallest fix (feature-preserving, no new table). Include the login and registration POST paths in the per-IP Cloudflare rule, and enforce a per-address minimum interval from the rows `users_tokens` already holds (`context = 'login'`, `sent_to`, `inserted_at`). Verify whether the pinned generator already throttles.

### A-F7 — Note, not a finding: deploy interruption × images-on-submission

arch:96 accepts a brief interruption; backend:261 and frontend:224 keep image entries only in the LiveView process. Every deploy while an author has images selected forces reselection. This is the owner-selected local-draft scope, not a defect. Record it in the deploy runbook (prefer low-traffic windows) and measure how often it bites; do not add staging.

### Disposition for challenge

A-F1 is the one item where the current combination cannot deliver a promised journey on the selected foundation and where an accepted consensus was lost in transcription. A-F2 and A-F3 are combination failures of individually sound rules. A-F4 prices an accepted trade correctly. A-F5 and A-F6 are hardening with one-line fixes. No context split, no new process type, no new table. Codex: challenge the fixes, especially whether A-F2's visibility compare is sufficient for every moderator stale-action case, and whether A-F5's disconnect-on-reissue costs more than it protects.

## Codex Round 2 — challenge of Fable's architecture findings

- **A-F1 accepted as a concrete integration gap (P1).** The intended behavior is stated, so I would say the mechanism is incomplete rather than that it is impossible to implement. Specify one allowed-local-destination carrier from public LiveView action through login/signup, emailed link, confirmation and controller redirect. Validate against allowed destination routes, not merely a leading slash (`//host`, encoded redirects and action-bearing endpoints matter). Keep this in TipsWeb. Cross-browser completion transfers destination only, never IndexedDB drafts or pending vote/report execution. Your param-based mechanism is appropriately small. Editor entry and settings must use the authenticated live-session boundary; do not unnecessarily mandate one single public live_session if implementation needs another public boundary.

- **A-F2 rejects a real safeguard, so I reject the proposed fix.** Equality of `dead_at` does not detect restore→hide→restore (the NULL→timestamp→NULL ABA cycle). Moderator A loads a live target at version 1; B hides it and C deliberately restores it; A's stale hide now passes both NULL visibility and unchanged edit version under your proposal, undoing the later moderator decision without review. The current version guards prevent this. A separate moderation generation would preserve that guarantee but add exactly the parallel version state we want to avoid. Keep one version and conservative author conflicts for MVP. We can reduce the explanatory burden of the conflict UI, but automatic rebasing or an extra version is not justified here. This is a deliberate simplicity/rare-conflict tradeoff, not a broken author write. Please challenge this ABA trace.

- **A-F3 accepts the missing liveness signal, rejects the proposed completeness claim.** Queue-running is not cron-running or useful-progress. Pausing a queue is detected, but a missing cron entry leaves queues running. An alert executed inside a stopped scan cannot detect that scan stopping. Once-until-clear also requires state despite the claim of no new state. Smallest invariant: an observer independent of the Oban work being checked must notice overdue scheduled work and aging unfinished cleanup/embedding work. Prefer existing Oban job timestamps/state plus existing operator monitoring/cron facilities; choose one supported check, not a dashboard/heartbeat platform. Keep the public app-and-DB probe's documented meaning clear. Distinguish provider-specific embedding failure from all queues stopping: an expired embedding credential does not itself stop media or registration jobs. Need a concrete operational check and acceptance test, not a requirement for a particular paid service.

- **A-F4 rejects mandatory ETS caching; accepts a finite latency budget, consolidated with A-C1.** The duplicate retrieval is explicitly accepted in backend:57 and frontend:19, not an undiscovered contradiction. A vector cache cannot make your timeout acceptance pass because failures must not be cached: first timed-out mount has nothing to reuse, so the connected mount still calls again. Concurrent initial misses also need coalescing to promise exactly one call. Your fix adds a process/table, TTL, eviction and synchronization without satisfying its strongest check. Keep successful-vector reuse optional as documented; require bounded overall search time/concurrency and evaluate slow-provider SSR and connection together. Do not promise one provider request per landing without implementing and justifying that stronger contract.

- **A-F5 provisionally accepts the session-renewal/logout seam; requests evidence before prescribing the fix.** The old row was never revoked, so this does not contradict the narrow claim that re-admission enforces revoked tokens; it does violate the user's expected same-browser logout if an old tab remains authorized. Please link the exact pinned generator code and check the latest intended pin. Deleting/disconnecting T1 during ordinary renewal may race simultaneous requests renewing T1 into T2 and T3; deleting the old row alone does not prove there is one surviving browser session. Bound the recommendation to a tested same-browser renewal/logout contract using the generated mechanisms, with a clear policy for simultaneous renewals and old sockets. Do not label it a one-line fix or introduce session-family tables without evidence.

- **A-F6 accepts explicit coverage, narrows the claim.** Login creates token rows and sends mail, so it can reasonably count as a write. The actual gap is unnamed unauthenticated auth endpoints/LiveView events plus per-address limits: an app per-user limiter cannot protect pre-auth traffic. Explicitly include sign-in, resend and email-change requests, including connected LiveView events that do not make a POST on each click. An edge POST rule alone is insufficient. Put the check before token/email creation and test across multiple clients. Reuse the existing app limiter rather than assuming token rows provide an atomic limiter. This is backend detail, not a new service.

- **A-F7 retained as an accepted tradeoff**, not another release blocker.

I accept architecture consensus on the monolith. I do not yet declare findings consensus: A-F2, A-F3, A-F4 and A-F5 need the narrowed dispositions above, and A-C4 needs Fable's challenge.

## Fable (McCord lens) — Round 2: critique of Codex Round 1

Verdicts first: **Accept A-C4's failure, narrow its invariant.** **Narrow A-C1** to two existing knobs. **Accept A-C2** with one addition. **Accept A-C3** as more than cleanup, with two concrete contradictions from my Round 1 as the evidence Codex asked for. Architecture verdict (single release, two contexts, Postgres + Oban, no extra draft store) accepted.

### A-C4 — Accept the failure; the trace is valid and understates the defect. Narrow the invariant.

The trace holds under the current text. Both tabs legitimately hold key K because "Opening New tip resumes it" (backend:319) and the draft is one record per account and form. A's publish is not guarded by the draft revision, so step 3 proceeds; backend:359 returns `:existing` to B; backend:364 clears. Y is gone. I add two things.

First, step 3 is itself a user-visible defect, not the "correct" part of the trace. The author's newest words are Y; the site publishes X. That happens whenever an idle tab publishes after a newer tab autosaved, and it happens before any `:existing` response exists. Root: Publish writes the draft's identity to the server without the draft's revision guard, while every other write to that draft (autosave, clear, discard) is guarded (frontend:202). Publish is the one unguarded write.

Second, Codex's invariant, "preserve until equivalence is established," needs a content read and a field-by-field compare including attachment order and descriptions. That is more machinery than the failure needs, and it does not cover the case where the compare is impossible (original hidden or deleted, storage unavailable). The design already has a cheaper fact: a tab knows whether it is retrying its own unresolved submission, because frontend:200 keeps "an unresolved submission's values fixed until its outcome is reconciled."

Narrowed fix, two rules in the existing vocabulary, no server read beyond the lookup the publish already performs:

1. Publish is a draft write. Before submitting, flush under the same `(draft_id, revision)` compare-and-set that autosave uses. On mismatch or missing record, do not submit; show the existing conflict state and reload offer (frontend:202, :218). This removes the human case (stale tab publishes stale text) entirely. It leaves the race between the flush and the response, which Codex is right cannot be closed from the browser.
2. `:existing` clears the local draft only when this tab is retrying its own unresolved submission of fixed values. Any other `:existing` preserves the draft, pauses autosave, and shows the published item with a link to its Edit form and the existing confirmed Discard-draft action. Unavailable originals show their normal state and still preserve the draft. No compare, no merge, no server draft.

Effects. Backend: `get_publication`/`publish_*` already return id, outcome and state; nothing to add. Frontend: one CAS before submit and one branch on `:existing`. Storage unavailable: rule 1 is skipped (nothing to compare) and rule 2 still preserves on-screen input.

Checks. Codex's exact trace: A is blocked at step 3 with the reload offer; if A reloads Y and publishes, B's next flush fails on the missing record and B's reload shows the publication. Race variant: A flushes at revision 6, B autosaves 7, A publishes 6 → `:created`; B publishes → `:existing` → B preserves Z. Lost-confirmation single tab: retry with fixed values → `:existing` → clear. Hidden or deleted original → notice plus preserved draft.

Phase routing agreed: backend states the response boundary, frontend the flow.

### A-C1 — Narrow: the budget already exists as two pool sizes; do not name a new admission layer

Two corrections before the fix. (a) LiveView's `start_async` with an already-running task of the same name cancels the running task (verify against the pinned version; if so, frontend:82 "let superseded work finish" describes what the framework does not do and should be reworded, and per-view in-flight retrieval is already one). (b) With my A-F4 query-vector cache, a filter or page change on an unchanged query makes zero provider calls, because the query text and model are unchanged. Codex's worst case, three filter changes during a slow provider, becomes three database queries and no inference.

What remains is real: the database pool. A killed or finishing retrieval still occupied a connection for up to the two-second statement timeout, and the dead render occupies another. Smallest fix: per-view one in-flight retrieval (framework cancellation or one `cancel_async`), the embedding client's own Finch pool size as the provider concurrency budget shared with the scan, and the existing pool and statement timeout as the database budget. Measure rapid filter changes plus a running scan as Codex proposes. Reject a separate search admission mechanism; the budget is those two pool sizes.

### A-C2 — Accept; add the sign-in journey to the first slice

The three gates are the right first slice and are already implied by arch:150; Codex's list makes them explicit and ordered. Add a fourth: sign-in completed in a different browser context returning to the intended tip or editor (my A-F1), because backend:25's first success signal depends on a newcomer reaching the review form. No prototype architecture; these become the acceptance tests.

### A-C3 — Accept as more than cleanup; two concrete contradictions

Codex asked for a contradiction. Two, both from restated rules that drifted:

1. arch:31 states the UX agreements are incorporated. The UX consensus's first-ranked fix, a validated destination carried through magic-link completion, exists only in `ux-architecture-review.md`. The contracts restate the plug's session-cookie mechanism in three places (arch:88–90, frontend:27, backend:466) and promise journeys it cannot deliver (my A-F1). A rule that lived only in a brainstorm note was lost exactly as Codex's check predicts.
2. The moderator use of `edit_version` is stated with different scopes in data:606 ("advance on a change"), data:610 (bulk hide advances all) and backend:390 ("Moderator changes also use that version"), and none names the visibility compare as the guard for hide. The duplication let the scope widen until hide bumps the version for no protected state (my A-F2).

Fix as Codex states it: ownership in practice, guarantees plus anchors in a later reconciliation edit, one integration test per accepted fix, no governance document. Add one step: diff the UX consensus tables against the contracts once, so no other first-priority item is missing.

### Retained tradeoffs

Agreed on all four. One nuance on "public search may still require a live parent": the review branches join `live_tips` (data:743, :750), so a hidden tip's independently visible reviews are reachable by permalink and profile but never by search. That is consistent with "Keep the tip out of feeds and search" (backend:442) and is a product rule, not a defect.

### Disposition of Codex's findings

| Finding | Verdict | What changes |
|---|---|---|
| A-C1 search work bounding | Narrow | Verify same-name cancellation; provider budget = embedding client pool size; database budget = existing pool and timeout; A-F4 cache removes inference on filter/page changes. No admission layer. |
| A-C2 first slice ordering | Accept | Add the cross-browser sign-in return journey as a fourth gate. |
| A-C3 documentation ownership | Accept, upgraded | Two concrete contradictions found (A-F1, A-F2). Fix as stated plus one diff of UX consensus against contracts. |
| A-C4 `:existing` erases newer draft | Accept failure, narrow invariant | Publish runs the draft CAS first; `:existing` clears only for this tab's own fixed-value retry, otherwise preserve and show the publication. No content compare. |

Open for Codex: my A-F1 through A-F6, in particular whether A-F2's visibility compare covers every moderator stale-action case and whether A-F5's disconnect-on-reissue is worth one reconnect per week.

## Owner clarification during review

Accept necessary complexity in the team agent harness when it makes the user's experience simpler. Do not make implementation look simple by pushing complexity onto the user. Apply this to our review coordination and to the existing product-design principle: reviewers must resolve and consolidate their disagreements, and a recommendation must count repeated actions, manual recovery and user effort, not just columns or modules removed. No new harness implementation is requested in this review.

## Codex Round 3 — challenge of Fable Round 2 and convergence proposal

**A-C4:** accept flush-before-submit CAS as an additional protection, with the existing storage-unavailable exception. Reject the proposed own-unresolved-retry exception as sufficient proof. Two tabs can both flush in sequence before either remote request commits; both can hold fixed but different payloads under K. With browser storage unavailable, even the local CAS protection is absent by contract. B can commit Y while A's X request loses confirmation; A retries its own fixed X and receives `:existing` Y. Knowing this is A's retry does not establish that A won. The unique key deliberately erases that distinction.

Keep the invariant: **never destroy unconfirmed local values on an identity-only receipt.** The simplest safe fallback is to preserve input for every `:existing` whose content is not established equivalent, show the published destination and offer the existing explicit edit/discard path. Reuse canonical form/no-op comparison where straightforward; when new-image identity, deleted originals or unavailable state prevent comparison, preserve conservatively. Do not require a new digest column or request log. Owner's clarification matters: a small compare using existing normalized form fields may reduce unnecessary manual recovery; refusing all comparison just to save implementation code moves the burden to authors. Backend/front-end phases can settle the precise minimal branch, but the unsafe retry exception cannot be architecture consensus.

**A-C1:** Fable's assertion that same-name `start_async` automatically cancels the old task conflicts with the primary documentation already cited in Round 1: the new result wins and the old result is ignored; explicit `cancel_async` is separately documented. Verify the pinned source before changing the contract. Pool-size-only also needs care: connection count is not necessarily HTTP request concurrency (multiplexing), and waiting callers can accumulate. Agree to use existing client/pool/admission capabilities and existing DB pool, with bounded queue waits/total deadlines. No new general-purpose admission layer or process is prescribed. A cache miss during a slow provider call remains a miss on three subsequent filter changes unless single-flight coalescing is added, so caching does not eliminate the cited scenario automatically.

**A-C2:** accept the sign-in-return gate, including a new browser context while explicitly excluding draft transfer.

**A-C3:** accept the return-destination example; reject the version example as a documentation contradiction. All current docs consistently choose one version for content/moderation. The safeguard's user cost is a tradeoff addressed in Round 2, not evidence of drift. Consolidate normative ownership when fixing accepted seams; no wholesale rewrite of historical decisions.

Proposed architecture outcome: retain topology and selected features; accept return-destination carrier, publication acknowledgement/draft preservation, bounded search work, independent background-progress observation, explicit pre-auth abuse limits and early integration gates. Keep one content version; keep successful-vector caching optional. Session-renewal/logout is a verified pinned-template seam requiring a tested bounded adaptation, not a one-line claimed solution. Precise liveness and session details can be carried into backend review with explicit acceptance criteria.

Source check for A-F5: Codex independently inspected both the linked v1.8.1 template and GitHub's latest reported release, v1.8.14. In [v1.8.14 auth.ex.eex](https://github.com/phoenixframework/phoenix/blob/v1.8.14/priv/templates/phx.gen.auth/auth.ex.eex), lines 49–60 revoke/disconnect the current token only; lines 94–119 issue a fresh token without consuming the predecessor. The older-token seam is therefore not merely an obsolete-template assumption. No generated application or browser reproduction has been run here. Backend review must address simultaneous renewals, cookie/disconnect ordering and same-browser logout without assuming an untested token-deletion patch solves them.

## Fable (McCord lens) — Round 3: dispositions on Codex Rounds 2–3 and convergence proposal

Applying the owner clarification: every disposition below counts the user's repeated actions and manual recovery, not only code removed. Where Codex's counterexample is valid I say so and move to the smallest fix that keeps the safeguard and removes the user effort.

### A-C4 — Accept Codex's invariant in full; withdraw the own-retry exception; put the equivalence test in the backend

Codex's counterexample is valid: with storage unavailable there is no CAS, A and B both submit different payloads under K, B commits Y, A's X loses confirmation, A retries fixed X and receives `:existing`. "This is my retry" does not mean "my payload won." The unique key erases that. Withdrawn.

Converged rules:
1. Publish is a draft write: flush under the `(draft_id, revision)` compare-and-set before submitting; on mismatch show the existing conflict/reload state and do not submit. Skipped only when storage is unavailable (existing exception).
2. `:existing` never destroys unconfirmed local values on identity alone. Equivalence is established by the backend, not the browser: on the `:existing` path `publish_*` compares the submitted fields against the stored publication with the same whole-edit comparator that already decides no-op edits (backend:144, :390: text, tag, setup, staged video ids and order, image slot count and descriptions) and returns `:existing_equivalent` or `:existing_divergent`. New image bytes cannot be compared (media rows hold no filename or hash), so a submission carrying new image files is divergent unless the stored publication has no images and the submission none. Frontend clears only on `:existing_equivalent`; on `:existing_divergent` it preserves input, pauses autosave, links the published item and its Edit form, and offers the existing confirmed Discard. No digest column, no request log, no browser-side content diff.

User-effort accounting: the common single-tab lost-confirmation retry (the reason submission keys exist) still resolves with zero user actions, because it is equivalent. Only a genuinely divergent payload costs one decision, and never a retype.

Two-tab acknowledgement trace under the converged rules:
1. Tabs A and B hold key K at revision 5 with text X. B autosaves Y → revision 6.
2. A clicks Publish. Flush CAS at (K, 5) fails. A shows "another tab changed this draft" with reload. Nothing is published. Effort: one reload click in A, or continue in B.
3. Storage-unavailable variant: A has no CAS and publishes X → `:created`. B publishes Y → `:existing_divergent` (body differs). B preserves Y, shows the published X with Edit and Discard. Effort: one decision; Y is not retyped.
4. Single-tab lost confirmation: retry with fixed values → `:existing_equivalent` → draft cleared, publication opened. Effort: zero.
5. Codex's race: A's X loses confirmation, B commits Y, A retries X → `:existing_divergent` → A preserves X. Correct.
6. Original hidden or deleted: state shown, draft preserved, same Edit/Discard path where permitted.

Routing: backend specifies the comparator reuse and the two outcomes; frontend specifies the divergent-state screen.

### A-F2 — Accept Codex's ABA trace; keep one version and the hide bump; remove the author's manual reapply where it is a false positive

The NULL→hidden→NULL trace is valid: a visibility compare cannot see C's restore, and A's stale hide would silently undo a later moderator decision. Keep the single `edit_version` and the bump on hide/restore/bulk hide. My Round 1 fix is withdrawn.

What remains is the user cost I raised: an author mid-edit gets a conflict whose cause changed nothing they can see, and frontend:226 then asks them to reapply by hand. Under the owner's principle that is exactly the complexity we must not push onto the author. Smallest fix, no second version, no merge: the editor already holds its base snapshot from `get_edit_form` and keeps a read-only reference on conflict. On a stale-version rejection it fetches the latest via `get_edit_form` and compares the author-editable fields of latest against its base (text, tag, setup, attachment ids, order, descriptions). If they are equal, the change was visibility-only and the editor offers one action, "Save at current version," which resubmits the same values with the new expected version. That is a fast-forward, not a rebase: no author-visible field moved, so nothing can be lost. If they differ (retag, destroyed media, another author tab), the existing manual path stays. Route the compare to the frontend phase; the backend contract is unchanged.

Checks: author edit at v1, moderator hides, author saves → conflict → latest equals base → one click saves, `dead_at` preserved. Moderator retag between → latest differs → manual path with the moderator's tag visible. ABA trace → A's stale hide rejected on version.

### A-F3 — Accept Codex's invariant; drop my completeness claim and the in-scan alert

Correct on all three points: queue-running is not cron-running or progress; a stopped scan cannot report itself; once-until-clear needs state. The observer must be independent of the work it checks and must not blur the public probe's meaning.

Converged check, using facts the system already writes: one bounded read-only routine, `check_jobs`, that reads `oban_jobs` for the most recent completed job of each periodic worker (embedding scan, media expiry, maintenance) and fails if any is older than twice its cadence; and counts aging unfinished work: `media` rows with `cleanup_at` older than 24 hours, and search rows still `embedding IS NULL` with `text_at` older than a threshold. Expose it as a second route, separate from the public app-and-DB probe, whose documented meaning stays "up," and as a release command the existing host cron (the one that runs `pg_dump`) can execute. The operator points one existing monitor slot at the route or at the cron result; no particular paid service is required, and alert deduplication belongs to the monitor, not the app. Provider-specific embedding failure is distinguished by the aging-rows count while the recency check stays green. Thresholds and the exact queries go to the backend phase with an acceptance test: pause a queue, remove the cron entry, and expire the embedding credential, each detected separately; the public probe stays green throughout.

### A-F4 and A-C1 — Accept consolidation; withdraw mandatory caching; correct my cancellation claim

Verified against the current LiveView docs: "If there is an in-flight task with the same `name`, the later `start_async` wins and the previous task's result is ignored." Cancellation is only what `cancel_async/3` does, which "will be killed with the provided reason." So frontend:82's "let superseded work finish" describes the framework correctly, and one in-flight retrieval per view needs one explicit `cancel_async` before starting the next. Codex is also right that a cache cannot satisfy my strongest check: failures are not cached, and misses during a slow call stay misses without single-flight coalescing. Withdrawn as mandatory; successful-vector reuse stays optional as documented.

Converged bound: a finite total search deadline per request (embedding timeout about one second, tunable, because the keyword branch exists); one in-flight retrieval per view via explicit cancellation; the embedding client's own pool with bounded queue wait as the provider budget shared with the scan; the existing database pool and two-second statement timeout. Measure slow-provider SSR plus connected retrieval plus a running scan together. No admission layer or process. Slow-provider user cost: about two seconds to results, then keyword results, with no reader-facing notice.

### A-F5 — Accept Codex's bounding; carry to backend with two candidate adaptations and acceptance criteria

Source: `priv/templates/phx.gen.auth/auth.ex` at Phoenix v1.8.1: `maybe_reissue_user_session_token` → `create_or_extend_session` generates a new token and does not delete the previous row; `log_out_user` deletes only the current token and broadcasts on the current `live_socket_id`. Re-verify against the pin chosen at implementation. Codex's concurrent-renewal point is right: two simultaneous renewals of T1 produce T2 and T3, the cookie keeps one, and the other is an orphan exactly like T1 is today, so "delete the superseded row" narrows the seam without closing it. Not one line.

Backend phase evaluates two bounded adaptations against one contract, "after logout in this browser, no LiveView mounted from this browser can re-admit": (a) delete and disconnect the superseded token on renewal, documenting the concurrent-renewal orphan as the generator's residual bounded by the 60-day expiry; (b) renew by extending the existing row's `inserted_at` in place so the token id never changes and logout revokes every LiveView holding it, at the cost of periodic token rotation. No session-family table.

### A-F6 — Accept Codex's narrowing

Sign-in, resend and email-change requests, including connected LiveView events, count as pre-authentication writes: check the limit before creating a token or sending mail, key by address and by client IP, reuse the app limiter, and keep the edge rule as a second layer. Backend detail.

### A-C3 — Accept Codex's rejection of the version example

The documents do consistently choose one version; my point was scope wording, which is not a contradiction. A-F1 stands as the concrete example. Disposition unchanged otherwise.

### A-C1 — Accept Codex's corrections

Cancellation corrected above; pool size is not request concurrency under multiplexing, so the provider budget is the client's configured concurrency and bounded wait, not connection count.

### Disposition table

| Finding | Final disposition |
|---|---|
| A-F1 return destination | Accepted by both. One validated destination carried through the whole sign-in path, checked against allowed routes in TipsWeb; destination only. Editors and settings behind the authenticated live_session; other public boundaries permitted. |
| A-F2 version bump on hide | My fix withdrawn (ABA). Keep one version and the bump. Add frontend fast-forward when latest author-editable fields equal the editor's base. |
| A-F3 background liveness | My completeness claim withdrawn. Independent `check_jobs` over `oban_jobs` recency plus aging cleanup and embedding rows; separate from the public probe; thresholds to backend. |
| A-F4 double retrieval | Mandatory cache withdrawn. Consolidated into A-C1's bounded search work. |
| A-F5 renewal/logout | Verified seam; to backend with the stated contract and two candidate adaptations. |
| A-F6 pre-auth limits | Accepted as narrowed by Codex. |
| A-F7 deploy × images | Accepted tradeoff. |
| A-C1 | Accepted as narrowed: explicit cancellation, client concurrency, DB pool, total deadline. |
| A-C2 | Accepted with the sign-in-return gate; no draft transfer. |
| A-C3 | Accepted with the return-destination example only. |
| A-C4 | Accepted in full as converged above. |

### Proposed joint architecture conclusion

Topology: one Phoenix release, `Tips.Accounts` and `Tips.Content`, Postgres owns business state, Oban owns attempts, the page owns interaction state, browser storage owns drafts. No new process type, table, service, draft store or admission layer. All owner-selected features retained.

Architecture invariants agreed for the backend and frontend phases:
1. Return destination: one validated local destination travels with the sign-in request, the emailed link, confirmation and the controller redirect; validated against allowed routes in TipsWeb; never drafts or pending actions. Editors and settings sit behind the authenticated live_session boundary.
2. Publication acknowledgement: Publish flushes the draft under the local CAS first; `:existing` never destroys unconfirmed local values on identity alone; equivalence is decided by the backend's existing whole-edit comparator; divergent results preserve input and offer the published item's Edit and Discard.
3. One content version for author and moderator writes; hide/restore keep the bump; the author's conflict UI fast-forwards when latest author-editable fields equal the editor's base, otherwise manual reapply.
4. Bounded search work: total per-request deadline, one in-flight retrieval per view via explicit `cancel_async`, provider client concurrency with bounded wait shared with the scan, existing DB pool and statement timeout; vector reuse optional.
5. Independent background-progress observation: a bounded read-only check of periodic-job recency and aging unfinished cleanup/embedding rows, separate from the public app-and-DB probe, runnable from a route and from the existing host cron.
6. Pre-authentication limits on sign-in, resend and email-change requests, before token or mail creation, by address and IP.
7. Session renewal/logout contract: after same-browser logout no LiveView from that browser re-admits; backend selects between the two bounded adaptations with tests.
8. First slice gates: text publish/edit with lost confirmation and same-browser recovery; one image surviving a known rejection; one private video through provision → transfer → completion → ready → publication → hide/delete; sign-in completed in another browser context returning to the intended destination; pinned search extensions evaluated alongside.
9. Documentation ownership applied when fixes land; one diff of the UX consensus tables against the contracts.
10. Accepted tradeoffs: deploy interruption forces image reselection; public R2 and signed Stream links revoke differently; hidden tips' reviews are reachable by permalink and profile but not search; rankings drift across pages; duplicate initial retrieval within the bound above.

Routing: backend phase owns 2 (comparator and outcomes), 4, 5, 6, 7 and the session/health acceptance tests; frontend phase owns 1's LiveView side, 2's divergent-state screen, 3's fast-forward, and the cancellation wiring in the search LiveView.

If Codex accepts this list, I consider the architecture phase at consensus and ready for the backend file.

## Codex closure — architecture consensus after Round 3

I accept Fable Round 3's proposed joint conclusion as the architecture direction, with the following implementation precision carried into the named later phases. These narrow guarantees; they do not reopen the topology or accepted findings.

- Publication comparison must distinguish **equivalent**, **different** and **cannot establish equivalence**. Treat the last two conservatively for draft preservation. A missing recovered image slot is not an empty attachment selection. Use current authorized state; never expose author-deleted original fields to compare in a page. A text-only fixed retry can clear automatically when equivalence is established; image-bearing retries may need the preserved-reference path. Do not promise every lost confirmation needs zero user action.
- Accept the one-click author conflict improvement when a complete original base and latest author-editable fields establish that no editable field changed. It must be an explicit action submitting the latest expected version, with normal server guards; no automatic replay. The frontend phase must specify how the original base survives draft restore and what happens when it is absent. This necessary complexity earns its place by avoiding manual retyping; it must not weaken the moderator ABA guard.
- The worker health threshold must include bounded maximum scan runtime, queue delay and deployment/startup grace, not mechanically twice the cron cadence: fifty timed-out row calls can exceed two minutes. Inspect only relevant eligible search rows. Backend will settle the minimal check and avoid duplicate monitors/alert paths.
- Same-browser logout is an acceptance requirement, not an endorsement of either untested adaptation. Do not accept an orphan-session exception that violates that requirement or silently trade away token rotation; backend will evaluate the candidates and choose a tested design recommendation.
- Cancellation reduces wasted local work; it cannot promise the provider retracts a request already received. Configure request concurrency, waiting and full operation deadlines, not connection count alone. No claim of a measured two-second response before integration testing.

**Phase status: consensus.** Codex and Fable have exchanged and challenged three numbered rounds each. Accepted architectural work: A-C4 acknowledgement/draft safety; A-F1 destination carrier; A-C1/A-F4 bounded search; A-F3 background progress; A-F5 session lifecycle; A-F6 pre-auth limits; A-C2 early vertical checks; A-C3 contract ownership. A-F2's unsafe removal of version bumps and A-F4's mandatory cache were rejected. A-F2's safe explicit shortcut proceeds to frontend review. No unresolved architectural disagreement remains; concrete backend/frontend contracts are the remaining review work.
