# Elixir/Phoenix idioms review — backend

Date: 2026-09-20. Status: phase 2 consensus reached in 3 rounds. Final disposition is the Round 2 closure amended by Codex Round 3 and Fable's final ratification; earlier proposals include withdrawn claims.

Review agreement: [architecture](idioms-architecture-review.md). Current design contracts only; review findings are not implemented fixes. Preserve earlier `adversarial-backend.md`.

## Accepted implementation map

| Need | Smallest agreed mechanism |
|---|---|
| Exact counters across ordinary and bulk writes | Two narrow PostgreSQL delta triggers in Ecto migrations; no duplicate application counter updates |
| Safe publication retry | UUID submission key, database unique index, changeset constraint annotation, rollback then authorized original-record lookup |
| Stale edit protection | Prefer Ecto `optimistic_lock` for ordinary changesets; guarded Ecto updates where clearer; preserve original expected version and whole-edit/no-op semantics |
| Re-report eligibility | Plain `author_revision` field plus report uniqueness constraints; moderator changes do not advance it |
| Transaction composition | Ordinary context functions with `Repo.transact`; `Ecto.Multi` when clearer; required Oban inserts inside the same transaction |
| Bulk restoration/invalidation | Lock subject accounts before discovering mutable membership; maintain ordered locks; review votes need the direct review lock, not its ancestor tip |
| Video readiness | One bounded, fairly rotated worker scan; editor reads DB only; provider recovery capability must be verified |
| Video activation/retry | Existing Oban lifecycle and retained job identity; no second attempt-counter scheduler |
| Edit-upload identity | Account plus stable content identity; remove redundant edit-version binding and rebind operation |

No new dependency is required for the three rules raised by the owner. Read the final ratification for qualifications; the debate below intentionally retains superseded proposals as review history.

## Codex (Valim lens) — Round 1

**Initial verdict:** ordinary context functions, Ecto changesets and explicit transactions fit the product. The database-specific pieces serve concrete invariants. The highest-value simplification is reducing media status update paths; the highest-risk proposed simplification is replacing Oban's attempt/state machinery with another scheduler hidden in `media`.

The architecture file owns the admission/privacy/context-boundary chains. This phase refines them and covers the remaining backend hotspots. Each chain uses first principles, Occam and 80/20; product reductions are labelled explicitly.

### B-J1 — High design hazard: discover the affected content set after locking the subject account

Evidence: backend :172 says "Discover immutable ids first, lock, and recheck eligibility"; data-model :32 says bulk operations first discover ids, then lock users/parents; publication locks its author before insertion (:519–522); unban restores all the subject's shadow-hidden content (:595). These are design statements, not implemented code.

Whys: (1) Why lock in one order? Triggers/FKs and concurrent operations can acquire the same rows. (2) Why discover parent ids? Updating a review also updates its tip counter. (3) Why is pre-lock discovery insufficient? A publisher can commit another review before unban obtains the author's lock. (4) Why does a recheck of eligibility not fix it? The *membership* of the affected set changed, not just an existing row's eligibility. (5) Why does that hurt? Updating only old ids strands content; updating every matching row can acquire an undiscovered parent out of order. (6) Why not retry dynamically? The author's existing eligibility lock already prevents new publication. (7) Why anything more? Locking the stable accounts first and then discovering content resolves the root without new infrastructure.

**Smallest fix:** for `Accounts.lift_ban`, determine actor/subject ids, lock those accounts in sorted order, then discover all current affected tips/reviews, prelock their parent tips sorted and reviews sorted, recheck and update in the same transaction. Distinguish early lookup of immutable identities from discovery of a mutable affected set. Do not create a generic lock planner. Other bulk operations must state how their affected membership is stabilized; do not blindly expand this rule into locking every user in the database.

**Downstream:** preserves counter lock order, restoration and first activation enqueue. Acceptance schedule: publish a new review between preliminary lookup and account-lock acquisition; unban must restore it without late parent-lock acquisition. This is a concrete counterexample to a literal algorithm, not a claim that an implementation already deadlocks. [Postgres lock documentation](https://www.postgresql.org/docs/current/explicit-locking.html#LOCKING-DEADLOCKS) supports consistent acquisition order; this schedule is our analysis.

### B-J2 — Medium proposal under challenge: keep Oban as the owner of activation attempts

Evidence: backend :200–208; phase-1 Fable Round 2 proposes replacing `activation_job_id`/snooze with `activation_attempts`, a failure marker and enqueue-on-each-restoration.

Whys: (1) Why keep a job after hiding? Activation is unfinished durable work. (2) Why snooze? Temporary ineligibility is not a failed provider attempt. (3) Why preserve the same job? Restoration must not reset the attempt budget. (4) Why derive status from it? Oban already records executing/retrying/discarded state. (5) Why move counters to media? It appears to remove the retained-job/pruning relationship. (6) Why might that add work instead? Application code must now settle interrupted reservations, concurrent attempts, final-attempt status and re-enqueue races. (7) Why does the root remain? Durable work still needs attempts, ownership and recovery regardless of which table holds them.

Two counterexamples for Fable's candidate:

- **Lost wake-up:** a job sees hidden content and prepares to finish. Restoration commits while that old job is still `executing`; active-job uniqueness returns the existing job instead of inserting another. The old job then completes. The media is live and unactivated with no future job. A retained snoozed job avoids this race.
- **Final attempt:** incrementing `activation_attempts` to ten before the call cannot immediately mean Failed—the tenth call is in flight and may succeed. A crash after reservation or provider success needs a rule distinguishing in-flight, uncertain and exhausted work. Adding a lease, watchdog or another scheduler to solve this would offset the claimed removal.

**First principles/Occam:** retain the existing single Oban job unless the replacement proves these cases with fewer mechanisms. **80/20:** hide scheduler details behind one author-status projection and shorten repeated specification prose; do not move scheduling into media merely to remove a foreign-looking job id. Existing media cleanup records are different: they retain external identifiers that job pruning must not erase. No need for a general-purpose job abstraction.

### B-J3 — Medium: a single bounded provider status scan can replace callback and request-time reconciliation

Evidence: backend :196, :250–252, :275, :280, :298; frontend :144. Phase 1 agrees on DB-only editor status reads and leaves webhook versus polling open.

Whys: (1) Why multiple update paths? Webhooks are quick; reads recover missed events. (2) Why must readiness be durable? Reopened editors and cleanup need trusted completion state. (3) Why does every browser need provider reads? It does not if that state is reconciled independently. (4) Why retain webhooks with a scan? Faster feedback and lower polling load. (5) Why is that worth another endpoint now? No sub-minute readiness requirement or production traffic measurement establishes it. (6) Why not one bounded scan? The app already schedules maintenance with Oban. (7) Why is polling not free? It adds provider traffic and readiness latency, so its cadence and fair progress must be explicit.

**Recommendation:** for this MVP, prefer worker-only polling plus five-second DB-only editor reads; omit the Stream webhook endpoint initially. Use the pinned Oban release's supported periodic scheduling, initially minute-based rather than inventing a 30-second scheduler. Poll only unresolved/provisioning/processing rows that need reconciliation. Bound batch size and request timeouts; rotate fairly across rows, including failed provider reads, so a long upload or poison row cannot monopolize every batch. A last-checked timestamp may be the smallest fair-selection aid; it is not a second retry engine. Phase 2 must settle its exact ownership.

**Tradeoff:** readiness may appear on a later tick and slower under backlog; do not promise "at most one minute" when queue wait, provider time and batch rotation exist. Keep trusted completion timestamps, terminal-state guards, claim/cleanup locking, and uncertain provisioning recovery. Poll responses can still be stale or arrive after discard; removing webhooks does **not** remove those business guards. If measured latency or provider cost warrants it, add verified callbacks later to the same update function. This is a recommended UX/operations tradeoff, not an already implemented behavior-preserving edit.

### B-J4 — Low, optional simplification: one-use Postgres domains

Evidence: data-model :19 and :46–49 define role, ban, report reason and notification type as text domains; each is used for one field. Backend :127 calls for Ecto where clear and focused SQL where necessary.

Whys: (1) Why domains? Reject values outside a fixed vocabulary. (2) Why a global database type? Reuse constraints across many columns. (3) Why here? Each vocabulary currently has one column. (4) Why not a named column check? It enforces the same invariant with standard Ecto migration support. (5) Why an Elixir custom type too? `Ecto.Enum` already casts the finite application vocabulary. (6) Why retain another abstraction? No demonstrated reuse remains; two further whys do not change this.

**First principles:** enforce finite values both at input and database boundaries. **Occam/80–20:** recommend `Ecto.Enum` backed by ordinary text plus named CHECK constraints, removing four global domain objects and their migration ordering. This is a small greenfield simplification, not a correctness blocker; keeping domains is valid PostgreSQL and not inherently unidiomatic Elixir. Do not add an enum synchronization code generator. [Ecto.Enum](https://ecto.hexdocs.pm/Ecto.Enum.html) and [migration constraints](https://ecto-sql.hexdocs.pm/Ecto.Migration.html#constraint/3) provide the ordinary mechanisms.

### B-J5 — Preserve: counter triggers and database-generated ranks

Evidence: data-model :17–18, :300–328; backend :166. Historical concurrency evidence belongs to earlier fixtures and is not this review's execution result.

Whys: (1) Why store counts? Lists need indexed rankings and cheap displayed totals. (2) Why not recompute joins on each page? The indexed sort depends on those totals. (3) Why triggers? Every vote/review transition, including bulk moderation, changes the same invariant. (4) Why not write counts in each context operation? That duplicates delta rules across many transitions. (5) Why retain explicit parent locks too? Triggers acquire locks; their order still must fit the larger transaction. (6) Why create counter processes or a generic event bus? Nothing requires asynchronous counts. (7) Why change the owner? One database-owned invariant is smaller than several application-owned copies.

**First principles/Occam/80–20:** retain the two narrowly scoped delta triggers, constraints and generated rankings. Implement them in migrations with focused SQL and test the real transaction flows. Keep provider calls and notifications out of triggers. Read returned counters after trigger execution; do not add client deltas or Ecto callbacks that double-update them. A PostgreSQL-specific feature is acceptable when it removes application complexity.

### B-J6 — Preserve: publication keys, edit versions and report revisions have different jobs

Evidence: backend :308–335, :343–359, :396; data-model :500–576, :600–610.

Whys: (1) Why a submission UUID? The first commit can succeed while its response is lost. (2) Why not compare text? Identical text need not mean the same intended publication. (3) Why an edit version as well? An old editor must not overwrite a newer change. (4) Why a separate author revision? Moderator retag/removal must invalidate an editor without making a new author revision reportable. (5) Why not collapse all three? They identify different events and would change retry/moderation semantics. (6) Why a generic idempotency service or event log? Existing rows and named unique constraints already carry the necessary facts. (7) Why more abstractions? The root is explicit operation identity, not a missing framework.

**Smallest solution:** keep the three identities where used; ordinary changesets for validation/inserts, one explicit conditional guard for edits, named constraints and after-rollback lookup for conflicts. No blanket `optimistic_lock` plus duplicate manual guard, no request-log table, no automatic replay with a fresh version. Preserve original input on ambiguity. Product alternative: simplifying re-report policy could remove `author_revision`, but that changes which reports are allowed; no evidence here justifies that cut.

### B-J7 — Preserve, narrow implementation: shared visibility and projection

Evidence: backend :174; data-model :445–456, :498; author-deleted, moderator-hidden and shadow-hidden states have intentionally different outcomes.

Whys: (1) Why centralize projection? A title/media leak can occur through a profile, search excerpt or metadata, not just the tip body. (2) Why not only filter live rows? Placeholder pages and independently visible child reviews are required. (3) Why track hiding causes separately? Unban must not undo deliberate moderation. (4) Why another presentation framework? The same few visibility decisions can be pure functions. (5) Why insist on literally one universal function for every return shape? That would couple unrelated list/page structures. (6) Why multiple policy copies? Shared decision functions can feed focused tip/review/link/media projections. (7) Why anything more? There is no need for DTO inheritance, schema macros or a policy DSL.

**Recommendation:** interpret "one Content projection function" as one shared policy with small explicit projection functions as needed, not an obligatory universal recursive serializer. Return only the authorized fields needed by each operation. Keep author-deletion precedence and query-level eligibility. Test full return shapes/metadata, not merely a helper's boolean result. This clarifies implementation freedom and removes a potential abstraction; it does not assert the current prose requires an implemented serializer.

### B-J8 — Preserve: generated auth with bounded registration cleanup

Evidence: backend :434–500; data-model :330–340. Architecture phase 1 already rejects removing admission checks.

Whys: (1) Why start with `phx.gen.auth`? Token creation/expiry/renewal and sensitive-action flows already exist. (2) Why adapt it? Public handles, deletion and confirmation are product rules. (3) Why expire unconfirmed accounts? Otherwise unverified signups reserve identity indefinitely. (4) Why reclaim on conflicting registration as well as scheduled cleanup? The agreed seven-day reservation must not depend on maintenance timing. (5) Why lock the row during verification and cleanup? A confirmed account must not disappear in a race. (6) Why a second pending-signup store? It duplicates generated token/account lifecycle. (7) Why more process state? Existing rows and one guarded cleanup function suffice.

**First principles/Occam/80–20:** reuse generated account/token machinery and its lifetimes, add only the handle/expiry checks and one reusable cleanup operation. Keep direct bounded Swoosh delivery outside transactions. For operation admission prefer a shared generated-query-based helper and explicit secret redaction; a server-derived row reference is acceptable only if it preserves token expiry/context and is never accepted as browser proof. Do not add a second session registry to avoid one database lookup.

### B-J9 — Preserve with bounded calls: LiveView image ownership and one embedding scan

**Images**, backend :236–238, data-model :767–773. Whys: (1) Why upload on submission? That is the agreed image lifecycle. (2) Why retain temporary files on failure? A known rejected save should be retryable while the page lives. (3) Why postpone consumption? Consuming ends LiveView's ownership of the temp file. (4) Why synchronous Content work? It keeps file lifetime straightforward while transferring to R2. (5) Why not put those paths in Oban? A durable job can outlive them. (6) Why page-held R2 staging? It adds reusable-object cleanup races already avoided by per-attempt keys. (7) Why change without measurement? Bounded file/provider limits and a disabled submit state are simpler until latency proves otherwise. Keep the current path; test worst allowed payload/provider delays before adding async staging. This is not evidence that synchronous upload performance already passes.

**Embeddings**, backend :197, :214; data-model :670–679. Whys: (1) Why async? Publication should not depend on inference availability. (2) Why a scan? Eligible current text is already in Postgres. (3) Why no per-row job? It would require publication/edit/restore hooks plus the same stale-text guard. (4) Why `embed_after`? Poison rows must cool down while other rows proceed. (5) Why `max_attempts: 1` on the scan? Retrying both the whole batch and each row duplicates scheduling. (6) Why not a dedicated process/cache? Oban periodic scheduling and a version-guarded update already recover after restart. (7) Why more? Throughput measurement, not another queue design, resolves capacity uncertainty. Keep the documented exception scoped to this scan; it is not permission to hand-build retries for all workers.

### Highest-leverage scope option, separate from the implementation recommendations

Native managed video is the largest optional feature by machinery count. Whys: (1) Why video? Authors can show a recorded workflow. (2) Why native hosting? Consistent upload/playback and evidence retention. (3) Why needed for every initial trial? Written firsthand accounts already satisfy publication requirements; images are optional too. (4) Why incur all provider lifecycles before validating demand? The current documents record a feature choice, not trial evidence establishing that native video is essential. (5) Why assume an external link is equivalent? It is not: privacy, availability and the integrated composer change. (6) Why silently remove it? That would override scope rather than simplify implementation. (7) Why a staged alternative? A text/image-first trial can test core discovery/trust with fewer failure boundaries.

**80/20 product alternative:** defer native video for initial trials and retain text/images plus ordinary author-supplied links where appropriate. This removes more machinery than weakening private-draft guarantees. It is explicitly a product-scope reduction, not the default accepted design or authorization to edit it. If native video remains a launch requirement, keep privacy and choose the smallest reliable lifecycle above.

### Questions for the counter-review

Challenge B-J1's schedule; prove the proposed activation-counter replacement handles both races in B-J2 without recreating Oban; decide worker-only polling versus callbacks with explicit cadence/fairness; challenge whether removing four domains pays for itself. Identify additional backend hotspots missing from the chains. Do not prescribe abstractions merely because no implementation exists yet.

## Fable (McCord lens) — Round 1

**Phase 1 wording confirmed.** Item 4: an explicitly redacted private token or a server-derived reference are both acceptable if generated expiry and revocation semantics hold; a client-supplied id is never session proof. Item 7: Media owns durable processing state; callbacks versus worker polling is decided here. Keyword-only launch is a labelled product alternative, not permission; the hybrid evaluation is required validation.

Method per hotspot: whys until two more do not move the root, then first principles, Occam, 80/20. Each recommendation is tagged **preserving** or **product cut**. No implementation exists; these are design risks.

### Responses to Codex Round 1

**B-J1 — accept.** The schedule is real: discovery before the subject lock can miss a review that a concurrent publish commits under the old shadow state, because publish holds the author lock only briefly. Lock actor and subject accounts first, then discover the affected set, then prelock parents and reviews in id order, then write. This applies to unban and to bulk hide by author; every other operation has a fixed target. It also fixes the wording at backend :172: "immutable ids" are the accounts, not the content membership.

**B-J2 — concede; candidate withdrawn.** Race 1 (lost wake-up) is answerable: make activation uniqueness exclude `executing` (`states: [:available, :scheduled, :retryable]`, allowed by [Oban.Job unique options](https://oban.hexdocs.pm/Oban.Job.html)), so Restore always inserts when no pending job exists, and the media row lock plus the `activated_at` check serialize the two workers; the provider call is idempotent. Race 2 (final attempt) is not answerable without a job link: with the counter reserved before the call, "ten and not activated" is either Failed or in flight, and only a live job distinguishes them. Adding the link back makes the candidate no smaller than the retained job. Keep the retained Oban job with the hourly visibility snooze from the earlier phase-2 closure. The only clarification I keep: author status reads `oban_jobs` by the retained id in one left join; a missing row means Failed. That is already the agreed projection.

**B-J3 — accept, with the cadence and fairness made concrete, preserving root requirement, latency labelled.** `* * * * *` through `Oban.Cron` (minute granularity is the plugin's minimum), `media` queue, unique across incomplete states, `max_attempts: 1`. Each tick: at most 50 rows where `kind = 'video' and cleanup_at is null and state in ('uploading','processing')`, ordered by `checked_at nulls first, created_at`; one GET per row with a 5 s timeout; write `checked_at = now()` whether or not the GET succeeded so a failing row rotates to the back; guarded writes `where state in ('uploading','processing') and cleanup_at is null` for state, and `where completed_at is null and tip_id is null and review_id is null` for trusted completion. The same GET answers the expiry question for apparently unfinished rows, so this scan replaces the separate expiry reconciliation; a row past its authorization deadline with `uploaded` absent is tombstoned in the same tick. One `checked_at` column, one worker, no webhook route, no signature verification, no ordering rules for callbacks. Latency: readiness lands on a later tick, typically within two minutes at MVP volume, longer under backlog; not promised as one minute. Verified callbacks can be added later as a second writer of the same function.

**B-J4 — accept, and apply it consistently.** `media.kind` and `media.state` already use inline checks (data-model :218–:224); the four domains are the odd ones out. `Ecto.Enum` plus a named column CHECK for all six.

**B-J5, B-J7, B-J9 — accept as written.** Counter triggers stay; projection is one shared policy with small shape-specific functions; image ownership and the embedding scan stay.

**B-J6 — accept; my planned challenge is withdrawn.** I had a chain collapsing `author_revision` into `edit_version`. Its saving is one integer column and one increment; its cost is one extra allowed report after each moderator action. Neither side moves the product. Not worth a round.

**B-J8 — accept the foundation; challenge one mechanism (see B-F3).**

**Scope option (defer native video) — agree on classification.** It is the largest single removal available and it is a product cut. Recommended default stays: native video with draft privacy, the retained job, and the polling scan. The owner has the alternative on record.

### B-F1 — Medium, preserving: explicit user and parent locks belong to publish, not to votes, reports or edits

Evidence: data-model :25 (rule 11), :30–32, :530 ("Lock the actor and relevant account rows, then the parent tip and review if applicable, before writing the vote"), :596 (reports lock the reporter); backend :172 ("lock participating user rows in id order, then parent tips ... then reviews ... then dependent rows").

Chain. Why lock the actor's user row? So an eligibility read serializes against ban, unban and deletion. Why does that matter? Rule 11: an unlocked subquery can admit a write under stale account state. Why does stale state hurt? For publish, a tip inserted with `shadowed_at` from a pre-unban snapshot is stranded, because unban discovers content under the author lock (B-J1). Why does it hurt for a vote? It does not: a shadow-cast vote is never revived by unban (data-model :30, :532); the user re-votes and it becomes live. A vote or report admitted a millisecond before a full ban is the same class the design already accepts as "already-admitted work may finish" (data-model :36). Why lock the parent tip on a review vote? The trigger updates `reviews`, not `tips` (data-model :300–:314); nothing in the transaction touches the tip row. Why lock the target at all on a tip vote? The counter trigger locks it anyway, in the same transaction, after the vote row; no second writer needs an earlier lock. Two more whys do not move the root: the user lock protects restoration membership, which only publish affects.

First principles: lock what the transaction writes or what a later restoration depends on. Occam: publish (tip and review) locks the author, and review publish locks the parent for the live check and the trigger. Votes: the single guarded insert and its trigger. Reports: the single guarded insert and its two unique indexes. Edits: the version guard with the eligibility predicate in the statement. Bulk operations keep the full ordered prelock. 80/20: votes are the hottest write path; today every review vote on a popular tip serializes on that tip's row through an app-level lock with no writer behind it.

Downstream: backend :172 and data-model :25, :530, :596 narrow to "publish locks the author; review publish locks the parent; bulk operations prelock in order". The lock-order rule stays the same for the operations that still lock. No product change.

### B-F2 — Medium, preserving: the encoded upload `target` has no threat behind it

Evidence: backend :274 (`begin_video_upload(scope, target, ...)` checks "target-specific permissions ... and whether a new submission already published"), :278 (four target tuples), :280 ("One server-owned encoder turns the typed target tuple into `target`"), :282 ("require the same author/target/submission"), :284 ("explicit reapplication must validate the same author and content target before binding them to the reloaded version"); data-model :211 (`target text`), :747.

Chain. Why record a target at upload time? So a staged video attaches only to the content it was uploaded for. Why does that matter? "It must not attach a video to a different author or draft" (backend :250). Why not a different author? `user_id` on the row already prevents that. Why not a different draft of the same author? No stated harm: it is the author's video and the author's content. Why bind an edit upload to `expected_version`? So a stale editor cannot attach it, but :284 then allows rebinding after reload, so the version is a check that is always waived. Why check "whether a new submission already published" before an upload? A retry returns the original publication and the staged video expires unattached in 48 hours. Two more whys stay at the same place: every property the target enforces is already enforced by ownership, the unattached-and-ready claim under the row lock, and the content operation's own permission checks.

Occam: `begin_video_upload(scope, file_attrs)` requires a confirmed, not fully banned account and the rate limit. A claim at publish or edit requires `user_id = author`, unattached, `state = 'ready'`, not expired, not tombstoned, under `FOR NO KEY UPDATE`. Drop the `target` column, the encoder, the four tuples, the "same target" checks and the rebind rule. Draft recovery checks author and expiry only. 80/20: one column and one encoder removed from the most-specified flow in the backend, with no change to what any user can do.

### B-F3 — Low, root requirement preserved with a labelled one-hour delta: registration should not reclaim expired signups inline

Evidence: backend :443 ("Registration must also reclaim an expired unconfirmed row that blocks the requested handle or email, using the same guarded cleanup operation ... Lock multiple conflicting identities in id order"); data-model :334–:336.

Chain. Why reclaim during registration? So the seven-day reservation does not depend on cleanup timing (Codex B-J8 why 4). Why does timing matter? If cleanup runs daily, a handle can be held up to eight days. Why not run cleanup hourly? Then the overrun is at most one hour on a seven-day window. Why is the inline path costly? It puts a delete-and-retry branch, ordered locking of up to two conflicting rows, and token-reuse reasoning inside the most sensitive flow in the app. Why lock rows in verification and cleanup at all? Both are single guarded statements; under Read Committed the second one re-evaluates its WHERE after the first commits, so a confirmed row survives the delete and an expired row fails confirmation with zero rows. Two more whys unchanged.

Occam: one hourly maintenance job, `delete from users where confirmed_at is null and inserted_at < now() - interval '7 days'` with tokens cascading; confirmation is `update users set confirmed_at = now() where id = $1 and confirmed_at is null and inserted_at > now() - interval '7 days'` plus the generated token consumption. No explicit row locks, no inline reclaim. Registration on a conflict says the handle or email is taken, which is true until cleanup runs. Delta, labelled: an expired signup can hold a handle for up to one hour past seven days. Nothing else changes.

### B-F4 — Low, preserving: deferrable slot constraints guard against a writer that cannot exist

Evidence: data-model :237–:238 (`media_tip_slot`, `media_review_slot` deferrable), :568–:570 (`SET CONSTRAINTS ... DEFERRED`, "duplicate final slots fail at commit"); backend :355.

Chain. Why unique `(parent, position)`? To reject duplicate slots. Why deferrable? Swaps inside one edit. Why does the database need to reject them? Only if two writers can race; edits are serialized by the `edit_version` compare, so at most one edit commits per version. Why keep it for application bugs? The changeset already validates one unique ordered selection of at most ten (backend :355). Two more whys unchanged: the constraint duplicates a validation that has no concurrent bypass.

Occam: keep `position between 0 and 9`; drop both deferrable constraints, the `SET CONSTRAINTS` step and the commit-time error mapping. Order attachments by `(position, id)` so a latent bug degrades to a stable order rather than a failed edit. Preserving.

### Changesets, SQL, projection, idempotency, auth: no further findings

Guarded single-statement writes with the eligibility predicate inline and the row count as the result are the right shape; use `Repo.update_all` returning `{count, rows}` rather than a CTE that spans `tips` and `tip_search` (data-model :566), since both statements already share the transaction. Changeset inserts after locked checks with `unique_constraint` on the named constraints, rollback, then read-by-key: correct and idiomatic. The submission key, edit version and count-matched inbox mark-read each guard a real race the earlier reviews reproduced; nothing to remove. Generated auth with the seven-day expiry stays, minus the inline reclaim above.

### Blockers to phase 2 consensus, from my side

1. B-F1: lock scope narrowed to publish and bulk operations, or a counterexample where an unlocked vote, report or edit strands restorable state.
2. B-F2: `target` removed, or a threat that ownership plus the unattached-ready claim does not cover.

B-F3 and B-F4 are recommendations; B-J1 through B-J9 are accepted as above.

## Codex (Valim lens) — Round 2

### Agreed findings and withdrawn candidates

Accept Fable's confirmation of phase 1, B-J1's account-before-membership discovery, B-J2's retained Oban job, B-J4's enum/check simplification, and B-J5–B-J9 with the qualifications below. The custom activation counter candidate is withdrawn: moving attempt state into media did not remove the need to track execution. Excluding executing jobs from uniqueness can allow another pending attempt, but media locks must never be held across provider calls; a short eligibility lock alone does not serialize those calls. We need not finish designing that rejected replacement.

### B-F1 — reject blanket lock removal; allow a proven narrower lock set

Whys: (1) Why prelock a target before changing its votes? Both the vote write and a bulk operation can touch the same target and vote row. (2) Why does the counter trigger not solve order? It locks the target *after* the vote row. (3) Why does that matter? A bulk operation takes the target *before* that vote row. (4) Why is this a real cycle? Ordinary vote holds vote V and waits for tip T; bulk invalidation holds T and waits for V. (5) Why would it be avoided by simply keeping locks on bulk only? It would not—the operations must share the order. (6) Why lock every ancestor regardless? That is a separate question; a review vote updates the review, not necessarily its parent tip. (7) Why a generic rule? An explicit per-operation lock set is smaller and more accurate.

**Counterexample:** the proposed child-first vote versus parent-first bulk invalidation deadlocks, irrespective of vote restoration semantics. No runtime reproduction was performed in this review; the row-lock cycle follows directly from the proposed order and the trigger. This is why "trigger locks it anyway" is insufficient.

**Narrow recommendation:** retain target-before-vote ordering and required account locks for the current eligibility contract. Review votes need not automatically lock their tip merely because a review has a parent: remove that lock if the operation neither checks a parent invariant nor writes it through a trigger/notification path, and demonstrate the full lock graph with bulk invalidation/moderation. Reports already have a documented exception from parent locking. Do not generalize an exception into removing all account/content eligibility locks.

Fable's "already admitted may finish" concerns **session** revocation at operation admission, while the current business contract explicitly rechecks account eligibility under write locks. Changing votes/reports/edits to snapshot-only account eligibility is a possible policy change, not a mechanical equivalent of the current contract. No evidence here requires weakening it to ship the MVP. Keep the standard transaction path; measure contention before adding selective complexity.

### B-F2 — simplify edit-target versions; label removal of target binding accurately

Whys: (1) Why bind a staged upload? The saved form must refer to the evidence prepared for that intended submission. (2) Why isn't account ownership the entire contract? The current design explicitly forbids attaching a video to a different draft (backend :250). (3) Why is that useful? It contains accidental cross-form references and makes discard/recovery intent local to one draft. (4) Why bind an edit to an old version too? The content's expected-version guard already rejects a stale edit. (5) Why rebind after an explicit reload? Prepared evidence should remain reusable for the same target once the author deliberately reapplies. (6) Why store the version in the media target at all? That repeats a guard and creates a rebind operation. (7) Why remove all binding to solve that? Keeping stable target identity removes the extra mechanism without broadening the upload's intended use.

**Smallest preserving recommendation:** for edit uploads, bind to the owning account and stable content identity, not `expected_version` in the encoded media target. Keep the edit operation's expected-version guard, current eligibility and explicit reapplication UI. For new publications retain submission-key/parent binding. This removes version rebinding while preserving the original content/draft destination.

**Product alternative:** account-owned, unattached uploads claimable by any of that account's drafts can remove `target` entirely. That does not inherently weaken cross-account privacy, and is a plausible simpler product rule, but it expressly changes the current no-cross-draft rule. It also makes sharing an unclaimed id across drafts subject to first-claim/discard wins. Record this as an alternative, not a security defect or equivalent refactor. No need to invent a threat to justify honest scope labelling.

### B-F3 — optional reservation-policy cut; no one-hour guarantee

Whys: (1) Why reclaim inline? A valid signup should not be refused because expired reservations await maintenance. (2) Why can periodic deletion leave a gap? Scheduling, queue load and outages delay it. (3) Why does hourly scheduling not bound that gap to one hour? A schedule is not a completion guarantee. (4) Why tolerate a gap? It removes a delete/retry branch from registration. (5) Why does the root matter? The product must choose exact expiry at use or eventual reservation release. (6) Why two cleanup implementations? Even exact expiry can reuse one guarded cleanup function in both paths. (7) Why replace generated verification with a one-line UPDATE? Token consumption, confirmation and login must still form one valid operation.

Keep the existing exact-expiry/reclaim default. Record scheduled-only cleanup as an explicit product alternative: expired identities may remain unavailable until maintenance succeeds, potentially longer than one hour. Guarded UPDATE/DELETE can acquire the necessary row lock implicitly, but verify the *whole* generated token-confirmation flow; do not replace it with illustrative SQL that omits token semantics. This is not a blocker.

### B-F4 — reject dropping attachment-slot constraints

Whys: (1) Why unique slots? Saved attachment order is a durable invariant. (2) Why defer the check? A valid swap temporarily reuses occupied positions. (3) Why does input validation not make it redundant? It validates intended selection, not every intermediate persistence statement or future writer. (4) Why does optimistic versioning not prove valid slots? It chooses one winning edit; the winning edit can still write an invalid order. (5) Why tolerate duplicate slots and sort by id? That silently stores a result that does not express the author's requested order. (6) Why keep the check? Two small constraints and a transaction-local defer replace that latent ambiguity. (7) Why more machinery? No additional service/state is involved; ordinary database enforcement is already the pattern here.

**First principles/Occam/80–20:** keep the constraints and defer only inside the reorder transaction. This is consistent with retaining other named database checks alongside changeset validation. An unexpected constraint violation may be treated as a bug after rollback; no generalized commit-error framework is needed. The proposed stable tie-breaker changes the failure guarantee and saves very little code.

### B-J3 refinement — accept polling-only, make its recovery contract complete

Accept one minute-based scan in the existing media queue, active-job uniqueness, `max_attempts: 1`, at most 50 selected records per pass and bounded provider requests. The `checked_at` timestamp is a fair-selection aid, not another attempt budget. Order by `(checked_at NULLS FIRST, created_at, id)`; bound overall work as well as individual calls and rotate failed attempts. Measure backlog/latency; withdraw the unmeasured "typically within two minutes" statement from acceptance criteria.

Four corrections to the literal algorithm:

1. A provisioning row may have `stream_uid = NULL`. It cannot use the same GET-by-uid path. Preserve the already-required provider correlation/recovery by media id, and prove that integration before considering provisioning complete. Unknown provider outcomes do not authorize deletion.
2. An expired authorization is not proof of an unfinished transfer. Tombstone only after a successful trusted read establishes the contract's expiry condition; timeout/5xx/unknown outcome must not become "uploaded absent".
3. Poll results can be stale relative to discard, claim or another state transition. Apply completion/state/expiry changes through the same locked/guarded Media operation, requiring current ownership/lifecycle eligibility; an already attached row must never regain expiry. Removing callbacks does not remove this check.
4. Ready or failed unattached videos also need expiry cleanup, yet the proposed scan selects only uploading/processing. Keep a bounded expiry branch for those rows and the retained cleanup jobs. Share trusted reconciliation for unfinished rows rather than claiming the active-state scan alone covers every cleanup case.

These are necessary parts of the one-worker approach, not grounds to add a generic reconciliation framework. Prefer a single worker with focused ordinary functions and explicit active/expiry selections. If this becomes more machinery than keeping callbacks, re-evaluate with the implemented integration; today it still removes a web endpoint and one provider-read owner from every editor.

### Proposed backend disposition

Agree on the public context/transaction foundation and the preserved invariants. Adopt B-J1, polling-only status reconciliation with the refinements above, enum/check fields, small shared projection functions, and stable edit-upload identity without media-version rebinding. Retain Oban activation state and database slot constraints. Do not remove the vote target's prelock. Keep product cuts (no native video; account-wide staged uploads; eventual registration release) explicit and unapplied.

Please challenge the vote/bulk lock cycle and the narrower upload proposal, then ratify or identify the remaining disagreement. No runtime concurrency or provider tests have been claimed as executed.

## Fable (McCord lens) — Round 2: lock graph, concessions, proposed closure

### B-F1 — the cycle is real; the lock that breaks it is the voter's account, not the target

Codex's schedule: a vote that updates an existing vote row V (changing value) holds V, then its trigger waits for tip T; bulk invalidation holds T (prelocked) and waits for V. Confirmed as a cycle when the two operations touch the same V, which happens only when the voter is the banned user. For an inserted vote there is no cycle: bulk cannot see or wait on an uncommitted insert.

Full graph, with `U_x` the user row, `T` the tip, `R` a review, `V_x` a vote row of user x, `S` the search row, `N` a notification row, `F` a flag:

| Operation | Lock order as proposed here |
|---|---|
| Vote by x on T (tip or review target) | `U_x` → `V_x` (insert/update) → target via trigger (`T` or `R`) → `N` (fold) |
| Vote invalidation of x | `U_x` → parents in id order → `V_x` rows |
| Bulk hide by author a | `U_a` → `T`s → `R`s → trigger `T`s |
| Unban a | `U_a` (then discover, B-J1) → `T`s → `R`s |
| Review publish by a on T | `U_a` → `T` → `R` insert → trigger `T` → `N` |
| Tip edit by a | `U_a` → `T` → `S` |
| Tip delete by a | `U_a` → `T` → `N`s → media |
| Single hide/restore/retag of T | moderator `U` → `T` (→ `S` for retag) |
| Report by x on T | `F` insert only |
| Inbox mark-read | `N` rows only |

Vote versus invalidation of the same user serialize at `U_x`; that is what removes the cycle. Vote by y on T versus any bulk operation over author a: bulk never waits on `V_y` or `U_y`; y's trigger waits on `T` with no reverse edge. Vote versus review publish, edit, delete, hide, retag: all take `T` before anything the vote holds after `T`; the vote holds only `V_y` before `T`, which none of them touch. Notifications: every writer that takes both `T` and `N` takes `T` first (vote via trigger, delete via prelock). Reports touch one new row. Two more whys do not change the graph: the target prelock in an ordinary vote has no reverse edge to protect.

Revised B-F1, **preserving**: votes lock the voter's account row, then write; no target prelock for tip or review votes. Publish, edit and delete keep the author lock; bulk operations keep the full ordered prelock; reports keep the single insert. The account lock is retained for the cycle, and it also keeps the eligibility recheck under a lock, so Codex's policy objection does not arise. Withdrawn: removing the account lock from votes and edits.

Acceptance for phase 2: the schedule above (existing vote update by x concurrent with invalidation of x) runs without deadlock; a vote by y during bulk hide of a on T commits after the hide. No runtime test was executed here.

### B-F2 — accept the narrower cut as the default; full removal recorded as the product alternative

Accept: edit uploads bind to the account and the stable content id, not to `expected_version`; the edit operation's version guard remains the only version check; no rebind operation. New publications keep the submission-key or parent binding. This removes the version-in-target and the rebind rule, which were the mechanisms I objected to.

Recorded alternative, **product cut**: account-owned unattached uploads claimable by any of that account's drafts, removing `target` entirely. It changes the no-cross-draft rule at backend :250; it does not change cross-account privacy. I still find no user benefit behind that rule, but that is a product judgement and it is on record for the owner.

### B-F3 — accept the default; alternative recorded

Agreed that a schedule is not a completion guarantee and that "at most one hour" was overstated. Keep exact expiry with inline reclaim as the default. Scheduled-only release stays a recorded **product alternative**. Two points of agreement worth keeping: guarded UPDATE and DELETE statements acquire the row lock implicitly, so the "lock the same user row" prose at backend :443 and data-model :334 can describe the guard instead of an explicit lock; and the whole generated token-confirmation flow, not an illustrative single statement, is the unit that must be verified.

### B-F4 — concede

A single winning edit can still persist a bad order through an application bug, and the constraint is two lines plus one transaction-local defer. Keep the deferrable slot constraints. Withdrawn.

### B-J3 — accept all four corrections

1. Rows with `stream_uid` null are provisioning rows; the scan recovers them by the media-id correlation the design already requires (creator or metadata on the reservation), and tombstones only after the authorization deadline passes with a trusted read showing no asset. Unknown outcome: skip this tick.
2. Expired authorization alone never tombstones; only a trusted read establishing the contract's expiry condition does. Timeout, 5xx or unknown outcome retries on a later tick via `checked_at` rotation.
3. Every state, completion and expiry write goes through the same guarded Media operation that callbacks would have used: `cleanup_at is null`, lifecycle-eligible, never restoring expiry on an attached row, never regressing a terminal state.
4. Selection has two branches in one worker: provider reads for `uploading`/`processing` rows, and expiry for any unattached row with `expires_at < now()` regardless of state, which needs no provider read because `expires_at` derives from trusted completion. Both branches bounded; the retained cleanup jobs are unchanged.

Withdrawn: the "typically within two minutes" statement.

### Proposed phase 2 closure

Consensus reached at round 2, subject to Codex's ratification. Later phases refine but do not contradict phase 1 or this list.

1. Context functions, changesets for casting and inserts, one guarded statement per conditional write with the row count as the result, named constraints mapped after rollback. `Repo.update_all` per table rather than cross-table CTEs.
2. Lock order: accounts, tips, reviews, dependents, each in id order. Publish, edit and delete lock the author; review publish locks the parent; votes lock the voter only and take the target through the trigger; reports insert without locks; bulk operations and unban lock accounts first, then discover membership (B-J1), then prelock parents and reviews.
3. Activation: one retained Oban job per attachment, hourly visibility snooze, ten counted provider attempts, `activation_job_id` retained across pruning, status from the row plus one left join on `oban_jobs`. Restore enqueues a first job only for never-enqueued media. Operator retry through release commands.
4. Video processing state: no webhook endpoint. One minute-cadence media worker, unique across incomplete states, `max_attempts: 1`, bounded per tick, `(checked_at nulls first, created_at, id)` rotation, 5 s per provider read, provisioning correlation by media id, trusted-read-only tombstoning, expiry branch for all unattached rows, all writes through the guarded Media operation. Editors read Postgres only. Latency measured, not promised. Callbacks may be added later as a second writer.
5. Upload targets: new publications bind to submission key or parent; edits bind to account and content id; no version in the target; no rebind. Full target removal is a recorded product alternative.
6. Fixed vocabularies: `Ecto.Enum` with named column CHECKs for role, ban, flag reason, notification type, media kind and state; no domains.
7. Counter triggers, generated rankings, deferrable slot constraints, submission key, `edit_version`, `author_revision`, count-matched inbox mark-read: kept as designed.
8. Projection: one shared visibility policy feeding small shape-specific functions; every returned shape tested.
9. Auth: generated flow, seven-day exact expiry with inline reclaim, guards expressed as single statements whose implicit row locks suffice; the whole token-confirmation flow is verified, not a single statement.
10. Images: built-in LiveView uploads, postponed consumption, synchronous Content attempt; embeddings: one bounded cron scan with `embed_after`.

Recorded product alternatives, none applied: defer native video for the first trials; account-wide claimable uploads; scheduled-only registration release; keyword-only launch if the hybrid evaluation fails.

Carried to phase 3: author status rendering including snoozed jobs, composer states for expired, tombstoned and provisioning uploads, report stale-revision form, moderator conflict reload, editor draft revision guard, admission helper placement in `on_mount` and event handlers.

Unresolved from my side: none.

### Fable library addendum — existing mechanisms re-evaluated (user steering)

Question: are there libraries for counter triggers, submission keys and separate edit/report revisions, and which idiomatic mechanisms make each simple? Checked against current Ecto, Oban and Phoenix docs. Where an existing mechanism is the better fit, I revise the closure rather than defend the earlier rule.

| Need | Library or built-in | Assessment for Tips |
|---|---|---|
| Counter caches | No maintained hex library. Ecto's documented idiom is `prepare_changes/2` running `update_all(inc: [...])` in the changeset's transaction. | Eight transitions change live-ness: publish, author delete, hide, restore, unban, bulk hide, vote value or dead change, vote removal. Four run through `update_all`, where `prepare_changes` does not apply, so the delta rule would live in two places. The two `AFTER` row triggers keep it in one. **Keep triggers.** Add one release command that recounts, as the design already allows. |
| Submission keys | `idempotency_plug` caches HTTP responses by header; wrong layer for LiveView events and for content identity. | Client UUID plus `unique_constraint(:submission_key, name: :tips_submission_unique)` in the changeset, rollback on `{:error, changeset}`, then read the original by key. This is already the design and it is the idiom. **Keep.** |
| Edit version | `Ecto.Changeset.optimistic_lock/3`. It compares the version held in the struct, increments it, and with `Repo.update(cs, stale_error_field: :edit_version)` returns `{:error, changeset}` on mismatch instead of raising. | **Revise the closure.** For single-target writes (tip and review edits; moderator hide, restore, retag, destroy media) the idiomatic path is: read the row with `lock: "FOR NO KEY UPDATE"`, check ownership, deletion, the two-hour window and account state in Elixir on the locked structs, set the struct's `edit_version` to the editor's expected value, build the changeset, `optimistic_lock(:edit_version)`, `force_change(:author_revision, rev + 1)` only for an actual author change, then `Repo.update` with `stale_error_field`. Eligibility is stable because the lock is held through commit. This replaces the hand-written compare-and-increment `UPDATE ... WHERE edit_version = $12`. The earlier "never `optimistic_lock/3`" wording was too categorical; the rule that survives is one version mechanism per write. Guarded `update_all` stays for set-shaped writes: bulk hide, unban, vote invalidation, author delete, registration cleanup. No-op detection: compare `changeset.changes` minus the lock field before updating. |
| Author and report revisions | No library. | `author_revision` is a plain forced change on the same changeset; `flags.author_revision` is a column bound by the insert. Nothing to add. |
| Conditional upserts (vote, notification fold) | `Repo.insert` with `on_conflict:` as an `Ecto.Query` carrying `update:` and `where:`, `conflict_target: {:unsafe_fragment, "(user_id, tip_id) WHERE tip_id IS NOT NULL"}`, `returning: true`. | Covers both the vote statement (update only when value or dead state changes) and the fold (`inc: [count: 1]`) without raw SQL. **Use it.** |
| Transactions | `Repo.transact/1` for simple; `Ecto.Multi` with `Oban.insert/5` for publish, edit, delete and moderation, since Oban's Multi variant keeps unique-job semantics inside the transaction. | **Use Multi where a job is enqueued**, `transact` elsewhere. |
| Row locks | `Ecto.Query` `lock: "FOR NO KEY UPDATE"`. | Ordinary Ecto. |
| Fixed vocabularies | `Ecto.Enum` plus named `check` constraints. | Closure item 6. |
| Per-user rate limit | `Hammer` with its ETS backend fits a single node. | Adequate for the app-side limit; per-IP stays at Cloudflare. |
| R2 and Stream | `req_s3` for R2 (S3-compatible), plain `Req` for the Stream API; `Req.Test` for the seams. | Matches closure item 9 of phase 1. |
| Vector type | `pgvector` hex package provides the Ecto type and query helpers. | Use it; pg_textsearch operators stay as fragments. |
| Markdown | `MDEx` (fast, with sanitization options) or `Earmark`. | Either satisfies raw-HTML-off and `rel` rewriting; pick during implementation. |

Amendments to the proposed phase 2 closure: item 1 gains "single-target versioned writes use `optimistic_lock/3` with `stale_error_field`; set-shaped writes use guarded `update_all`"; item 7 keeps `edit_version` and `author_revision` with that mechanism split. Nothing else changes. Codex, please confirm or object in the same round.

## Codex (Valim lens) — Round 3: libraries and final eligibility corrections

The library question changes our implementation recommendation, not the three distinct invariants. I accept the revised use of Ecto optimistic locking with the qualifications below. I accept Round 2's closure except for the lock/eligibility and mandatory-Multi statements below; these need explicit ratification before phase 2 closes.

### B-F1: the voter account breaks that cycle, but target eligibility still matters

Concede: retaining the voter account lock serializes that voter's existing-vote update against invalidation; my earlier two-row schedule assumed its removal. That deadlock alone does not prove a target prelock necessary.

However, the revised graph does not preserve the current target-eligibility contract. Schedule: voter locks its account and the vote statement sees a live tip; moderator commits hiding the tip; vote's trigger subsequently locks the now-hidden tip and increments its counters, and the operation may fold a notification. The trigger does not recheck target eligibility. The SQL snapshot predates its wait. Round 2 explicitly accepts the vote committing after hide, but the current design locks target eligibility through the mutation. This is distinct from session admission being allowed to finish after revocation.

**Smallest preserving disposition:** keep the direct voted-on target locked before the vote write; for a review vote, remove the ancestor tip lock because reviews remain independently votable and count-only review updates do not update the tip's review count. Keep the voter account lock. A snapshot-at-statement vote policy is a legitimate alternative, but label that concurrency-policy change instead of calling it preserving. Reports keep the reporter account lock explicitly required by backend :396; no target lock is needed because that same contract intentionally allows the author edit to overlap the report snapshot. Round 2's closure accidentally dropped this distinction.

### Built-in mechanisms, without a new dependency

Five whys for the mechanism choice: (1) Why revisit mechanisms after validating rules? A necessary rule can still have an unnecessarily custom implementation. (2) Why prefer Ecto? The project already uses it and its primitives make the intent recognizable. (3) Why not force every rule into changesets? Bulk queries do not run changeset callbacks. (4) Why not add a specialized package for each? Extra lifecycle and storage owners can exceed the work removed. (5) Why preserve separate report revision? Its meaning is a product rule, not generic locking. (6) Why stop here? The remaining operations are ordinary fields, constraints and transactions; another abstraction would not remove a failure boundary.

- **Counters:** Ecto documents `prepare_changes/2` with an atomic `update_all(inc: ...)` counter example. That is an idiomatic alternative for a changeset-only write path. Tips has bulk/SQL transitions as well, so keep the two triggers as the sole delta owner. Do not claim that no maintained counter library exists; the defensible result is that we have not identified a better-fitting dependency. [Official Ecto example](https://ecto.hexdocs.pm/Ecto.Changeset.html#prepare_changes/2).
- **Publication identity:** UUID plus actual `(user_id, submission_key)` database uniqueness, annotated by `unique_constraint`, followed by rollback and authorized original-row lookup on conflict. The annotation does not create the index. [IdempotencyPlug](https://idempotency-plug.hexdocs.pm/IdempotencyPlug.html) handles HTTP headers and cached responses; adding that request lifecycle does not replace this LiveView/domain invariant.
- **Edit conflicts:** prefer `optimistic_lock(:edit_version)` for ordinary single-record changesets when it replaces the manual compare/increment. The original expected version must remain explicit: a freshly locked row's version must not silently replace the editor's value. Check stale version before accepting a no-op, and determine actual changes before adding the lock increment. Associated tag/media changes count too; `changeset.changes` on the parent alone is not sufficient. Then bump `author_revision` only for an actual author change, update the version once, and commit search/media/job effects in the same transaction. A guarded Ecto `update_all` remains idiomatic where a conditional/set-based write is clearer; no mandatory raw SQL and no second version mechanism. [Official optimistic locking](https://ecto.hexdocs.pm/Ecto.Changeset.html#optimistic_lock/3).
- **Report identity:** keep a plain author-revision integer and the two report uniqueness constraints. No history/versioning package is needed for a history that the product does not store.
- **Transactions:** retain the existing choice of ordinary `Repo.transact` or `Ecto.Multi` based on clarity. Oban supports insertion inside a Repo transaction as well as Multi; job insertion alone does not require converting all surrounding control flow to Multi. Required enqueueing stays inside the transaction. The library addendum's other packages are candidates, not newly audited or version-pinned dependencies.

This is first principles plus Occam: keep one owner for each invariant and use a built-in where it actually removes code. The 80/20 gain is replacing bespoke version/upsert plumbing while retaining the two small triggers that cover every writer. No implementation or benchmark was performed.

### Final requested ratification

Accept the corrected direct-target vote lock, no review-vote ancestor lock, reporter account lock, built-in version mechanism with whole-edit/no-op handling, and optional Multi. Other Round 2 closure items accepted, with provider correlation recovery still an implementation proof obligation rather than a verified provider capability. Then begin phase 3.

## Fable ratification — phase 2 complete in 3 rounds

All Round 3 corrections accepted; none needs a further round.

- **Vote target lock, accepted as preserving.** With the target locked before the insert, a vote that waits behind a hide runs its insert under a fresh statement snapshot and inserts nothing; without it, the vote lands on the hidden target and folds a notification to its author. That is a visible delta, so snapshot-at-statement voting is a labelled concurrency-policy alternative, not the default. Order for a vote: voter account, direct target (tip, or review only), vote row, trigger, notification. The graph in Round 2 stays acyclic with this addition because every writer takes the target before the vote row.
- **Reporter account lock restored** in closure item 2; no target lock for reports, per backend :396.
- **Multi optional**: `Oban.insert/2` inside `Repo.transact` is equally valid; choose by clarity. Required jobs stay inside the transaction.
- **Optimistic lock qualifications accepted**: the editor's expected version is set on the struct explicitly and never replaced by the locked row's value; stale is checked before a no-op is accepted; "actual change" includes tag and media changes, not only the parent's `changeset.changes`; one version increment per edit; search, media and job effects commit in the same transaction.
- **Counter wording corrected**: no better-fitting dependency was identified; the triggers remain the single delta owner because four transitions bypass changesets.
- Provider correlation by media id is an implementation proof obligation, not an assumed provider capability.

Phase 2 closure is the Round 2 list with these amendments. Recorded product alternatives remain unapplied. Phase 3 begins in `idioms-frontend-review.md`.
