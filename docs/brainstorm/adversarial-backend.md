# Adversarial review — backend

Date: 2026-09-20. Status: consensus reached in 4 rounds. Phase 2 of 3 complete.

## Read first

The final recommendations are the Round 2 closure as corrected in Rounds 3–4 and **Codex ratification of phase 2 closure**. Both reviewers agree. Earlier proposals remain for the review history; do not implement them in isolation. Retain activation job history and snooze temporary ineligibility; never reset failed attempts on Restore.

The settled direction is one media table with stable ids and durable cleanup markers, retained job linkage, ordered database locks, deletion-first Content projections, both report uniqueness constraints, and one bounded embedding scan. No source design has been changed. Reduced-schema PostgreSQL reproductions support the locking, media ordering and report findings; they do not replace application integration tests.

Use the roles, evidence standards, and append-only round protocol in adversarial-architecture.md. Review database contracts, authorization, transactions, jobs, media, search, authentication, and their frontend effects. Source designs remain unchanged by this review.


## Codex Round 1

Architecture findings carry forward; the following make their repairs concrete and add local/backend seams.

### B-C1 — High: define the lock order including triggers and foreign keys

Evidence: data-model.md:243-267,470-491,505-521,533-539,583-627; backend-design.md:394. The executed account-unban reproduction establishes a real cross-row race. The obvious fix of sprinkling FOR UPDATE into the CTEs can introduce deadlocks, especially when child triggers lock parents and notifications reference other users.

Recommendation: lock current actor/affected account state before checking eligibility; use the weakest sufficient lock (the reproduction passes with FOR NO KEY UPDATE, compatible with FK key-share locks). Account transitions take the same serialization point. Prelock affected parent tips before review transitions that change review_count; consistent sorted order for bulk operations, then child/media/report rows. Discover immutable ids first, then lock/recheck; never mutate based only on the discovery read. Include all operations participating in each invariant, not just publication. Account/session checks include confirmation state and revocation per architecture consensus. Do not hold these locks over provider calls or browser work. A narrow operation helper is enough, not a lock manager.

Effects: add deterministic two-session tests for unban/publish, delete/review publish, report/author edit/resolution, and attachment claim/expiry. Keep deadlock retry bounded around database-only work; never rerun external uploads blindly. The exact final lock graph must be checked against actual schema and triggers during implementation.

### B-C2 — High: read projections still leak author-deleted tip identity

Evidence: data-model.md:390-400 returns the title and author of an author-deleted tip; profile review query :667 masks only dead_at. This contradicts backend-design.md:361 and frontend-design.md:114, which mask deleted titles, attribution, metadata and slugs for every viewer. This is acknowledged pending work, but it is an implementation blocker if the SQL is copied.

Recommendation: implement deletion-first viewer projections, using the independent hiding causes agreed in phase 1. Reuse the predicate/projection across tip, profile, inbox, search hydration, selected-review reads and generated URLs. Existing visible reviews retain their own eligibility. Recheck selected-review visibility when hydrating a search excerpt so a hit id selected before hiding does not expose newly hidden text. Test anonymous, author, moderator, deletion plus hiding, and a visible review of an unavailable parent.

Effects: fixes title/metadata leakage without denying the parent placeholder or cascading restrictions to review edits/votes/media. No whole-page visibility gate.

### B-C3 — High: durable job state and author-visible state can diverge on crash

Evidence: backend-design.md:188-196 requires exactly 10 activation attempts, durable failed/ready state, restart recovery and operator retry. A worker setting failed in its own final error branch cannot do so if killed during the final attempt. Job rescue may discard that job; a generic pruner can then erase it while the attachment still says retrying. Provider activation can also succeed before the process dies.

Recommendation: pinned Oban configuration with interrupted-job rescue; bounded reconciliation from job outcome/provider state into existing media state, including crash on the final attempt and operator retry. Do not rely solely on telemetry or a worker's return path. Preserve failed state and cleanup identifiers in application rows; configure an explicit operator retry retention window for job records. If retrying after pruning is supported, reconstruct only through an explicit operator operation with eligibility checks, never an automatic reset of the attempt budget.

[Oban Lifeline](https://oban.hexdocs.pm/Oban.Lifeline.html) documents rescue and exhaustion; [Pruner](https://oban.hexdocs.pm/Oban.Pruner.html) includes discarded jobs. This is a configuration/reconciliation gap, not a reason to add Oban Pro or a second scheduler. Test a killed final attempt and a lost provider response.

### B-C4 — Medium: finish the embedding scan's single retry policy

Evidence: backend-design.md:170,183; data-model.md:718-727,978. Architecture Round 2 prefers Fable's existing bounded scan, not per-row jobs. Oban schedules each scan once; embed_after owns per-row cooldown. Explicitly document this narrow exception to the blanket Oban-retry statement.

Recommendation: isolate provider failures per row or returned batch item, update cooldown only for the same pending text version, and let the next cron run revisit a crashed batch. Make a poison input unable to starve later pending rows. Prevent overlapping scan jobs with the pinned Oban configuration; keep each scan bounded and provider calls outside DB transactions. No per-row attempt-chain table or enqueue hooks on every content transition. Live-content joins make restored content eligible automatically. Test partial success, a poison row, crash before cooldown, obsolete text and restore after hiding.

Effects: keyword fallback remains usable while embedding work recovers. The existing infinite periodic retry behavior is retained deliberately for embeddings; the video's ten-attempt budget remains separate. Do not inherit activation limits accidentally.

### B-C5 — Medium: retained attachment reordering conflicts with immediate slot uniqueness

Evidence: backend-design.md:204 requires ordered retained media without re-upload; data-model.md:178-194 makes `(tip_id, position)` and `(review_id, position)` immediate unique constraints with positions restricted to 0..9. A simple in-place swap 0↔1 fails even though the final order is valid. Removing/reinserting retained attachment rows could change identities used by activation/cleanup work and old editors.

Executed on Postgres 18.6 with isolated reduced schema: `docs/brainstorm/adversarial-media-order.py`. Immediate uniqueness rejects a two-item swap; deferrable uniqueness with constraints deferred only in the edit transaction allows it, preserves media ids, and still rejects duplicate final positions at commit.

Recommendation: keep stable retained asset/attachment identity and defer the two slot unique constraints within the parent-locked reorder transaction, or demonstrate an equally small safe alternative. Ownership/slot/count validation and edit_version guards remain. Test swaps, ten-item permutations, removal plus addition, and stale edits.

### B-C6 — Medium: specify first public-video release during a concurrent hide

Evidence: backend-design.md:186,226-228. Recheck-before-provider-call plus recheck-after-call cannot make Postgres visibility and Stream public access atomic. A tip can be hidden between eligibility check and provider activation; a post-call no-op does not undo that exposure. Existing saved-link availability is explicitly accepted only for publicly released assets.

Recommendation to challenge: define first-release authorization at a committed, eligible release claim; hiding prevents new claims, while already claimed in-flight release may finish. Deletion remains terminal and gets provider cleanup; no task can recreate a deleted asset. This is a narrow policy clarification with a real externally observable interval, not proof of atomic revocation. If that interval is unacceptable, a stronger provider access design is required and must be raised as a product tradeoff. Do not pretend a final SQL check prevents an external effect already performed.

### Scope discipline

Keep the already-agreed tus-only upload path; it addresses the 1 GB transport requirement. Keep Stream, ten mixed attachments, report author revisions, trigger-owned counters, submission-key retries, and the two contexts. The frontend phase will own image-consumption retries, IndexedDB replacement races, and form-recovery ordering. No new services or history tables are justified by these findings.

## Fable Round 1

Role: senior Elixir/Phoenix implementation and conventions. Order of assessment per the shared rules: local correctness, then direct and downstream effects of the fix, then whole-system fit. Executed evidence: `docs/brainstorm/adversarial-media-edit.py` (Postgres 18.6, isolated DB): E1 full attachment edit under deferred slot constraints, E2 duplicate final slot rejected at commit, R1 report insert against an uncommitted author edit.

### Responses to Codex Round 1

**B-C1 — accept the lock summary, reject the deadlock-retry layer.** Local: correct; it restates phase-1 rule 4 and adds "discover ids, then lock and recheck", which is right for bulk kill and bulk vote invalidation. Downstream: "keep deadlock retry bounded" adds a retry wrapper around every transaction. With one lock order, a deadlock is an ordering bug, not a transient. Let it raise, report to Sentry, and fix the order. No retry helper. Whole system: the attachment-claim/expiry pair is the only new participant. The expiry scan and publish both lock the staged video rows `FOR NO KEY UPDATE` after the user row, so they serialize on the same rows without new rules. Tests: two-session unban/publish and delete/review exist as scripts; add expiry/claim in the same style. Report/edit/resolution needs no two-session test, see report revision below.

**B-C2 — accept the finding; the fix is one Elixir function, not shared SQL.** Local: correct. data-model.md:390-400 masks only `dead_at`; the deleted tip's title and handle leak, and data-model.md:569 already admits it. Fix: read rows unmasked with `deleted_at`, `dead_at`, `user_id`, then apply one `mask(row, scope)` function in Content to every tip/review struct before it leaves the context. Five CASE expressions copied across tip page, profile, inbox, queue, and search hydration is the duplication that created this bug. Downstream: the media query at data-model.md:430 already filters by parent visibility and stays in SQL, because it decides which rows to fetch, not how to present them. Search hydration reads current rows by id, so a hit hidden between retrieval and hydration drops out; no extra recheck. Whole system: the moderator queue is the one place that must see the original title of a hidden item, and the same function handles it via the scope's role.

**B-C3 — accept the crash case; reject a reconciliation scan, derive status from the job row.** Local: correct. `Oban.Plugins.Lifeline` marks a rescued job whose attempts are exhausted as discarded, so a worker killed during attempt 10 never runs its failure branch, and the attachment row stays "retrying". Fix, smaller than Codex's: store no failed flag at all.
- `media.activated_at` is the only public-access truth. Null means omitted from public projections.
- Insert the activation job inside the publish/edit/restore transaction and write its id to `media.activation_job_id`.
- Author-facing status is a join: `activated_at` set → Ready; job in `available|scheduled|retryable|executing` → Retrying; otherwise, including a pruned job → Failed. Nothing the worker fails to write can leave the row lying.
- Worker: read eligibility, PATCH Stream (idempotent), then `update media set activated_at = now() where id = $1 and activated_at is null`. A crash after the PATCH and before this write repeats the PATCH on the next attempt or on operator retry; Stream returns the same state.
- Pruner `max_age` 7 days so `Oban.retry_job/1` works within the operator window. After pruning, the operator release command inserts a fresh job and updates `activation_job_id`; that is the explicit path Codex asked for, with no reset of a stored attempt budget because none is stored.
Downstream: the same join serves images with `activated_at` set at insert, so one projection covers both kinds. Whole system: the cleanup jobs follow the same pattern. Deletion CTEs delete the media row and insert the Stream/R2 cleanup job with provider ids in args in the same transaction. The job row is the durable cleanup record; a cleanup table duplicates it. Give cleanup workers a long attempt budget and report exhaustion to Sentry; the weekly R2 sweep remains the last resort. This drops "preserve cleanup identifiers in application rows" from Codex's fix.

**B-C4 — accept; two implementation choices settle the open points.** Poison rows: send one row per embedding request, not a batch. A failing row then defers only itself; 50 local calls per scan is cheap and `Req` retries are off. Overlap: the `embeddings` queue runs with concurrency 1 and the scan worker has `max_attempts: 1`. Two scans cannot execute concurrently and a crashed scan is simply superseded by the next cron tick. No `unique` options, no lock. Text-version guard, `embed_after` as the only retry state, and live-join eligibility stay as written.

**B-C5 — accept deferrable constraints; delete-and-reinsert is not an equal alternative.** Local: reproduced. Reinserting rows changes media ids, and `activation_job_id` plus in-flight activation jobs reference the row; a reorder during a retrying activation would orphan the job. E1 shows the complete edit shape works under one `set constraints ... deferred`: delete removed, `UPDATE ... FROM (VALUES ...)` for retained positions, insert new. E2 shows duplicates still fail at commit. Implementation notes: Ecto's `create unique_index` cannot emit DEFERRABLE, so the two constraints go through `execute` per phase-1 rule 2. A commit-time violation raises `Postgrex.Error`, not `{:error, changeset}`; the edit validates distinct positions in the changeset first, so the raise means a bug and is reported, not mapped. A deferrable unique index cannot serve `ON CONFLICT`; nothing upserts media, so no effect.

**B-C6 — agree it is policy, not a guarantee; the claim state is unnecessary.** Local: correct that no SQL after a provider call undoes the call. Whole system, the part Codex's framing misses: before activation, no reader can obtain the Stream uid. Public projections omit unactivated videos, and the author and moderators already see hidden content. The interval therefore exposes the playback link to nobody who could not already see the video. The policy line that hidden content keeps its saved links already covers what happens after. So the rule is: the worker reads eligibility without a lock, calls Stream, and records `activated_at` unconditionally. If a hide committed during the call, the row is truthfully activated and the hidden page omits it; restore needs no new job. If a deletion committed during the call, the deletion transaction already enqueued Stream deletion, which runs after and wins; an activation PATCH against a deleted asset returns 404 and is treated as permanent. No committed "release claim" row, no product tradeoff to raise. This is a wording clarification of backend-design.md:226 for the user, not a mechanism.

### Fable findings

**B-F1 — High: the video/staging schema is missing and every B-C3/5/6 fix depends on it. One table, not two.** data-model.md:788-801 says staging records and Stream references are "not yet included". Simplest shape that meets the stated contracts: a staged video is a `media` row with no parent.
- Relax `media_one_parent` to `num_nonnulls(tip_id, review_id) <= 1`; a null-parent row is a staged upload.
- Columns: `user_id` (owner; needed because a staged row has no parent to derive it from), `kind` (`image|video`), `key` nullable for videos, `stream_uid` unique nullable for images, `state` (`uploading|processing|ready|failed`), `duration_s`, `expires_at`, `target text` (e.g. `tip:new:<submission_key>`, `review:edit:<id>:<version>`), `activated_at`, `activation_job_id`. Checks: `(kind = 'image') = (key is not null)`, `(kind = 'video') = (stream_uid is not null)`, `(tip_id is null and review_id is null) = (expires_at is not null)`.
- Claim at publish/edit: `update media set tip_id = $1, position = v.pos, expires_at = null, target = null from (values ...) v where media.id = v.id and user_id = $2 and tip_id is null and review_id is null and state = 'ready' and target = $3 and expires_at > now()` with a row-count check, after the parent lock. The activation job inserted in the same transaction references this id, which never changes afterwards.
- Expiry scan: `update media set state = 'failed' where tip_id is null and review_id is null and expires_at < now() returning id, stream_uid`, then enqueue Stream deletion. Same rows, same lock, so it serializes with claims.
- Discard: same guarded update by owner and null parent.
This removes a `video_uploads` table, a media-to-upload foreign key, and a copy step at attachment. Position stays null until claimed; make `position` nullable with check `(tip_id is null and review_id is null) = (position is null)`. The image path is unchanged: images are inserted with a parent in the content transaction.

**B-F2 — Medium: unique-violation mapping in publish, carried from phase 1.** Publish a tip through `Repo.insert` with a changeset carrying `unique_constraint(:submission_key, name: :tips_user_submission_key)` and, for reviews, `unique_constraint(:tip_id, name: :reviews_one_per_user)`. The insert-select CTE at data-model.md:470 becomes an eligibility read that locks the user row, then a changeset insert, then `insert_all` for search, vote, media, notification rows. On `{:error, changeset}` the transaction rolls back and `publish_*` reads the original by key in a new statement, exactly as data-model.md:452-461 requires. The one thing not to do is catch `Postgrex.Error` inside the transaction and continue; the transaction is already aborted.

**B-F3 — Medium: report revision needs no lock or CAS; the race is benign.** R1 executed: a report bound to `author_revision = 1` commits while the author's edit to 2 is uncommitted; afterwards the tip is at 2. That is identical to a report submitted one second before the edit, which the product must accept anyway. The invariants that matter are enforced elsewhere: one open report per reporter/target by the partial unique index; re-report only after resolution and edit by the insert-select predicate `not exists (resolved flag with author_revision = current revision)`; moderator actions compare `edit_version` and reviewed report ids. The `author_revision = $rev` predicate on the insert is a UX guard for the stale form, not a serialization point. Drop "serialize eligibility, inserts, edits and resolution" from data-model.md:203 to "one statement, one partial unique index". Reporter eligibility locks the reporter's user row per rule 4; nothing locks the parent.

**B-F4 — Medium: `author_revision` and `edit_version` can be one column with a flag, but should not be.** Checked the alternative: moderator operations (retag, destroy_media) increment `edit_version` to invalidate old editors; author edits must advance a separate counter for re-reporting. Folding them requires reports to store a version and the moderator ops to skip it, which reintroduces the ambiguity. Two integer columns is the simpler choice. No change to Codex's position.

**B-F5 — Low: unconfirmed-registration cleanup and the phx.gen.auth schema.** The generated `users_tokens` table and `confirmed_at` column exist; cleanup is `delete from users where confirmed_at is null and inserted_at < now() - interval '7 days'` with tokens cascading, locking the user row `FOR NO KEY UPDATE` so it serializes with confirmation, which updates the same row. Registration reclaiming an expired handle runs the same delete for the conflicting handle or email before insert, in the registration transaction. Confirmation checks `inserted_at` age in its guarded update. No new table or state.

### Scope

Kept: tus-only video transport, Stream, ten mixed attachments, report author revisions, trigger counters, submission keys, two contexts, embedding scan. Removed from Codex's fixes: deadlock retry helper, cleanup-identifier application rows, activation failed flag, release-claim state, per-query masking SQL. Added: staged-video rows in `media`, status derived from `activated_at` plus job state, deferrable slot constraints via `execute`, per-row embedding calls, queue concurrency 1 as the overlap guard.

### Challenge

Codex, three things to attack: (1) B-F1's `target` text column versus your view that no new table is justified: is a null-parent `media` row acceptable as the staging record, or does it break a projection you rely on? (2) B-C3 replacement: any path where `activated_at` null plus no live job is not "Failed"? (3) B-C6: any reader who can hold a Stream uid before activation?

## Codex Round 2 — challenge the simplifications as well as the fixes

### B-C1: accept no generic deadlock retry wrapper

My proposal was bounded retry around demonstrated transient DB-only conflicts, not every transaction. For this MVP, agree to remove a general retry helper: establish lock order, return a recoverable error/preserve input on abort, log the failure, and fix ordering bugs. Existing Oban worker retries remain. Discover/prelock/recheck still applies to bulk operations and workers. Do not infer SQL evaluation lock order merely from the written order of CTEs; use explicit ordered locking steps where needed.

### B-C2: accept a shared boundary projection with one qualification

One Content projection/masking function is simpler than duplicating CASE expressions, provided no raw row escapes via nested associations, metadata, notification links, search excerpts, or worker-facing web responses. SQL still filters which rows may be returned; the projection masks an unavailable parent's identifying fields while preserving independently visible children. Moderator access bypasses moderation hiding, never author deletion. Add tests at each public context return shape, not only tests of the helper. This is normal context code, not a serialization framework.

### B-C3: accept derived activation status; reject prunable cleanup jobs as the only durable record

A projection of `activated_at` plus the existing activation job state avoids a duplicate failed flag and handles final-attempt crashes once rescue settles the job. Accept `activation_job_id`, a documented operator retry window, and explicit operator reconstruction after pruning. Do not promise an immediately accurate failed status before the chosen rescue interval. Provider success followed by a crash may be labelled Failed until confirmation/operator retry; public projection remains omitted until application confirmation. Every final activation update still checks the same media identity and does not recreate detached/deleted rows. Restoring content must not automatically start a fresh attempt budget for a previously exhausted activation.

The cleanup proposal violates a stronger existing requirement: backend-design.md:188 and data-model.md:35 explicitly retain provider ids until confirmed cleanup even if job history is pruned. Counterexample: author removes a Stream video; its media row is deleted; cleanup exhausts during a provider outage; seven days later the discarded job is pruned. Now no record identifies the asset to delete, no operator retry can reconstruct it, and the R2 sweep cannot recover a Stream uid. Sentry is neither guaranteed nor a cleanup ledger. Increasing attempts or retention only postpones this failure.

Smallest fix: retain the removed media row itself as a non-readable cleanup tombstone, including provider id, until provider deletion/cache purge succeeds. Clear its live attachment reference/slot, mark cleanup requested, and enqueue the normal job transactionally. Only successful cleanup permits final deletion of that row. Reuse the proposed media table; no separate cleanup table or retry scheduler. Explicit operator cleanup retries can rebuild jobs from this row after pruning. A retained nullable-parent row therefore cannot always mean recoverable staged upload.

### B-C4: simplify calls, but queue concurrency alone does not bound scan backlog

Accept independent per-row failure handling and disabling HTTP-client retries so `embed_after` owns retry timing. One-row requests are an implementation starting point, not a claim that 50 CPU inference calls are cheap; measure the bounded scan runtime, including long texts and timeouts. Concurrency 1 prevents overlap in normal execution but a periodic scan taking longer than its schedule accumulates available jobs. Use the normal Oban uniqueness options for this singleton scan across active states, or schedule its next run after completion. Cron plus uniqueness is smaller than a custom scheduler. A new tick must remain possible after an exhausted rescued scan is discarded. Test that configuration with the pinned version. No additional queue table.

### B-C5: accepted

Retain media ids; use deferred slot constraints for atomic reorder/remove/add. Commit failures roll back all attachment and parent-version changes. Keep early feedback and the actual DB constraint. Fable's extended reproduction confirms the downstream shape. No media upsert means the deferrable-constraint ON CONFLICT limitation is irrelevant.

### B-C6: withdraw persistent release-claim state, but state the observable policy honestly

The UID is known to the uploader before activation and can be copied/shared; it is an identifier, not a secrecy guarantee. More fundamentally, 'no-longer-eligible activation is a no-op' cannot forbid an external activation already in flight. Accept the smaller implementation: check eligibility at activation admission, make the provider call outside the transaction, record its confirmed outcome if the media still exists, and always filter page projections by current content visibility. A hide prevents subsequent activation admissions; an already-admitted call may finish and leave the saved link usable. Deletion remains terminal and durable cleanup removes the provider asset; activation never recreates it.

This is a necessary clarification of the permitted in-flight race, not proof the current stronger wording is implementable as written. Recommend documenting this exact window in the design. No new claim field, per-asset lock process, signed-public-link system, or transaction held over HTTP. If the user requires hide to prevent even in-flight first release, that is a stricter product guarantee and a separate access-design decision. Reviewer consensus can recommend the narrow clarification without pretending the race is impossible.

### B-F1: one media table is viable, but the proposed state model fails three required paths

Accept a single media row transitioning from provisioning/staged to attached and finally cleanup. It is less copying and preserves identity. Reject the proposed checks as implementation-ready:

1. `video iff stream_uid is not null` prevents creating durable staging metadata **before** the provider request returns its uid, contrary to backend-design.md:262. A provisioning phase must allow missing provider id and retain a server-owned correlation id for unknown outcomes.
2. Setting `state = failed` on discard is not a terminal cleanup transition. A late signed ready webhook can change failed back to ready while `expires_at` is still in the future, making a discarded upload claimable again. A cleanup-requested marker/state must block claims and all processing/activation callbacks permanently.
3. The null-parent/expiry equivalence assumes every detached row is a draft. The cleanup tombstone above is detached but must survive until deletion succeeds, including beyond draft expiry. Keep staged expiry separate from cleanup retention. Persist trusted upload completion time once to enforce the distinct 1-hour transfer and 48-hour completed-upload deadlines without duplicate-event extension.

Smallest model: one table with explicit provisioning/staged/attached/cleanup eligibility (ordinary checked fields; no state-machine library), provider-specific identifiers, owner and intended target, immutable completion/deadline semantics, stable id, and activation job linkage. Canonical target text is acceptable only if a single server-owned encoder covers new-review parent id, submission key, content kind/id and edit version unambiguously; typed columns are also fine if clearer. Clients cannot choose arbitrary target strings. Define the actual constraints from these required states rather than a nullable-parent shortcut.

### B-F2: changeset insert is fine after a locked eligibility check, with accurate constraint names

Accept the standard Repo.insert approach; no need to preserve a one-statement CTE for its own sake if user and applicable parent eligibility remain locked through commit. Use actual migration names (`tips_submission_unique` / `reviews_submission_unique` in the baseline), not a guessed index name. This narrows architecture closure item 3: ordinary changeset inserts are also valid when required guards are enforced under locks in the same transaction. Expected constraint errors roll back before the submission-key lookup; side effects happen only for a new row. No duplicated optimistic-lock path.

### B-F3: accept the benign report/edit ordering, retain permanent revision uniqueness

Your R1 is a valid counterexample to my assumption that every concurrent edit needs report serialization. A report can linearize at its single statement's observed author revision and then coexist with a later edit, just like any historical report. Withdraw a separate parent lock for report insertion if the statement checks the submitted revision and eligibility in one snapshot. Moderator resolution still uses its existing target/version/report-set contract.

However, retain the required **unique `(reporter, target, author_revision)` constraint** as well as one-open-report uniqueness. A check against resolved rows alone has an insertion/resolution race: two same-revision inserts observe no committed report; one inserts and commits, a moderator resolves it, then the other inserts against its older snapshot. The partial open index now allows the second insert. The permanent revision unique constraint rejects it and lets the API return the original receipt. This is already required by data-model.md:200-204; do not silently reduce it to one partial index. No parent locking framework needed.

### B-F4 / B-F5

Accept separate author_revision and edit_version; this is two different invariants, not waste. Accept generated confirmation/token lifecycle plus guarded expiry/reclaim and no new table. Tests must cover verification versus cleanup, exact seven-day deadline, expired rows blocking either unique identity, and old tokens after replacement. Column names/types follow the reconciled generated schema, not a mixture of created_at and inserted_at.

### Remaining questions for closure

Please respond to cleanup record loss after pruning, provisioning/late-callback/cleanup state holes, scan backlog, permanent report-revision uniqueness, and the honest in-flight activation wording. If accepted, these use fewer mechanisms than our initial proposals and cover the concrete counterexamples. Then we can close phase 2 and move to frontend.

### Codex Round 2 addendum — report race executed

`docs/brainstorm/adversarial-report-race.py` ran on Postgres 18.6 using an isolated temporary database that was removed. A delayed report INSERT takes its eligibility snapshot; another request inserts the same revision and commits; the moderator resolves it; the delayed insert then continues. With only one-open-report uniqueness, two reports for the same reporter/target/revision are accepted. With permanent revision uniqueness, the second insert is rejected and the original receipt survives. The delayed statement includes Fable's `NOT EXISTS` resolved-revision predicate. This validates keeping both constraints while avoiding a new parent lock for report insertion.

## Fable Round 2 — responses and closure

Assessed in the shared order: local correctness, downstream effects, whole system.

**Cleanup record after pruning — accept the tombstone, as one column.** data-model.md:35 and backend-design.md:188 do require the provider id to survive job pruning, and OSS Pruner has no per-worker exemption; the counterexample stands. Smallest shape: `media.cleanup_at`. Removing an attachment, discarding an upload, and expiring an upload all do the same thing: set `cleanup_at = now()`, null `position`, keep parent ids and provider ids, and insert the cleanup job in that transaction. Projections and claims filter `cleanup_at is null`. The cleanup worker deletes the row only after the provider confirms: `delete from media where id = $1 and cleanup_at is not null`. Downstream: the delete CTEs at data-model.md:552-565 change from `delete from media ... returning key` to that update; the weekly R2 sweep stays for files orphaned before a row exists. Operator retry after pruning rebuilds the job from the row. No `state = 'failed'` for discard or expiry. This also answers B-F1 point 3: a detached row is a draft if `cleanup_at` is null and a tombstone if not; no equivalence with expiry.

**Provisioning before the provider uid — accept, without a correlation column.** My check `(kind = 'video') = (stream_uid is not null)` was wrong for the insert-then-call sequence backend-design.md:262 requires. Drop it; `stream_uid` is nullable until the Stream response is stored. The media id is the correlation id: pass it as the upload's `meta.name` so an operator can find a stray asset. No reconciliation path is needed for a crash between the Stream response and the uid write, because the browser receives the upload URL only after that write, so no bytes ever reach the orphan and the 1-hour row expiry tombstones it with nothing to delete.

**Late ready webhook after discard — accept; `cleanup_at` closes it.** Every webhook write is `... where id = $1 and cleanup_at is null`; every claim requires `cleanup_at is null`. `state` shrinks to the provider's processing outcome only: `uploading | processing | ready | failed`. Completion: the ready webhook runs `update media set state = 'ready', completed_at = now(), expires_at = now() + interval '48 hours' where id = $1 and completed_at is null and cleanup_at is null`, so duplicate events cannot extend the deadline, and provisioning sets the initial `expires_at = now() + interval '1 hour'`. Two timestamps, one guard.

**Target encoding — accept as clarified.** One encoder in Content turns the typed target tuple into the text key; the browser sends the tuple, never the string. Text stays; four nullable typed columns plus a check are more schema for the same comparison.

**Scan backlog — accept the one-line `unique` option.** Queue concurrency 1 prevents overlap but lets ticks queue while a scan runs. `unique: [period: :infinity, states: [:available, :scheduled, :executing]]` on the scan worker makes it a singleton, and a discarded rescued scan is outside those states, so the next tick inserts. Keep concurrency 1 as well; both are configuration. Throughput is then 50 rows per tick, which is far above expected publish rate; measuring per-row inference time is a test task, not a design change.

**Permanent `(reporter, target, author_revision)` uniqueness — accept; it also simplifies the insert.** The window is real: statement snapshot before A commits, A commits and is resolved before B's index check, partial open index then admits B. Microseconds, but data-model.md:200-204 already requires the constraint and it is one index. Consequence: the insert-select no longer needs the `not exists (resolved flag with same revision)` predicate; the permanent index enforces "re-report only after an edit" by itself. Predicate is `author_revision = $rev` plus eligibility; both unique violations roll back and return the existing receipt. Two indexes, one statement, no parent lock.

**Activation wording — accept Codex's text.** The uploader holds the uid before activation, so a link shared early starts working if an admitted activation finishes after a hide. That is the author's own content under the existing hidden-content link policy. Design wording for the user: activation is authorized when the worker's eligibility read passes; a hide committed after that read does not revoke the in-flight release; the hidden page omits it; deletion's cleanup job removes the asset afterward. Stronger than that is a product decision on signed playback, not a backend fix.

**One pushback on B-C3: restore may enqueue activation.** "Restoring must not start a fresh attempt budget" needs restore to inspect the prior job's outcome. backend-design.md:393 already says restoration enqueues activation where needed. Rule: restore inserts an activation job when `activated_at is null` and no job in a live state references the row, and writes the new `activation_job_id`. A moderator restore is an explicit action, not the silent re-enqueue the limit forbids. Same rule for operator retry after pruning, so there is one path.

**B-C2 qualification, B-F2 names, B-F4, B-F5 — accepted as stated.** Constraint names are `tips_submission_unique`, `reviews_submission_unique`, `reviews_one_per_user`. Column names follow the generated auth schema after reconciliation.

### Phase 2 closure

Both reviewers agree on:
1. Lock order per phase 1; bulk and worker operations discover ids, lock in order, recheck. No deadlock retry helper; a deadlock raises and is fixed.
2. Visibility masking is one Content function applied to every returned struct; SQL selects rows, the function masks fields; moderator access bypasses hiding, never deletion; tests per public return shape.
3. `media` is one table for images, staged videos, attached videos, and cleanup tombstones. Columns: parent ids nullable, `user_id`, `kind`, `key`, `stream_uid` nullable, `state` (provider processing only), `duration_s`, `position` nullable, `target`, `completed_at`, `expires_at`, `activated_at`, `activation_job_id`, `cleanup_at`. Check `num_nonnulls(tip_id, review_id) <= 1`. Slot constraints deferrable, deferred only in the edit transaction, created with `execute`.
4. Public access truth is `activated_at`. Author status derives from `activated_at` plus the linked job's state; no failed flag. Worker: eligibility read, idempotent provider call, unconditional `activated_at` write if the row exists and is not tombstoned. Pruner retention 7 days. Restore and operator retry enqueue a new job when not activated and no live job.
5. Cleanup: removal, discard, and expiry set `cleanup_at`, keep provider ids, enqueue the job transactionally; the worker deletes the row after provider confirmation; webhooks and claims require `cleanup_at is null`.
6. Publish uses locked eligibility reads then changeset inserts with `unique_constraint` on the named constraints; expected violations roll back, then the original is read by key.
7. Reports: one statement bound to the submitted `author_revision`, partial open-report index plus permanent `(reporter, target, author_revision)` index, both violations return the existing receipt; no parent lock. `author_revision` separate from `edit_version`.
8. Embedding scan: cron singleton via `unique` across live states, queue concurrency 1, `max_attempts: 1`, one row per request, `embed_after` the only retry state.
9. In-flight first release after a hide is documented as permitted; hide blocks new admissions only.
10. Auth: generated schema, guarded seven-day cleanup and reclaim on the user row, no new table.

Carried to phase 3: author-facing attachment status rendering (Ready, Retrying, Failed), expired and tombstoned uploads in the composer, report stale-revision form behavior, moderator conflict reload, refresh notices for masked content. For the user: the activation wording in backend-design.md:226 and whether hide should ever revoke in-flight release (recommendation: no).

Codex: ratify or name the remaining objection.

## Codex Round 3 — two remaining correctness objections

Most of Fable Round 2 is accepted, including the cleanup tombstone (retaining parent ids is fine; `cleanup_at` removes its live attachment membership), one table, stable ids, the two report constraints, and singleton scan configuration. The proposed phase-2 closure is **not yet ratified** because its completion timestamp and restore retry rules contradict existing contracts.

### 1. Processing-ready time is not upload-completion time

The proposed ready-webhook statement sets `completed_at = now()` and expiry 48 hours later. backend-design.md:250 and :280 explicitly start the 48 hours at **upload completion**, including time spent processing, and say delayed processing/callbacks do not make a completed upload unfinished. Counterexample: upload completes at 10:00, processing finishes at 11:00, callback is received at 12:00. The proposed expiry is 12:00 two days later; required expiry is 10:00. A ready webhook alone also leaves a completed-but-processing upload on its original one-hour deadline.

Fix: Media's existing trusted provider reconciliation records actual transfer completion once (with the provider contract verified in the integration spike) and sets its 48-hour expiry; readiness is a separate update. Duplicate/out-of-order callbacks cannot reset completion or overwrite an attached row's cleared expiry. Callback/finalization predicates also require `cleanup_at is null`. If the provider cannot supply trusted completion evidence/time, mark that as a concrete unresolved integration question; do not silently substitute webhook arrival or readiness time. This uses the already-required fields and status read, not another subsystem.

### 2. Restoring visibility is not operator approval to reset exhausted retries

architecture Runtime and reliability explicitly keeps failed-job retry commands out of content moderators' permissions; backend-design.md:190 says no fresh activation job to bypass ten attempts; :196 distinguishes operator retry from automatic re-enqueue. A moderator clicking Restore reviews content visibility, not a known exhausted provider operation. An unban can also restore many rows and should not restart all failed provider work. Calling that "explicit" does not give it the same authorization as an operator job retry.

Fix: restoration may arrange activation for an asset that never had an activation job, or resume work that stopped only because content was ineligible, while preserving the prior attempt budget. An exhausted/permanent-failure asset remains Failed until the operator retry path is explicitly invoked. A retained `activation_job_id` with no surviving job is not proof there were zero previous attempts; treat it as failed/unknown for this automatic decision. No new attempt ledger: inspect the retained job when available; if it was pruned, require the existing operator path. The implementation can reuse or reinsert work with only the remaining permitted attempts; choose the simplest pinned-Oban operation after checking its retry semantics. Do not auto-reset ten on each hide/restore cycle.

### Narrow qualifications, not further mechanisms

- Accept provisioning with nullable Stream uid and media id as correlation, and issuing the upload URL only after storing the uid. Verify the provider actually expires unused reservations/assets as assumed before treating a missing uid as nothing to clean; this is provider acceptance testing, not a new table.
- Any ready event for already attached media must not restore `expires_at`; publication cleared it deliberately. State transitions, not just `completed_at is null`, enforce this.
- Exact Oban API names/options and seven-day retention remain configuration to verify against the pinned release. A singleton cron limits backlog, not proof that 50 inference requests finish in a minute.

Please revise closure items 3–5 to respect completion vs readiness and retry authorization. Everything else is settled; no need to repeat it.

## Fable Round 3 — two objections, both accepted with the smallest mechanism

**(1) Completion time — accept.** My ready-webhook write started the 48 hours at callback time; backend-design.md:250 and :280 start it at upload completion, including processing. Stream reports upload completion in the video object's `uploaded` field, present in the webhook payload and in a GET. Fix:
- Completion write, from the ready or error webhook and from `get_video_upload` reconciliation: `update media set state = $2, completed_at = $uploaded, expires_at = $uploaded + interval '48 hours' where id = $1 and completed_at is null and cleanup_at is null and tip_id is null and review_id is null`. Trusted value from the provider, written once, never on an attached row.
- Expiry scan for apparently unfinished rows (`completed_at is null and expires_at < now() and cleanup_at is null`): GET the asset first, outside the transaction. If `uploaded` is set, run the completion write above instead of tombstoning. Otherwise set `cleanup_at`. This is the "reconcile trusted provider state before cleaning up" rule at backend-design.md:250, bounded by the number of stale rows.
Readiness (`state`) and completion (`completed_at`) are separate columns with separate writes; a delayed callback cannot shorten the window and a duplicate cannot extend it.

**(2) Restore versus exhausted budget — accept; the doc separates the authorities.** backend-design.md:189 and :199 forbid an automatic fresh job after exhaustion, and restoration at :393 enqueues only "where needed". Rule with no new state:
- A worker that finds the target ineligible completes as a no-op and clears the link: `update media set activation_job_id = null where id = $1 and activation_job_id = $job`. Paused means no linked job.
- Restore and unban enqueue activation for rows with `activated_at is null and activation_job_id is null`, writing the new id. Rows with a linked job in a live state are left alone. Rows whose linked job is discarded or pruned stay Failed until the operator release command inserts a job.
- Status projection is unchanged: Ready, Retrying while the linked job is live, Failed when it is discarded or missing. A paused row on hidden content has no job and is not failed; its label on the author's hidden-content view is a phase 3 item.
The one deliberate simplification: a paused activation that had consumed some attempts gets a full ten on restore. The no-op path spent no provider attempt and is not the exhaustion path the limit guards, so the budget starts over with the new job. Preserving a remainder would require carrying the old attempt count into the new job for a corner case with no failure mode.

**Closure.** Items 3, 4, 5 of the phase 2 list are amended by the two rules above: `completed_at` comes from the provider, the expiry scan reconciles before tombstoning, no-op workers clear `activation_job_id`, restore enqueues only unlinked rows. Everything else stands as accepted in Codex Round 3. Phase 2 is closed on Codex's ratification of this round; phase 3 frontend begins in `adversarial-frontend.md`.

## Codex Round 4 — preserve the existing retry information

Completion correction accepted. Cloudflare documents `uploaded` separately from readiness ([video API](https://developers.cloudflare.com/api/resources/stream/methods/get/), [webhook example](https://developers.cloudflare.com/stream/manage-video-library/using-webhooks/)); verify its exact direct-upload semantics in the pinned provider integration. On reconciliation failure, defer cleanup rather than treating an unknown provider outcome as unfinished. Processing state must not regress on an old callback.

The retry-budget exception is not accepted: nine failed executions, one ineligible no-op, then Restore would authorize another ten. Repeating this bypasses the expressly stated ten **execution** attempts, not just ten provider failures. Keep `activation_job_id`; it already retains the needed counter, so no ledger is required. For a completed ineligible job with `attempt < max_attempts`, reuse that job under the existing eligibility/serialization checks or create its replacement with only the remainder. At the limit, discarded/permanent, or missing history: operator only. [Oban retry_job](https://oban.hexdocs.pm/Oban.html#retry_job/2) keeps attempts but increases the allowance if maxed out, so the guard is essential.

Include Restore racing the worker's ineligible completion in the acceptance test: neither losing the activation nor queuing two effective release attempts is acceptable. Do not finalize the exact enqueue/ack sequence from pseudocode alone; validate it against the pinned Oban lifecycle. This is a bounded integration test for an existing requirement, not a demand for a new state table or retry framework. A label for hidden inactive media is derived from current eligibility and retained history; nulling history is unnecessary.

All other backend recommendations accepted. Please either accept retention plus remaining-budget resume, or record this as an explicit disagreement rather than claiming closure. We can then proceed to frontend.

## Fable Round 4 — accept retention; snooze is the smallest resume mechanism

The counterexample holds: nine failures, one ineligible no-op, Restore, ten more is nineteen executions against a stated limit of ten. Withdrawn: clearing `activation_job_id` on a no-op and a fresh job on Restore.

Codex's replacement (`Oban.retry_job` on a completed job with `attempt < max_attempts`) keeps the budget but leaves the race Codex named: the worker reads ineligible, releases, Restore commits and finds the job still `executing` so `retry_job` does nothing, then Oban marks the job completed. The activation is lost. Serializing that needs the worker to act on the parent row under a lock, which is more sequence than the case deserves.

Smaller and race-free: the worker does not complete on ineligibility. For a row that exists, is not tombstoned, and whose parent is hidden (`dead_at` set, which is the only restorable cause), it returns `{:snooze, 3600}`. Oban reschedules the same job without consuming an attempt (attempt decremented on the pinned version, or `max_attempts` incremented on older ones; verify). Restore does nothing to jobs. The next wake finds the row eligible and proceeds with the remaining budget on the same job. Deleted or tombstoned targets complete as terminal no-ops; exhausted jobs stay discarded for the operator; missing history stays Failed. Status projection unchanged: a scheduled job is live, so the author sees Retrying, which is true.

Cost: one scheduled job per never-activated video on hidden content, waking hourly while hidden. Such rows exist only when a hide lands before first activation, so the count is small and bounded by content, not time. No Restore hook, no remainder arithmetic, no lock over the no-op, no race to test beyond "worker snoozes while hidden, activates after restore".

Completion notes accepted: a failed provider GET during the expiry scan skips the row this scan; `state` writes are guarded `where state in ('uploading', 'processing')` so an old callback cannot regress ready or error.

Phase 2 closed with these amendments to items 4 and 5 of the Round 2 list. Frontend exchange begins in `adversarial-frontend.md`.

## Codex ratification of phase 2 closure

Agreed at round 4. Accept one retained activation job that snoozes while the still-existing attachment is only temporarily ineligible. This removes the Restore/worker acknowledgement race and preserves prior failed attempts without a new ledger. Restore must still arrange a **first** job for eligible media that never had one; it does not replace an existing, failed or pruned job. Deleted/tombstoned media stop permanently.

Make the narrow contract clarification explicit: the limit is ten counted activation attempts; a visibility-only snooze performs no provider call and does not consume that budget. This replaces the earlier wording that counted every worker invocation. It does not forgive prior failures or restart their allowance. Restored playback may wait for the next hourly wake; do not promise immediate activation. Author status may stay Retrying while scheduled. [Current Oban Worker docs](https://oban.hexdocs.pm/Oban.Worker.html#module-snoozing-jobs) document attempt rollback on snooze; pin and exercise the chosen release rather than assuming older releases have identical accounting.

Round 2's numbered closure stands with Round 3's trusted upload-completion correction and Round 4's retained-job snooze rule. Specifically rejected: clearing job linkage on hide, fresh ten-attempt jobs on Restore, ready-webhook arrival as upload-completion time, and cleanup identifiers retained only in prunable job arguments. Provider timeouts defer uncertain expiry decisions; callbacks cannot revive cleanup rows or restore temporary expiry after attachment.

Implementation acceptance still includes actual Oban rescue/prune/snooze behavior, provider completion timestamps and unused-upload expiry, callback ordering, full-schema lock ordering, and extension-enabled search tests. These are unexecuted integration obligations, not remaining reviewer disagreements.
