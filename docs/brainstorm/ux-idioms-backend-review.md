# UX conventions and simplification — backend

Date: 2026-09-20. Status: revised recommendation consensus after the user-effort reassessment below. Earlier review: two substantive rounds, closing ratification and cross-phase reconciliation. Final recommendations are adopted in the technical design documents; application implementation remains outstanding.

## Adoption status

The owner authorized applying the final consensus to the technical designs. The data model, backend and frontend contracts now incorporate the final reassessment plus the review-setup override below; the architecture overview is aligned. The attributed debate remains historical, including statements that source documents had not yet changed. Design adoption does not mean the application or integration tests are implemented.

## Final cross-page consistency pass

2026-09-20. Two-round Codex/Fable audit. The owner authorized applying these recommendations, and they are now adopted in all three technical designs. Findings and line references below describe the pre-adoption state; application implementation remains outstanding. See the [cross-page matrix](ux-idioms-architecture-review.md#final-cross-page-consistency-pass).

- **Filter navigation:** backend-design.md lines 77–81 leave tag-link destination/context ambiguous and offer clear-all search filters that frontend discovery does not explicitly provide. On browse/search, a curated tip tag/model link should set that dimension, preserve other filters and the submitted query or applicable sort, and reset page one. From tip/profile metadata, it should open browse with that dimension and default Hot. Free-text model names have no exact-filter predicate (`model_other` versus `model_id`, data-model.md rule 6 and Browse query); render them as plain text. Reviewer setup remains distinct from tip-filter navigation. Use Clear filters for resetting the current filter group, retaining query and sort. No new search mode or schema is needed.
- **Selected review:** Individual review links plus frontend-design.md's Show all reviews contract do not say what happens to explicit reviewer filters. Recommend dropping selected review, review page and reviewer filters while retaining review sort. Normal list controls do not apply to selected-review mode.
- **Feed voting:** data-model.md Read groups and Browse fetch viewer votes, and frontend-design.md Paged reading lists supports row vote updates, but feed-row UI lists only a score. Preserve the implied voting capability: compact Helpful / Not helpful actions using the same selected/pending/authentication behavior as detail, while the summary retains net score. Do not remove the vote read and add a required tip-opening step just to simplify implementation.
- **Report authentication:** reporting requires current account eligibility, but the frontend lacks voting's explicit signed-out flow. Preserve a validated local target through sign-in, reopen the reporting interaction, and require explicit submission; never send a report as a side effect of authentication.
- **Small projection/wording fixes:** search excerpt sources include body, while frontend labels omit Review; return/use an unambiguous source label. Sort URL parameters apply only where the user can sort; search remains fixed relevance. Existing-review action capabilities should support the same authorized Edit/Delete actions in ranked and selected views.

These recommendations preserve the settled schema, ranking formulas, filtering predicates, visibility, publication and recovery invariants. The data-model comment at line 485 already says Clear; Fable's first-round citation of View all reviews was stale and was withdrawn in round two. First page versus Previous was rejected as a false contradiction between document layers.

## Owner decision — prefill review setup

The owner selected this behavior after the reassessment: a fresh review starts with the tip's model and environment, including a free-text model. Both fields remain optional, editable and clearable. If the tip leaves a field unspecified, the review starts with that field blank. Show brief guidance to check that these values match the reviewer's own attempt; no separate Same-as-tip button or confirmation step is needed.

Initialize these defaults only once for a fresh form. Restored drafts, reconnects and existing reviews retain their own values, including deliberate blanks. Publishing stores the submitted values independently; later tip edits never overwrite review setup. This supersedes the blank-default and explicit-fill recommendations in the attributed review history below. The technical data model, backend and frontend already specify this prefill behavior; it remains the selected design, not a claim of implemented UI.

## User-effort reassessment

The [owner's governing principle and architecture reassessment](ux-idioms-architecture-review.md#user-effort-reassessment) supersede arguments based only on fewer columns, workers or operations. The technical documents now include the principle; their selected behavior remains unchanged. Earlier consensus below is historical where reopened here.

### Codex reassessment round 1

For native video, retain managed encoding and resumable direct uploads. Reject requiring a user to press Publish repeatedly to discover readiness, restarting an interrupted transfer solely to remove a dependency, or making unpublished video public to remove signing. Candidate simplification: bounded, asynchronous server-side status checks while an editor is active, automatic UI updates, and a fresh check on reopening; avoid a separate continuous background status scan if no off-screen workflow needs it. Cleanup remains durable and independent of whether an editor is open. This is a proposal, not an adopted contract.

Challenge Fable's proposed weekly orphan-sweep equivalence: creation plus 48 hours is not completion plus 48 hours, and a weekly sweep does not enforce a precise expiry. A lost provider-creation response and cleanup racing publication still need a defined resolution. Sharing a cleanup mechanism can be sound, but deleting deadline/ownership/target guards without replacing their guarantees is not established as safe. Keep current recovery behavior until a smaller replacement is specified end to end.

Preserve exact model/environment query capability while architecture revisits control design. Retain idempotency, permission checks, edit conflicts, moderation freshness checks and notification counters where they prevent user-visible mistakes. Existing simplifications to shadow bans, invalidated votes and report bookkeeping must preserve their previously documented outcomes; the new principle alone does not reverse them. Bilateral reassessment is pending.

### Fable reassessment round 1 (synopsis)

Proposed, then largely withdrew, four lean-video levers against backend-design.md:259–331: manual readiness check at Publish (withdrawn: pushes waiting onto the author), basic POST under 200 MB (withdrawn: resume protects mobile users), public playback (withdrawn: unlike images, videos exist unattached for up to 48 hours), and folding expiry into the orphan sweep (withdrawn: creation-plus-48h is not completion-plus-48h and the provisioning and cleanup-versus-publish guards address real races). Kept: inline signed player; reopened exact model and environment predicates as retained capability with simpler controls.

### Fable reassessment round 2 — contracts I now accept

- **Readiness.** No global status scan and no webhook. While an editor has pending videos, the editor's LiveView runs one bounded asynchronous cycle: concurrent provider reads for that editor's pending uids with a small concurrency cap and a per-call timeout, each result applied through the existing guarded Media write, next cycle only after completion, one refresh read on reopen. Timeout leaves state unchanged. `checked_at` and `media_status_scan` are removed; the scheduled cleanup retains its provider read for deadline resolution.
- **Publish.** Trusts committed ready rows. Refreshes only pending attachments before deciding; provider outage returns `:media_pending` for those and never regresses ready ones. Commit-time ownership, eligibility and readiness locks unchanged.
- **Lifecycle.** All current deadline, ownership, target and conditional-uid guards retained.
- **Filters.** Model and environment predicates and indexes retained for browse and search (data-model.md:452, :761) behind immediate native selects. Review-list model and environment predicates retained (data-model.md:489–492), opt-in with All default including reviews that reported no setup; the response labels the narrowing as "reported setup".
- **Reviewer setup.** Blank default stands; a Same-as-tip fill is a frontend action that submits ordinary values, so no backend inheritance rule returns.
- **Profile.** Single union list with `kind` filter parameter (all, tips, reviews) over the same ordering.

Shadow-ban, invalidated-vote and report-bookkeeping simplifications keep their documented outcomes. No remaining backend objection.

### Codex reassessment round 2 — closure

Accept Fable's revised contracts. Retain Stream, tus, signed access, trusted readiness/duration, ownership/target checks, publication idempotency and existing recovery/cleanup deadlines. Recommend removing the global readiness scan and its rotation bookkeeping, replacing it with bounded asynchronous pending-video refresh while the editor is open and on reopen. A ready row is not demoted by an outage or stale response; readiness never authorizes attaching an expired, removed or ineligible asset. Cleanup remains scheduled and may query the provider to resolve deadlines independently of the editor. Do not replace completion-based recovery with a weekly age sweep.

Keep direct reads asynchronous and nonoverlapping, with small concurrency bounds, per-call timeouts and rate-limit/backoff handling. Leave writing responsive while multiple attachments are pending. When refreshing at Publish, first reconcile any previously successful publication by its submission key; already trusted ready state needs no extra provider round trip. A new ready result passes existing guarded writes before the publication transaction rechecks current eligibility. No webhook or background auto-publication is added.

Retain exact setup query predicates and supported indexes; preserve all-default inclusion of reviews with unspecified setup. As subsequently selected by the owner, initialize fresh review fields from the tip once, then store submitted values independently; cleared fields remain unspecified and later tip edits never propagate. Profiles keep the shared ordering with an optional type predicate. Preserve all other prior recommendations unless explicitly superseded in this addendum.

**Verification required during implementation:** multiple slow provider responses do not block typing; rate limits do not trigger a hot retry loop; reopen discovers an off-screen completed upload; timeout does not become encoding failure; repeated Publish yields one item; a ready upload can publish during a provider status outage; cleanup cannot delete a concurrently attached video; signed access follows current visibility with the existing bounded token lifetime. No migration or runtime test was run here.

### Fable reassessment round 3 — ratification

Verified against my round 2; no discrepancy. Ratified: Stream, tus, signed access, trusted readiness and duration, ownership and target checks, idempotency and existing deadlines retained; global readiness scan and rotation bookkeeping removed in favour of bounded, asynchronous, non-overlapping pending-video refresh with per-call timeouts and rate-limit backoff while the editor is open and on reopen; a ready row is never demoted by an outage or stale response; Publish reconciles a prior successful submission key first and trusts committed ready state without an extra provider round trip; cleanup stays scheduled and may read the provider for deadlines; no weekly age sweep replaces completion-based recovery. Exact setup predicates and indexes retained with All-default inclusion of unspecified setups; Same-as-tip submits ordinary values; profile type predicate optional. The verification list is accepted as unexecuted. Reassessment closed.

## Historical recommendations before the user-effort reassessment

| Change | What disappears / what remains |
|---|---|
| Defer shadow bans | Remove shadow visibility and automatic unban restoration; keep explicit bans, deletion rights and deliberate moderation |
| Delete invalidated votes | Remove `votes.dead_at` and dead/live transitions; keep transactional counters and locking |
| Permit one open report per reporter/item | Remove report-specific author revisions and stale-report forms; allow fresh reports after resolution; accept delayed-retry duplicates |
| Start reviewer setup blank | Remove copied assumptions about the model/environment used; preserve drafts and explicit selections |
| Reduce media to images/GIFs | Remove Stream/video lifecycle; retain ordered ownership, cleanup, publication safety, optional descriptions and trusted motion classification |
| Propagate simpler discovery/editing | Remove structured setup filters, tip edit deadlines and accumulated lists; keep metadata, bounded page reads and edit conflicts |
| Simplify review/profile reads | Single-review destinations, lightweight own-review capability lookup, live own review at rank and one mixed profile list |

**Keep:** seven-day unfinished-signup expiry; moderator content-version and reviewed-report-set guards; targeted media-removal UI; no-op edit detection; notification race counters; publication idempotency and local draft protection.

**Why guards differ:** a duplicate report adds queue work without automatically hiding content. A stale moderation dismissal can silently lose unread evidence; uncertain publication can duplicate a user's post. Those outcomes justify different safeguards.

[Architecture decisions](ux-idioms-architecture-review.md) and [frontend details](ux-idioms-frontend-review.md) form one recommendation set. Earlier proposals below that conflict with this summary were challenged and superseded; no technical source has been updated.

Use the [architecture review protocol](ux-idioms-architecture-review.md). Review the smallest backend/data contracts that support conventional user journeys, and states/operations that can be removed. Append attributed rounds; stop at explicit consensus or ten rounds. Source documents remain unchanged.

## Codex Round 1 — candidates prepared while architecture is under review

These candidates apply conditionally to the architecture recommendations. Source anchors refer to `docs/design/technical/`. No implementation is claimed. Architecture-scope changes remain subject to Fable's challenge here and the whole-journey check.

### B1 — Change: defer shadow bans; keep explicit full bans and content moderation

- **Anchor/scenario:** data-model.md:15, :32, :75–87, :132, :174; backend-design.md:438–446. A small launch community carries two ban modes, three content-visibility causes, author-only shadow projections, and a special bulk restoration transaction on unban. Its visible product job is preventing abuse while preserving reviews and deletion rights.
- **Whys:** Why a separate shadow state? To suppress contributions without telling the author. Why silent suppression? To slow adversaries. Why an MVP need? No measured evasion problem is supplied. Why does it reach every read/write path? Suppressed authors see a different truth. Why preserve a separate marker? Unban must not undo deliberate hides. Why does that restoration exist? Because shadow publication was added. Two more whys leave the same root: a sophisticated abuse response creates product-wide state before the abuse pattern is demonstrated.
- **Classification:** optional product/abuse policy, not a standards violation. This is not a claim that social platforms never use shadow bans.
- **Replacement/removal:** MVP supports normal accounts and explicitly banned accounts. Ban blocks contribution and permits reading, sign-in and deletion as already specified. Retain deliberate moderator hide/restore and author deletion. Remove shadow publication, `shadowed_at`, per-author shadow projections, and unban's content-restoration participant. Lifting a full ban changes account eligibility only; it does not reveal previously moderated content or revive invalidated votes.
- **Costs/loss:** loses covert abuse suppression; a banned spammer can learn the decision and create another account. Existing rate limits, verified email, reports and explicit moderation remain. Do not add automatic moderation, trust levels, ban appeals or device tracking to compensate.
- **Effects:** all live predicates/views/indexes/counters/search/media access consistently use deletion + deliberate hide. Keep account locks that serialize publication against bans and moderation; keep bulk moderation/vote invalidation locks for operations that remain. This is not permission to delete the shared visibility projection or stale-session admission guard.
- **Acceptance:** ban during an open editor refuses publication without losing text; own-content/account deletion works; unban enables contributing while hidden/deleted content and invalidated votes remain unchanged; public projections never expose hidden text.

### B2 — Change: leave a new review's optional setup blank

- **Anchor/scenario:** backend-design.md:364; frontend-design.md:273. A reader tests the tip on a different model but posts the inherited setup without noticing. The system creates a false first-hand claim from the tip author's metadata.
- **Classification:** product/data-integrity choice, not a web-standard violation. Optional setup is the reviewer's own report; lack of a value is more honest than an unconfirmed guess.
- **Replacement:** fresh review form starts with no model/environment. Use “Model used (optional)” and “Environment used (optional).” Restored drafts and edits retain their own values, including blanks. Do not add a “same as tip” toggle or inherited/suggested/confirmed tri-state. Display existing tip setup in context, not as saved reviewer data.
- **Removed/new costs:** deletes initial inheritance, free-text copy and inherited-value explanatory copy. Requires authors with matching setup to select it themselves; some will omit metadata. With structured filters removed, metadata remains helpful search context rather than a promised exact retrieval facet.
- **Effects/acceptance:** publish an untouched fresh form → review has no setup; publish explicitly chosen setup → appears in reviewer-labelled metadata and review search text; restore/edit blanks → remain blank despite later tip edits. No authoring operation guesses what the reviewer tested.

### B3 — Scope propagation: simplify media without breaking image ownership and cleanup

- **Anchor:** data-model.md:216–263; backend-design.md:239, :251–257, :337–362.
- **Correction to architecture U5:** image rows are attached in the publish transaction; image objects exist in R2 before that transaction. There is no staged-image media-row lifecycle in the current schema. Earlier Codex shorthand “staged images” meant these pre-commit objects, not new staged database rows.
- **If video is deferred:** remove Stream-specific columns, operations, signing, worker polling and expiry. An image-only row still needs owner, exactly one parent, object key, ordered position, cleanup marker, key uniqueness and slot uniqueness. `kind` can disappear if all retained uploads are images. Keep durable removal of attached images and orphan handling for failed/unknown publication uploads; keep unknown-outcome reconciliation before deleting files. Do not move images to upload-on-selection to imitate removed videos.
- **Alternative text:** add a nullable per-image plain-text description field; rendering/authoring requirements settled in frontend phase. Author edits to descriptions use the existing whole-content edit/version transaction and draft slots. Do not accidentally permit modifying another user's media or reassociating it. Description text does not need a new search branch or automatic embedding/OCR.
- **Motion:** if the frontend selects static-only images, validate decoded file content, including animated WebP and APNG; reject unsupported animation with actionable copy before publication. Do not flatten animation silently and destroy evidence. Exact library and resource limits are implementation choices requiring a real fixture check.
- **Acceptance:** uncertain publish leaves possibly committed image objects intact; same-key retry produces one post; deleted media eventually cleans up; image reordering and description edits preserve association and slot rules; a renamed animated file is not accepted as static. Costs: one description field and image-content checks; these directly enable the retained evidence type.

### B4 — Keep report revision guards; reject a superficially simpler retry policy

- **Anchor:** backend-design.md:420–428; data-model.md:267–293.
- **Challenge:** allowing one open report per reporter/target and deleting `author_revision` looks simpler. But after resolution a delayed retry can open a new report. Fixing it requires a separate durable report submission key and lifecycle; “one report ever” instead prevents reporting harmful later edits, especially with indefinite tip editing. Dropping deduplication is not a UX simplification.
- **Disposition:** keep current one-open + author-revision uniqueness for MVP. Keep the previous correction: distinguish a newly saved report from an existing receipt; do not say changed explanation was saved when returning the old report. State the product limit plainly when a resolved unchanged revision cannot be reported again. New evidence without an author edit is a retained limitation, not a resolved workflow.
- **Effects/acceptance:** duplicate retry across edit/resolution returns original receipt; a genuinely edited target allows a fresh report only after the old one resolves; moderator retag does not impersonate an author edit. No status dashboard, appeal queue or generic request-log table added.

### Required propagation of architecture decisions

If agreed: remove tip edit-deadline results/queries/tests, retaining current ban/version/visibility checks; retain author `edited_at` distinct from moderator retagging. Remove model/environment retrieval predicates and filter options while retaining metadata tables and values. Add review setup text to the existing search document. Map search page to existing final offset, with no snapshot/cache/session table. Combining registration fields does not remove server-side handle uniqueness, registration-expiry reclamation or safe magic-link destination validation.

Preserve notification fold counters even if numeric notification copy is removed: they detect events racing mark-read. Preserve idempotency keys, CAS draft identity and optimistic edit checks. These are necessary safeguards, not unfamiliar user-facing features to cut.

### Pre-debate alignment after architecture Codex Round 3

Pagination recommendation now covers **browse as well as search**. Browse uses current Hot/New order, twenty results, offset and one-row lookahead, without the search candidate cap or an arbitrary fifty-page cap. Remove browse seen sets and scan-past-duplicates machinery; accept cross-page movement explicitly. Profile, inbox and review keysets stay. Optional image description is now the proposed smaller authoring interaction; missing alternatives remain an accessibility limitation rather than a solved standards gap. Media animation mechanism remains for frontend closure.

## Fable Round 1 — independent candidates and challenge to Codex B1–B4

Anchors are `file:line` in `docs/design/technical/`. Architecture dispositions (one-form signup, indefinite edits, technique select only, video deferred, pages for browse and search, local drafts kept) are taken as given. Codex's candidates are `C-B1..C-B4`; mine are `F-B1..F-B4`.

### C-B1 shadow bans — Accept, and extend to vote invalidation

The why-chain holds: two ban modes and three visibility markers exist for an adversary the MVP has not met, behind Turnstile, verified email and an invited group. Removing `shadowed_at`, the viewer-specific counter adjustment (data-model.md:514), the dead self vote and unban's restoration participant is a clean subtraction. Extension (F-B2 below): once shadow votes are gone, `votes.dead_at` has one remaining user, the moderator bulk "invalidate votes" operation, and that operation can be a delete.

### C-B2 blank reviewer setup — Accept

Prefill from the tip (backend-design.md:364; frontend-design.md:273) manufactures a firsthand claim and drags an "initialize once, never reapply" rule set behind it. Blank default with "Model used (optional)" is honest and smaller. With structured filters gone, the only cost is thinner metadata in search text. Disposition: change.

### C-B3 media scope — Accept the correction and the image-only row

Correct: images have no staged rows (data-model.md:238–243). Image-only `media` keeps owner, one parent, key, position, `cleanup_at`, plus the optional description column; `kind`, Stream columns and four constraints go. Images stay upload-on-submission. Static-only versus user-initiated animation is the frontend phase's call; if static-only, validate decoded content. Disposition: change.

### C-B4 report guards — Reject the keep; see F-B1

Codex argued against a simplification nobody proposed and kept a mechanism whose only failure case is rare and harmless. Costed below.

### F-B1 — Change: drop `author_revision` and revision-bound re-reporting; keep one open report per reporter and target

- **Source.** data-model.md:111, :149 (`author_revision` on both tables), :275, :285–288 (two permanent revision indexes plus two one-open indexes), :618–628 (revision-bound insert, "resolved-row precheck alone is unsafe"); backend-design.md:384 (whole-edit change detection to decide whether to bump it), :426 (re-report only after resolution *and* an author edit), :436 (moderator retag must not bump it); frontend-design.md:223 (stale-form flow that asks the reader to review current content).
- **Scenario.** A reader reports a tip. A moderator dismisses it. The reader later finds the same tip still harmful; the site refuses a second report until the author edits, and Codex records this as "a retained limitation". Meanwhile every author edit must decide, across text, tag, media membership and order, whether it counts as an author change, and every report form carries a revision that can go stale.
- **Whys.** Why bind reports to a revision? So a resolved report on old text does not block a report on new text. Why would it block? Because one-open-per-target plus "resolved means done" would refuse repeats. Why refuse repeats after resolution at all? To stop a lost-confirmation retry from creating a second report after the moderator resolved the first. How often? The retry window is minutes on an open form; resolution takes hours or days. What is the harm of the duplicate? One extra row a moderator dismisses. Two more whys stay on *a permanent revision column guarding against a rare, harmless duplicate*.
- **Classification.** Product preference. Reddit and Discourse let a user flag again after a flag is handled; neither ties the flag to a content revision.
- **Replacement.** Keep only `flags_open_tip` and `flags_open_review` (one open report per reporter and target). Insert; on conflict return the existing receipt with the agreed "already recorded, nothing added" copy. After resolution a new report is allowed whenever the reporter chooses. Report insert binds to nothing but the target.
- **Disappears.** Two columns, two unique indexes, the whole-edit change detector that decides when to bump the author revision, the moderator-versus-author revision distinction, the stale-revision form flow, and the "cannot re-report without an edit" limitation. **Appears.** A possible duplicate report when a retry lands after resolution; dismissed in the queue.
- **Effects.** Backend: `report_content` loses a parameter and a revision check; edits lose one increment rule. Frontend: the report form has no hidden revision. Moderation: the queue may show a second report from the same person on an unchanged item, which is also what "I still think this is harmful" looks like.
- **Acceptance.** Report, resolve, report again: two rows. Retry while open: one row, existing receipt. Retry after resolution: second row, new receipt, moderator sees both.
- **Disposition.** Change; owner decision only in that it drops a guard the earlier reviews reproduced as correct. Correct is not the same as needed.

### F-B2 — Change: drop `votes.dead_at`; invalidation is deletion

- **Source.** data-model.md:208 (`dead_at` "cast while shadow-banned"), :316–319 (trigger branches on `dead_at`), :548 ("If an unbanned user votes again, their previously dead vote becomes live"), :614 (bulk invalidate sets `dead_at`), :32 ("Unban does not revive invalidated votes"); backend-design.md:446.
- **Scenario.** With C-B1 accepted, a vote is never cast dead. The column's only remaining job is a moderator stripping a banned account's votes, and the trigger still has to reason about dead-to-live transitions on every vote.
- **Whys.** Why keep dead votes as rows? So unban could revive them under shadow rules. Why after C-B1? No reason; unban does not revive invalidated votes anyway. Two more whys do not move.
- **Replacement.** `delete from votes where user_id = $1` under the existing account and target locks; the trigger subtracts. The self-vote rule is unchanged. `votes` becomes `(user_id, target, value, created_at)`.
- **Disappears.** The column, both trigger `dead_at` branches, the live-to-dead vote transitions and their tests, and the viewer-specific counter adjustment already removed with C-B1. **Appears.** Nothing; deletion is the existing removal statement.
- **Loss.** Invalidated votes are not retained for forensics. `votes_by_tip` investigation reads (data-model.md:376) lose them; moderators keep the ban record.
- **Acceptance.** Ban plus invalidate: counters drop by the account's live votes; unban: counters unchanged; the trigger has no `dead_at` reference.
- **Disposition.** Change.

### F-B3 — Change: drop the seven-day registration expiry and its cleanup job; reclaim inline only

- **Source.** backend-design.md:472–474 (seven-day deadline, Oban maintenance deletion, verification checks the deadline, registration reclaims expired rows); data-model.md:346; frontend-design.md:35 (verification screen explains the seven-day rule; "The previous handle may no longer be available after registration expiry").
- **Scenario.** A newcomer registers on the phone, gets distracted, and returns eight days later. The link they request fails with "restart signup", and the copy on the verification screen has to explain a calendar rule that exists only to free a handle nobody else asked for.
- **Whys.** Why expire registrations? To release handles and emails held by unconfirmed rows. Why a scheduled job? To do that without a trigger. Why does verification check the deadline? So cleanup lag does not matter. Why must the user know? Because the rule can refuse them. Why can it refuse them? Because the row was deleted on a timer, not because anyone wanted the name. Two more whys stay on *a timer solving a contention problem that has no contender*.
- **Classification.** Conventional variation. `phx.gen.auth` has no registration expiry; unconfirmed users persist and cannot act.
- **Replacement.** Unconfirmed rows persist. Registration reclaims a conflicting unconfirmed row older than one hour (the same guarded takeover the design already specifies for expired rows), so a squatted handle or mistyped email is released the moment someone wants it. Verification checks token validity and that the row is still unconfirmed; if it was reclaimed, "This handle was taken while your signup was incomplete; start again." Magic links keep their fifteen minutes.
- **Disappears.** The maintenance job, the deadline check at verification, the seven-day copy, and the "resending does not extend" rule. **Appears.** Nothing; the reclaim path already exists and now has one trigger instead of two.
- **Loss.** Unconfirmed rows accumulate until reclaimed or swept by an operator; a handle stays reserved by an abandoned signup until someone wants it, which is the only moment it matters.
- **Acceptance.** Register, wait nine days, request a link, verify: success. Register handle X, abandon; another user registers X after one hour: takeover succeeds and the first user's later verification fails with the restart message.
- **Disposition.** Change.

### F-B4 — Change: drop version checks and reviewed-report snapshots from moderator actions; move file destruction to an operator command

- **Source.** backend-design.md:428 (hide, restore, dismissal compare content version and reviewed report state; reject stale actions), :450–452 (`dismiss_reports` with `expected_version` and `reviewed_report_ids`), :454–458 (`destroy_media` with version compare); data-model.md:608–611; frontend-design.md:229 (stale action shows latest content before retry), :245, :249.
- **Scenario.** One moderator, the founder, reviews a reported tip. Between loading the case and clicking Hide, the author fixes a typo. The action is rejected, the page reloads, and the moderator clicks again. The mechanism protects against hiding content the moderator has not seen, and costs a version parameter, a report-id snapshot, a conflict path and a reload flow on every moderator action.
- **Whys.** Why compare versions? So an action is not applied to content the moderator did not review. Why does that matter for Hide? Hide is reversible and the moderator would look again on the next report. Why does it matter for Dismiss? A report that arrived after review would be dismissed unread. How likely is a new report in the seconds between load and click? Rarely, and the case page shows the report count at click time. Two more whys stay on *optimistic concurrency applied to reversible actions by a single moderator*.
- **Classification.** Product preference. Reddit's mod queue and Discourse's flag handling act on the current item without a content-version precondition.
- **Replacement.** Hide, restore and retag act on the current row under the existing locks; dismiss resolves all open reports on the target as of the transaction. The case page shows `edited_at` and the current report count so the moderator can judge. Permanent file destruction leaves the moderator UI and becomes a documented release command, the same pattern the architecture already uses for job retries (software-architecture.md:102); Hide plus author deletion cover the reversible cases.
- **Disappears.** `expected_version` and `reviewed_report_ids` parameters, three conflict paths, the stale-action reload flow, `destroy_media` as a web operation and its selection UI (frontend-design.md:249), and the "moderator changes advance `edit_version`" rule except where retag rebuilds search text. **Appears.** One operator command.
- **Loss.** A dismiss may resolve a report that arrived seconds earlier; a hide may apply to a just-edited version. Both are visible on the next look and reversible. File destruction requires shell access, which for one moderator is the founder anyway.
- **Acceptance.** Concurrent author edit and moderator hide: hide applies, no conflict. Report arrives after case load, then dismiss: resolved, count visible before click. Destroy via release command: references removed, cleanup enqueued.
- **Disposition.** Change; owner decision on moving destruction out of the UI.

### Kept

Submission keys and `get_publication`, `edit_version` with optimistic locking, one review per user per tip, notification fold counts with count-matched mark-read (a timestamp comparison fails the reproduced overlap at data-model.md:676, so the count is the smallest correct guard), account locks that serialize publication against bans, and the shared visibility projection. Codex's propagation list is accepted as written.

Open for Codex: F-B1 (against C-B4), F-B2 extension, F-B3, F-B4.

## Codex Round 2 — challenge the proposed backend cuts

### Accept C-B1–C-B3, and accept F-B2 vote deletion

Defer shadow bans, start reviewer setup blank, and keep an image-only media contract with the remaining ownership/cleanup constraints. With no shadow casting and no automatic revival, **delete invalidated votes** under the existing account/target locks; retain the counter trigger's insert/update/delete duties. Unban cannot recreate votes. A later explicit eligible vote is a new vote and follows normal notification rules. Losing invalidated-vote forensic rows is real and acceptable for this MVP. Do not accidentally delete content `dead_at`, which still represents deliberate moderation.

### F-B1: accept the smaller report policy, with an honest retry trade

Fable's challenge changes my recommendation. Keeping author revisions provides a stronger invariant, but a report creates no automatic penalty, rank change or content hiding. One open report per person and target bounds active duplicate pressure; a new report after resolution can also carry genuinely new evidence without requiring the author to edit first. That is a useful capability, not just a code reduction.

**Recommend removing report `author_revision`, content author-revision columns and the two permanent revision indexes; retain the two one-open constraints.** Remove the stale-author-revision reporting flow. Preserve report explanations until an outcome is known; distinguish newly stored report from existing receipt, and never claim newly supplied text was saved when returning the existing report. No automatic retry loop. An explicit retry after uncertain submission may create a new report if an earlier one has already resolved; document this accepted at-least-once effect. Both report rows remain history, and the moderator can see them. Current reporter/target eligibility and rate limits still apply.

Corrections: “rare and harmless” is not established. A moderator may act quickly, or a reader may retry an old tab days later. The cost is additional queue work; judge it on its limited effect, not a guessed time window. The competitor re-flagging claims need primary evidence or withdrawal. **Do not delete the whole-edit/no-op detector:** avoiding false `edited_at`, needless search rebuilds, embedding invalidation and `edit_version` changes still requires appropriate change detection. We remove the separate report-specific revision distinction and increment, not every edit comparison.

I considered a per-report submission UUID. It would add a durable field but still needs a decision about a second key that encounters an already-open report and then retries after that report resolves. An alias ledger is excessive here. Accept the limited duplicate effect explicitly rather than pretending a single key eliminates every report race.

Acceptance: repeated submission while a report remains open returns its receipt; resolution permits a deliberate fresh report with new detail on unchanged content; delayed uncertain retry may create one new open report; reporting never auto-hides or penalizes the target; a no-op content edit still does not move its Updated date.

### F-B3: reject the one-hour takeover proposal; keep seven-day expiry

The replacement does add policy and cost: it changes a seven-day reservation to one hour, leaves abandoned personal data indefinitely unless contested, and makes return behavior depend on whether an unseen third party requested the name. “This handle was taken” is not a safe generic explanation for an email collision, expired token or deleted/reclaimed account.

The current seven-day rule applies only to unfinished signup, not a returning confirmed user. It is ordinary bounded reservation housekeeping behind a form, unlike the two-hour limit obstructing corrections to already-published tips. Inline reclamation and scheduled cleanup serve different purposes: timely availability and bounded abandoned-row retention. Both share the guarded operation already specified. Removing expiry does not remove token/reclaim races or restart messaging; it replaces a predictable deadline with contention-dependent outcomes. Keep the seven-day expiry and cleanup, briefly explained on verification. No additional “account expires” messaging for confirmed users. The proposed one-hour threshold has no evidence and is materially less generous to a newcomer.

Acceptance remains: a timely valid confirmation wins against cleanup; an expired unfinished signup restarts; confirmed accounts are never swept; old tokens cannot authenticate replacements. If later trial users regularly return after a week, reassess that product threshold with evidence, not an assumed generator default.

### F-B4: reject removal of moderator freshness guards

The race is not limited to seconds or one moderator. A single moderator can leave a tab open for hours while authors edit and other users report. The frontend explicitly does **not** broadcast automatic updates; showing a count at page load does not mean the count is current at click time. Even a fresh fetch followed by an unconditional write leaves the same race.

Dismissal of an unread report is not a harmless reversible hide: the source has no reopen-resolved-report workflow, and the reporter receives no outcome notice that would prompt them to report again. A report of leaked information can disappear from the open queue without having been read. A stale Restore can also reveal material changed after review. Existing `edit_version` and reviewed-report-id guards are narrow correctness mechanisms, reused across operations; keep them. Do not replace them with “rarely” or unsupported competitor implementation claims.

Also keep targeted permanent-media removal available to authorized moderators. Moving it to shell adds a command and an operational handoff; it does not remove ownership, file selection, current-state checking, cleanup durability or the need to distinguish irreversible deletion from reversible hiding. No evidence establishes that every intended moderator has release-shell access. The proposal bundles UI subtraction with weakened backend safeguards; neither is a necessary consequence of the other. A later explicitly founder-only operator workflow can revisit the interface without weakening Content's operation.

### Whole-product effect

Normal or explicitly banned accounts; live, hidden or author-deleted content; actual votes or no vote; reports can be renewed after resolution without pretending retries are exactly once. These are simpler states. We keep the guarded transitions that protect another person's writing or prevent unread moderation evidence disappearing. Publication idempotency, optimistic edits, draft CAS and notification fold counters still have higher-impact jobs than report retry suppression.

Please ratify or challenge these narrowed dispositions. Frontend candidates are ready in the shared frontend file; start that phase after backend closure.

## Fable Round 2 — concessions and backend closure

- **F-B1.** Accept Codex's form. The whole-edit no-op detector stays for `edited_at`, search rebuild and `edit_version`; only the report-specific revision, its columns, indexes and stale-form flow go. "Rare and harmless" withdrawn as unestablished; the cost is queue work from an at-least-once retry, accepted explicitly. Competitor re-flag claims withdrawn for lack of primary evidence.
- **F-B2.** Consensus: invalidation deletes vote rows under the existing locks; content `dead_at` untouched.
- **F-B3.** Withdrawn. Codex's retention point decides it: abandoned emails kept indefinitely need a sweep anyway, so my proposal removed only the verification-time check and replaced a predictable deadline with a contention-dependent one and a message that cannot cover every collision. Seven-day expiry and cleanup stay. One amendment for the frontend phase, not a backend change: explain the deadline when it bites, not on every verification screen.
- **F-B4.** Withdrawn in full. Hours-old tabs, no live counts, no reopen flow for a dismissed unread report and stale Restore revealing changed material are concrete; my competitor claims were not sourced. Version and reviewed-report guards stay; media removal stays in the moderator UI.

### Backend dispositions

| Item | Disposition |
|---|---|
| C-B1 shadow bans | Change: defer; two visibility causes remain (author deletion, deliberate hide) |
| C-B2 reviewer setup | Change: blank default, "used (optional)" labels |
| C-B3 media | Change: image-only row with owner, parent, key, position, cleanup, optional description |
| C-B4 / F-B1 reports | Change: one open report per reporter and target; `author_revision` removed; at-least-once retry duplicate accepted |
| F-B2 votes | Change: `dead_at` removed; invalidation deletes |
| F-B3 registration expiry | Reject; keep seven days; deadline copy on failure only (frontend) |
| F-B4 moderator guards | Reject; keep version and reviewed-set guards and media removal UI |
| Propagation | Accepted as Codex wrote it |

Backend phase closed at two rounds. Source documents unchanged.

## Codex Round 3 — closure

Ratify the backend dispositions in Fable Round 2. Consensus reached after two substantive rounds and this closing ratification. The proposed change to registration-deadline copy is a frontend candidate, not an already-agreed exception to the backend policy. Frontend may refine list presentation and animation; those refinements must propagate consistently to backend contracts before implementation. Technical source files remain unchanged.

## Cross-phase ratification — contracts propagated from the frontend phase (Fable)

Within the round cap and without altering sources, the following backend contracts follow from frontend consensus:

- **Pagination.** All list reads take a validated page and return one page plus `has_more` from one-row lookahead: browse and search (twenty), profile union of tips and reviews ordered `(created_at desc, kind, id desc)` (twenty), inbox (twenty), tip reviews by `review_sort` (thirty). Offset queries over the existing indexes; keyset cursors and seen-id parameters removed. Search keeps `total_in_window` internal. Inbox snapshot and count-matched mark-read run once per connected visit regardless of page changes.
- **Reviews on a tip.** The ranked query includes the viewer's live own review (the `user_id is distinct from` exclusion goes). A separate lightweight lookup returns the viewer's own-review identity and current capability, including hidden state, for the header control. `get_tip_page` with a review id returns the tip and that single authorized review, or the existing unavailable notice; no separate-plus-ranked dedup.
- **Media.** Image rows gain an optional `description` text column and a stored motion classification from server-side content parsing at upload; no transcoding or poster extraction.
- **Registration.** Seven-day expiry unchanged; the deadline is explained only when it causes rejection.

Codex to confirm. Source documents unchanged.

### Wording correction (Fable, after frontend Round 3)

In the cross-phase ratification above, "one-row lookahead" applies to browse, profile, inbox and tip reviews. Search keeps its existing internal `total_in_window` to derive `has_more` over the bounded ranking; no second count query and no exhaustive-count claim.

## Cross-phase ratification — Codex, after frontend Round 3

Confirm Fable's propagated contracts with one clarification: ordinary lists use one-row lookahead; **search retains its existing internal `total_in_window` for `has_more`**, over the current bounded ranking. Do not add a second count query. All expose the same page navigation; no exhaustive search count is displayed. Choose ordinary assigns holding the current bounded page in the frontend, not accumulated streams. Content still returns current visibility-safe rows and operation capabilities.

Adopt the single-review projection and lightweight own-review lookup, the mixed profile order with a type tie-break, and optional image description plus trusted motion metadata. Server parsing remains authoritative; static canvas composer thumbnails do not replace validation or establish a source-decode memory bound. These are one cross-phase reconciliation after the two backend debate rounds and closing ratification, still within the ten-round limit. Final UI behavior is in the frontend closure. Source designs remain unchanged.

## Final artifact verification — Codex

All four technical source SHA-256 hashes match the review baseline. The three review files have valid local Markdown link targets, source line references within file bounds, both reviewers' attributed findings and ratification, and round counts below ten even counting the cross-phase reconciliation. This verifies the review artifacts and untouched source baseline, not the proposed software. No application/browser tests were run; acceptance scenarios remain implementation work. Final summaries and closure sections govern over superseded debate proposals.
