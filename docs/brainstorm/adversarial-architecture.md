# Adversarial review — overall architecture

Date: 2026-09-20. Status: consensus reached in 2 rounds. Phase 1 of 3 complete.

## Read first

Keep the Phoenix monolith. The blocking work is reconciling current contracts, serializing related writes, and refreshing operation authority—not adding architecture layers. The final agreed recommendations are under **Phase 1 closure**, qualified by Codex ratification. Round 1 contains proposals later corrected or withdrawn; do not implement it in isolation.

The full review reached consensus in all three phases: architecture in 2 rounds, [backend](adversarial-backend.md) in 4, and [frontend](adversarial-frontend.md) in 2. The frontend report ends with the cross-phase implementation priorities. Backend closure refines the write rule to allow ordinary changeset inserts after locked eligibility checks; it also settles report uniqueness and the retained-job activation lifecycle. No source design document was edited.

## Review agreement

The user requested review of the combined data-model, backend, and frontend decisions. Include software-architecture.md as the governing foundation. Review only; changes to source designs are recommendations, not implemented fixes.

Fable (pane wJ:p1): senior Elixir/Phoenix implementation and conventions perspective. Codex (pane wJ:p2): orthogonal end-to-end invariants, failure recovery, and MVP complexity perspective. Both challenge findings and fixes, checking local correctness, downstream impact, then whole-system behavior. Preserve product requirements unless explicitly identifying a proposed product change. Prefer ordinary Phoenix/Ecto/Postgres capabilities and the smallest working solution.

Each round consists of both reviewers' analysis/rebuttal. Append sections under your own name; do not overwrite the other reviewer. Consensus requires an explicit response to remaining objections, not silence. Stop at consensus or 10 rounds and record unresolved differences. Later phases may refine but must not silently contradict earlier conclusions.

## Scope and evidence

Sources: docs/design/technical/software-architecture.md, data-model.md, backend-design.md, frontend-design.md. Line references refer to the source documents as read on this date. Historical test claims do not establish correctness of later requirements.

## Codex Round 1

### Root problem (five whys)

1. Why can locally reasonable decisions fail together? Their guarantees cross database, provider, LiveView and browser boundaries.
2. Why are those boundaries inconsistent? Interview amendments override executable-looking SQL without replacing it.
3. Why does that matter during implementation? Each layer can implement its own apparently authoritative contract.
4. Why will local tests miss the mismatch? Historical fixtures test the earlier baseline, and successful single-operation tests do not exercise overlapping transitions.
5. Why not add another orchestration layer? Ownership already exists in Accounts/Content; the missing work is reconciling contracts and transitions there. Two further whys do not change the answer: use one current contract and test its cross-boundary outcomes.

### A-C1 — High: the design is not yet one implementable specification

Evidence: data-model.md:15,29-43,200-204,272-282,568,638-640,794-800; backend-design.md:7,499-503. The data model is called the reference yet retains combined hiding, image-only storage, no confirmation state, lifetime report uniqueness, and old deletion projections. Several omissions are honestly labelled; do not report them as deployed bugs. The risk is implementing incompatible baselines or mistaking old test results for current verification.

Smallest fix: reconcile current requirements into the actual schema/queries/fixtures, removing superseded instructions from the normative path. Keep old SQL in existing brainstorm/history files if useful. No new specification framework. Accept changes by complete flows, not by independently signing off these files.

Effects: migrations, read projections, write guards and tests change together. Preserve monolith, two contexts, explicit transactions, triggers, LiveView and Oban. A rewrite into more contexts/services would not address the cause.

### A-C2 — High: guarded SQL is not a cross-row serialization contract

Evidence: data-model.md:25,470-491,505-521,533-539; backend-design.md:147,186,392-396. Reads of users/parent eligibility inside INSERT/UPDATE do not lock those rows against concurrent restriction/visibility changes. Example: publishing reads shadow ban; concurrent unban scans existing hidden content and commits; publication inserts afterward with obsolete hiding state, stranded after unban. A review can pass a live-parent read while deletion commits before its insert/counter update. Existing tests only establish pre-write changes and vote/counter races.

Smallest fix: a documented, consistent locking/transition contract for participating account and content operations; recheck eligibility under those locks. Keep provider calls outside transactions. Cover user restriction/deletion, publication, parent visibility, report snapshots and attachment claims. Do not prescribe serializable isolation globally or a distributed lock. Backend phase must prove actual order, including trigger-acquired locks.

[Postgres Read Committed documentation](https://www.postgresql.org/docs/17/transaction-iso.html) establishes the snapshot limitation; these Tips race examples are our analysis, not executed tests.

### A-C3 — High: live-session authority must include session validity

Evidence: architecture Caller identity and access; backend-design.md:147,309,477 (email-change revocation); frontend-design.md:29. Current user/role checks alone do not invalidate an already-running LiveView after session token revocation if it keeps only user identity. A disconnect is useful lifecycle behavior but an old scope must not remain authority for writes or privileged reads.

Smallest fix: specify how authenticated context entry points refresh caller/session validity, including moderation reads and async work; reuse generated session resolution/disconnect handling. Keep public reads public. No generic authorization engine. Backend/frontend phases should decide the narrow contract and test a revoked session's still-running socket.

### A-C4 — Medium: async-only search and readable initial HTML need one contract

Evidence: backend-design.md:61-63 and frontend-design.md:17,66-70. LiveView async tasks start only when connected, so a direct GET /search?q=... cannot obtain server-rendered results by using assign_async alone. The sentence saying this does not change initial HTML requirements does not implement them.

Smallest fix proposal: initial direct search GET performs bounded keyword retrieval for readable HTML; connected submitted searches use async hybrid retrieval. Explicitly replace rather than append if upgrading the initial results, or keep keyword results until a new interaction. Fable: challenge whether that mode difference is worse than a bounded synchronous initial hybrid call or an explicitly scoped search-loading exception. Keep normal public tip/browse HTML synchronous.

[LiveView async documentation](https://phoenix-live-view.hexdocs.pm/Phoenix.LiveView.html#module-async-operations) confirms connected-only task startup.

### A-C5 — Medium: unverified search stack is on the primary product path

Evidence: backend-design.md:13-27; data-model.md:9,716-790,828; architecture Runtime and reliability. Discovery is the first complete journey, but the chosen extension/parser/query/embedding combination has not been run. Synthetic counter timings do not verify search or single-VPS coexistence with embedding inference.

Smallest fix: retain agreed hybrid search but run a focused deployment spike using pinned actual Postgres/pg_textsearch/pgvector and production-compatible embedding runtime. Verify representative developer queries, filtered branches, fallback, timeouts, memory and restore. Do this before designing more search infrastructure. If infeasible, present an explicit product tradeoff; do not silently replace agreed relevance behavior or build a search service.

### Challenge to Fable

Please challenge the recommended serialization scope and the initial-search proposal. Is there a smaller conventional Phoenix solution that preserves the exact user-visible guarantees? Also look for complexity that can actually be removed without deleting agreed product behavior.

### Codex Round 1 addendum — executed race evidence

Ran a reduced-schema two-session reproduction on local Postgres 18.6 in an isolated temporary database, then removed that database. Script: `docs/brainstorm/adversarial-account-race.py`. Publication inserts under a shadow ban and remains uncommitted; unban updates the user and restores currently visible rows; publication then commits. Baseline result: account unbanned, new tip still hidden. With publication locking its user row before checking eligibility: unban waits for publication and restores the committed tip. This proves A-C2's narrow failure and repair, not the complete lock graph or revised production schema.

Output: baseline `account_unbanned|content_still_hidden=true|true`; locked `true|false`.

## Fable Round 1

Role acknowledged: senior Elixir/Phoenix implementation and conventions. I read all four source documents independently before reading Codex's round. Findings first, then responses to Codex, then executed evidence.

### Root problem (whys)

1. Why do the four documents disagree in places? They were written as decisions, not as one implementation contract.
2. Why does that bite in Elixir specifically? The data model is written as raw SQL while the architecture and backend say "Ecto", and nobody has said which one owns the schema, the guarded writes, and the tests.
3. Why does that matter now? The first implementer picks one, and the other document becomes fiction. Two more whys do not change this: decide the ownership rules once, in the architecture.

### A-F1 — High: schema and query ownership is undefined between raw SQL and Ecto

Evidence: architecture "Use Ecto and Postgres"; backend-design.md:128,162,166; data-model.md:43-268 (domains, generated columns, triggers, views), 470-475 and 485-491 (data-modifying CTEs), 544 (`Ecto.Changeset.optimistic_lock/3`).

Problems, each concrete:
- `Ecto.Migration` cannot express domains, generated columns, triggers, functions, or views. They need `execute/2` with explicit down steps. Nothing says so.
- Because of triggers and functions, `mix ecto.dump` / `structure.sql` (`config :tips, Tips.Repo, ... ; mix test` with `ecto.load`) is required for test setup, or tests must run every migration. Nothing says so.
- `Ecto.Query.with_cte/3` does not support data-modifying CTEs. The one-statement publish and delete CTEs need `Repo.query!` with hand-bound parameters, losing the changeset error mapping the backend relies on.
- `optimistic_lock/3` is a changeset mechanism that puts only `edit_version` in the WHERE. The guarded edit also needs ownership, ban, deletion, and the two-hour window in the same WHERE (data-model.md:533-539). Using both is two mechanisms for one write.

Smallest fix, all standard Ecto:
- Migrations are the schema truth; the markdown SQL becomes the body of `execute` calls. Generate `priv/repo/structure.sql` and load it in test.
- Guarded writes use `Repo.update_all/insert_all` with a full WHERE and `select:`/`returning:`; the `{count, rows}` result is the row-count check the design already requires. Drop the `optimistic_lock/3` reference.
- Publish uses `Repo.insert_all(Tip, eligibility_query, returning: [:id, :dead_at])` (Ecto accepts a query as the insert source), then the search-row, self-vote, media, and job inserts as ordinary statements inside `Repo.transact`. Same atomicity as the CTE, no raw SQL.
- Generated columns are declared `read_after_writes: true`. Reads of live content go through the view without a second schema: `from t in {"live_tips", Tip}`. That keeps the live predicate in one place, which the hiding-cause change (data-model.md:29-31) will need.
- `Repo.query!` is reserved for the search fusion statement.
- `Repo.transact/2` exists from Ecto 3.13; pin that floor.

Downstream: changesets stay for input validation only. The search SQL and triggers are untouched. No new library.

### A-F2 — High: the 2 s role-level `statement_timeout` breaks migrations, backups, and repair

Evidence: data-model.md:812 sets `statement_timeout = '2s'` on the app role. Architecture line 91 runs migrations through the release command with the same Repo config. Migrations build HNSW and BM25 indexes (data-model.md:313-316), and rule 4 says to drop and recreate `hot_score` and its index. `pg_dump` and the counter recount (data-model.md:906-918) run on the same database.

At the fixture size in the data model these exceed two seconds. The deploy step "a failed migration must stop the deployment" would then fail every deploy that adds an index.

Smallest fix: `statement_timeout` is user-settable, so each long migration starts with `execute "set statement_timeout = 0"` (Ecto's `@disable_ddl_transaction true` migrations for `CONCURRENTLY` keep it session-wide). Run `pg_dump` and operator repair as the database owner role, which has no timeout. Keep the 2 s default on the app role for request traffic. Add the rule to Runtime and reliability.

### A-F3 — Medium: stale authority has a stated rule and no mechanism

Evidence: architecture line 83 "Long-lived LiveViews must not treat an old scope as permanent permission." data-model.md:391-400 and 429-441 take `$3 viewer is moderator` from the caller, while writes already check `moderator($2)` in SQL (data-model.md:578). backend-design.md:460 already uses the generated session disconnect for email changes.

Gap: a moderator demoted or banned while a moderation LiveView is open keeps privileged reads until remount. Writes are safe; reads are not.

Smallest fix, two lines of policy:
- Privileged read queries derive the moderator flag in SQL with the same `moderator($2)` predicate the writes use, from the scope's user id. One index probe per page.
- Ban, unban, role change, and account deletion call the generated `UserAuth.disconnect_sessions/1` for that user's tokens after commit, the same way email change already does. The LiveView remounts with a fresh scope.

No per-call token verification. See my response to A-C3.

### A-F4 — Medium: Oban shutdown and orphan recovery are not configured against Compose

Evidence: architecture "gracefully stop the old app" (line 91) and "Configure and test the chosen Oban version's recovery of interrupted jobs, graceful shutdown" (backend-design.md:192).

Oban's `shutdown_grace_period` defaults to 15 s; Docker Compose's `stop_grace_period` defaults to 10 s. The container is SIGKILLed while Oban is still draining, and the job stays `executing` with no process. Without `Oban.Plugins.Lifeline`, that job is never rescued.

Smallest fix: enable `Oban.Plugins.Lifeline` (open source) and set `stop_grace_period` above the Oban grace period. Add both to the deployment section. Record that the release traps SIGTERM into `init:stop`, so a plain Compose stop is already a graceful BEAM shutdown.

### A-F5 — Medium: embeddings have two retry schedulers on paper

Evidence: backend-design.md:183 asks to reconcile `embed_after` with Oban; data-model.md:157,164,718-727 define the per-row scan with `embed_after`; backend-design.md:394 needs restored content to become eligible again.

Per-row Oban jobs would need enqueueing at publish, edit, retag, unhide, and unban, and would still need the `text_at` check. The periodic scan already handles every case, including restarts and restoration, because it selects `embedding is null` joined to live content.

Smallest fix: one Oban cron job (`Oban.Plugins.Cron`, every minute, `unique`, `max_attempts: 1`) that runs the existing bounded scan. `embed_after` stays the only retry state. No per-row jobs, no enqueue at restoration. This resolves the backend's open item without a new mechanism.

### A-F6 — Medium: no test seam for external providers

Evidence: architecture line 29 and 127 prefer community capabilities and built-in testing; no document names an HTTP client or how R2, Stream, or the embedding server are faked in tests.

Smallest fix: one HTTP client (`Req`), one small behaviour per provider (`Tips.Content.Media.Storage`, `.Video`, `Tips.Content.Search.Embedder`), the implementation chosen by config, `Mox` in test. This is the standard Elixir convention and costs three behaviours. Swoosh already provides this for email.

### A-F7 — Medium: development and CI databases cannot run the search SQL

Evidence: data-model.md:9 and 828: the local server lacks pgvector and pg_textsearch. Architecture line 127 wants built-in tests to validate the user journey; search is the first journey.

Smallest fix: development and test use the same pinned `timescaledb-ha` image through a `docker-compose.dev.yml`; `mix test` requires it. Then the search statement, filters, and fallback are ordinary ExUnit tests. This also answers Codex A-C5 without a separate spike framework.

### A-F8 — Low: the embedding call on the request path needs a timeout, and Load more re-embeds the query

Evidence: backend-design.md:58 defines fallback for "temporarily unavailable"; backend-design.md:116 uses the same `search_tips` for later pages.

A slow embedding server is the likely failure on a shared VPS, not an absent one. Give the embedding call a bounded timeout and treat timeout as fallback. Keep the page-one query vector in the search LiveView's assigns and pass it for later pages; it is the same kind of retained state as the query and filters. One fewer inference per Load more.

### A-F9 — Low: "exposed through Content" contradicts "no wrapper layers"

Evidence: backend-design.md:368 exposes Moderation operations through `Tips.Content`; architecture line 9 rejects matching layers of wrapper modules.

Smallest fix: the web layer calls `Tips.Content.Moderation`, `.Media`, `.Search` directly. Phoenix contexts are modules; nested modules are still the context. No `defdelegate` layer.

### Responses to Codex Round 1

A-C1 (one implementable specification): Accept the risk; reject the remedy as stated. "Reconcile the markdown" produces a fourth document. The reconciliation target is A-F1: migrations and `structure.sql` are the schema truth, ExUnit fixtures replace the historical SQL scripts, and the markdown SQL stops being normative once the migration exists.

A-C2 (guarded SQL is not a serialization contract): Accept the race; I reproduced Codex's script locally, both outputs identical. Reject the remedy's scope. A "locking and transition contract covering user restriction, deletion, publication, parent visibility, report snapshots and attachment claims" is a document nobody will keep current. The actual conflicts are two, and both are one clause each:

1. Eligibility reads on `users` inside a write take a row lock: `... from users u where ... for no key update`, inside the insert-select. Not `for update` as in Codex's script: `for update` also conflicts with the `key share` lock every one of that user's own inserts takes through the foreign key, so `for update` would block the user's concurrent vote for the transaction's duration. `for no key update` is the strength `UPDATE users SET ban` itself takes, which is exactly what must serialize.
2. Parent-liveness reads for a new review take `for no key update` on the tip row. Not `for share`: the counter trigger then upgrades to `no key update` on the same row, and two concurrent reviews on one tip deadlock. Executed below.

Everything else Codex lists is already a single-row compare-and-set: report dismissal and retag check `edit_version` in the WHERE, attachment claims lock the upload rows (backend-design.md:264). Lock order falls out naturally: user row, then tip row, then review row; every write listed already touches them in that order. Record that order as the one rule. No serializable isolation, no advisory locks.

A-C3 (session validity): Reject per-call session verification. The generated `disconnect_sessions/1` kills the socket; the LiveView remounts and `on_mount` re-resolves the token. The remaining window is the milliseconds between commit and broadcast in the same function. In that window, a revoked session belongs to the same user id, whose writes are still guarded by `users` state in SQL, so nothing crosses a permission boundary. The real gap is A-F3: privileged reads take the moderator flag from the scope. Fix that in SQL and reuse the disconnect on ban and role change. One query per operation to re-verify a token would double the write cost for a window that cannot be exploited.

A-C4 (initial search HTML): Reject the two-mode proposal. Keyword results on the dead render, hybrid results after connect, means the page visibly reorders itself a fraction of a second after load, two retrieval paths to test, and two queries per shared link. The honest alternatives are:

- (a) Run the same `search_tips` synchronously in both mounts. Identical results, no flip, but two hybrid searches and two embedding calls per direct GET.
- (b) Async only. The initial HTML carries the query, applied filters, and a loading state; results arrive after connect. One search per page. Browse and tip pages stay synchronous.

Recommend (b), and change backend-design.md:55 from "does not change the initial public HTML requirement" to an explicit exception for search results. Search is reached by pressing Enter on a connected page; a direct GET of a search URL is the shared-link case, and search pages carry `noindex`. If the user considers server-rendered search results a requirement, (a) is the smallest implementation that gives them; (c) is not. User's call on the requirement; my recommendation is (b).

A-C5 (unverified search stack): Accept. It is already listed under Before implementation (data-model.md:999-1000). The missing piece is A-F7: without the pinned image in development, the spike cannot become a test. Add one measurement to the spike: document embedding of a 20,000-character body on the VPS CPU, since the embedding runtime shares the machine with Postgres and Phoenix.

Complexity that can go without touching product behavior: per-row embedding jobs (A-F5), the `optimistic_lock/3` mechanism (A-F1), the delegation layer (A-F9), and the second embedding call per Load more (A-F8).

### Executed evidence

Script: `docs/brainstorm/adversarial-lock-variants.py` (isolated temporary database, Postgres 18.6, removed afterwards). Reduced schema with the counter trigger.

| Test | Setup | Result |
|---|---|---|
| T1 | Codex's unban race, lock as `for no key update` inside the insert-select | tip visible after unban (fixed) |
| T2 | Two concurrent reviews on one tip, parent read `for share`, counter trigger | one transaction aborted with deadlock |
| T3 | Same with parent read `for no key update` | no deadlock, both reviews inserted, count 2 |
| T4 | Review insert with parent `for no key update` while deletion is uncommitted | insert waits, re-evaluates, inserts nothing |

Codex's script also reproduced here: baseline `true|true`, locked `true|false`.

### Challenge to Codex

Show a third real cross-row conflict that the two lock rules and existing compare-and-set guards do not cover. If there is none, the "locking and transition contract" reduces to the lock-order sentence in my A-C2 response. On A-C4, state which of (a) or (b) you accept and why the two-mode version is worth its second retrieval path.

## Codex Round 2 — rebuttal and proposed closure

Fable's independent review strengthens the implementation boundary and catches a real lock-upgrade trap. I accept keeping the lock rule short. I do not accept framework claims or a session-revocation guarantee without checking the failure path.

### Responses to Fable findings

- **A-F1: accept migration ownership; narrow the implementation prescription.** Ecto migrations become executable schema truth, using `execute` where needed; tests run the migrations. A structure dump is optional acceleration, not mandatory architecture. Two factual corrections: Ecto migrations support generated columns with `generated:`, and `with_cte` supports update/delete operations (the specific multi-insert CTE is a separate limitation). See [Ecto.Migration](https://ecto-sql.hexdocs.pm/Ecto.Migration.html) and [Ecto.Query 3.11.2](https://ecto.hexdocs.pm/3.11.2/Ecto.Query.html#with_cte/3). Prefer ordinary transaction statements/Ecto queries when clearer, but allow focused parameterized SQL for other genuinely clearer guarded operations, not only search. `insert_all/update_all` also bypass changeset constraint mapping; choosing them does not automatically solve expected unique-constraint feedback. Map known failures after rollback. Use one explicit edit-version mechanism per write, not both. My A-C1 remedy means reconciling the existing documents with these migrations, not creating a fourth normative spec.
- **A-F2: accept scoped operational timeouts.** Keep bounded request queries, configure the migration/maintenance connection separately, and restore any session override before returning it to a request pool. Do not state all pg_dump operations fail at 2 seconds: backup tools have their own connection setup, and no timeout measurement was supplied. Test the actual release/backup/restore commands. No need to require an owner-role backup just to change a user-settable timeout.
- **A-F3: accept fresh privileged-read eligibility and generated disconnects.** User/role checks must also cover reads; derive access from current state rather than a cached moderator boolean. Session-only revocation remains a separate issue below.
- **A-F4: accept explicit shutdown/rescue configuration, pinned to the chosen versions.** Verify the Compose grace exceeds application/Oban drain time. Current Oban docs expose `Oban.Lifeline`; the older Plugins name is deprecated. Avoid asserting a module name independent of the pin. Backend phase must cover the last-attempt crash and application failed-state reconciliation, not only rescue to available.
- **A-F5: accept the bounded scan as the smaller starting point, with explicit ownership.** Oban supplies the periodic run; per-row `embed_after` is eligibility/backoff for that scan, not an additional set of retrying per-row Oban jobs. Process failures independently, catch/classify a poison row, and make progress beyond it; crashed batches are revisited at the next scheduled run. Explicitly reconcile the backend's blanket 'Oban owns retry delays' wording with this exception. Do not add per-row jobs, version-failure metadata and enqueue hooks just for architectural uniformity. Backend phase will close details.
- **A-F6: accept provider test seams, reject requiring three behaviours plus Mox now.** Req.Test already supports HTTP stubs, transport errors and process ownership ([official docs](https://req.hexdocs.pm/0.5.9/Req.Test.html)); ordinary provider functions with injectable HTTP request options suffice initially. Use an existing storage SDK's seam if selected. Add a behaviour only when it materially simplifies an actual test. No need to select every dependency during an architecture review.
- **A-F7: accept actual extension-enabled dev/test database.** Pin the production-compatible image; migrations plus representative queries in CI are the concrete implementation of A-C5. No separate spike framework.
- **A-F8: accept bounded timeout.** Reusing a successful query vector within the current normalized-query generation is an optional local optimization; never cache failure for the whole session. It must not freeze ranking, pin a fallback mode, or survive a model/query change. Do not make it a prerequisite to implementation.
- **A-F9: reject as a contradiction.** A deliberate public Content boundary is not automatically a redundant wrapper stack, and the docs explicitly say module lists are not scaffolding checklists. Keep public operations cohesive; extract helpers on demand. No action required merely to replace `Content.foo` with `Content.Helper.foo`.

### A-C2 scope settled; one important limitation

I accept the short order rule: lock participating users (sorted when several), then parent tips, then reviews, then dependent rows. Use `FOR NO KEY UPDATE` when sufficient; my saved reproduction was updated and rerun with that mode. Fable's tested parent lock avoids the counter-trigger upgrade deadlock.

The claim that every current operation already follows this order is not established: the historical bulk vote invalidation at data-model.md:627 locks multiple vote rows then trigger-updates parents in execution order; concurrent parent-first code can invert that order. Bulk review restoration similarly touches many parents through triggers. These operations must prelock affected parents consistently or have a demonstrated safe alternative. A third conflict is report insert versus resolution/author edit: uniqueness handles one open report, but does not by itself serialize eligibility against the observed author revision. The backend already *requires* serialization, but has no implementing statement; count it as required verification, not a new subsystem. We agree on a small rule and targeted tests rather than a maintained lock-manager document.

### A-C3 still disputed: disconnect-only does not satisfy the stated revocation contract

Counterexample: email change commits deletion of old session tokens; process dies before the after-commit disconnect broadcast. Other LiveViews remain running. The user row remains undeleted, confirmed and unbanned. Their user-id-only guards all pass indefinitely. This is not a few-millisecond window and a user-id check cannot distinguish the deliberately revoked credential. Even a delayed, healthy broadcast permits a request with a revoked session through the stated guards. backend-design.md:460 explicitly says revoked sessions must not retain write access.

Smallest proposal: at authenticated operation admission (mutations and privileged reads, not every render/public read), resolve the current session using the generated Accounts token query and build fresh scope; perform business authorization in the context as already agreed. Keep the generated disconnect for immediate UI behavior. No polling, per-user process, new token table, or general auth framework. Do not promise retroactive cancellation of an operation already admitted before revocation. Async privileged results need current authorization before delivery. A single Account query need not double all DB work: it replaces stale caller resolution and can combine account/session eligibility.

Please either accept this bounded admission rule or identify the actual mechanism that rejects the post-commit/pre-broadcast-crash case. Reclassifying all old sessions as valid until disconnect would change the existing contract.

### A-C4 resolved proposal: preserve the requirement with one search function

I withdraw keyword-first/hybrid-upgrade. Choose Fable's (a): direct HTTP mount runs the same bounded search operation (including normal fallback); connected interactions run that operation asynchronously. Do not require identical rankings across mounts—the accepted reranking contract already permits changes—but do not create a separate keyword-only initial mode. Accept initial duplicate retrieval at MVP scale; it is measurable and can be optimized later without snapshots. Public readable initial HTML is an explicit existing decision; an async-only exception is a product tradeoff, not something this review should silently adopt. No user clarification is needed to preserve the stated requirement.

### Proposed architecture consensus

Keep the monolith and existing product scope. Reconcile schema through migrations and current documented contracts; use a small tested lock order; refresh operation authority; preserve initial HTML through bounded synchronous search and async connected interactions; configure operational timeouts/shutdown/rescue; use a pinned search-enabled dev/test environment and minimal provider test seams. Leave concrete job, media and frontend transitions to the next two phases. Pending only Fable's response to the revocation case and the narrowed corrections above.

## Fable Round 2 — responses and closure

### Corrections accepted

- A-F1: `Ecto.Migration` supports `generated:` on `add`, and `with_cte` supports `update_all`/`delete_all`; my claim was too broad. The remaining limitation is an INSERT inside a CTE body. Structure dump is optional; tests run the migrations. `insert_all`/`update_all` raise `Ecto.ConstraintError` instead of changeset errors, so publish rescues the unique violation after rollback and then performs the submission-key lookup the design already specifies. One edit-version mechanism per write. Parameterized SQL is allowed wherever it is clearer than a query, not only for search.
- A-F2: retracted for `pg_dump`. It issues `SET statement_timeout = 0` on its own connection, so the role default does not affect it. The migration release task starts its own Repo pool through `Ecto.Migrator.with_repo`, so a session override never returns to the request pool. Keep the rule to migrations, the recount, and any operator statement run as the app role; test the actual release commands.
- A-F4: plugin module name follows the pinned Oban version. Last-attempt crash and failed-state reconciliation go to phase 2.
- A-F5: agreed. Oban owns the periodic run; `embed_after` is per-row eligibility and backoff for that scan and nothing else. Poison rows are classified and skipped so the batch makes progress. The backend's blanket "Oban owns retry delays" sentence gets this one stated exception.
- A-F6: `Req.Test` is the smaller seam. Provider functions take injectable request options; a behaviour appears only when a test needs one. `ReqS3` keeps R2 inside the same seam.
- A-F8: optional optimization, scoped to the current normalized query, never caching failure. Not a prerequisite.
- A-F9: withdrawn. No action.

### A-C2: bulk operations accepted into the lock rule

Codex is right that multi-parent statements can invert the order. Concrete case: bulk vote invalidation for user X takes vote rows in scan order and the trigger takes each parent; a concurrent vote by X holds its vote row and waits for a parent the bulk statement already holds, while the bulk statement reaches X's row and waits. Deadlock.

Rule as closed: lock participating user rows first (sorted when several), then parent tips (sorted), then reviews, then dependent rows. Multi-parent operations, meaning bulk kill, bulk vote invalidation, and unban restoration, prelock their users and then their parents in id order before the child writes. With every eligibility read locking the user row, a targeted user cannot start a competing write while the bulk statement runs, which removes the vote-row inversion above. Postgres still detects any remaining cycle and aborts one side; moderator and Oban retries make that survivable, but the prelock is the correct order, not the retry.

Report insert versus edit and resolution: single-statement compare-and-set on the observed author revision plus the open-report unique index. Verification item for phase 2, no lock.

### A-C3: bounded admission rule accepted

The crash-between-commit-and-broadcast case is real, and its consequence is not a millisecond window: the surviving socket keeps a user id that every SQL guard accepts until something remounts it. backend-design.md:460 states the contract, so disconnect alone does not meet it.

Accepted as proposed: at admission of a mutation or privileged read, resolve the session through the generated token query, build a fresh scope, then call the context. Keep the generated disconnect for immediate UI behavior. No per-render check, no polling, no new table. One refinement: check at admission only. A delivery-time recheck for async results guards a window the admission check already bounds, and would be a second mechanism. The fresh scope also carries the current role, which closes A-F3 without changing the read queries; the SQL `moderator()` predicate stays on writes as today.

### A-C4: (a) accepted

The same bounded `search_tips` runs synchronously on the HTTP mount and asynchronously on connected interactions. One retrieval path, one function, the reranking contract already covers differences between mounts. The duplicate retrieval on a direct GET is the measured cost of the existing initial-HTML requirement. If the user later prefers to drop server-rendered search results, the change is one `connected?` branch in mount; that is a product choice for them, not for this review.

### Phase 1 closure

Consensus reached at round 2. Both reviewers agree on the following. Later phases refine but do not contradict.

1. One Phoenix monolith, two contexts, existing product scope. No new services, processes, or contexts.
2. Ecto migrations are the schema truth, with `execute` for domains, triggers, functions, and views. Tests run the migrations against the pinned search-enabled Postgres image in development and CI. The markdown SQL stops being normative once the migration exists; documents are reconciled to the migrations, not the reverse.
3. Guarded writes are one statement each with the full WHERE, via Ecto query functions or parameterized SQL, whichever is clearer. Row count is the result. One edit-version mechanism per write. Constraint violations are rescued after rollback and mapped explicitly.
4. Lock rule: users, then tips, then reviews, then dependent rows; eligibility reads take `FOR NO KEY UPDATE` on the user row; new reviews take `FOR NO KEY UPDATE` on the parent; multi-parent operations prelock users and parents in id order. Executed evidence: `adversarial-account-race.py`, `adversarial-lock-variants.py`.
5. Authority: mutations and privileged reads resolve the session token at admission and build a fresh scope. Generated disconnect on email change, ban, role change, and account deletion. Public reads stay public and unchecked.
6. Search: the same bounded `search_tips` on HTTP mount and async when connected. Bounded embedding timeout; timeout is fallback. One retrieval path.
7. Background work: Oban in the release, jobs enqueued in the business transaction, shutdown grace and orphan rescue configured against Compose and verified for the pinned version. Embeddings run as one periodic bounded scan; `embed_after` is that scan's only retry state.
8. Operations: request queries keep the 2 s timeout; migrations and operator statements lift it per session; release commands are tested as run.
9. Provider seams through `Req.Test` and injectable request options; behaviours only on demand.

Carried to phase 2: bulk-operation prelock statements, report-revision compare-and-set, Oban last-attempt crash and failed-state reconciliation, poison-row handling in the embedding scan, unique-violation mapping in publish. Carried to phase 3: admission-check placement in LiveView event handlers and `on_mount`, search mount branch, refresh notice behavior.

Unresolved: none.

## Review rules (from the user, applied to all phases)

- Use proven architecture, standards, and conventions from widely used software similar to this project.
- Strive for simple, working, elegant solutions. Choose simplicity over elegance when they conflict.
- Build an MVP for fast iteration and product-market fit. No unnecessary enterprise complexity. No backwards compatibility.
- Perfection is when there is nothing left to take away.
- Order of assessment for every finding and fix: first local correctness; second direct and downstream effects on its module, feature, or tests; last the whole system end to end.

## Codex ratification of phase 1 closure

Agreed at round 2. Accept admission as the authority boundary for already-admitted async work; do not promise retroactive cancellation after later revocation. Public projections still enforce content visibility. Provider client/library examples remain implementation options, not compulsory dependencies. Report-revision atomicity remains a phase-2 verification item: an INSERT SELECT predicate is not itself a compare-and-set on the parent row.
