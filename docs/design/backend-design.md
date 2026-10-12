# Backend design

## Scope

This document defines business operations, context boundaries, authorization, transactions, external service coordination, and background work.

Apply the architecture's user-experience principle to every operation: accept necessary implementation complexity that removes user effort. Keep ownership, idempotency, conflict protection, recoverable failure handling and automatic progress where the user journey requires them. A smaller backend is not an improvement if users must repeatedly check status, redo completed work, repair duplicate submissions or manage provider details themselves. Prefer established capabilities and shared mechanisms before removing these protections.

Follow the [software architecture](software-architecture.md), including its [MVP design constraints](software-architecture.md#mvp-design-constraints). The [frontend design](frontend-design.md) owns LiveView, forms and browser interactions. The [data model](data-model.md) owns the canonical schema, database and locking invariants. This document owns operations. Link to those contracts rather than repeating their procedures.

## Business requirements

Tips serves two connected needs: discovering relevant AI techniques and judging whether they are worth trying. Design the backend around discovery and trust.

Design task-first discovery as the first complete reader journey: a reader has something they want to do with AI and searches for techniques that could help. Existing browse, sorting, and filtering features remain in scope.

Prioritize finding relevant techniques, recent firsthand reports of what still works, and actionable explanations with optional prompts and results. Trust supports these needs.

Authors publish their own experiences through the normal forms; there is no import or publishing-on-behalf workflow. Signup is open to anyone who verifies their email; there are no invitation codes, allowlist or account-approval queue. No task-category field or analytics system is needed for the [validation plan](product-validation.md).

A tip should come from the author's firsthand use of the technique. Prompts, result text, and media are optional supporting examples. The required body remains one Markdown textbox with short guidance to describe when to use the technique, the steps, and what happened when the author tried it. Do not require headings or split these into separately required fields. Content validates the body as text; it does not parse headings to decide whether the account meets the firsthand-use rule.

A review reports firsthand use of a tip. The reviewer describes what they tried and what happened. A concrete written account is the minimum; prompts, outputs, and media are optional supporting evidence that strengthens trust in the account. Evidence attachments are not required to publish a review.

State the firsthand-use requirement in the publishing forms and community rules. Publish immediately under the existing account and content rules, without an additional confirmation checkbox or moderator approval step. Reports and moderation handle violations. Required-field validation does not establish whether an account is truthful.

Reviews and votes handle effectiveness, including techniques that no longer work. A failed attempt or disagreement alone is not a moderation violation. Reports concern suspected spam, harm, fabricated firsthand experience or supporting evidence, and other community-rule violations. The reporting form and moderator queue must make this distinction clear.

Any eligible signed-in reader may vote Helpful or Not helpful on a tip or review without personally trying the technique. Firsthand experience is required for writing tips and reviews, not voting. Scores express perceived helpfulness; they are not verified success rates or counts of successful attempts. A useful negative review can receive Helpful votes. Do not require a review or firsthand-use checkbox to vote.

The MVP has tips, firsthand reviews, and helpfulness votes. Defer clarification questions, general comments, and replies. A reader who has not tried a technique cannot use the review form to ask a question. Do not turn reviews into a discussion thread or add comment tables, reply notifications, or threaded pagination. This is a product scope decision; the resulting lack of an in-app clarification channel is accepted for launch.

The review form has three main content sections: a required review textbox rendered as Markdown, an optional prompt textbox, and an optional result section accepting text, uploaded media, or both. Result uses one combined composer with an attachment button, paste/drop support, and removable previews, without a format selector. Model and environment remain optional setup metadata under the existing data model.

## Future MCP access (v2)

Explore an MCP server that lets users or AI agents search and access tips, and potentially submit tips, from their AI application or coding harness (for example, Codex or ChatGPT web). This is a future direction only; defer capability, protocol, authentication, and implementation decisions. It adds no MVP requirements.

## Task-first discovery

Reject empty or whitespace-only queries before embedding or search retrieval. The web handler returns one “Enter a task or keywords to search” message, preserving the last submitted results, heading, filters, URL and page. No query or navigation occurs. Do not reinterpret empty submission as navigation to browse. Context validation also prevents blank queries from invoking the search pipeline.

The web layer calls `Content.search_tips(scope, query, opts)`; `Content.Search` is an internal helper. Run the same bounded operation synchronously for the disconnected and first connected load. Later changed URL parameters and explicit Retry use one page-owned named async retrieval helper. Ordinary submit/filter events only normalize intent and patch the URL; unchanged submissions do not retrieve again. Retry deliberately reruns the current requested page without changing the URL. Initial connection may retrieve twice and rankings may differ. Pass query, filters and caller data, never the socket. The [frontend search lifecycle](frontend-design.md#search-retrieval-and-list-state) owns explicit cancellation and loading state; this is page work, not an Oban job.

Every page request reruns retrieval within one total operation deadline covering provider queue wait, query embedding, database work and any keyword fallback. Bound provider request concurrency and queue wait across reader queries and the embedding scan; a connection-pool size alone is insufficient, especially with multiplexed requests. Keep the existing DB pool and two-second request query timeout. On embedding timeout or unavailability, use keyword fallback within the remaining budget; if the overall budget or keyword retrieval fails, return a retryable search error. Local task cancellation cannot retract a provider request already received. Select numeric concurrency and total-deadline settings in the pinned integration and measure them before making latency claims. Successful query-vector reuse by normalized query and model/version is optional; never cache failure or freeze ranking.

If query embedding or meaning-based retrieval is temporarily unavailable, use the existing keyword fallback without a reader-facing notice. Preserve the query, filters, visibility rules, and bounded pagination contract. Choose hybrid retrieval or keyword fallback independently for each request; recovery can change later pages' rankings. Keep the retrieval mode and failure observable internally. If keyword retrieval also fails, return a search error with retry rather than an empty result. Do not present keyword-only results as a complete semantic search or add a badge claiming meaning-based matching.

Start a new text search only after Enter or an explicit Search action; Previous/Next reruns the submitted search for the requested page. Typing alone does not request query embeddings, retrieve results, or replace temporary search state. Defer autocomplete and typeahead suggestions. Distinguish the input being edited from the submitted query used by the URL, results, filters, and continuation state; committing a changed query starts new search state.

The MVP accepts ordinary search text for keyword and semantic retrieval. Defer strict quoted-phrase syntax and other advanced operators. Quotation marks must not imply an exact-match guarantee or cause user text to be executed as search-engine syntax. Normalize/escape input consistently for retrieval and continuation state, and test pasted error messages containing quotes and punctuation. Evaluate demand for exact phrases during developer trials.

Search includes the description, optional prompt, and optional Result text of tips and reviews, plus the tip title and each contribution’s own model/environment labels or free-text model, and the tip’s technique tag. Content.Search uses one search-text write helper for publication, searchable edits and retagging: update `search_text` and its `text_at` freshness token, clear `embedding`, and reset `embed_after` in the same transaction. An output-only edit also invalidates the old embedding. Curated labels are stable for the MVP; changing a label requires rebuilding affected search rows through this helper. Match excerpts may come from the body, prompt, result or reported setup and identify their source. Matching review excerpts use Review for the body, Prompt, Result, or Reviewer setup; return source identity with the excerpt rather than making the frontend guess. A Reviewer setup excerpt is labelled metadata, not a quotation or proof of a parent-tip model match. Search still groups matches by tip and respects visibility and selected filters. Do not add image OCR or video transcription for the MVP. Evaluate long-output noise and error-message queries with the initial developer trials.

The reader searches for a task, opens a relevant tip or matching review, and assesses firsthand accounts before trying the technique. The existing hybrid search returns one result per tip and can identify a matching review. Keep that behavior.

### Main feed and clickable filters

The main page combines a tip feed, search, and clickable technique and model tags, following the requested Hacker News/Reddit style. Retain Hot and New for browsing and the existing environment filter. A task can be expressed in the search box; a separate task-category field is not part of this discovery entry point.

Use compact text-only rows, following [Hacker News](https://news.ycombinator.com/news): title, technique/model metadata, author, age, net score, review count, and compact Helpful / Not helpful controls. Browse and search summary projections include the current viewer vote and voting capability; batch those reads for the visible tip ids. Images, GIFs, and videos appear after opening the tip; browse does not fetch media previews or initialize video players. Reuse the text summary for filtered listings and search, retaining the matching-review text excerpt in search. Full attachment data belongs to `get_tip_page`.

Technique tags and model labels are distinct filter dimensions backed by the existing curated data. On browse/search, clicking a curated tip tag or model link sets that dimension, preserves other filters and the submitted query or browse sort, and resets page one. On tip/profile pages, links on tip metadata open browse with that single filter and default Hot. Free-text model names have no model-id predicate and render as plain text; reviewer setup metadata is not parent-tip filter navigation. Browse URLs carry filters, sort and page; search URLs carry query, filters and page with fixed relevance ordering. These URLs support sharing and restoration without a discovery-history store. [Reddit's flair navigation](https://support.reddithelp.com/hc/en-us/articles/15484545678996-Post-Flair) and [Stack Overflow's tag browsing](https://stackoverflow.com/help/interesting-topics) provide the navigation precedents.

Use three labelled native selectors for Technique, Model and Environment, each with All. A deliberate change immediately patches applied URL state and resets to page one; preserve focus. There is no filter panel, pending selection state or Apply step. Use the last submitted text query; typing stays local until Enter or Search. Clickable tags remain direct filter navigation actions. Changing filters does not submit unfinished search text. For browse/search and normal-review filter groups, Clear filters removes the group's predicates, preserves the submitted query and applicable sort, and resets page one. Show that action whenever a filter is active, including empty results. Review Best/New and profile All/Tips/Reviews use the same native-select interaction; profile needs only its single All option to reset.

When a filtered search returns no matches, preserve its query and filters and return an empty result. Offer explicit actions to remove individual filters, use Clear filters while retaining the query, or edit the query. Do not automatically relax predicates or fetch a separate section of out-of-filter suggestions. A reader’s change starts a fresh search and pagination state. Distinguish a successful empty search from a search failure; failures offer retry rather than claiming no tips exist.

`Tips.Content.list_tips(scope, opts)` owns the home and filtered browse feeds using Hot/New ordering and validated page offsets. `search_tips` owns text-query relevance and bounded search pagination over rankings that may change between requests. Reuse tip-summary rendering, filter parsing, and visibility policies across both flows; no new feed service or table is required.

The Hot/New feed is shared rather than personalized. All reading lists use URL Previous/Next pages with validated positive page numbers and offset = (page - 1) × page size. Return twenty rows (thirty for normal reviews) plus one-row lookahead to determine Next, without a total-count query. Search uses its existing bounded-window count instead. Preserve current sort/filter parameters; changing them resets page one. Each request checks current visibility and deterministic tie-breaks. Rankings can drift between pages; accept repeats or omissions without seen-id sets, accumulated batches, frozen snapshots or an arbitrary history cap outside search. Measure deep-offset performance on the intended corpus.

A model tag filters only the model selected by the tip's author, in both browse and search. A review using a different model does not make its parent tip eligible for that model filter. Reviews retain their own model metadata on the tip page. Apply the model predicate to the parent tip in all search branches, including branches that match review text; an unfiltered text query may still discover those reviews. Present a model label as the author's reported setup, not as a guarantee that the technique works on that model. This follows the post-level classification pattern of Reddit flair.

Images link to their full-size asset; static previews may load lazily, while animated evidence uses deliberate Play/Hide with no autoplay. Videos use the signed provider player inline, with Play and fullscreen. On Play, load the stable Tips watch route as the iframe source so it performs fresh authorization and redirects to the provider iframe destination. Return app watch/thumbnail paths in media projections, not persistent playback tokens. Draft access remains owner-authorized; the managed-video contract below governs all access.

Opening a tip from filtered browse or search starts its review list without model or environment filters. Discovery filters describe the tip author’s setup and are not inherited by reviewer setup filters. Readers apply review filters independently. Honor explicit review-list filters in a tip URL or a restored Back-navigation state; this is distinct from inheriting discovery filters. Selected-review links use the focused destination contract below.

Review pages return the full authorized body, prompt, result text and ordered attachment metadata for the current page. Optional review evidence can be disclosed locally without another fetch; the full review body remains visible. Tip evidence and selected-review evidence start open. Keep pagination and lazy media delivery; loading text does not require downloading full media assets.

### Individual review links

Following the user's direction to use established conventions, give each review a stable link. A search result's title opens the tip normally; its matching review excerpt links to that specific review in the tip's context, even when the review is outside the first page of Best or New results.

The convention is supported by [HN's comment timestamp links](https://news.ycombinator.com/newsfaq.html), [Reddit's comment sharing](https://support.reddithelp.com/hc/en-us/articles/53602138490388-How-do-I-share-Reddit-content-off-Reddit), and [Google Maps' individual review sharing](https://support.google.com/maps/answer/6230175?hl=en). Showing the selected review within the tip page is our application of that convention; these products do not have identical layouts.

### Proposed context contract

Keep this flow behind `Tips.Content`. The `Tips.Content` module documentation ("Reading") is the contract for `get_tip_page/2` and `get_review_page/2`: viewer, readmission and errors.

| Function | Responsibility | Data and frontend interaction |
|---|---|---|
| `search_tips(scope, query, opts)` | Validate the query and filters; coordinate hybrid retrieval and the existing keyword fallback | Rerun bounded retrieval and ranking for the requested page, including visible matching review excerpts. Return page position and `has_more`, derived from internal `total_in_window`; do not present a total result count. The web layer renders links. |
| `get_tip_page(viewer, tip_id)` | Load projected tip context and the own-review header link | Return the projected tip and a lightweight own-review id/capability lookup, including a hidden own review under an unavailable tip. The thirty-review ranked page is a separate read. |
| `get_review_page(viewer, review_id)` | Load one selected review for `/reviews/:id` with its tip context | Authorize the review directly and return `Projection.selected_review/4` output with its media and vote. Fetch no ranked page. |

For readable tip context, return `has_earlier_reviews` from an existence check for currently visible, nondeleted reviews created before the tip’s `edited_at`. Use the same viewer-aware visibility policy; do not expose hidden review dates or compute public copy from an unavailable tip’s hidden edit metadata. This supports the single earlier-review note without loading more review bodies.

The selected-review destination is `/reviews/:id`: `get_review_page/2` reads the review first and uses its parent as tip context, so the review always belongs to the tip shown. The tip context follows the ordinary projection, including deleted/hidden placeholders, and the review keeps its own visibility. Its link does not bypass deletion or moderation rules. A selected-review destination shows tip context, that review and Show all reviews, not a selected-plus-ranked list. The direct lookup ignores review-list filters, sort and page; no list controls render in this mode. Show all reviews opens the current authorized tip permalink with reviewer model/environment filters and review page cleared, retaining the current/default review sort and opening unfiltered page one. On a normal list the viewer’s live review appears at its normal rank with a Your review badge. Fetch only its id and capabilities for the header link, including authorized access to a hidden own review; do not pin or hydrate a second full own-review slot. Return current authorized action capabilities with each displayed review so ranked and selected presentations use the same Edit/Delete controls for the viewer's own review. Recheck current visibility on every destination.

The frontend owns positioning and visual emphasis. The review id is in the `/reviews/:id` path so the initial server request knows which review to fetch; a fragment alone cannot. Use a review anchor for scrolling. For a selected review, show “Review deleted by author” when deleted, or “Review removed by moderators” when deliberately moderator-hidden from the caller. Keep tip context available and provide Show all reviews to the normal list. Unavailable reviews remain absent from the normal list; the notice is for a direct-link destination, not a retained list item. If its removal cause cannot be safely disclosed, use “Review unavailable” without exposing review data. An unknown or malformed review id has no parent to derive and returns not found, as a nonexistent tip does. Author/moderator access to hidden reviews follows the existing permissions. This adapts Reddit's deletion/removal distinction to flat reviews without replies.

Search supports Previous/Next pages and refining the query or filters. Rerun retrieval and ranking for every requested page using current content and visibility. New tips, reviews, edits, completed embeddings, and semantic-service availability can change later pages. No search snapshot table, lifetime, expiry notice, or cleanup worker is required.

### Bounded search pagination

Keep pages of 20 and the bounded discovery window. Each of the four retrieval branches contributes at most 50 tip candidates, giving at most 200 distinct tips; keyword fallback has two branches. Keep these candidate limits fixed across page requests rather than enlarging them with page depth. Each request recomputes the bounded ranking, orders ties by tip id, and takes the requested page using a validated, bounded offset. Do not apply the final page offset independently within each retrieval branch. Use the same `search_tips(scope, query, opts)` operation for the first and subsequent pages.

The frontend retains the submitted query, applied filters and page in the URL and holds only that page in ordinary assigns. Each request reranks and replaces the page; no appended results or seen-id set. Query/filter changes reset page one. Back and remount rerun the requested URL page, preserving useful reading position where possible without promising an old ranking. A failed page request offers retry and does not label old rows as the requested page. Show no Back-only refresh notice; actual disconnect, reconnect and error feedback remain. An empty valid page keeps Previous available when page > 1. Search pages remain bounded by the discovery window.

Every request checks current visibility and only returns authorized tips and matching-review excerpts. Reaching the end of the current candidate window means refine the search, not that all relevant database rows have been exhausted. Search failure remains distinct from an empty page. Keyword fallback remains invisible and is selected per request.

Page-based requests are established in [Algolia pagination](https://www.algolia.com/doc/api-reference/api-parameters/page). Keeping a bounded ranking window follows the principle described in [Elasticsearch RRF pagination](https://www.elastic.co/docs/reference/elasticsearch/rest-apis/reciprocal-rank-fusion#pagination-in-rrf); neither source establishes a cross-request frozen-order guarantee for Tips. The data-model SQL applies the final bounded offset; verify current-visibility checks during result and excerpt hydration against the pinned extensions.

Include matching-excerpt hydration, selected-review lookup, and authenticated operation admission in query measurements.

## Implementation foundation

Implement business operations as ordinary Elixir functions using the Transaction Script pattern. Contexts call Ecto directly, with related schemas and query helpers alongside their feature code. Ecto migrations are executable schema truth. Use migration `execute` for database features that need SQL, with explicit rollback steps; tests run migrations, and a structure dump is optional. Prefer ordinary Ecto queries and changesets; use focused parameterized SQL only where Ecto cannot express the query. Pin versions before using their APIs.

Use one version mechanism per write. Prefer `Ecto.Changeset.optimistic_lock/3` for ordinary single-record changesets; use guarded `Repo.update_all` for conditional or set-shaped writes where clearer. Do not combine an Ecto lock increment with a second manual compare-and-increment. The [edit contract](#editing-and-conflicts) preserves the original expected version and whole-edit/no-op behavior. `Repo.insert` with an Ecto `on_conflict` query can express conditional vote and notification upserts; preserve the exact predicates, partial-index target and affected-row semantics.

Web handlers invoke context operations. Pass the caller's scope and explicit inputs into business functions instead of passing a connection or LiveView socket. `Tips.Content.publish_tip(scope, submission_key, attrs, uploads)` illustrates this boundary; see [Publishing and retry contract](#publishing-and-retry-contract).

### Database implementation

Implement the canonical [data-model tables and constraints](data-model.md#tables) in Ecto migrations. Fixed vocabularies use `Ecto.Enum` with named text CHECK constraints; retain the two narrow delta triggers, generated ranks and deferrable media-slot constraints.

Ecto's `prepare_changes/2` can update a counter inside a changeset transaction, but Tips also has bulk and SQL writes that bypass it. The two narrow triggers keep the delta rule in one place across those paths. Keep notifications and provider work out of triggers. Retain a release repair/recount operation and verify real transaction flows.

Submission keys and edit versions need no extra dependency. A UUID and database unique index on `(user_id, submission_key)` identify a publication retry; annotate the actual index with Ecto `unique_constraint` for feedback. `edit_version` rejects stale editors and moderator actions. Reports use one open report per reporter/target with no separate author-revision column or permanent revision index. Keep whole-edit no-op detection so unchanged saves do not update dates, search text or the edit version.

## Agreed context boundaries

Use two contexts for the MVP, following Phoenix’s grouping of related resources:

| Context | Related functionality |
|---|---|
| `Tips.Accounts` | Identity, authentication, and account lifecycle |
| `Tips.Content` | Tips, reviews, and votes |

Group related schemas within a context. A database table does not automatically need its own context.

Operations spanning multiple areas still use the same application and database. The discovery flow gives search a concrete initial home inside Content. The following responsibilities belong inside these contexts. Extract helper modules when the implementation needs them; the table does not require creating every module upfront:

| Module | Functions and responsibility | Collaboration |
|---|---|---|
| `Tips.Accounts` | Resolve caller identity and current account state; manage magic links, sessions, and account lifecycle | The web layer builds a scope. Content operations use its caller identity and check current eligibility with `Accounts.check_eligibility/2` under the transaction rules below. |
| `Tips.Content` | Public operations such as search, page reads, publishing, editing, deletion, and voting | LiveViews, controllers, and workers call these APIs with explicit inputs. Each write operation owns its transaction. |
| `Tips.Content.Search` | Retrieve and rank candidate ids, fetch search pages, and build search text | Publishing and editing write search text in their transaction. Search reads the same tables; embeddings are generated asynchronously. |
| `Tips.Content.Notifications` | Fold notifications, read the inbox and unread badge, and mark captured notifications read | Vote and review operations call notification writes inside the originating transaction. Inbox reads apply content visibility rules. |
| `Tips.Content.Media` | Validate image uploads, prepare Stream videos, attach media rows, and coordinate file cleanup | Videos upload on selection; images upload on submission. Content attaches ready media inside its transaction. Cleanup respects committed references and pending publication attempts. |
| `Tips.Content.Moderation` | Flag content, read the queue, hide/restore content, and resolve flags | Content changes and their required flag updates share a transaction. Account bans remain Accounts operations. Lifting a full ban changes account eligibility only; it neither restores hidden content nor recreates invalidated votes. |

These are ordinary modules and functions, not separate processes or services. Related schemas remain with their context. Search and notifications read user information through joins where needed; those reads do not transfer ownership of account lifecycle into Content. This grouping follows [Phoenix's context guidance](https://phoenix.hexdocs.pm/contexts.html), which colocates related resources and exposes business operations through context modules.

Search navigation crosses the web boundary: the frontend retains query, filters, and page position; Content recomputes ranking and checks visibility for each page. No saved search-order state is stored on the server.

## Business operations and transactions

Use ordinary Elixir functions for workflows and reusable policies. A Transaction Script is an application operation; it does not imply that every step runs inside one database transaction.

Use `Repo.transact/1` with ordinary control flow for straightforward transactions. Use `Ecto.Multi` when composing the steps makes the code clearer. Oban insertion works inside either transaction style; enqueueing a job does not by itself require Multi. Reuse the same Repo and transaction for every required database effect.

Keep database changes that must succeed together in one transaction. This includes the related notification when the data model requires it. Upload images before starting the content transaction; handle cleanup according to the data model if the operation fails. Generate embeddings asynchronously.

Ecto changesets provide input casting, validation, and useful error feedback. Postgres retains the constraints, guarded writes, counter triggers, and generated rankings. Application validation does not replace database enforcement. Context operations must interpret affected-row counts and constraint failures rather than assuming that a write succeeded.

### Admission, locking, and returned data

The `Tips.Accounts` module documentation ("Admission contract") is the contract for admission, session validity and revocation, `Scope`, `SessionRef`, `check_eligibility/2` and operation results. Every mutation and privileged read admits freshly through it, including author and moderator projections, inbox reads, draft previews and upload polling.

Operations return `{:ok, value}` or `{:error, reason}` and document their subset. Shared reasons are `Tips.Accounts.operation_error/0`: `:unauthenticated`, `:unconfirmed`, `:forbidden`, `:not_found`, `:conflict` or a changeset. The `Tips.Content` error types add `:outcome_unknown`, `{:rate_limited, seconds}`, `{:capacity, seconds}`, `:already_reviewed`, `{:conflict, case}`, `{:upload_failed, refs}` and `{:upload_pending, ids}`.

Broadcast disconnects on stable family topics after committed email changes, bans, role changes and account deletion. The broadcast is UI feedback, not the authorization boundary. Transaction-level business eligibility follows the locks below.

Within a write transaction, acquire required locks in this order: participating accounts by id, tips by id, reviews by id, then dependents. Use Ecto queries with `FOR NO KEY UPDATE` where sufficient. Discover immutable target ids first, then lock and recheck eligibility. For bulk hiding and vote invalidation, lock the subject accounts **before** discovering their mutable affected-content set; concurrent publication must not fall between discovery and account locking. Then prelock affected tips/reviews, including locks acquired by counter triggers, before dependent writes.

Publication locks the author; new reviews also lock their live parent. Edits and author deletion lock the account and affected content. Votes lock the voter and direct target before writing, preserving eligibility against concurrent hide/delete; a review vote needs no ancestor-tip lock because reviews remain independently votable and its count-only update does not change the tip's review count. Reports lock and check the confirmed reporter account, then select the reportable direct target `FOR SHARE` before insertion. This serializes insertion with author deletion; a review report needs no ancestor-tip lock. These are operation-specific lock sets, not a generic lock-planning framework.

| Review operation | Required content locks after participating accounts |
|---|---|
| Insert, hide, restore or author delete | Parent tip first, then the existing review where applicable; liveness changes make the review-count trigger write the tip |
| Text/media edit or review vote | Direct review only when liveness is unchanged; no ancestor-tip lock |
| Bulk visibility or vote changes | All actual tip/review trigger targets in id order, after locking subject accounts and discovering current membership |

Never hold locks over provider calls. Hold ownership, deletion and edit-version eligibility stable through commit. Evaluate upload and registration deadlines with current wall time after lock waits at the guarded decision point, not transaction-start `now()`; this is a decision-time guarantee, not a promise that time cannot pass before commit. Ordinary changeset writes are sufficient once eligibility is held stable by the required locks. Interpret conditional-write row counts and map expected named constraint failures only after rollback. Do not add a generic deadlock retry layer; log and fix lock-order defects while preserving input. Oban retains its own bounded job retries.

Queries select eligible rows; one shared Content visibility policy feeds small, shape-specific projection functions for tip pages, profiles, inbox links, search excerpts, selected reviews, media, metadata and slugs. Avoid a universal recursive serializer. Author deletion takes precedence for every viewer, including moderators. Independently visible reviews survive a hidden or deleted parent. Raw structs and nested associations never bypass projection. Recheck visibility when hydrating search ids and excerpts; old candidate ids grant no access.

### Runtime and integration checks

Development and CI run migrations against a pinned production-compatible Postgres image containing both pg_textsearch and pgvector. Exercise actual hybrid queries, filtered recall, keyword fallback, punctuation handling, bounded pagination, latency and memory, including long document inference on the intended production runtime.

Use ordinary provider functions with injectable request options and `Req.Test` (or the selected SDK's equivalent) for provider failures and unknown outcomes. Add behaviours only when a concrete test needs them. Request queries retain the 2-second database timeout; migration and maintenance connections use explicit longer or disabled timeouts without leaking overrides into the request pool. Test the actual release migration, backup, restore and repair commands.

## Durable background work

Use open-source [Oban](https://oban.hexdocs.pm/Oban.html) with the existing Repo and Postgres database, supervised inside the Phoenix release. Oban owns job scheduling, attempts, retry delays, and execution, with the bounded expiry and embedding scans described below. Content and its helpers own attachment eligibility, processing state, media access, search versions and cleanup rules. Do not create a second general-purpose job queue or per-feature retry scheduler.

Use three queues with independent concurrency limits: `media`, `embeddings`, and `maintenance`. Media handles provider work such as upload reconciliation and explicit attachment deletion/cache purging. Embeddings handles embedding generation. Maintenance handles registration expiry and orphan-image cleanup; staged-video expiry uses a bounded Media expiry worker. Assign each worker to its configured queue; queue ownership does not change the context that owns its business rules. Authentication emails use direct Swoosh delivery, with no email queue.

This applies [Oban's workload-based queue guidance](https://oban.hexdocs.pm/defining_queues.html); the three-way grouping is a Tips design choice. Queue limits isolate execution slots, not CPU, database connections, or provider capacity. Keep total concurrency within the single deployment's capacity; choose and validate numeric limits during implementation. No additional service or worker deployment is required.

Required work follows these boundaries:

| Work | Application responsibility | Durable boundary |
|---|---|---|
| Delete media and purge cached images | Media deletes the intended provider asset and purges R2 delivery caches as applicable; cache purge is an M4 requirement | Preserve provider identifiers and enqueue cleanup in the same transaction that removes the attachment reference. Repeating deletion must be safe. |
| Expire abandoned videos | Media checks due unattached rows, reconciles uncertain completion and serializes expiry against attachment claims | Bounded periodic Oban work in `media`, unique across incomplete states and `max_attempts: 1`; rows retain ownership, completion/expiry and lifecycle state. No global readiness scan. |
| Generate embeddings | Search reads current eligible text and writes a vector only if its text version still matches | One periodic singleton scan, queue concurrency 1 and `max_attempts: 1`; uniqueness covers active job states so ticks cannot build a backlog. `embed_after` is the only per-row retry cooldown. No per-row jobs or publication/restoration enqueue hooks. |
| Sweep orphaned images | Media compares old R2 objects with committed references under the existing grace-period rules | Schedule the existing periodic sweep through Oban; the sweep remains recovery for files orphaned before a content transaction. |

Enqueue transaction-dependent jobs before the transaction commits, never only in an after-commit callback that a process crash could skip. Provider requests run outside database transactions. Workers tolerate duplicate execution, deleted targets, obsolete text versions and lost provider confirmations; Oban uniqueness alone does not make external effects execute exactly once. Deletion is terminal; late status responses must not recreate assets or restore attachment membership.

Use bounded retries with backoff for transient failures, and preserve exhausted failures for investigation. Keep permanent-cleanup identifiers until cleanup is confirmed; pruning old job records must not erase the only record of an unfinished deletion. Keep that record in `media`: set `cleanup_at`, clear `position`, retain provider and parent identifiers, and enqueue cleanup in the removal/discard/expiry transaction. Delete the row only after provider deletion and any required cache purge are confirmed; until M4 no purge is required, so the row is deleted after Stream and R2 deletion. Status writes and claims require `cleanup_at is null`; a late provider response cannot revive removed media. Job pruning never deletes this cleanup record.

Retain terminal Oban jobs for seven days. Cleanup identifiers remain on media rows until provider deletion succeeds; an operator can reconstruct selected cleanup work after job history is pruned. Playback signing needs no job, attempt counter or retained job id.

Configure and test the pinned Oban interrupted-job rescue mechanism, including last-attempt crashes and duplicate delivery. Set Compose stop grace above application/Oban drain time and test shutdown as deployed. Keep the Repo outside individual worker lifetimes. Application restarts preserve committed background jobs; search reruns from request parameters rather than restoring a stored ranking. Paid workflow features and a separate worker deployment are unnecessary for these requirements.

Report exhausted job failures to hosted Sentry under the architecture's error-reporting policy; retain ordinary transient retries in local logs. Use the SDK's Oban integration and sanitize reported context. Durable failed attachment/cleanup state remains authoritative even if reporting fails, is filtered, or exceeds the free service quota.

After investigating and fixing a failure’s cause, an operator can inspect and retry selected jobs through documented [release commands](https://phoenix.hexdocs.pm/releases.html#custom-commands) backed by [Oban APIs](https://oban.hexdocs.pm/Oban.html#retry_job/2). Name the intended jobs explicitly; never retry every failed job. Recheck target eligibility and durable state, and keep author-facing state in step with resumed work. Add no failed-jobs admin UI and no author control for retrying operational cleanup jobs, and do not give moderators these commands through their moderation role. Upload failure Retry/Replace remains available through the normal editor flow. Operator retries do not justify automatically bypassing a worker’s configured attempt limit.

The embedding worker performs the existing bounded scan of up to 50 rows, alternating tips and reviews, with one bounded provider request per row. Classify failures independently, set `embed_after`, and continue past poison rows. Disable overlapping HTTP retries for these calls; a crashed scan is revisited on the next scheduled run. Measure inference duration and backlog rather than assuming every batch completes within a minute.

### Independent background-progress checks

Use one bounded, read-only health routine outside Oban execution. Inspect relevant periodic-job recency and the oldest eligible unfinished cleanup and missing-embedding work, including rows never attempted (`embed_after IS NULL`) as well as rows cooling down. Use bounded oldest-age or EXISTS queries, not full backlog hydration. A stalled queue must not disable its own observer. Expose the routine separately from the basic public app-and-DB probe and through a release command; choose one external monitor or host schedule to invoke it, with monitor-owned deduplication. Do not add heartbeat tables, a dashboard or a second alerting platform.

Thresholds include the maximum bounded scan runtime, queue delay and deployment/startup/backfill grace. Fifty bounded calls can exceed a minute cadence; do not use twice that cadence as a universal failure threshold. Treat six hours for eligible embedding age and twenty-four hours for unfinished cleanup as initial tunable investigation thresholds, not service guarantees. Verify stalled cron, stopped queues, never-attempted rows and recovery, including when the web/DB probe stays healthy.

## Markdown, embeds and secure headers

Render tip/review authored Markdown through **MDEx 0.13.5 with its built-in Ammonia sanitizer** (`mdex_native`). Use one options list, without HtmlSanitizeEx or a custom Scrubber module. The strikethrough and table extensions produce the `del` and `table` tags the allowlist names:

```elixir
extension: [strikethrough: true, table: true],
render: [unsafe: false],
sanitize: [
  tags: ~w(p br hr h1 h2 h3 h4 h5 h6 blockquote ul ol li pre code em strong del a table thead tbody tr th td),
  tag_attributes: %{"a" => ~w(href title)},
  generic_attributes: [],
  url_schemes: ~w(http https mailto),
  link_rel: "nofollow noopener noreferrer"
]
```

`unsafe: false` omits author raw HTML, but Markdown image syntax still produces an `img` tag. The sanitizer’s tag allowlist removes those images. Only the sanitized result may be marked HTML-safe. See [MDEx safety options](https://github.com/leandrocp/mdex/blob/v0.13.5/guides/safety.md). Titles and metadata stay escaped text; prompt/result fields stay verbatim escaped text with copy preserving bytes.

Allow only the tags in `sanitize.tags` above. Allow only validated `href` and `title` on links; URI schemes are HTTPS/HTTP/mailto plus relative URLs/fragments. Add application-controlled `rel="nofollow noopener noreferrer"`; do not accept author `target`, styles, event handlers, scripts, forms, SVG, images, video or iframe tags. Uploaded media is rendered separately through authorized components. Disable syntax highlighting initially so the allowlist needs no author-controlled style/class exceptions.

**Author embed host allowlist: empty.** No pasted iframe or automatic third-party URL embed. Required application-owned embeds are separate HEEx components:

- Turnstile script/frame: exactly `https://challenges.cloudflare.com`.
- Private Stream player: exactly the configured `https://customer-<CODE>.cloudflarestream.com` host (the code comes from provider configuration). The initial iframe source is the same-origin `/media/{id}/watch` route, which authorizes then redirects to the signed `/iframe` destination. Do not wildcard all customer hosts or accept an author-supplied destination. Thumbnails use the separately authorized route; R2 images use the configured cookie-free media origin.

Retain the generated `put_secure_browser_headers` plug and all [Phoenix 1.8.14 defaults](https://github.com/phoenixframework/phoenix/blob/v1.8.14/lib/phoenix/controller.ex): CSP `base-uri 'self'; frame-ancestors 'self';`, `referrer-policy: strict-origin-when-cross-origin`, `x-content-type-options: nosniff`, and `x-permitted-cross-domain-policies: none`. Those defaults restrict who can frame Tips; they do not forbid Tips from embedding Stream or Turnstile.

When adding a stricter CSP, preserve those default directives and allow `frame-src 'self' https://challenges.cloudflare.com https://customer-<CODE>.cloudflarestream.com`, plus Turnstile's exact script host or its documented nonce approach. Follow [Turnstile's CSP requirements](https://developers.cloudflare.com/turnstile/reference/content-security-policy/). Test the real redirects, signed video playback and signup widget. Do not weaken global headers to accommodate authored HTML.

## Publishing and draft recovery

### Review content and evidence

Each image/GIF has an optional plain-text `description`, editable with the content and preserved in draft slots and ordering. Blank input becomes NULL; no required-description gate or decoration checkbox. Render supplied descriptions as escaped alternatives and use an honest generic fallback when absent; the fallback is not equivalent to a meaningful description, so no accessibility-conformance claim follows. Media validates content with a maintained parser to derive `is_animated` for GIF, WebP and APNG as well as static files, rather than trusting extensions or browser flags. Persist that classification with the uploaded file; authors cannot edit it. Bound parser resources and reject unclassifiable files with preserved input. The parser is Pillow, run in its own OS process under a wall-time and address-space ceiling; [Image/GIF upload integration](#imagegif-upload-integration) gives the ceilings and outcomes, and the [image parser probe](../development/image-parser-probe.md) the selection evidence. The frontend controls animation and static editor previews.

The shared composer supports attachment reordering through drag gestures and equivalent Move earlier / Move later buttons. Publish and edit receive the intended ordered attachment set, validate ownership and uniqueness, and persist positions with the content transaction. Upload completion order must not determine display order. Reordering retained media does not re-upload it; a saved order-only edit follows the existing permission and edit-version guards.

Keep the author's written review separate from optional supporting evidence. The review is the firsthand account of what they tried and what happened, stored in `reviews.body` and rendered as Markdown. The prompt textbox maps to `reviews.prompt`. Result text maps to `reviews.output`; uploaded result media use the review's existing `media` rows. Prompt and result text retain the data model's verbatim rendering contract.

The frontend keeps Review visible and places optional Prompt and Result controls in one native evidence disclosure; drafts, edits or errors containing evidence open it automatically. Result accepts text alone, media alone, both, or neither. No result-type discriminator or mutual-exclusion constraint is needed. The review body remains required in every case. Content validates the text and coordinates publication; Media handles selected files and their attachments. The [frontend result composer](frontend-design.md#result-composer) owns selection, paste/drop, previews, and file removal.

MVP result media includes images, GIFs, and short videos for recorded workflows or generated video output. Keep PNG, JPEG, WebP, and GIF support. Accept common video recording formats and use a managed service to prepare browser playback automatically. The `media` table represents both stores and their lifecycle.

Tips and reviews share the optional Result composer and media rules. For tips, prompt and result text map to `tips.prompt` and `tips.output`; media attach to the tip. The tip's title, required technique description, and required tag remain distinct from the review form. Reuse the same attachment controls, validation, readiness, and recovery behavior. This applies [GitHub's shared attachment support across issues and comments](https://docs.github.com/en/get-started/writing-on-github/working-with-advanced-formatting/attaching-files) to Tips' two contribution types.

Each tip or review allows up to ten attachments in any mix of images, GIFs, and videos. Multiple videos are allowed; each remains limited to three minutes. Use one ordered attachment list and a shared count, not separate image and video quotas. Validate the combined final selection on publish and edit, including retained attachments. The composer prevents an eleventh selection without removing existing items; the backend enforces the same total independently. Ten is a Tips product limit, not an industry standard.

### Image/GIF upload integration

Start with a limit of 10 MB (10,000,000 bytes) per image/GIF and 50 MB (50,000,000 bytes) across newly uploaded images/GIFs in one publish or edit submission. Retained published attachments do not consume this upload-byte allowance. Videos retain their separate 1 GB per-file limit and direct Stream transport; all media still share the ten-attachment limit. Validate individual sizes and the aggregate selection before transfer for feedback, and enforce the limits on the server during upload and before R2 storage/publication. These are adjustable MVP defaults, not a requirement to compress files automatically.

Use [built-in LiveView uploads](https://phoenix-live-view.hexdocs.pm/uploads.html), with upload on selection disabled. On submission, LiveView transfers files to temporary server storage before invoking the submit callback. Validate text first, then use `consume_uploaded_entries` with `{:postpone, path}` to obtain completed files without releasing them. Start with a synchronous Content attempt over those page-owned paths; Content validates files, stores R2 objects and owns transaction/cleanup decisions. Consume with `{:ok, result}` only after the submitted content is acknowledged as created/equivalent or its explicit edit is confirmed; different/unknown receipts retain the entries for recovery. Known failures retain the entries for retry while the page lives; unknown outcomes reconcile before another attempt. Disable attachment changes during submission. Never pass consumed temp paths to background work, keep R2 keys as reusable page-only staging, or delete uncertain objects when the page terminates. Keep sockets and LiveView upload entries out of context APIs. Preserve the existing permissions, file limits, retry, and orphan-cleanup contracts. Temporary upload completion is not publication or durable draft recovery. The frontend may use one page-owned async attempt only if measured blocking warrants it, retaining entries until page-side consumption; no detached task or durable job may own these paths. Video uploads go directly to Stream on selection.

`Tips.Content.Media.store_images/2` is the attempt: it checks the count and byte limits, parses every new file before storing any, then puts each under a fresh key and returns the stored images or an explicit error. Its module documentation states the results and who deletes what. `Tips.Content.Media.ImageParser` runs `priv/image_parser/classify.py` under these ceilings:

| Ceiling | Value | Enforced by |
|---|---|---|
| Bytes | 10,000,000 | the caller before parsing, and the parser |
| Width or height | 8,192 px | the parser, from the header before decoding |
| Pixels per frame | 40,000,000 | same |
| Frames | 300 | same, from the declared count |
| Pixels across frames | 100,000,000 | same |
| Wall time | 5 s | `timeout --signal=KILL` |
| Address space | 1 GiB | `prlimit --as`, on Linux only |

The 40 MP frame limit rejects a 48 MP phone photo (8064×6048) even under 10 MB. A file over a size ceiling is `too_large`; content that is not PNG, JPEG, WebP or GIF is `unsupported`; a malformed file, the memory ceiling, the deadline and any other parser failure are `invalid`. An accepted file is animated when it has more than one frame, and its format, not its file name, sets the stored extension and Content-Type. Files are parsed one at a time, and at most two parsers run at once across the application.

### Managed video

Use [Cloudflare Stream](https://developers.cloudflare.com/stream/uploading-videos/) for video ingestion, encoding, storage, and playback delivery. Keep images and GIFs in R2. Stream accepts formats including MP4, MOV, and WebM. Each video may be at most three minutes (180 seconds). Each video may be up to 1 GB (1,000,000,000 bytes); enforce both the byte cap and the 180-second duration limit. Check file size before requesting/uploading and enforce the cap through the server-authorized upload integration; browser validation alone is insufficient. Reject oversized files with a clear message while preserving other form input. Do not make users convert otherwise supported recordings manually. Store Stream asset identifiers for videos; do not duplicate video originals in R2 in the MVP.

Keep every Stream asset private from reservation onward by setting server-owned `requiresignedurls` metadata. There is no public-access activation after publication, no `activated_at` or activation-job link, and no separate Retrying/Failed activation status. A confirmed database commit makes a ready attachment eligible for public readers under Content’s visibility policy. Processing completion alone never publishes content.

Expose ordinary controller routes `GET /media/:id/watch` and `GET /media/:id/thumbnail`. Both call one Content media-access function checking current ownership, attachment membership, readiness, expiry/cleanup and visibility. Anonymous readers may access eligible public attachments; staged and other privileged previews require current authorization. A hidden tip does not hide independently visible reviews. Accept only the Tips media id and choose the configured Stream host and representation server-side. The watch route redirects to the documented signed Stream `/iframe` destination, loaded inline on Play; thumbnail redirects to the signed poster. Return `Cache-Control: private, no-store` so app redirects are not reused to bypass authorization.

Sign locally using [JOSE](https://jose.hexdocs.pm/JOSE.JWT.html#sign/3), RS256 and the Stream signing key in release secrets, following [Stream’s signing protocol](https://developers.cloudflare.com/stream/viewing-videos/securing-your-stream/). Use one-hour tokens initially, with downloads disabled. `Phoenix.Token` is not this provider JWT format. No per-view API call, token table, refresh task or browser-stored playback token is needed. A missing/broken signing configuration fails closed with an operational error, never a bare-uid fallback. Verify the signed iframe and thumbnail destinations with the real integration. On each player opening request fresh authorization; no mandatory new-tab playback or custom player is needed.

Share tip/review permalinks as the stable content destination. Provider URLs expire; opening the player again obtains fresh authorization without making the reader repair a URL. Hiding stops new authorization but issued tokens may work until expiry. Explicit media removal deletes the provider asset asynchronously; neither hiding nor deletion recalls saved copies. Images retain their R2-link policy. Hidden attachments remain stored and are not orphans. Tokens are necessarily present in provider network requests; do not persist them in browser drafts/storage or app tables.

The three-minute limit follows [YouTube Shorts' duration convention](https://support.google.com/youtube/answer/15424877?hl=en), applied here to short workflow demonstrations. It is a configurable product starting point, not a provider limit. Check browser-reported duration for early feedback when available; enforce the limit using trusted Stream metadata before attaching a playable video. For direct creator uploads, set Stream's `maxDurationSeconds` to 180 when creating the upload URL. Reject overlong videos with a clear message; never silently trim evidence.

`Tips.Content.Media` owns video preparation, provider identity, processing state, readiness and cleanup. Stream owns encoding; Content owns attachment eligibility and publication. While an editor has pending videos, its LiveView requests bounded asynchronous status refresh through Content, and updates progress automatically. Refresh pending uploads on reopening. There is no global readiness worker or Stream webhook. Processing completion never publishes content, restores deleted rows or transfers media ownership.

Upload completion and playback readiness are separate states. Run one nonoverlapping async refresh cycle per editor, bounded to its selected upload ids, with a small provider-call concurrency limit and the Stream API timeouts below. Schedule the next cycle about five seconds after completion, with rate-limit/backoff handling and no nested retry loop. Stop periodic refresh when no pending videos remain or the editor terminates. Do not block typing while several calls time out. Re-admit privileged access and verify ownership/target for every id before provider work; apply results through guarded Media writes. Timeout means still checking, not encoding failure, and cannot demote a trusted ready row. Keep polling state in the page, without `checked_at` or a scan-rotation index. Enforce existing account/provider request budgets across editors and measure actual capacity.

A NULL uid means the upload endpoint was never released to the browser. At its original one-hour deadline, retire and delete the NULL-uid row locally; a definite provisioning failure may retire it sooner. Perform no provider rediscovery or deletion job without an identifier. The composer retains its local attachment slot and failure, expiry or missing-asset feedback with replacement/removal actions; deletion of the server row does not silently drop the selection or prove why a generic missing id disappeared. Stream releases unused reservations at expiry; this does not promise removal of every empty provider metadata record. The conditional uid-persist rule below prevents a late provisioning response from reviving an expired row.

Use a separate bounded periodic expiry worker for unattached media, including processing, ready and failed rows. Start with a minute cadence, at most fifty due candidates per run, active-job uniqueness and `max_attempts: 1`; bound each provider call and the run’s total work. Select by the stored expiry and a NULL-or-due `reconcile_after`. Completed rows expire at the fixed recovery deadline, authorization plus 49 hours; the data model's [Video states and deadlines](data-model.md#video-states-and-deadlines) owns the completion fact and the worker's cases. Apparently unfinished known-uid rows require a provider read that starts at least 10 minutes after the upload deadline before cleanup. On uncertainty, set a guarded `reconcile_after` to current wall time after the attempt plus ten minutes initially, allowing later rows to progress. Keep the user-facing expiry unchanged. NULL-uid rows expire locally. Clear obsolete cooldown on definitive progress, attachment or cleanup. The data model owns the static index and runtime due predicates. Serialize cleanup against attachment claims under the media-row lock and enqueue deletion in that same transaction when a provider id exists. Provider calls stay outside locks. Editor refresh and expiry use the same guarded state transition; this is not a continuous readiness scan.

Every server-side Stream API call (reservation, status read, deletion) uses a 5-second connect timeout and a 5-second receive timeout, with no automatic retry. Reservations took 503–668 ms in the [#61 probe](https://github.com/chenghanlee/tips/blob/ffc45699da0e07650b4e3ddd4081a9d8e7df28a5/docs/development/media-provider-probe.md#stream-findings). A timed-out read is uncertain, not failed; a timed-out reservation follows the lost-response rule below. The browser's tus client owns `PATCH` timing; Stream's upload expiry bounds it.

Publish only when all selected videos are playable. This follows [YouTube's publication readiness rule](https://support.google.com/youtube/answer/57407?hl=en): standard-definition processing must finish, while higher resolutions may follow. Show upload and processing progress in the composer; preserve the text on failure and allow removing a failed attachment before publishing. Do not publish while selected videos are still processing or silently drop selected evidence from the saved submission. Check readiness and attachment ownership on the server before committing publication; encoding runs outside that transaction.

Use the single `media` table defined in the data model for R2 images, staged/attached Stream videos and cleanup records. Stable ids survive attachment and reordering. `kind`, provider identifiers and processing state distinguish the storage paths. Access is authorized from current database state when a playback or thumbnail link is requested. Publishing retries, author deletion, moderator file destruction, orphan cleanup, and draft recovery must account for both stores. Do not infer that an uploaded video is ready from the upload response alone.

Choose Stream over [Cloudflare Media Transformations](https://developers.cloudflare.com/stream/transform-videos/) for broad upload compatibility and explicit processing readiness. Media Transformations recommends H.264 MP4 input (other video formats are untested), limits inputs to 100 MB and ten minutes, and caps output clips at sixty seconds. It does not meet the same upload contract without narrowing accepted recordings. Do not add this second video pipeline or silently truncate submitted evidence.

Observed Stream behaviour ([provider probe](https://github.com/chenghanlee/tips/blob/ffc45699da0e07650b4e3ddd4081a9d8e7df28a5/docs/development/media-provider-probe.md#stream-findings)):

- Read the uid from the `stream-media-id` response header, not from `Location`.
- Stream accepts a declared `Upload-Length` of 1,000,000,001 (201). Only Tips enforces the 1 GB cap: refuse a larger length before reserving.
- `Upload-Length` of `0`, `-1` or `abc`: 400, code 10026.
- A `PATCH` cannot raise the declared length. A `PATCH` with more bytes than declared: 400, nothing stored.
- Bytes sent after the upload is complete: 204, but `Upload-Offset` stays the same and the bytes are not stored. Read `Upload-Offset`; the status does not signal refusal.
- A non-final `PATCH` that is not a multiple of 256 KiB: 400, code 10031.
- A non-final `PATCH` under 5,242,880 bytes: 400, code 10015 ([#243 run](../development/stream-completion-probe.md#result)). Non-final tus chunks must be at least 5 MiB and a multiple of 256 KiB.
- An expiry less than two minutes ahead: 400, code 10005.
- `uploadExpiry` is fixed at reservation. Pause and resume do not extend it.
- A `PATCH` started after `uploadExpiry`: 400, code 10017; the video stays `pendingupload`. A `PATCH` still sending at expiry is unproven: three were refused with 400, code 10017, when their bodies finished ([completion probe](../development/stream-completion-probe.md)).
- `uploaded` is the reservation time and no field records completion time.
- The state leaves `pendingupload` only after the last byte.
- If the creation response is lost, the reservation still exists at Stream. The caller has no uid; only the `name` metadata finds it.
- A video over 180 seconds ends in `state: error` with `ERR_DURATION_EXCEED_CONSTRAINT`; its signed manifest returns 424.
- Unsigned manifest, thumbnail and iframe URLs return 401.

### Video upload before publication

Start video upload and processing immediately on selection, while the author keeps writing. Publishing remains an explicit action after selected videos are ready. This follows [GitHub's immediate attachment upload](https://docs.github.com/en/get-started/writing-on-github/working-with-advanced-formatting/attaching-files) and [YouTube's upload-before-publication flow](https://support.google.com/youtube/answer/57407?hl=en). Images and GIFs retain the existing upload-on-submission flow.

Use [Stream direct creator uploads](https://developers.cloudflare.com/stream/uploading-videos/direct-creator-uploads/): Phoenix authorizes an upload and obtains a limited upload URL; the browser sends video bytes directly to Stream. Keep the Cloudflare API token on the server. The composer shows transfer progress locally, then processing/readiness from the backend. Selecting a file does not create a tip, review, search row, vote, or notification.

Use the resumable tus protocol for every video, including files below 200 MB. This provides one video transport and supports the 1 GB cap; do not add a basic POST path for smaller videos. Phoenix provisions the Stream tus endpoint using a validated upload length and server-controlled privacy, duration, and expiry metadata. The browser sends chunks directly to Stream and resumes interrupted transfers while the source file and upload endpoint remain available. This does not promise continued transfer after closing the browser or automatic recovery of file bytes after reopening. Use LiveView external uploads with a small tus-js-client adapter for video transfer. Preflight calls the Content operation below and returns server-issued metadata; browser progress is not proof of readiness. Images/GIFs retain their separate built-in upload-on-submission configuration.

An unfinished video upload expires one hour after authorization. Persist this deadline and configure the Stream upload expiry accordingly; resuming a transfer does not extend it. After expiry, require explicit initiation of a fresh upload and make the unfinished asset eligible for cleanup. Preserve the written draft and show the expired attachment rather than silently dropping it. A completed upload is recoverable until 48 hours after that upload deadline, so at least 48 hours after its last byte, or 47 hours 50 minutes if Stream completes it inside the 10-minute cleanup margin; delayed processing or status reads do not turn a completed upload into an unfinished one or move its deadline. For an upload with a persisted uid, reconcile trusted provider state before cleaning up an apparently unfinished transfer; never-released NULL-uid reservations expire locally.

Content operations shared by tip and review forms:

| Function | Contract |
|---|---|
| `begin_video_upload(scope, target, file_attrs)` | Check contribution eligibility, target-specific permissions, upload limits, and whether a new submission already published. Record ownership and the intended target; request a Stream upload URL with the duration limit. Return a Tips upload id and upload URL. |
| `get_video_uploads(scope, upload_ids)` | Re-admit the author, authorize each bounded upload id/target, refresh only pending states through bounded provider reads, apply guarded writes, then return current committed state and safe feedback. Run from page-owned async work; ready rows need no provider call. Browser progress never declares readiness. |
| `discard_video_upload(scope, upload_id)` | Mark an owned, unattached upload unavailable for publication, then arrange Stream deletion outside the transaction. An attached video must go through the content edit/delete operation. |

The upload target is one of `{:new_tip, submission_key}`, `{:new_review, tip_id, submission_key}`, `{:edit_tip, tip_id}`, or `{:edit_review, review_id}`. Ownership binds every target to its account. New reviews require a live parent; edit targets require ownership and current edit eligibility. Neither tip nor review author edits has a time limit; account, ownership and deletion rules still apply. Keep the edit version on the edit operation, not in the upload target: there is no version-rebinding operation.

Persist a `media` row before provisioning: author, canonical target, processing state and original one-hour deadline. One server-owned encoder turns the typed target tuple into `target`; accept no arbitrary browser target. Send server-controlled privacy, duration and the fixed expiry on the initial tus request. Read the provider uid from `stream-media-id`, not by parsing the endpoint. Persist it only while the row still has a NULL uid, has not entered cleanup or failed/expired state, and remains before its original deadline at a `clock_timestamp()` check after acquiring the row lock; then commit before returning any upload URL. If that guard fails, never expose the URL. A persisted uid is never cleared. Disable automatic creation retries; an explicit fresh upload gets a new row. Keep the media id in the reservation metadata, for operators only. No lookup recovery path is required for a never-released endpoint. Verify expiry and lost-response/late-persist races against the actual integration. The [reservation trace](../development/stream-reservation-trace.md) records these cases against real Stream. Return the durable media id during external-upload preflight so the frontend preserves its form position and draft reference before transfer. Written content stays in browser drafts; status updates grant no ownership or publication rights.

`publish_tip` and `publish_review` receive selected Tips upload ids alongside form values and image files. Inside their transaction, lock and verify those upload records, require the same author/target/submission and playable videos within the duration limit, and attach each asset only once. Removal and cleanup must use the same records to avoid deleting a video concurrently with attachment. Repeated publication returns the original content using the existing submission key. A validation failure may retain reusable video uploads; never treat them as disposable per-request image uploads. Use the media state and constraint contract in the data model; claims and cleanup serialize on the same row.

Edits use the same preparation flow and require ready videos before saving. Starting an upload does not bypass stale-version or current-eligibility checks. After a conflict, preserve prepared assets until expiry; explicit reapplication retains the same account/content target without rebinding media to a version. The final edit transaction independently checks the original expected version and current permissions. Confirmed attachment removes temporary expiry; removed assets enter cleanup after commit.

An explicit edit may also claim an owned, ready, unattached, unexpired, non-cleanup video prepared for a new-submission target when the stored author/kind/submission key resolves to this exact published item; for a review, its stored parent must also match. Resolve this equivalence from immutable database facts at claim time. Do not rewrite the target, add a rebind endpoint, move attached media or permit editing a deleted original. This supports the frontend’s in-place recovery handoff without requiring another video upload.

### Browser drafts

The [frontend saving and recovery contract](frontend-design.md#saving-and-recovery) owns IndexedDB records, revision CAS, restore, leave confirmation and the publication-to-edit handoff. Keep one new-tip slot per account, one new-review slot per account/parent, and edit slots per account/content. There is no server draft table or fallback store. Storage failure does not block explicit publication or saving; preserve on-screen work and acknowledge its risk.

Content treats restored values as untrusted input, rechecks current admission/ownership/eligibility, and never treats a submission key or browser revision as content acknowledgement. Publication recovery uses the outcomes below; edit recovery retains its original expected version and complete editable base. A draft in handoff edit mode follows the edit contract even though it remains in its original new-draft slot. Only the submitted record/revision may be cleared after its content is acknowledged; unrelated or newer work survives.

Recover existing attachments by authorized references, and staged videos by their current owned target and expiry, including the exact-item target equivalence above. Reopening requires image reselection and may require the source file to resume an unfinished video transfer. Missing, destroyed, expired or failed assets remain represented with replacement/removal feedback; never silently remove intended evidence. No provider token or image bytes belong in the draft.

Completed, unattached videos remain recoverable until 48 hours after the one-hour upload deadline, including processing time. The first trusted completion sets that fixed deadline once; reopening and observation do not extend it. Reconcile uncertain unfinished known-uid rows before cleanup using the expiry cooldown above. Claims and cleanup lock the same row; attachment clears temporary expiry and cooldown. Attached assets are unaffected by draft expiry.

Leaving or losing the editor does not publish, discard or cancel provider processing. Explicit discard first reconciles uncertain operations and affects only the selected draft and its still-unattached temporary media; it never deletes published attachments or proves rollback. Unknown image outcomes follow committed-reference reconciliation and the orphan sweep. Publication and edit outcome rules below remain authoritative even without browser storage.

### Publishing and retry contract

Publishing uses a submission key. Generate a UUID for the intended publication and retain it with the browser draft before submitting. Reuse it across disconnects and retries. Tips and reviews require `submission_key`, unique per author within each table. The key remains on deleted rows. Submission keys protect publication only.

The `Tips.Content` module documentation ("Publication and edit contract") is the contract for `publish_tip/4`, `publish_review/5` and `get_publication/4`: inputs, receipts, outcomes, the whole-intent comparator, errors and transaction participants. Compare intent without a digest column or request-log table. Neither an existing key nor a restored draft grants extra permissions.

Tip and review forms validate all text on Publish/Save, including missing required fields. State limits up front and preserve pasted text rather than silently truncating it. Before the first submission, do not show errors on untouched fields. After a failed submission, revalidate corrected fields so errors clear. Use the same Content changeset rules; validation has no publication, notification, indexing or upload side effects. Final writes recheck current authorization and constraints. Attachment checks remain immediate.

The operation runs as follows:

1. Resolve the authenticated caller. Validate the submission key and target identifier. Look for an existing publication by that caller and key before uploading; for a review, verify that its stored parent is the requested tip. Compare and return an existing publication without repeating side effects. This branch precedes required-field/file validation and upload work, so an incomplete recovered form can still reconcile identity and return unknown equivalence.
2. Validate form inputs and perform early eligibility checks. These provide feedback; the transaction locks and rechecks the current author, confirmation, ban and applicable parent eligibility before writing.
3. Validate and upload images through Media using the existing upload contract. Keep each attempt's generated file keys separate. Trust previously committed ready video state; refresh only pending selected videos before deciding. Provider calls occur outside the content transaction. Return pending or failed attachment feedback with the draft intact if any selected video is not playable. Reconcile a prior successful submission key before waiting on media; provider outages cannot invalidate already ready uploads. The single media table holds the selected staged videos.
4. In one transaction, verify attachment ownership and readiness, then insert content through a changeset, search text, self vote, and image media rows, and attach the selected staged video rows. Publishing a review also folds the eligible author's notification. The existing triggers update counters. Only a new insert runs these writes.
5. Map `tips_submission_unique`, `reviews_submission_unique` and `reviews_one_per_user` by their actual migration names. On a submission-key conflict, roll back the attempt and look up the original row in a fresh statement, applying the same whole-intent comparison. A review's one-per-user constraint can report the conflict first, so resolve the submission key before returning "already reviewed." Clean up only the losing attempt's new unattached image objects; reusable staged videos retain their normal recovery window. If a guarded insert returns no id, recheck the key before returning the current write rejection.
6. Return a receipt only after commit is confirmed or a committed original is found. Only created or established equivalent content permits normal post-save clearing of the submitted browser revision. Different/unknown preserves the proposal and offers the frontend’s explicit edit/discard journey. A failed clear CAS preserves newer work. Embedding generation runs asynchronously from the committed search row.

After a lost response, restore the draft and check its submission key. If no publication is found, the author may retry with that same key; an earlier request still in flight is handled by the unique constraint. Preserve the draft and key while the outcome remains unknown. Keep the submitted values fixed during uncertain-outcome recovery; even a fixed retry can lose a race to another tab with the same key, so it still requires content comparison before clearing. A committed key always identifies its original publication; subsequent changes use the edit operation. Deliberately starting a new post or re-review uses a new key.

An unknown commit outcome is not a confirmed rollback. Never delete an attempt's uploaded files merely because confirmation was lost. Reconcile with committed media references or leave uncertain files for the existing orphan sweep. The [data model's retry contract](data-model.md#publish-retries) owns the SQL details and required verification cases. This follows [Mastodon's submission-key pattern](https://docs.joinmastodon.org/methods/statuses/) using content rows and unique constraints rather than an additional request-log table.

When opening a fresh review form, prefill its optional model and environment from the tip, including a free-text model if present. Let the reviewer change or clear either field and explain briefly that these values should describe their own attempt. Initialize once: a restored draft or an existing review uses its own saved values, including explicit blanks. Later tip edits must not overwrite review input or published review metadata. Publishing stores the submitted setup; the backend must not fill omitted or cleared fields from the tip. Each review owns its setup independently. A review has at most one primary model and one primary environment. Authors may compare additional setups in the body and associate their outputs through the explanation. Structured setup filters match only the stored primary values; textual mentions do not expand those filters. Do not introduce multiple setup selections or per-attempt records in the MVP.

Add user-triggered Copy prompt and Copy result buttons beside nonempty verbatim blocks; copy exact raw text with whitespace and report success only after the browser confirms it. Ordinary selection remains the fallback. Whole-tip clipboard export and copy tracking remain deferred; no Content operation or copy-event storage is needed.

Text preview is deferred for tip and review composers, including edits. Render Markdown after confirmed publication or save. No preview operation is required; attachment previews retain their existing behavior.

## Editing and conflicts

Only the author can edit while eligible to contribute. Tips and reviews can be edited at any time. Show Updated on edited tips too, with one nonblocking note that earlier reviews may describe an older version. Tip edits preserve publication time, existing votes and ranking inputs, and emit no new review/vote notification. Keep one active review per author per tip, update it in place, and show its original publication date and an “Updated” date after edits. There is no immutable review log or appended-update mechanism. An edit timestamp records a change, not proof that the author retested the technique. The review list’s “New” sort continues to use `created_at` with the id as a tie-breaker. Editing does not move the review up that list or reset its publication date; display the updated date separately. Review edits retain existing Helpful and Not helpful votes, including their counters; eligible voters may change or remove their votes under the normal voting rules. Votes refer to the review as a whole and may predate its latest revision. An edit does not recreate votes or emit vote notifications. Editing an existing review also does not create or refresh a tip-author notification: only a newly published review triggers the existing review notification, subject to its eligibility rules. An existing inbox entry may display the current review text when read, but its timestamp, count, and read state are not changed by an edit. Reject an edit based on an older saved version and preserve the submitted proposal. Use the explicit conflict choices below; never automatically retry with a newer version. This follows [Discourse's edit-conflict behavior](https://github.com/discourse/discourse/blob/main/app/controllers/posts_controller.rb).

The `Tips.Content` module documentation ("Publication and edit contract") is the contract for `get_edit_form/3`, `edit_tip/5` and `edit_review/5`: inputs, locks, version checks, no-op, conflict and unknown outcomes, receipts and errors.

The frontend retains its original expected version alongside unsaved values. Content validates input and asks Media to upload new images before the transaction. Build the versioned write on the editor's expected base version, using `stale_error_field: :edit_version` for conflict feedback. Never silently substitute the freshly loaded row's version. Use one compare-and-increment mechanism, as in [Implementation foundation](#implementation-foundation).

Detect actual changes across the whole intended edit, including tag, setup, descriptions, media membership and order, before adding the version increment; inspecting only the parent changeset is insufficient. Author and moderator changes advance the same `edit_version` once; votes, counters and embeddings do not advance it. No report-specific author revision exists.

Only a successful versioned write permits the related attachment and search changes to commit. Preserve retained media ids; mark removed rows for cleanup, update positions, attach ready staged videos and insert new image rows. Defer both media slot constraints only within this transaction; the final selection must be unique, owned and within ten slots. Commit search text, media effects and required Oban jobs together. Return the committed version on success.

For a confirmed failed attempt, Media removes only newly uploaded unattached images; reusable staged videos retain their normal expiry. For a confirmed successful edit, transactionally enqueued cleanup removes retired files after commit, retaining identifiers until confirmation.

The [data model](data-model.md#edit) defines the version fields and eligibility contract. Moderator file destruction also advances the edit version so an old editor cannot restore destroyed attachments. No edit-history table, editor session lock or automatic merge mechanism is needed.

Conflict recovery follows the module documentation. An explicit Save at the current version still passes the ordinary version guard, so a concurrent change can reject it. A missing or incomplete base, or changed editable fields, use the frontend’s preserved-reference/manual-reapply path. Hide and restore advance the same `edit_version`, so a stale moderator action cannot undo a later restoration. The shortcut is not an automatic rebase or a second version column.

## Voting

When a signed-out reader clicks Helpful or Not helpful, require sign-in and preserve a validated local return destination for that tip or selected review. After authentication, return there and load current vote state; do not automatically cast or replay the earlier vote. The reader clicks again to vote. Use the same behavior when authentication expires before the vote request is accepted.

The tip page displays separate Helpful and Not helpful counts for the tip and each review. Include both counters in `get_tip_page` and subsequent review-page reads. Compact browse, filtered-feed and search rows retain net score and expose the same Helpful / Not helpful actions, selected state, pending feedback and signed-out return behavior. Summary hydration includes the viewer's vote and current voting capability; both layouts call the same set_vote operation. Display counts as opinions of helpfulness, never as successful/failed attempts; retain the existing visibility and viewer-specific vote rules. Ranking formulas are unchanged.

Expose `Tips.Content.set_vote(scope, kind, id, desired_value)`, where the desired value is Helpful (`1`), Not helpful (`-1`), or no vote (`nil`). The UI uses the toggle interaction: clicking the selected button requests removal, and clicking the other button requests that value. Send the resulting state to the backend rather than a toggle command that could reverse itself on retry. This follows [Mastodon's separate favourite/unfavourite operations](https://docs.joinmastodon.org/methods/statuses/), which succeed when the requested state already holds.

Content locks the voter account and direct target, then rechecks current account and target eligibility before the guarded vote write. A review vote does not lock its ancestor tip. Write the vote and any eligible upvote notification in one transaction; existing triggers update counters and ranking inputs. Repeated requests for an unchanged live vote create no new notification. Preserve self-vote behavior and event-count notification semantics. Invalidating a vote deletes its row under the existing locks; the trigger subtracts its contribution. Unbanning never recreates votes. A later explicit eligible vote is a new vote. An affected-row count of zero requires distinguishing an unchanged vote from a rejected operation; it is not automatically success.

Return the confirmed viewer vote, current Helpful and Not helpful counts, and net score after the write. Read these counters consistently after the vote transaction; do not derive the response by adding a client-side delta. The frontend keeps one vote request in flight per target and shows pending state. On an uncertain response, read current state before offering another change; do not replay old intentions after a newer choice. Updating a displayed score does not reorder the current feed or search results. No firsthand-experience record or review lookup is needed for vote eligibility.

### Author deletion confirmation

Authors confirm once before deleting a tip or review. Explain that the action cannot be undone and that deleting a tip preserves its existing visible reviews under the deleted-tip placeholder. After confirmation, commit the deletion and initiate the existing attachment cleanup; do not add an undo window, restoration operation, or delayed deletion lifecycle. Database row retention for references does not provide author recovery. This follows [Reddit’s no-restoration policy](https://support.reddithelp.com/hc/en-us/articles/360043483451-If-I-delete-a-post-or-comment-can-it-be-restored).

### Author-deleted tip pages

An author-deleted tip retains its original URL as a “Deleted tip” placeholder with its existing visible reviews and their attachments. Hide the deleted tip’s title, body, prompt, result, author attribution, and attachments for all viewers, including its author and moderators. Use a neutral `deleted-tip` slug and masked page metadata and profile/inbox links; resolve old links by id. Deletion takes precedence over moderator-hidden presentation. Keep the tip out of feeds and search, and block new reviews. Existing reviews retain their independent visibility, editing, voting, and deletion permissions. Delete only the tip’s own media through the normal cleanup flow; its deletion does not cascade to review media.

## Reports and moderation

For a signed-out Report action, preserve a validated local return destination identifying the target and reporting interaction through sign-in. Recheck target availability and reporter eligibility before reopening it; authentication must never insert or replay a report. Require explicit submission after return. If admission expires during submission, preserve input and offer reauthentication before another explicit submit.

Use the `flags` table with a required reason and optional explanation of up to 1000 characters. Present the `fabricated` reason as fabricated experience or evidence. This applies [Google Maps' separation of policy violations from disagreement](https://support.google.com/business/answer/4596773?hl=en) to Tips' firsthand-use requirement.

Operations exposed through Content and implemented in its Moderation module:

| Function | Contract |
|---|---|
| `report_content(scope, kind, id, attrs)` | Validate the reason and optional detail, check current reporter eligibility and reportable target, and insert the report. Permit at most one open report per person and target; after resolution permit a new report even on unchanged content. Return whether a report was newly stored or an open report already exists, only after confirmed persistence. |
| `list_moderation_queue(scope, opts)` | Require moderator access and group open reports by target using the existing queue ordering; return twenty cases plus one-row lookahead at the validated offset. |
| `get_moderation_case(session_ref, kind, id)` | Readmit the session, require the moderator role and return the content, attachments, and individual reports with their explanations. A reason-count summary alone is insufficient for assessing a fabrication report. |

After newly confirmed persistence, show “Report received.” If an open report already exists, return its receipt and say it was already reported; never claim newly supplied detail was stored. Preserve input for uncertain outcomes. There is no automatic report retry loop, report-status page, outcome notification or email. Reports never automatically hide content, change ranking or impose a penalty.

After a report is resolved, its reporter may submit a new report on the same content without an intervening author edit. Keep resolved rows as history; do not reopen them. Lock the reporter account and require confirmation, undeleted status and no full ban, then select the reportable direct target `FOR SHARE` before insertion. Author deletion either waits and resolves the inserted flag, or commits first and causes report eligibility to fail. No author-revision parameter or ancestor-tip lock for a review report is needed. Enforce partial one-open indexes per reporter/target. On expected uniqueness conflict, roll back and read the existing report receipt; resolution may race that read, so return its actual state and preserve submitted detail if no receipt can be established. An explicit delayed retry after an uncertain submission may create a new report if the earlier report was already resolved. Accept that extra queue work; do not promise exactly-once reporting or silently retry until a new row appears. Moderator content-version and reviewed-report-set guards remain independent.

Moderator actions on reviewed content must reject stale state: hide, restore, and report dismissal compare the content version and relevant moderation/report state that the moderator loaded. If the content changed, change nothing and return the latest content for review before an explicit retry. Do not automatically retry against a newer version or resolve reports that arrived after the reviewed set. Repeated requests for an already completed identical action may return its confirmed outcome. The frontend preserves the moderator’s context and explains that the content changed. The report-dismissal and media-removal contracts below define the action scopes.

Reporting creates a moderation record; it does not change votes, search ranking, or visibility. Existing moderator hide/restore and flag-resolution operations control visibility. Failed techniques remain available for readers to evaluate alongside firsthand reviews. Use the guarded target-version and reviewed-report-set contracts below in the same transaction as each action.

When an author opens a tip or review deliberately hidden by a moderator, show a generic removal notice without a reason. Retain the existing author/moderator access to the hidden content. Do not add a removal-reason field, infer a moderator conclusion from report reasons, or expose reporters' identities or explanations. No separate author-removal notification or appeals workflow is added. Shadow bans are deferred; accounts are normal or explicitly fully banned.

A moderator-hidden tip keeps its public URL and a removed-tip placeholder, with existing visible reviews and their attachments readable. `Content` assembles the page using each item's visibility; it must not reject the whole page because the parent is hidden or expose the hidden tip's text and media to ordinary readers. Keep the tip out of feeds and search. Block new reviews while hidden, rechecking the parent at publication even if the editor was opened earlier. Hiding a tip does not cascade to its reviews or change their existing edit/vote permissions. Authors may edit moderator-hidden tips and reviews at any time, subject to account eligibility and version checks. Saving preserves `dead_at`; only explicit moderator restoration clears it. Restoration clears only the tip's moderation marker; individually hidden reviews and author deletions remain unchanged. No separate lock column is needed for this rule.

Moderators can change a tip's technique tag at any time, without changing its title, body, model, environment, prompt, result, attachments, or visibility. Expose `Content.retag_tip(scope, tip_id, expected_version, tag_id)` through Moderation. Require an active eligible moderator, an existing nondeleted tip, and an active curated tag. Compare and increment `edit_version`, update the tag and use the shared search-text write helper in one transaction: rebuild text, advance `text_at`, clear the vector and reset `embed_after`. A worker holding the old freshness token cannot store its vector afterward. A stale moderator form returns a conflict; an unchanged tag is a no-op. Preserve the author's `edited_at`, since this action changes classification only. The moderator UI offers a tag selector; an older author editor must reload and explicitly reapply changes after a conflict. This follows [Reddit's moderator flair controls](https://support.reddithelp.com/hc/en-us/articles/15484545678996-Post-Flair).

Keep bulk hiding and vote invalidation atomic for the MVP. Measure at least ten thousand reviews across many tips with concurrent votes against the request timeout before changing that contract. If measured capacity requires it, first consider one bounded maintenance transaction through Oban with an explicit UI outcome. Chunking requires a fixed target set under the account lock and explicit partial-progress semantics; it is not the default. Do not couple bulk hiding to a ban or raise the request-pool timeout.

### Bans and lifting a ban

Accounts support normal (`ban IS NULL`) and full-ban states only. A full ban blocks contributions but preserves reading and the existing own-content/account deletion rights. Banning does not retrospectively hide content; an explicit moderation operation handles that separately.

`Accounts.lift_ban(scope, user_id)` locks the eligible moderator and subject accounts in id order and clears the account restriction. It does not restore hidden/deleted content, recreate invalidated votes, replay notifications or change media. No Content restoration participant is needed. Keep account locks that serialize account eligibility changes against publication and other writes.

### Dismissing reviewed reports

Dismiss reports at the content-case level: resolve only the report ids returned in the moderator’s reviewed snapshot, leaving visibility unchanged. Reports arriving later stay open. If the content version or a captured report’s resolution changed, reject the stale action and reload before retrying. This adapts [Reddit’s content-level moderation workflow](https://support.reddithelp.com/hc/en-us/articles/15484440494356-Moderation-Queue). Unlike Reddit’s Approve action, dismissal does not restore hidden content. Do not add an Ignore future reports mode; later reports remain eligible under the existing reporting rules. Resolving only the reviewed snapshot is Tips’ concurrency contract, not a documented claim about Reddit’s internals.

Content operation: `dismiss_reports(scope, kind, id, expected_version, reviewed_report_ids)`. Recheck current moderator eligibility and return confirmed state or a conflict.

### Permanent removal of selected media

Allow moderators to select specific attachments for permanent removal, then confirm the selected count and that removal cannot be undone. Preserve all unselected attachments and text. `Content.destroy_media(scope, kind, id, expected_version, media_ids)` rechecks moderator eligibility and validates that every selected id belongs to the target. In one transaction, compare and increment the target edit version, remove the selected attachment references, and record durable provider cleanup work. Reject stale state without deleting anything.

Media performs R2 deletion/cache purge or Stream deletion after commit and retries failures. An old edit or status response must not restore removed assets. Provider cleanup failure does not roll back an already committed reference removal; retain cleanup progress and provider identifiers for retry. Use `cleanup_at` to remove selected rows from live attachment membership while retaining provider identifiers; set their positions to NULL so later edits can reuse the slots.

## Authentication

Require sign-in before opening a new-tip or review editor. Preserve the intended local destination through authentication and return the user to that form after successful sign-in. Browsing remains public. Validate the return destination as an allowed local route. The editor rechecks access on entry, and publishing still enforces current eligibility and target state when writing.

TipsWeb owns one `return_to` carrier through sign-in/registration, the emailed magic link, confirmation form and controller redirect. Validate against allowed local routes when accepting and consuming it; a leading slash alone is not validation. The generated GET-session destination is a fallback, not the only carrier: public LiveView vote/report events cannot write Plug session state, and another-browser email confirmation has no original cookie. Carry only the destination, never draft contents or pending mutations. Recheck target access after sign-in and require an explicit vote/report/save/delete action. Use live or ordinary navigation according to actual router/live-session boundaries; editor entry must pass through the authenticated plug.

### First-time signup

Use one signup form with a suggested editable public handle and email, followed by magic-link verification. After verification return to the intended editor. Returning users sign in with email without repeating handle selection.

Preserve both handle and email across validation errors and rerenders; never replace an edited handle with a fresh suggestion. Accounts owns neutral-word/random-suffix suggestions, validation, registration and verification. Suggestions and availability checks reserve nothing; the case-insensitive unique constraint decides availability at registration. A conflict returns field feedback on the same form, preserving email and intended destination.

Do not create a user row merely to suggest or preview a handle. Registration receives both the chosen handle and email; the generated authentication flow must prevent contributions before email verification. Use the generated confirmation/token lifecycle and the user fields specified in the data model; no separate registration table.

An unconfirmed registration expires seven days after its original registration time. Resending a magic link does not extend this deadline. Verification checks both token validity and registration expiry; an expired registration cannot become verified merely because cleanup has not run. Tell late returners to restart signup. Verified accounts are unaffected.

Use an Oban maintenance job to delete expired unconfirmed registrations and their authentication tokens, releasing their handle and email. Both verification and cleanup serialize on the same user row, recheck `confirmed_at` and the immutable `inserted_at + 7 days` deadline against current wall time after any lock wait, then mutate tokens/account state in that transaction. Guarded mutations may acquire the needed row lock implicitly; retain an explicit lock where the multi-step token flow needs it. Verify the whole generated confirmation/cleanup transaction, not an isolated statement. A successfully confirmed account cannot be deleted. Registration must also reclaim an expired unconfirmed row that blocks the requested handle or email, using the same guarded cleanup operation, so the cleanup schedule does not extend a reservation. Old tokens must not authenticate a replacement account. These accounts cannot have contributions because every contribution path, including reports and upload authorization, requires verification. An unexpected foreign-key failure during reclaim is an operational invariant error, not a normal handle conflict or permission to cascade-delete content; preserve the registrant’s input. Distinguish it from the expected race in which confirmation wins.

If registration finds an already registered email, explain that the address is registered and offer Sign in. Follow Phoenix's generated registration feedback rather than introducing a generic response that conceals account existence. Do not overwrite the existing account's handle or email; retain the intended local return destination through sign-in.

The handle is fixed once signup completes. Clearly explain this before the user finishes, including when they keep the autogenerated suggestion. Do not expose a post-signup rename operation or accept handle changes through account-settings input. Account deletion still clears the handle under the existing deletion rules. This follows [Reddit's finalized-username convention](https://support.reddithelp.com/hc/en-us/articles/204579479-Can-I-change-my-username); it does not change Tips' existing decision to release handles after account deletion.

### Sessions and authentication foundation

Browser drafts belong to the signed-in account. If the session expires during composition, preserve the local draft and submission key, require sign-in again, and restore only for the same account. An expired session does not turn publishing into an anonymous operation.

Use Phoenix's `mix phx.gen.auth` generator as the foundation for email magic-link authentication. Adapt its generated code and migrations to the handle, ban, and account-deletion rules. Passwords and OAuth remain excluded.

Use 15-minute magic links, seven-day email-change links, and the recorded **60-day Tips session-token validity**, with seven-day session reissue. Sixty days is an explicit Tips customization, not the pinned generator default and not a fixed maximum continuous sign-in duration. Configure persistent remember-me cookies consistently with the 60-day server validity. Keep generated token formats and recency semantics; session renewal copies `authenticated_at`, while real reauthentication advances it. Verify settings against the pinned generated code.

The data model uses this generated authentication foundation, retaining generated token formats and timestamp names. Configure and test it with the pinned generator. Integrate email delivery and the Turnstile sign-up protection with this foundation.

### Session renewal and logout

Add one indexed server-generated UUID `session_family_id` to session rows in the existing `users_tokens` table. A fresh browser login starts a family; same-account renewal and genuine reauthentication in that browser retain it. No family table, root-token foreign key or second token format is needed. Keep each LiveView’s private session-row reference for admission and use a stable family disconnect topic for immediate UI feedback.

Renewal locks the account first, then revalidates the predecessor session’s context, expiry and current account, and creates its successor from that valid row with the same family. Concurrent successors remain in one family. Logout takes the same account lock, deletes the entire browser family in the transaction, commits, then broadcasts its family topic. A late response/cookie for a deleted successor cannot restore admission, even if disconnect delivery fails. Another browser’s family remains signed in.

An account switch locks old and new accounts in id order, validates the new login proof, revokes the prior browser family and starts a family for the new account. Email change revokes all old session families and starts a fresh family for the confirming browser ([#102](https://github.com/chenghanlee/tips/issues/102)). Account deletion revokes all tokens ([#103](https://github.com/chenghanlee/tips/issues/103)). Prune expired token rows in bounded maintenance batches by context validity; expiration or pruning of the first family token must not revoke valid successors. Reuse the shared Accounts validity definition for controllers, LiveViews, renewal and pruning. Test real cookies, concurrent responses, sudo recency and disconnects; generated code does not supply this adaptation unchanged.

### Authentication email delivery

Deliver sign-in, verification, and email-change messages directly through Swoosh, with a bounded provider timeout and retry feedback on failure. Authentication emails do not use Oban or durable automatic retries. This follows [Swoosh guidance](https://swoosh.hexdocs.pm/Swoosh.html#module-async-emails); direct delivery is the MVP choice.

Accounts owns token creation and the generated notifier flow. Persist required account/token state before requesting delivery, outside the database transaction. Provider acceptance does not guarantee inbox delivery or verify an account/address. A timeout can leave delivery uncertain; do not claim that no message was sent. Allow another request through the normal authentication flow and existing protections. Failed delivery must not create a duplicate account or change the current sign-in email.

Apply the existing app limiter before creating authentication tokens or requesting mail for sign-in, verification resend and email-change requests, including LiveView events. Limit by normalized destination address and trusted client IP, with clear retry feedback; signup Turnstile and HTTP route limits do not cover these events alone. An in-process ETS-backed limiter is sufficient for the single-node MVP. Keep delivery bounded and avoid automatic mail-retry loops.

The limiter has four buckets:

| Bucket | Keyed by | Charged before |
|---|---|---|
| `auth_destination` | Normalized destination address | Token creation or mail for sign-up, sign-in (including reauthentication and verification resend) and email change |
| `auth_ip` | Trusted client IP | The same requests |
| `write` | Account | A new publication, every edit attempt, author deletion, hide, restore, vote and report |
| `upload` | Account | Each upload |

`Tips.AdmissionLimiter` is the contract: denials, capacity classes and no refunds. `config/config.exs` holds the budgets.

One configured total budget bounds each attempt from request to result, including after the requesting process exits; `Tips.Accounts.UserNotifier` documents the outcomes. Sign-in, including reauthentication, gives one neutral answer on the form for an unknown address, a sent link and unconfirmed delivery, so the page does not reveal account existence. Response time still can: unknown addresses return at once, and there is no latency equalization or dummy provider call. Registration and email change report unconfirmed delivery as uncertain with a retry.

### Changing the sign-in email

Allow an account owner to change their email after recent sign-in and verification of the new address. Keep the same user id and fixed handle, so tips, reviews, votes, browser drafts, submission keys, and moderation state remain attached to the same account. Keep the current email active until the new address is confirmed.

Use the generated authentication flow as the foundation, including its recent-authentication check (Phoenix's "sudo mode"). If that check has expired, require another magic-link sign-in through the current address before requesting the change. This is an account-setting operation owned by Accounts, not a Content operation. [Phoenix's authentication design](https://github.com/phoenixframework/phoenix/issues/6041) uses recent authentication for email changes; [Mastodon](https://docs.joinmastodon.org/user/contacts/) also exposes email changes in account settings.

Accounts operations ([#102](https://github.com/chenghanlee/tips/issues/102)), adapting the generated functions rather than building a second authentication system:

| Function | Contract |
|---|---|
| `request_email_change(scope, attrs)` | Check recent authentication and the current undeleted account; validate the new email, create an expiring confirmation token, and request delivery to that address. Return validation, reauthentication, or delivery feedback without changing the login email. |
| `confirm_email_change(scope, token)` | Verify the token belongs to this account and pending email change. In one transaction, check the expected current email and undeleted account, enforce email uniqueness, change the email, and consume the token. Return the committed account state. |

Bind confirmation to the account, original email, and proposed address using the generated token mechanism. A stale link must not undo a later change or restore a deleted account. Recheck uniqueness at confirmation; an earlier availability check cannot reserve the address. Invalidate authentication links tied to the old address when the change commits. Revoke existing session tokens as part of the successful change and issue a fresh session family for the confirming browser through the adapted Phoenix authentication flow. Broadcast revoked family topics after commit; revoked sessions must not retain write access. Failed confirmation leaves existing sessions unchanged. Account state, including bans, does not reset when email changes.

The frontend distinguishes a verification email being requested from the login email actually changing. Failed delivery, expired or invalid links, and a newly occupied address leave the old email active. Report success only after the confirmation transaction commits.

### Lost mailbox access

If the user cannot access the registered mailbox and has no usable recently authenticated session, recovery requires regaining access through their email provider. Otherwise they must create a new Tips account. The MVP provides no manual ownership override or recovery codes. The normal email-change flow remains available when its recent-authentication and new-address verification requirements can still be met.

A replacement account has a new user id. Do not transfer the old account's contributions, release its handle, or clear its moderation state as part of recovery. Losing mailbox access does not delete the old account. This applies [Reddit's requirement for verifiable account ownership](https://support.reddithelp.com/hc/en-us/articles/360046187591-I-m-having-issues-with-email) to Tips' email-only authentication. The sign-in help should explain the mailbox-recovery path directly.

### Full bans and deletion

A full ban blocks publishing, editing, voting (including removal), reporting, and moderation actions. It does not prevent sign-in, reading, deleting the account's own tips or reviews, or deleting the account. Account deletion retains content under the existing deleted-author rules; it is not bulk content deletion.

`Tips.Accounts` owns current account state and account deletion. `Tips.Content` enforces operation-specific permissions when writing: contribution operations reject full bans, while author deletion checks the current account and ownership without rejecting a full ban. A blanket ban check on all authenticated routes would incorrectly block the allowed deletion flows. The frontend hides unavailable contribution controls and keeps author-deletion and account-deletion controls accessible. An editor opened before a ban preserves its text when the backend refuses the save.

This follows [Reddit's policy of blocking edits while retaining author deletion during a ban](https://support.reddithelp.com/hc/en-us/articles/34435967815188-Changelog-February-3-2025). Allowing account deletion is an explicit Tips decision.

### Account-deletion confirmation

Require recent authentication through the generated Phoenix sudo-mode check, followed by an explicit account-deletion confirmation. Reuse the same recent-sign-in foundation as email changes, including for banned users; a ban does not deny deletion. If recent authentication has expired, sign in again by magic link before confirming. This follows [Phoenix’s sensitive-operation mechanism](https://phoenixframework.org/blog/phoenix-1-8-released) and adapts [Reddit’s identity confirmation before account deletion](https://support.reddithelp.com/hc/en-us/articles/204579509-How-do-I-delete-my-account) to Tips’ passwordless login.

Explain before confirmation that deletion ends account access, leaves published tips and reviews under the deleted-author presentation, and cannot be undone. Authors who want their content removed must delete it first. `Accounts.delete_account(scope)` rechecks recent authentication and current account state, clears account identity and revokes authentication tokens in one transaction, then signs the browser out. No automatic deletion follows a reauthentication link; return to the confirmation page. An older session without mailbox access cannot bypass this check; the existing mailbox-recovery policy applies.

## Profile reads

All reading-list URLs carry page and their applicable filters; only browse and normal-review lists offer a sort parameter. Search uses fixed relevance; profiles, inbox and moderation retain their fixed ordering. Remounts fetch that page rather than resetting to the first batch. Preserve useful Back reading position where possible, accept current-ranking drift and show no Back-only refresh notice.

Public profiles default to one newest-first combined contributions list, with `kind=all|tips|reviews` as an optional URL filter. Use `UNION ALL` over the two content types with deterministic `(created_at DESC, kind, id DESC)` ordering, validated offsets and twenty rows plus lookahead. Type participates in row identity because tip and review ids can overlap. The frontend renders kind as a labelled native Contributions select with immediate updates and retained focus. Filter before pagination and reset page when kind changes; All removes the kind predicate. No inactive-tab caches or cursors. Keep nondeleted contributions only; hidden items need current author/moderator admission. Visible reviews of deleted/hidden tips use projected parent labels and links.

## Implementation acceptance

Run the early vertical slices before broad screen expansion: text publication/edit with lost confirmation and browser recovery; one image retained across a known rejection; one private video from reservation through upload, readiness, publication, hide and delete; and magic-link authentication completed in another browser context returning to the intended destination. Run the following integration checks against the implementation.

1. Implement migrations from the canonical data model and run them in extension-enabled development and CI. Test named constraints, author deletion and deliberate hiding, stable media ids and complete lock order, including bulk writes and triggers.
2. Exercise publication retries, whole-edit/no-op version handling and report races, including lost confirmations. Test publication versus ban/unban eligibility and vote eligibility versus hide/delete, including single-review liveness changes against bulk tip-then-review operations. Verify every returned shape masks deletion before hiding and never leaks raw associations or stale search excerpts.
3. Test generated auth admission after revoked tokens even when disconnect broadcasting fails; cover verification versus seven-day cleanup/reclaim and token reuse against replacement accounts.
4. Verify Oban rescue, seven-day pruning and shutdown; retain cleanup identifiers across job pruning. Test async nonoverlapping editor status cycles, provider timeouts/rate limits, late results, NULL-uid expiry versus late persistence, the fixed recovery deadline and attachment-versus-cleanup races. Verify private-at-creation uploads, fresh signed inline-player/thumbnail access, token expiry, visibility changes, fixed provider destinations and no-store responses. Ready rows remain usable during status-provider outages; pending polling never blocks writing. Media signing remains local.

Additional integration checks:

- Race different drafts under one publication key, including a fixed retry, unknown image identities, deleted originals and unique-conflict rollback. Clear only created/equivalent submitted content. Verify exact-item video target equivalence and rejection for another author/item/parent.
- Test both report/delete lock orders, confirmed-reporter enforcement and the full schema’s implicit trigger/FK lock graph. Cross upload/registration deadlines while waiting for locks.
- Test renewal versus logout in both orders, concurrent successors, late cookies, another browser remaining signed in, account switch, sudo recency, email change, token pruning and failed disconnect delivery. Carry the return destination through another-browser confirmation without replaying actions.
- Verify zero lexical hits stay empty under sequential and index plans; pause an embedding scan across retagging; exercise bounded search cancellation, provider queue saturation and total-budget exhaustion.
- Verify expiry progress past fifty uncertain rows, cooldown survival across restart, guarded late results and independent health detection when cron/queues stall. Run the bulk moderation capacity fixture before introducing a background bulk workflow.

Verify context-preserving curated filter links and Clear filters, unfiltered Show all reviews destinations, summary vote/capability hydration, labelled review-body excerpts, consistent own-review action capabilities, and sign-in-to-report without an automatic insert.

Page titles, review-filter presentation and technique-selector guidance are specified in the [frontend design](frontend-design.md#navigation-and-content); their underlying visibility and selection invariants remain in the data model.

## References

- [Phoenix and Ecto](https://hexdocs.pm/phoenix/ecto.html)
- [Ecto transaction guidance](https://hexdocs.pm/ecto/Ecto.Multi.html)
- [Ecto optimistic locking](https://ecto.hexdocs.pm/Ecto.Changeset.html#optimistic_lock/3)
- [Ecto counter-cache example](https://ecto.hexdocs.pm/Ecto.Changeset.html#prepare_changes/2)
- [Phoenix authentication generator](https://hexdocs.pm/phoenix/mix_phx_gen_auth.html)
- [Stream signed playback](https://developers.cloudflare.com/stream/viewing-videos/securing-your-stream/)
- [JOSE JWT signing](https://jose.hexdocs.pm/JOSE.JWT.html#sign/3)
- [Req.Test provider seams](https://req.hexdocs.pm/Req.Test.html)
- [Fowler's architecture pattern catalog](https://martinfowler.com/eaaCatalog/)
