# Chavruta 02: adversarial review of data-model-v3

Date: 2026-09-19
Participants: Claude (Fable 5.1, author of v3) and Codex (reviewer)
Medium: this file. Each partner appends under its own heading. Nobody edits the other's text.

## Brief from the user

Adversarially review `data-model-v3.md` (with `data-model-v3-test.sql` and `data-model-v3-scale.sql` as evidence of what was verified).

1. Focus on correctness and performance. If they conflict, correctness wins.
2. Check industry standards and conventions. Find every invented convention or algorithm. For each one ask: (a) is there an industry standard or convention we can follow instead? (b) if not, is there a better convention than the invented one?
3. Use first principles, Occam's razor, and Pareto 80/20 to derive the simplest working and elegant solution.
4. This is a greenfield MVP looking for product-market fit. It is not enterprise software. Do not review it as enterprise software.

Context the reviewer should know:
- Product: Urban Dictionary for LLM prompting tips. Tips have reviews (one per user per tip), Helpful/Not helpful votes on both, one curated tag per tip, optional model and environment, up to 10 images each.
- Stack: Postgres 18 (timescaledb-ha image for pg_textsearch + pgvector), Cloudflare R2 for images, Qwen3-Embedding-0.6B for vectors.
- Everything except the search SQL was run locally. The search extensions were not available locally, so that SQL is unrun.
- Writing rule: no mannered prose, plain simple English, be direct. The user has ADHD. Short sentences. Lists over paragraphs.

## What Codex should produce

Append a section `## Codex: round 1` with:

1. **Correctness bugs** — ordered by severity. For each: what breaks, a concrete input or sequence that triggers it, and the smallest fix.
2. **Performance risks** — only ones that matter before ~1M rows. Say which query, why, and the fix.
3. **Invented conventions** — a table: invented thing | industry standard that could replace it | recommendation (adopt standard / keep / replace with X).
4. **Cut list** — what a PMF-stage MVP should drop or defer, with the reason. Apply Pareto.
5. **Ranking, independent take** — before you critique v3's choices, brainstorm on your own. Tips use Hot (classic Reddit: `log10(max(|score|,1)) + sign(score) * (created_epoch - 1134028003) / 45000`, votes only, no review weight). Reviews use Best (Wilson lower bound, z=1.2816, votes only). Both are stored generated columns, keyset-paged. Questions: What would you pick for tips and for reviews if you started from scratch for this product? Name real systems that use each candidate (Reddit, HN, Stack Overflow, Steam, Amazon, Yelp, Discourse, Lobsters). Compare candidates on: what signal it uses, what it ignores, gaming resistance, cost to compute and index, whether it needs a background job. Then say whether any candidate beats v3's choice and why. If v3's choice is the right one, say so and stop.
6. **Verdict** — ship as is, ship with fixes, or redesign. One paragraph.

Do not repeat the design back. Do not praise. Every claim about SQL must be checkable: quote the line or the constraint name.

---

## Codex: round 1

References below use `v3` for `data-model-v3.md`, `test` for `data-model-v3-test.sql`, and `scale` for `data-model-v3-scale.sql`. Line numbers refer to the files reviewed.

I ran the fixture and scale scripts on Postgres 18.6 in a separate scratch database. I also ran targeted vote, ban, account deletion, and query-plan checks. Search extensions were unavailable. Search findings below come from the SQL and extension docs, not a successful search run.

### 1. Correctness bugs

**C1. Hidden content leaks through other reads.**

- Evidence: the inbox selects `t.title, r.body` without visibility checks (v3:457–462). Review search checks only the review's markers (v3:485–489). The profile example joins tips for their title; `scale:119–120` checks only review visibility.
- Trigger: publish a review, send its notification, then kill it. The recipient can still read its body in the inbox. Kill a tip with live reviews. Those reviews can still return its id through search and its title through profiles. Filtering the final search fetch avoids disclosure there, but leaves holes in the result page.
- Fix: apply viewer permissions wherever content is read. Mask or omit killed targets in the inbox and profiles. Check parent eligibility inside review search before candidate limits. Keep the chosen policy for reviews on author-deleted tips separate. Gate child reads and writes on permission to access the parent; `references tips(id)` checks existence, not access.

**C2. Upload validation can check different bytes from those published.**

- Evidence: Upload says HEAD, inspect first bytes, then copy from staging (v3:503). `media_key_chk` checks only the key string.
- Trigger: reuse the signed PUT after validation but before copy. Replace the small raster with a different object. The copy publishes bytes that were never checked. R2 permits reuse until expiry. [R2 presigned URLs](https://developers.cloudflare.com/r2/api/s3/presigned-urls/)
- Fix: copy into a private key that the browser cannot overwrite. Validate that exact object before exposing it or inserting its media row. Bind upload keys to the signed-in uploader. Reject failed checks and remove failed copies. An object copy and a database commit are separate operations; allow cleanup when the commit fails.

**C3. Concurrent vote changes corrupt counters. Reproduced.**

- Evidence: `returning ... (select value from votes o ...) as old_value` (v3:354; test:247,275).
- Trigger: session A inserts an upvote and holds its transaction. Session B starts a downvote for the same user and tip. B waits. A commits. B updates A's vote, but its subquery uses the earlier snapshot and sees no old vote. It adds a downvote without removing the upvote. My run stored `(up_count, down_count) = (2,1)`. Live votes were `(1,1)`.
- Fix: use Postgres 18's `RETURNING OLD.value AS old_value, NEW.value AS value`, plus old and new visibility. Compute the delta from the actual changed row. Apply this to review votes too. I checked that `OLD.value` returns the previous value on conflict. Keep the counter update in the same statement. [Postgres INSERT](https://www.postgresql.org/docs/18/sql-insert.html), [Read Committed behavior](https://www.postgresql.org/docs/18/transaction-iso.html)

**C4. The vote ban check fails. Reproduced.**

- Evidence: `values (..., (select case when ban = 'shadow' ... and ban is distinct from 'full'))` (v3:351). Conflict handling updates only `value` (v3:353).
- Trigger: fully ban user 2, then vote on tip 1. The scalar subquery returns no row, which becomes NULL. The outer insert succeeds with a live vote. Deleted accounts also pass this statement. Next, shadow-ban an existing voter and switch their live vote. Its `dead_at` stays NULL and public counts change.
- Fix: use `INSERT ... SELECT` from an eligible user, as publishing already does. Define shadow-ban behavior for existing votes. The smallest rule is to leave existing live votes unchanged while shadow-banned, and make new votes dead. If changes must appear successful, handle old and new visibility explicitly in the counter delta. Apply the shared account check to edit and unvote handlers too.

**C5. Review counts depend on commands, not state changes.**

- Evidence: kill and unkill are unconditional `update reviews set dead_at ... where id = $1` (v3:404–405). The next paragraph says subtract or add 1. Author delete separately decrements the parent (v3:388–389).
- Trigger: kill the same live review twice. Both updates match and the prescribed decrement runs twice. Delete a review, then kill and unkill it. A deleted review must never count as live. A crash between the review update and parent update also leaves drift unless both share a transaction.
- Fix: use the difference between old and new live status: `deleted_at IS NULL AND dead_at IS NULL`. Update the parent only by that difference, in the same transaction. No matched row means no follow-up delete, notification change, or R2 action. Use the same rule for deletion, kill, and unkill. A recount is a repair tool, not normal correctness.
- Related: publishing starts dead tips and reviews at `up_count = 1` while their self-vote is dead (v3:317–321,332–336). Unkill exposes that uncounted vote as a score. Start dead rows at zero, or explicitly revive the vote and recount when restoring the row.

**C6. Hot is not the classic Reddit formula.**

- Evidence: `log(greatest(abs(up_count - down_count), 1)) + sign(up_count - down_count) * ...` (v3:71–72).
- Trigger: hold creation time fixed. Change net score from -1 to -10. Hot rises by 1. More downvotes improve the rank. At net score zero, all age information disappears. Between negative-score tips, older tips gain an advantage.
- Fix: use `sign(score) * log10(max(abs(score), 1)) + time_term`. In this generated expression, repeat `up_count - down_count`. The sign multiplies the log, not the time. Add cases for positive, zero, and negative scores. The fixture checks only positive-score age order. [Archived Reddit implementation](https://raw.githubusercontent.com/reddit-archive/reddit/master/r2/r2/lib/db/_sorts.pyx)

**C7. Another user can block account deletion. Reproduced.**

- Evidence: `handle = 'deleted-' || id, email = 'deleted-' || id || '@invalid'` (v3:428), with `users_handle_unique` and `users_email_unique`.
- Trigger: register `deleted-2`, then delete account 2. The update fails on `users_handle_unique`. The placeholder email is also allowed by `users_email_chk` and can collide.
- Fix: allow NULL handle and email only on deleted accounts. Clear both on deletion. Keep live-account validation and uniqueness. Render `[deleted]` from account state; browse and review projections currently return only `u.handle` (v3:262,291–292). Revoke sessions through the selected auth library.

**C8. An embedding job can undo edit invalidation.**

- Evidence: edit writes `embedding = null` (v3:376). The worker reads missing vectors, calls a server, then writes them back (v3:473). No conditional write is specified.
- Trigger: the worker reads body A. The author changes it to B. The worker then saves A's vector. The row is no longer NULL, so B is never embedded.
- Fix: save only if the embedded input still matches the input read. An input hash or a comparison against the captured text is enough. If it changed, discard the result and retry later. Check the configured model before accepting a result too. Do not hold a database transaction open during inference.

**C9. Search adds review volume to relevance.**

- Evidence: each review contributes `1.0 / (60 + rank)` and the final query uses `group by tip_id` with `sum(s)` (v3:491–496).
- Trigger: tip A has one review at rank 1. Tip B has ten reviews at ranks 2–11. In that branch, A gets about 0.0164; B gets about 0.151. B wins through repetition. Fifty candidate reviews can also all belong to one tip.
- Fix: produce a list of distinct tips per retriever, using each tip's best matching review. Rank those tips, then fuse. The candidate budget must be defined in distinct tips if 20 results are expected. Ordinary RRF gives one contribution per document per retriever. This parent grouping is an extra algorithm. [RRF definition](https://www.elastic.co/docs/reference/elasticsearch/rest-apis/reciprocal-rank-fusion)

**C10. Search can choose the wrong snippet and lose result order.**

- Evidence: `(array_agg(review_id order by s desc) filter (...))[1]` (v3:495). The app then runs browse queries on the ids (v3:499); browse orders by `t.hot_score` (v3:265).
- Trigger: review A ranks first in one branch. Review B ranks second in both. B has the larger combined score, but A supplies the snippet. A review snippet is also chosen whenever any review matched, even if the tip was the best hit. Reusing browse's ordering then replaces relevance order with Hot.
- Fix: combine contributions per review before choosing a snippet, and compare it with the tip hit if that is the intended display rule. Fetch results in the fused order, with a final id tie-break. Do not reuse browse's sort.

**C11. Hot and Best page queries omit their cursor values.**

- Evidence: browse selects `t.score` but not `t.hot_score` (v3:262). Reviews select counters but not `r.best_score` (v3:291–293). Their next-page predicates require those stored ranks.
- Trigger: fetch the first page and try to create the documented cursor from the returned row. The required value is absent.
- Fix: select the actual rank alongside the id. Preserve its precision in the cursor. Do not recompute it from counters in application code. The scale script gets cursors through extra queries (`scale:59,79`), which hides this omission.

**C12. Notification counts do not count people.**

- Evidence: `count = notifications.count + 1` (v3:451), displayed as “N people” (v3:467).
- Trigger: one user upvotes, removes the vote, and upvotes again. The unread count becomes 2 for one person. Repeated switches repeat the problem even when no-op requests are skipped.
- Fix: for the MVP, drop the number and say the tip received helpful votes. Fold the row by updating its timestamp. Keep the count only if there is a clear event-count meaning or per-actor accounting. Do not add an event ledger just to support this sentence.

**C13. The test script has a separate dead-vote bug and weak assertions.**

- Evidence: `unvote_tip` returns only `value` and always decrements (test:251–254). The design's unvote correctly includes `dead_at` (v3:362–365).
- Trigger: remove user 4's dead vote on tip 3. I reproduced the test version reducing `up_count` from 1 to 0 even though that vote never contributed.
- Fix: test the actual intended statement. Turn expected values into assertions that fail the run. `\echo 'expect ...'` does not assert anything. Expected constraint failures should check the constraint name. The kill/unkill test only checks timestamps (test:383–385), and the final recount cannot detect drift that an unkill already canceled.

**C14. A recount can overwrite a concurrent vote.**

- Evidence: repair aggregates votes, then assigns absolute counts with `set up_count = coalesce(v.up, 0)` (v3:560–566).
- Trigger: a vote transaction holds a tip row lock. The recount starts and reads votes before that transaction commits. It waits for the tip, then assigns its older totals after the vote commits.
- Fix: run this manual repair while writes are paused, or lock the affected parent rows first and take a fresh snapshot for the aggregate. Extend repair to reviews if it is meant to repair both kinds of vote counts. The current statement updates only `tips`.

**Search execution remains an open check.** The query passes `(select text from q)` to `<@>` (v3:479,485). Current pg_textsearch docs require explicit index context for prepared or dynamic query text. Use `to_bm25query($1, 'tips_bm25')` and the review equivalent. Pin the extension version and run this exact prepared query, including its keyword-only fallback. I have not verified it on the target image. [pg_textsearch query requirements](https://github.com/timescale/pg_textsearch#explicit-queries)

### 2. Performance risks

**P1. The actual review page cannot use its ranking indexes. Reproduced at 200k reviews.**

- Query: `where r.tip_id = $1 and r.dead_at is null` (v3:297).
- Why: `reviews_best` and `reviews_new` require `deleted_at is null and dead_at is null` (v3:208–209). The page deliberately includes deleted placeholders. Its predicate does not imply the index predicate. [Postgres partial indexes](https://www.postgresql.org/docs/18/indexes-partial.html)
- Evidence: with the actual visibility rule and no model/environment filter, my scratch run scanned about 200k reviews and sorted. It used 3,167 shared buffers and took 12.1 ms. Adding the missing deletion filter used `reviews_best`, 126 buffers, and 0.077 ms. These are laptop measurements, not capacity estimates. The scale query already adds that filter (`scale:76`), so it measures different behavior.
- Fix: preserve the requested placeholders. Change the two ranking index predicates to `dead_at is null`. Benchmark the page query as shipped.

**P2. Rare browse filters can scan most of the feed.**

- Query: Hot plus `tag_id`, `model_id`, or `environment_id` (v3:271).
- Why: `tips_hot` indexes only rank and id. A nearly uniform eight-tag fixture does not cover a rare model, an old model, or a filter combination with no matches. The scan may walk every eligible tip to return an empty page.
- Fix: test a rare and a zero-result filter. Add a composite filter/rank index for the common slow filter after measuring it. Do not create indexes for every combination. Keep separate first-page and next-page statements.

**P3. Filtered vector search needs a recall and latency test.**

- Query: vector branches use `limit 50` with live-row predicates (v3:481–489). Both HNSW indexes include all rows (v3:219–220).
- Why: pgvector applies filters after approximate candidate retrieval. Its default HNSW search size is 40. Hidden rows and rare filters can leave far fewer candidates than requested. A LIMIT is not a guarantee of 50 surviving hits. [pgvector filtering](https://github.com/pgvector/pgvector#filtering)
- Fix: begin with exact vector search on a small corpus. When adding HNSW, test live partial indexes, iterative scans, and a search size suited to the candidate limit. Compare result recall with exact search. Do not infer search performance from the non-search scale script.

**P4. Polling for missing embeddings can scan the whole corpus repeatedly.**

- Query: the worker finds `embedding is null` (v3:473). No queue index supports that lookup.
- Why: when almost every row is done, a poll can inspect all rows to find a few pending ones. Large batches also make one failed request delay later work.
- Fix: fetch bounded batches. Add a small partial id index for pending, eligible rows on each table. Back off on service failure. Keep one worker until measured throughput requires more.

The scale script uses short bodies, no vectors, and no concurrent writers. It also loads counters independently of votes (`scale:13,21,33–36`). It establishes some read plans. It does not establish production row size, search cost, or counter correctness under load. Keep one focused concurrent-writer check; do not turn this into an enterprise load-testing project.

### 3. Invented conventions

An established technique does not make every parameter or product policy a standard.

| Invented thing | Industry standard that could replace it | Recommendation |
|---|---|---|
| Hot sign placement, v3:71–72 | Archived Reddit Hot. | Adopt the source formula. See C6. |
| Vote delta from a separate SELECT, v3:354 | Postgres 18 `RETURNING OLD/NEW`. | Adopt it. See C3. |
| Wilson with z=1.2816, v3:103–112 | Archived Reddit Best uses this value. | Keep. No new algorithm here. |
| Counts changed by kill/unkill commands, v3:404–421 | Transactional deltas from old and new state. | Replace with state transitions. |
| Review contributions summed into parent RRF, v3:493–496 | RRF over the same document identity in each list. | Replace with distinct-tip retrieval lists. |
| Snippet picked by the largest single branch contribution, v3:495 | Rank each candidate document before selecting its snippet. | Replace. See C10. |
| NULL-vector retry queue, v3:473 | Polling plus conditional writes. | Keep the small loop. Add stale-result protection and bounded batches. |
| “Just switch to 4B,” v3:473 | A versioned embedding configuration. | Defer. Changing the model also requires compatible dimensions, query embeddings, and rejection of old worker results. |
| Query embeddings without a stated input format, v3:477 | The embedding model's published retrieval recipe. | Adopt Qwen's query instruction format; keep document inputs consistent. [Qwen model card](https://huggingface.co/Qwen/Qwen3-Embedding-0.6B) |
| Folding events but displaying distinct people, v3:451,467 | Separate event and actor semantics. | Replace the wording and drop the count for MVP. |
| Rewriting `created_at` on notification folds, v3:451 | Separate creation and activity timestamps. | Rename it to `updated_at` or `last_event_at` if it means latest activity. No need for both yet. |
| Synthetic deleted handles/emails, v3:428 | Nullable removed identity fields with live-row checks. | Replace. See C7. |
| Custom email regex, `users_email_chk` | The chosen auth library's validation and email verification. | Keep only coarse database checks. Align normalization with auth. The regex is not email verification. |
| Base36 id plus regenerated slug | Reddit-style encoded ids and id-based routing are established. | Keep if wanted. Decimal ids are simpler. Neither is an access check. |
| `epoch_of` declared immutable, v3:32–33 | An immutable expression for a time-zone-independent epoch. | Keep if retaining Hot. This specific epoch extraction does not need a job. Do not generalize the wrapper to time-zone-sensitive extraction. |
| Text domains for three small lists, v3:26–28 | Domains, enums, and CHECK constraints are all established. | Keep. Changing this does not solve a current problem. |
| Two parent FKs with `num_nonnulls(...) = 1` | Exclusive parent references with real foreign keys. | Keep `votes_one_target`, `media_one_parent`, and `flags_one_target`. Do not replace them with unchecked type/id pairs. |
| Ten numbered media slots | A bounded ordered set using CHECK and UNIQUE. | Keep `media_position_chk`, `media_tip_slot`, and `media_review_slot`. The limit is a product choice. |
| UUID-looking object-key regex, `media_key_chk` | Server-generated UUIDs and controlled object keys. | Keep as a shape check only. It accepts strings that are not valid UUIDs and proves no ownership. |
| NULL means unknown; unknown reviews survive setup filters, v3:298–299 | No universal product convention. | Keep only with clear UI wording: selected setup plus unspecified setup. Do not claim unknown means compatible. |
| Two-hour editing, one tag, self-upvotes, tombstones | Product policies borrowed from different systems. | Keep the user's decisions. They are not database standards. Apply them consistently. |
| `reviews_one_per_user` excludes deleted rows | Unconditional uniqueness for one lifetime review; partial uniqueness for one active review. | State “one undeleted review.” If lifetime uniqueness was intended, remove the predicate. |
| Author-only/moderator-only dead visibility | HN has a public `showdead` option. | Keep the stricter product policy, but stop calling it an exact copy of HN. [HN FAQ](https://news.ycombinator.com/newsfaq.html) |
| Anonymous flags despite “account to write,” v3:162 | Either authenticated reporting or an explicit exception. | Require login for MVP, or document the exception. |
| Future notification types in `data jsonb`, v3:182 | Add fields when a real event needs them. | Drop for now. |

### 4. Cut list

- Drop the rule that every write must be one SQL statement. One short transaction is enough. Use a CTE where it removes a real race; do not make statement count the design goal.
- Drop numerical vote-notification counts. A folded “received helpful votes” message needs less state and avoids C12.
- Drop the unused notification `data` payload. Three known types do not need a future schema yet.
- Defer embedding-model migration machinery. Pin one model, dimension, and input recipe. Keep only the stale-worker check needed for current edits.
- Defer HNSW until exact vector search is too slow on real data. Hybrid search is an explicit user decision, so keep it. Do not treat an approximate index as required on day one.
- Drop the justification “leaves room for replies later” for deleted review placeholders. Keep placeholders because the user chose them. Do not add reply structure now.
- Defer extra ranking methods, voter reputation weights, review-count boosts, and model-specific vote scores. There is no data here to calibrate them.
- Do not add queues, event ledgers, or counter services to fix this review. Conditional writes, correct deltas, and a few real assertions cover most of the failures.

### 5. Ranking, independent take

Start with the jobs these lists must do:

- Tips: expose useful new techniques. Old advice can become stale as models change.
- Reviews: expose useful evidence, including negative results. Agreement with the tip is not the ranking signal.
- Early traffic means few independent votes. A score must not pretend that one vote proves quality.
- No vote formula can tell whether accounts are independent. Rate limits and moderation still matter.

These are candidates, not claims about any site's full current ranking system. Compute costs below are my assessment of implementing the stated formula here.

| Candidate and real use | Signal used | What it ignores | Gaming resistance | Compute, index, background job |
|---|---|---|---|---|
| New. [Reddit New listings](https://www.reddit.com/dev/api/#GET_new). | Creation time. | All helpfulness evidence. | No vote manipulation, but posting floods win. | One timestamp index. No job. |
| Net score. [Stack Exchange answer sorts](https://api.stackexchange.com/docs/answers). | Upvotes minus downvotes. | Age and uncertainty. 100 up / 90 down beats 9 up / 0 down. | Extra accounts add score directly. Old winners gain more exposure. | Constant work per vote. Stored value and B-tree. No job. |
| [Classic Reddit Hot](https://raw.githubusercontent.com/reddit-archive/reddit/master/r2/r2/lib/db/_sorts.pyx). | Signed log of net votes plus creation time. | Helpful ratio, uncertainty, and model compatibility. | Log compresses large scores. It does not stop coordinated votes or reposts. | Constant work per vote. Stored value and B-tree. No job. |
| [HN-style gravity](https://news.ycombinator.com/newsfaq.html). | Points divided by a power of age. HN also uses moderation and abuse signals. | A bare formula misses those extra signals. Story ranking has no downvotes. | Bare gravity is still vulnerable to coordinated votes. | Age changes relative order without a new vote. Compute and sort candidates at read time, or refresh stored ranks with a job. More work here. |
| Wilson lower bound. [Archived Reddit Best](https://raw.githubusercontent.com/reddit-archive/reddit/master/r2/r2/lib/db/_sorts.pyx). | Helpful fraction and sample size. | Age, voter independence, and whether the review matches the reader's setup. | Discounts tiny samples. Does not stop coordinated accounts. | Constant work per vote. Stored value and B-tree. No job. |


From scratch, I would pick classic Reddit Hot plus New for tips. Search serves old tips with lasting value. I would pick Wilson plus New for reviews. Helpful votes should reward useful evidence, even when that evidence says the tip failed. Review volume should not boost Hot: a dispute can produce many reviews.

Now compare with v3. Its intended choices stand. Its Hot equation does not: the sign belongs on the log term, as C6 shows. Wilson's z=1.2816 matches archived Reddit; it is not a new confidence rule. Keep it. At low vote volume, Hot will mostly follow New. That is acceptable for launch. No candidate above offers enough benefit to add another ranking system or refresh job.

### 6. Verdict

**Ship with fixes.** Fix visibility, upload validation, vote deltas, ban handling, lifecycle counts, account deletion, and stale embedding writes before launch. Correct Hot and make the review indexes match the actual page. Run the exact search query on the pinned target image, then test its ranking with a few hand-checked examples. The table structure does not need a redesign. The failures are in state transitions, query contracts, and claims that the current scripts do not verify.

## Claude: round 1

I re-read every cited line and re-ran the claims marked "reproduced" on my own `tips_v3` database. Verdict per item below. **Accept** means the facts or my own run support it. **Reject** means they do not. **User's call** means it is a product choice, not a correctness fact.

### Correctness

| # | Verdict | Evidence and the smallest fix |
|---|---|---|
| C1 inbox and search leak dead content | **Accept, smaller fix** | Inbox selects `r.body` with no marker check. Fix: `case when r.deleted_at is null and r.dead_at is null then r.body end`. Search review branches: add `join tips t on t.id = r.tip_id and t.deleted_at is null and t.dead_at is null`. Profile pages: same marker filter on the joined parent. No permission layer. Three predicates. |
| C2 upload validate-then-copy race | **Accept, smaller fix** | A presigned PUT is reusable until expiry, so bytes can change after the check. Fix: copy first, then validate the copy under `media/`. The browser cannot write that key. Nothing else from Codex's list (private buckets, uploader binding) is needed for MVP. |
| C3 concurrent vote switch corrupts counters | **Accept. Reproduced.** | Two overlapping sessions, same user, same tip: counters ended `(2,1)`, live votes were one up and one down. Cause: the `old_value` subquery in `returning` reads the statement snapshot, not the row the upsert just updated. Fix, verified on 18.6: `returning old.value as old_value, new.value as value, new.dead_at`. Same for review votes. |
| C4 full-ban vote check is a no-op | **Accept.** | `(select ... where id = $1 and ban is distinct from 'full')` returns no row, so `dead_at` is NULL and the vote is live. Verified. Fix: `insert ... select $2, $3, case when u.ban = 'shadow' then now() end from users u where u.id = $1 and u.deleted_at is null and u.ban is distinct from 'full'`, same shape as publish. Existing live votes of a later shadow-banned user: leave them. Do not touch on switch. |
| C5 kill/unkill counters are not idempotent | **Accept.** | Kill is `where id = $1` with no state guard, and the app subtracts 1 per call. Fix: `update reviews set dead_at = now() where id = $1 and dead_at is null returning tip_id, deleted_at`, and change `review_count` only when a row came back and `deleted_at` is null. Same for unkill and for author delete. Also: born-dead rows start at `up_count = 1` with a dead self-vote. Fix: `up_count = case when u.ban = 'shadow' then 0 else 1 end`. Unkill leaves the dead self-vote dead. |
| C6 Hot sign is on the wrong term | **Accept. Reproduced.** | Same `created_at`, current formula: score -10 ranks above score -1, and score 0 loses all age. Reddit's source is `sign * log10(max(abs(s),1)) + seconds / 45000`. Fix: `sign(up_count - down_count) * log(greatest(abs(up_count - down_count), 1)) + (epoch_of(created_at) - 1134028003) / 45000`. Verified it gives the expected order. Fixture test to add: negative score and zero score ordering. |
| C7 deleted-account handle collision | **Accept.** | `users_handle_chk` allows `deleted-2`. Fix: make `handle` and `email` nullable with `check ((deleted_at is null) = (handle is not null and email is not null))`. Deletion sets both NULL. Reads use `coalesce(u.handle, '[deleted]')`. |
| C8 embedding worker overwrites a newer edit | **Accept.** | Fix: worker reads `id, edited_at, text`, writes `update ... set embedding = $2 where id = $1 and embedding is null and edited_at is not distinct from $3`. One predicate. No hash. |
| C9 RRF sums review hits per tip | **Accept.** | Ten weak review matches beat one strong tip match. Fix: in `reviews_bm25` and `reviews_vec`, keep the best review per tip with `distinct on (tip_id)` before ranking, then re-rank with `row_number()`. Each retriever then contributes one score per tip, which is standard RRF. |
| C10 result order lost, snippet choice | **Accept the order part. Reject the snippet part.** | The doc says the app reruns browse on the ids, and browse orders by Hot. Fix: `order by array_position($1::bigint[], t.id)`. Snippet: after C9 each tip has at most one review per branch, so "largest single contribution" and "combined score" pick the same review in most cases. Not worth more SQL. |
| C11 cursor values not selected | **Accept.** | Add `t.hot_score` and `r.best_score` to the page selects. Cosmetic in the doc, real in the app. |
| C12 notification count counts events | **User's call.** | Fact: up, remove, up again gives count 2 for one person. Options: (a) keep the number, change the wording to "N helpful votes", accept the toggle inflation as a vanity number; (b) drop the number, say "Your tip got helpful votes". Both are one line. I lean (a): the toggle case is rare and the number is the small satisfaction the user asked for. |
| C13 test script unvote decrements dead votes | **Accept the bug. Reject the rest.** | The prepared statement in the test lacks `and v.dead_at is null`, which the doc has. Fix the test. Turning `\echo expect` into hard assertions is not needed for a hand-run MVP script. |
| C14 recount can overwrite a concurrent vote | **Accept as a one-line note.** | It is a hand-run repair. Note: run it when writes are quiet. Extend it to reviews' counters. No locking design. |
| `<@>` needs `to_bm25query` | **Cannot verify.** | Stays in Open until the query runs on the Docker image. |

### Performance

| # | Verdict | Note |
|---|---|---|
| P1 review page cannot use `reviews_best` | **Accept.** | The page keeps deleted placeholders (`where r.dead_at is null`), the index requires `deleted_at is null` too. My scale run used the wrong predicate. Fix: both review ranking indexes become `where dead_at is null`. Deleted rows are rare, the index barely grows. |
| P2 rare filters scan the Hot index | **Accept the fact, defer the fix.** | A zero-result model filter walks the whole index. At 20k tips that is milliseconds. Add a composite index only after measuring on real data. |
| P3 HNSW post-filtering drops candidates | **Accept, and it simplifies.** | Drop the two HNSW indexes from v1. Exact cosine over a few thousand rows is fast. Add HNSW when a measured query is slow. One less thing. |
| P4 embedding poll scans the table | **Accept.** | `create index tips_needs_embedding on tips (id) where embedding is null and deleted_at is null and dead_at is null`, same on reviews. Batches of 50. |

### Conventions table

Accept: Hot fix, `returning old/new`, state-transition deltas, per-tip RRF, Qwen query instruction format (model card says queries use `Instruct: ...\nQuery: ...`, documents do not), drop `data jsonb` (no type needs it), require login for flags (`user_id` becomes `not null`), say "one undeleted review per user" in the doc.

Reject:
- Rename `created_at` on notifications. It means "moved to the top" and the index sorts by it. A rename buys nothing.
- "Not an exact copy of HN" because HN has showdead. The doc borrows HN's two markers, not its visibility UI. Wording only.
- Email regex concern. It is a coarse shape check and says so.
- "Just switch to 4B needs a versioned config." Qwen3-Embedding-4B supports Matryoshka truncation to 1024 dims, so the column stays. The only real requirement is C8's conditional write, which also rejects stale results from the old model. Keep the sentence, add "at 1024 dims".

### Cut list

- "Every write is one SQL statement" is not a rule in the doc. The doc says "one statement" where a statement was enough. No change.
- Drop `data jsonb`: accept.
- Drop HNSW for v1: accept (P3).
- Drop the notification number: user's call (C12).
- Everything else on the list was already out of scope.

### Ranking

Codex's independent pick matches v3: Hot plus New for tips, Wilson plus New for reviews. The one defect was the sign placement, fixed above. No new algorithm.

### Questions for Codex, round 2

1. C4 fix: `insert ... select ... from users where ...` returns zero rows for a banned or deleted user, and the counter update then does nothing. Any hole left?
2. C5: with the guarded kill and `up_count = 0` for born-dead rows, is there still a path where `review_count` or `up_count` drifts without a crash mid-transaction?
3. C9: with `distinct on (tip_id)` inside the review branches, the `limit 50` now counts distinct tips. Any ranking problem left?
4. Dropping HNSW for v1: exact `<=>` over every live row. At what row count does this stop being fine on a 2-vCPU VPS? Give a number with reasoning, not a benchmark demand.
5. Is there anything in the accepted fixes that you think is wrong or bigger than needed?

Append under `## Codex: round 2`. Short. Only disagreements and answers.

## Codex: round 2

### 1. C4: remaining vote holes

`INSERT ... SELECT` fixes the full-ban and deleted-account bug. Keep the `OLD.value` fix too.

“Leave existing live votes unchanged” must cover both switching and removal. The original conflict branch updates `value`; the unvote statement deletes any matching vote. Guard both for shadow-banned users. Otherwise they can still change public counts. The eligibility SELECT alone does not enforce this policy.

### 2. C5: remaining counter drift

No additional drift path in those lifecycle transitions if all these rules hold:

- Kill requires `dead_at IS NULL`. Unkill requires `dead_at IS NOT NULL`.
- Only an affected, undeleted review changes `review_count`.
- Author delete decrements only an affected review whose `dead_at` was NULL.
- Each review change and parent delta commit in one transaction.
- Dead self-votes start with zero contribution and stay dead on unkill.

A crash cannot partially commit a transaction. It rolls back. The problem was separate commits, not a crash inside one transaction. Concurrent vote drift still needs C3. Recount still needs writes paused.

### 3. C9: distinct tips and snippets

The volume boost is fixed if the order is: filter eligible rows, choose each tip's best review, rank the distinct tips, then `LIMIT 50`. A limit inside the input to `DISTINCT ON` would retain the old short-page problem. Use relevance to choose the review, with id as a tie-break; `DISTINCT ON (tip_id)` alone does not select the best one.

I withdraw my combined-score snippet counterexample after this change. With one review per tip per branch, that example no longer applies. Keep the simpler snippet choice. Change the promise to “show the best matching review when one exists.” The current expression does not check whether the tip itself was the best hit.

Keep the parent visibility checks and preserve fused order when fetching rows. No further ranking change needed.

### 4. Exact vector search: a planning number

**Use 50,000 live, embedded rows across tips and reviews combined as the point to plan for HNSW.** This is an engineering estimate, not a measured limit. Assume warm memory, low search concurrency, and inference running elsewhere.

A 1024-dimensional vector takes 4,104 bytes. At 50k rows, each full search examines about 205 MB of vector data and 51 million dimensions, before row access and sorting. At 100k, those amounts double. Concurrent searches multiply the work. [pgvector storage format](https://github.com/pgvector/pgvector#vector-type)

A few thousand rows are a reasonable exact-search MVP. I would not budget for 100k-plus exact searches on two shared vCPUs while also running inference there. The 50k number becomes too optimistic if the same machine hosts Qwen. Dropping HNSW for launch still stands.

### 5. Other disagreements and corrections

- **C1: the proposed profile fix breaks a chosen rule.** Filtering joined tips with `t.deleted_at IS NULL` removes reviews on author-deleted tips. v3 explicitly keeps those reviews on profiles. Preserve them. Handle killed parents separately. The inbox fix also needs to protect `t.title`, not only `r.body`. Shared predicates are enough; I did not mean a new permission service.
- **C2: copy-first is enough only if the copy stays inaccessible until validation.** v3 exposes `media/{uuid}` through a public URL. Copying unchecked bytes straight there creates a public window, even without a database row. Use a private immutable copy or gate reads until validation. No new bucket is required if the existing setup can do that.
- **C7: the proposed CHECK is too weak.** `(deleted_at IS NULL) = (handle IS NOT NULL AND email IS NOT NULL)` allows a deleted row with NULL handle and a retained email. I checked that expression in Postgres. Require each field's non-NULL state to equal `deleted_at IS NULL`, using two checks.
- **C8: the edit predicate does not reject old-model results.** Start an old-model request, clear embeddings for migration, then let it return. `embedding IS NULL` and unchanged `edited_at` both pass. Equal dimensions do not make the two models' vectors compatible. Smallest fix: stop and drain the old worker before resetting vectors and switching both document and query embedding models. No versioning system needed.
- **C14: “quiet” is insufficient.** One overlapping vote is enough. Say “pause writes and let active write transactions finish before recounting.” This is still a one-line operating note.
- **C13: keep a few hard assertions.** Counter totals, rejected banned writes, and repeated kill/delete behavior should fail loudly. No framework needed. Printed expectations already missed failures here.
- **C12: event-count wording is a product choice.** “Received N helpful votes” is acceptable if explicitly treated as events, not unique people or current live votes. I still prefer no number.
- I withdraw “every write must be one statement” as a claimed rule. It was my inference. I will not block on the notification timestamp name, the HN wording, or the coarse email check.

## Claude: round 2

Checked each pushback against the doc. Verdicts:

| Item | Verdict | Resolution |
|---|---|---|
| 1. Shadow-banned user switching an old live vote | **Accept for switch. Reject for removal.** | Switch: `do update set value = excluded.value, dead_at = coalesce(votes.dead_at, excluded.dead_at)` and the delta uses old and new visibility: `up_count + (new.dead_at is null and new.value = 1)::int - (old.dead_at is null and old.value = 1)::int`. Same for down. One statement, no extra query. Removal: a shadow-banned user deleting their own old live vote subtracts one honest vote. That is not gaming. No guard. |
| 2. C5 rules | **Agree.** | The five rules go into the doc as written. |
| 3. C9 dedupe before limit | **Reject the full-scan order. Keep index use.** | `distinct on (tip_id)` over every eligible review means scoring every review, so the BM25 and HNSW indexes cannot serve a top-k. Elasticsearch `collapse` does top-N first, then collapses. Same here: each review branch takes 200 candidates by the index, then `distinct on (tip_id) order by tip_id, rank`, then re-ranks. A short page is possible only when 200 review hits cover fewer than 50 tips. Fine for MVP. Snippet promise becomes "the best matching review, when one matched". |
| 4. 50k rows for exact search | **Accept as a planning number.** | Goes in Open: "add HNSW at about 50k embedded rows, earlier if inference shares the box". |
| 5. C1 profile keeps reviews on deleted tips | **Accept, Codex is right.** | Doc rule 2 keeps deleted tips' pages and reviews. Parent filter in search and profile is `t.dead_at is null` only. Inbox: simpler than masking columns. A moderator kill deletes the row's notifications, the same as an author delete already does. Then the inbox has no dead content to mask. One statement in the kill transaction. |
| 5. C2 public window | **Accept, smaller fix.** | The doc does not say `media/` is public, but it will be served, so treat it as public. Fix: HEAD staging to get the ETag, check size, type, and first bytes, then copy with `x-amz-copy-source-if-match: <etag>`. A replaced object fails the copy. No private copy, no read gate. Open item: confirm R2 honors that header. |
| 5. C7 two checks | **Accept.** | `check ((deleted_at is null) = (handle is not null))` and the same for email. |
| 5. C8 old-model results after a reset | **Accept as an operating note.** | "Stop the worker, reset embeddings, switch the model in the worker and the query path, start the worker." No versioning. |
| 5. C14 wording | **Accept.** | "Pause writes and let open write transactions finish before a recount." |
| 5. C13 hard assertions | **Accept, small.** | Counter totals after the behavior tests and the recount go in a `do $$ ... raise exception ... $$` block. Constraint tests keep `\echo`. |
| 5. C12 | **User's call.** | Both options recorded. |

### Consensus list for the v3 doc

Correctness: C1 (parent `dead_at` filter in search and profile; kill deletes notifications), C2 (copy with if-match), C3 (`returning old/new`), C4 (`insert ... select` from an eligible user; visibility-aware delta), C5 (guarded kill, unkill, delete; born-dead rows start at zero), C6 (Hot sign on the log), C7 (nullable handle and email, two checks), C8 (conditional write on `edited_at`; drain-before-reset note), C9 (200 candidates then `distinct on (tip_id)` per review branch), C10 (`array_position` order), C11 (select the cursor columns), C13 (test unvote statement; one assertion block), C14 (note).

Performance: P1 (review ranking indexes on `dead_at is null` only), P3 (no HNSW in v1; add at about 50k rows), P4 (partial index for `embedding is null`). P2 deferred.

Conventions: Qwen query instruction prefix, drop `data jsonb`, flags require login, "one undeleted review per user" wording.

Open for the user: C12 notification number.

Codex: reply under `## Codex: round 3` with either "Agreed" or the remaining objections, five lines at most.

## Codex: round 3

- Vote delta: on insert, `old.value` is NULL, so your Boolean subtraction makes the counter NULL. Verified in Postgres. Use `coalesce((old.dead_at is null and old.value = 1)::int, 0)`, likewise for downvotes.
- Inbox: deleting notifications on kill does not stop a concurrent action inserting one afterward. Keep visibility checks on inbox reads, including the parent tip.
- Upload: bind the validation GET and CopyObject to the same ETag. Otherwise validation can inspect different bytes. R2 documents support for both conditions: [R2 compatibility](https://developers.cloudflare.com/r2/api/s3/api/).

## Claude: round 3 (close)

- Vote delta NULL on insert: **Accept, verified.** `(old.value = 1 and old.dead_at is null)::int` is NULL when `old.value` is NULL. Fix: `((old.value = 1 and old.dead_at is null) is true)::int`. Same for down. Checked: gives 0 on insert, 1 for a live up vote.
- Inbox: **Accept masking on read, drop delete-on-kill.** One rule is enough and masking is complete. `case when t.dead_at is null or t.user_id = n.user_id then t.title end`, same shape for `r.body`. Kill does not touch notifications.
- Upload: **Accept.** The range GET and the CopyObject both send `If-Match` with the HEAD ETag.

Consensus reached. The list in "Claude: round 2" plus these three lines is the change set for `data-model-v3.md`. Open for the user: C12, the notification number.

## Brief, round 2

All round 1 fixes are applied to `data-model-v3.md`, `data-model-v3-test.sql`, and `data-model-v3-scale.sql`. Both scripts pass. The user decided C12: keep the number, defined as an event count. The round 2 brief is in `review-brief-v3-r2.md`. Codex: review the revised files against that brief and append under `## Codex: round 4`. Fresh eyes. Do not re-report round 1 items unless the fix is wrong.

## Codex: round 4

References use the revised files: `v3` is the design, `test` is the fixture, and `scale` is the scale script. I ran both scripts on Postgres 18.6 in my own scratch database. Both exited successfully. The fixture produced the 11 expected errors and passed its counter assertion. Additional checks found the issues below. Search extensions and live R2 were not available; those limits are stated where relevant.

### 1. Correctness bugs

**F1. The inbox fix still exposes author-deleted reviews. Before PMF.**

- Evidence: `case when r.dead_at is null or r.user_id = n.user_id then r.body` (v3:479). It never checks `r.deleted_at`.
- Trigger: delete a review and its notifications. A delayed notification insert then arrives for that review. This can happen if notification creation follows the content transaction. The inbox displays the removed body. I reproduced this sequence with review 1; it returned `Worked great on Claude.` to the tip author.
- Smallest fix: check `r.deleted_at` first and return `[deleted]`. Apply kill permissions after that. An author exception must not bypass deletion. Keep notification cleanup, but do not rely on it for read visibility. This is an incomplete round 1 fix.

**F2. Reusing a staging key can overwrite a published image. Before PMF.**

- Evidence: Upload copies `staging/{uuid}.{ext}` to `media/{uuid}.{ext}` before inserting the media row (v3:538). `media_key_unique` runs after that copy. `x-amz-copy-source-if-match` checks the source, not whether the destination already exists.
- Trigger: publish image A. Reuse the still-valid PUT to put image B at the same staging key. Submit that key again. The app validates B and copies it over the published key. The database then rejects the duplicate media row, but A has already changed outside the database transaction.
- Evidence limit: I reproduced the duplicate-key rejection. I did not run the storage sequence against R2. This finding follows from the documented copy order and source-only condition. Destination overwrite prevention is a separate storage condition. [S3 conditional writes](https://docs.aws.amazon.com/AmazonS3/latest/userguide/conditional-writes.html)
- Smallest fix: generate a fresh destination UUID on the server for each new attachment attempt. Keep the source ETag checks. Never overwrite a key already referenced by `media`; remove only the newly created orphan if the database write fails. This adds no table or queue.

**F3. A rejected author-delete can still delete someone else's notifications. Before PMF.**

- Evidence: the ownership condition is inside the review update (v3:398). The next command is unconditional: `delete from notifications where review_id = $1` (v3:400). Tip deletion has the same separation (v3:402–403).
- Trigger: user 4 requests deletion of user 2's review 1. The update affects zero rows. The notification delete still runs. I reproduced `UPDATE 0` followed by `DELETE 2`.
- Smallest fix: run cleanup only for ids returned by an authorized content update. A short transaction with `UPDATE ... RETURNING id, tip_id, dead_at` is enough. Do not infer success from the parent counter update: deleting a dead review correctly changes no parent counter. Gate R2 cleanup on the same returned content id. The guarded-update fix stopped count drift but left this side effect unguarded.

**F4. The revised counter statements can reject valid concurrent writes. Before PMF. Reproduced.**

- Evidence: `RETURNING OLD/NEW` feeds the parent update in the same statement (v3:357–369; test:246–256). `tips_counts_chk` requires nonnegative counts. The child change can observe a concurrent row after waiting, while the parent calculation starts from the statement's older snapshot.
- Trigger: start a tip at `(up_count, down_count) = (0,0)`. Session A inserts an upvote and holds its transaction. Session B starts a downvote for the same voter and waits. Commit A. B tries a parent tuple with `(-1,1)` and fails `tips_counts_chk`. Its vote change rolls back. The final vote stays up, although the later request asked for down.
- I also reproduced the reverse switch and a switch followed by unvote. Both failed. A separate lifecycle test failed too: A unkills the only review; B starts author deletion while A is uncommitted. After A commits, B tries `review_count = -1` against its old parent snapshot (v3:398–399).
- Why: Postgres checks the proposed tuple before attempting the physical update that would detect and handle a concurrent parent update. This is visible in `ExecUpdateAct`: `ExecConstraints` precedes `table_tuple_update`. [Postgres 18 executor](https://raw.githubusercontent.com/postgres/postgres/REL_18_STABLE/src/backend/executor/nodeModifyTable.c)
- Smallest fix: keep `OLD/NEW`, but return the delta to the app. Apply the parent delta in a second statement, inside the same Read Committed transaction. The second statement gets a fresh snapshot after the child wait. I tested this fix for the overlapping up/down case; both transactions committed and the result was `(0,1)`. Use the same pattern for removals and lifecycle deltas. Keep the nonnegative checks. Add these two-session cases to verification. My earlier claim that `OLD/NEW` alone completed the concurrency fix was wrong.

**F5. Hidden parents consume the review search budget before filtering. Before PMF.**

- Evidence: each inner review query applies `limit 200` before joining eligible tips (v3:514–516 and 521–523).
- Trigger: the first 200 review hits belong to removed tips. Hit 201 belongs to a live tip. The branch returns zero candidates, even though an eligible hit exists. This differs from the accepted short-page tradeoff caused by several eligible reviews sharing one tip.
- Reproduction: with 201 pre-ranked SQL rows, the current limit-then-parent-filter order returned 0; filtering before the limit returned 1. This tests the relational order, not the unavailable search operators.
- Smallest fix: put parent eligibility inside the candidate query, before `LIMIT 200`. Do the same for selected filters. Keep the bounded candidate pool and collapse afterward. Do not restore a full-corpus distinct-tip scan.

**F6. The tip page never fetches the tip's images. Before PMF.**

- Evidence: its only media query is `where review_id = any($1)` (v3:310). The five-query page plan lists only review media. `t.*` contains no media keys.
- Trigger: attach an image to a tip. The documented queries cannot return it. I inserted one tip media row; the page's review-only filter could not select it, while a `tip_id` lookup returned it.
- Smallest fix: fetch both parent kinds in that media query, using `tip_id = $tip OR review_id = ANY($review_ids)`. Select both ids so the app can group the images. Keep attachment visibility tied to the already-authorized page rows.

### 2. Performance risks

**P1. Numbering every tip hit forces a full sort before the top-50 limit.**

- Query: `row_number() over (order by embedding <=> ...)` and `limit 50` are in the same SELECT (v3:507–508). There is no vector index in v1.
- Why it matters: scanning exact distances is required, but sorting every result is not. In a 200k-row numeric-distance probe, this shape used an external merge sort with 4,320 kB of disk space. It took about 50 ms. Limiting first, then assigning row numbers, used a 28 kB top-N sort and took about 11 ms. These are sort-shape measurements, not vector latency estimates.
- Fix: select the nearest 50 tips in an inner query. Assign `row_number()` over those candidates outside it. Apply that structure to the keyword branch when its plan does not provide index order. This needs no new index or service.

**P2. The revised scale script no longer measures the documented profile query.**

- Evidence: `scale:122` omits `r.deleted_at is null`. The design includes it (v3:458), and `reviews_by_user` requires it.
- Result: the scale run scanned about 200k reviews, used 3,130 buffers, and took 10.2 ms. Restoring the design predicate used `reviews_by_user`, 123 buffers, and 0.17 ms. The design's profile query is not the bug; its performance evidence is wrong.
- Fix: restore the predicate in the scale query. Replace the stored plan/timing claims with results from the revised scripts. Do not add another profile index to accommodate a test-only query.

No new evidence justifies extra browse indexes, HNSW at launch, or a separate counter service.

### 3. Invented conventions

Only new or incompletely fixed choices are listed here. Settled round 1 choices are not reopened.

| Invented thing | Industry standard that could replace it | Recommendation |
|---|---|---|
| Treating child `OLD/NEW` as enough to make a same-statement parent delta safe | Read Committed transactions with a fresh snapshot for the dependent statement | Split the two statements. Keep one transaction. See F4. |
| Cleanup keyed by request id after a guarded update | Cleanup keyed by the successfully changed row | Adopt returned ids. See F3. |
| The same UUID for staging and published objects, with copying before uniqueness validation | Immutable published object keys | Use a fresh server-generated destination. Source ETags solve a different race. |
| Candidate limit before parent eligibility | Filter eligibility before selecting top candidates | Move the parent predicate inward. Keep the accepted 200-candidate budget. |
| Calling a fixed 200-hit pool “the same as Elasticsearch collapse” | Elasticsearch selects the top sorted document per group | Describe this as bounded candidate retrieval followed by grouping. Its short-page behavior is a local tradeoff, not an Elasticsearch guarantee. [Collapse documentation](https://www.elastic.co/docs/reference/elasticsearch/rest-apis/collapse-search-results) |
| Relying on `row_number()` to define all result ordering | Explicit `ORDER BY` at each limited result boundary | Add stable id tie-breaks and explicit ordering to the outer review-branch limits and final fused limit (v3:512–531). Window ordering does not define a unique order for equal scores. [Postgres LIMIT](https://www.postgresql.org/docs/18/queries-limit.html) |

### 4. Cut list

- Stop forcing the affected child and parent writes into one statement. Two statements in one transaction fix F4 without a new locking system.
- Drop stale benchmark numbers. Keep the actual queries and fresh output. Passing a script is not proof that its printed expectations or old timing table still match.
- Do not increase the search candidate budget to hide F5. Move eligibility before the budget. Keep broader recall tuning deferred.
- Do not add upload-session tables or a storage job to fix F2. Fresh destination keys and cleanup of failed attempts are enough for this issue.
- Keep notification event counts as the user decided. No new ranking formula, event ledger, or auth framework is needed for these findings.

### 5. Verdict

**Ship with fixes.** The concurrency fix is incomplete, and the deletion and upload paths still allow visible side effects after failed or outdated actions. Fix F1–F6 before launch. Apply the small sort change and repair the profile benchmark. Keep the existing requirement to run search on the target image; this review does not establish that the search SQL executes there. The schema does not need a redesign.

## Claude: round 4

| Item | Verdict | Resolution |
|---|---|---|
| F1 inbox shows deleted review body | **Accept.** | Mask order: `deleted_at` first, then killed-unless-own. One `case`. |
| F2 staging key reuse overwrites a published object | **Accept.** | The copy targets `media/{fresh uuid}` chosen by the server per attempt. Source ETag checks stay. The staging key is never the published key. |
| F3 unconditional notification delete after a rejected delete | **Accept.** | Fold into the CTE: `with d as (update ... returning id, tip_id, dead_at), n as (delete from notifications where review_id in (select id from d)) update tips ...`. R2 cleanup keyed on returned ids. |
| F4 check constraint fails under overlapping votes | **Accept. Reproduced. Different fix.** | Reproduced: B fails `tips_counts_chk` with `(-1, 1)`. Then I dropped the constraint and ran the same two sessions: B succeeded and the row ended at `(0, 1)` with the vote at -1. One statement, correct result. Postgres re-evaluates the update on the fresh row version after the wait (EvalPlanQual). The only thing that broke was the check, which runs before that re-evaluation. So: drop `tips_counts_chk` and `reviews_counts_chk`. `update ... set n = n + delta` is the standard concurrent counter pattern and it is correct without a nonnegative check. The counter assertion in the test script and the recount cover drift. This is smaller than splitting vote, unvote, delete, kill, and unkill into two statements each. Objection? |
| F5 candidate limit before parent filter | **Accept.** | Parent join moves inside the 200-candidate query. |
| F6 tip page never fetches the tip's images | **Accept.** | `where tip_id = $2 or review_id = any($1)`, select both ids. Doc omission. |
| P1 `row_number()` forces a full sort before `limit` | **Accept.** | Inner `order by ... limit 50`, `row_number()` outside, for both tip branches. |
| P2 scale script profile query lost `deleted_at` | **Accept. My error.** | A global replace hit the profile query. Restored. Timing table refreshed from the new run. |
| Ordering tie-breaks at limits | **Accept.** | `, id` added to every ordered limit in the search statement. |
| "Same as Elasticsearch collapse" | **Accept wording.** | "Bounded candidates, then one per tip." |

Everything else in the cut list matches what is already in the doc. Codex: reply under `## Codex: round 5` on the F4 choice only, five lines at most. Then I apply all of round 4 together with the three Opus reviews that are running in parallel.

## Codex: round 5

- Reject. I dropped `reviews_counts_chk` and reproduced another failure: start at `(up, down) = (0,1)`; A switches that vote to up and holds; B switches it back to down, waits, then A commits.
- B fails with `cannot take square root of a negative number`. Its provisional counters are `(-1,2)`. Generated `best_score` evaluates Wilson's square root before the concurrent-row recheck. Removing CHECK constraints does not remove this failure.
- Keep the checks and split the child change from the counter update inside one transaction. Test assertions and a later recount cannot rescue a rejected user action or enforce production invariants.

## Claude: round 5

F4: **Codex is right. Accept the split.** The generated column runs before the recheck too, and Wilson takes a square root. So the vote, unvote, review delete, kill, and unkill each become two statements in one transaction: the child change returns the delta, the parent counter update runs second with a fresh snapshot. Publish stays one statement because it only adds. Checks stay. Rule 3 in the doc changes from "same statement" to "same transaction". Two-session cases go into the test script.

Round 4 is settled. Applying it with the Opus reviews.

## Codex: round 6

The current challenge overrides the older product proposals.
All agreed features stay.
Costs below are rough implementation estimates, not measured delivery times.
They exclude tests unless stated. Shared fixes are counted once.
I read sections 1–5 of all three Opus reviews.
I checked the current SQL, ranking arithmetic, and the sources linked below.
I did not run the search extensions in this round.
I also ran small temporary-table checks for notification bounds and deleted-row kills.
Those checks were rolled back and left no tables behind.

### A1. Keep the vector half of search

Symptom: vectors add an untested service, worker, and expensive reads.

1. Why are vector results uncertain? The actual extension path has not been exercised.
2. Why do proxy timings not settle it? They measure byte access without the real distance query.
3. Why is the real query important? Filtering, grouping, and index choice change its work.
4. Why can the current plan scan too much? It computes distance for every eligible embedding.
5. Why does review volume matter? Reviews add a second, potentially larger corpus.
6. Why is the fixed row trigger inadequate? It ignores that combined workload and available hardware.
7. Why does a background worker add failure modes? Remote inference can fail independently of publishing.
8. Why need that not block publishing? The agreed worker already runs asynchronously.
9. Why can search still degrade silently? Retry handling and backlog visibility are incomplete.
10. Why is deletion not the root fix? The missing work is dependency verification and bounded operation.

Root: no measured operating envelope for the actual search path.
Use the B1 deployment check, per-row retries, and real load measurements.
Keep both vector branches, the agreed model, and asynchronous indexing.
Use HNSW if the actual latency/recall results require it at launch.
That changes access paths, not the hybrid feature.
Keep keyword fallback for an embedding-service failure, with visible operational errors and recovery.
Fallback is a failure mode; it must not quietly become the normal launch implementation.

Pushback: “BM25 alone is complete search” changes the specified retrieval behavior.
Short documents can still use different words for the same idea.
A's proxy identifies a risk; it does not establish the asserted crossover below 20k rows.
Running two requests does not by itself prove either misses two seconds.

Cost: shared with B1, not a second service or worker implementation.
Two retry-time columns total across tips and reviews, plus integration checks.
Zero feature removals; ongoing model RAM, CPU, and monitoring remain real costs.

### A2. Keep review embeddings

Symptom: reviews dominate the vector row count but results collapse by tip.

1. Why do reviews dominate bytes? The fixture has roughly ten reviews per tip.
2. Why embed them separately? Each review can report different facts or vocabulary.
3. Why can a tip embedding not replace them? It represents the tip's text, not later observations.
4. Why does collapse not make them redundant? Any review may be the parent's strongest match.
5. Why is one returned parent enough? The user needs the tip once, with its matching evidence.
6. Why is cost still high? Exact retrieval examines many documents to identify those matches.
7. Why does cutting the column change results? A review-only semantic match can disappear entirely.
8. Why is “least per byte” unproven? A reports row counts, not the relevance value of those matches.
9. Why must relevance and cost be tested together? A fast query that loses required matches is not the same feature.
10. Why is the root an access-path problem? Document coverage and search work were treated as inseparable.

Root: the larger corpus needs measured retrieval costs, not less coverage.
Keep one embedding per review, updated by the same worker as tips.
Test paraphrased review-only matches as well as literal keyword matches.
Apply C7's parent grouping and B1's measured choice of exact or indexed retrieval.
Do not average all reviews into one tip vector; that can erase a minority match.
Prioritize neither tips nor reviews so completely that the other queue starves.
Alternate bounded batches in the existing loop.

Pushback: collapsing results limits duplicate presentation, not the value of the source documents.
A supplies no recall test showing review embeddings contribute least.

Cost: retain the already specified embedding column and model column on reviews.
About 5–10 worker lines for fair batch selection; no extra worker or service.
Index and grouping costs are shared with B1/C7.
Review embedding storage and inference remain proportional to review text volume.

### A3. Isolate frequent updates once, not twice

Symptom: counter changes cause BM25 maintenance on unchanged tip text.

1. Why is BM25 reached? It shares a table with the updated counters.
2. Why can unchanged text still cost work? Non-HOT updates need new index references.
3. Why is this expensive for text? The inspected extension tokenizes the inserted document version.
4. Why would a search side table help? Voting would no longer update its heap row.
5. Why is that not the only separation? Moving counters also leaves text untouched.
6. Why must reviews be considered too? Their Best counter updates share the same problem.
7. Why is `tip_search` alone incomplete? It does not isolate review BM25 updates.
8. Why not apply both A3 and C4? Two separations add joins and synchronization for the same write path.
9. Why does moving text not erase duplicate storage? The searchable copy still exists in another table.
10. Why is the root physical coupling? The search content's lifetime differs from a counter's update rate.

Root: unrelated update rates share one heap row and its indexes.
Use C4's two counter tables for both content types.
Keep stored search text on the now less frequently updated content row.
Do not also add `tip_search` and a parallel review search table for this same issue.
Keep text edits and embedding writes conditional and transactional where appropriate.
Those operations can still update search indexes; they are not the vote write path.

Pushback: a side table is a valid alternative, not a required additional fix.
Moving one column does not prove that the physical tips heap halves.
TOAST placement and actual text sizes determine that; total searchable text remains stored.
Likewise, “every vote changes Hot” is false: net scores -1, 0, and 1 share the same Hot term.
A's own table reports 4.6% HOT updates, contradicting “no vote can ever be HOT.”
The frequent rank-changing updates still justify addressing the shared-index work.

Cost: C4's two tables and query changes, counted once.
Zero additional search tables, columns, statements, or app code for A3.
Do not stack both structural proposals without a separate measured reason.

### A4. Keep model and environment filters; fix optional predicates

Symptom: a generic prepared plan can scan and sort many reviews for optional filters.

1. Why can a generic plan be worse? It must handle both null and non-null parameters.
2. Why is the optional-filter expression broad? One OR arm disables the filter entirely.
3. Why cannot planning discard that arm? A generic plan does not know the supplied value.
4. Why can ordering then lose? The estimated cheapest path may be bitmap scan plus sort.
5. Why is this not inherent to the dropdown? The app knows whether the filter is active.
6. Why can separate query shapes help? Each shape states only the active conditions.
7. Why must unknown values remain included? The agreed review filter deliberately includes them.
8. Why not replace the remaining OR with strict equality? That would change the filter's meaning.
9. Why does a plan still need measurement? Data skew and selectivity remain even after removing optional arms.
10. Why is deferral misplaced? Query shape and indexes can change while the same control stays visible.

Root: optional query predicates hide useful facts from generic planning.
Build only active predicates, with bound parameter values and fixed SQL fragments.
For reviews, retain matching-or-unspecified conditions from B12.
Two optional review filters mean four filter shapes, each with first/next-page variants.
Test forced custom and generic plans for every shape and meaningful parameter distribution.
Use B7's selective access paths where needed. Keep all browse controls.

Pushback: the shown null-parameter OR clauses belong to tip-page reviews.
Browse already says to append active equality predicates.
A's review-plan result is not proof that the Browse controls must disappear.
Also, PostgreSQL does not promise to switch every prepared statement on execution six.
It compares a generic plan with the earlier custom plans; the outcome is workload-dependent.
[Postgres prepared-plan selection](https://www.postgresql.org/docs/18/sql-prepare.html)

Cost: zero columns. About 10–20 app lines for fixed predicate assembly.
About 10–20 SQL lines across templates; still one query per list page.
The index cost is shared with B7. No new filter semantics.

### A5. Keep prompt and output on reviews

Symptom: thirty large reviews can transfer a large amount of text.

1. Why can the page be large? It returns multiple full text fields for thirty reviews.
2. Why are those fields distinct? A prompt and its output are evidence, not merely commentary.
3. Why is deletion not an equivalent optimization? The reader loses that evidence.
4. Why is truncation not equivalent either? It discards part of the submitted text.
5. Why might fetch-on-click change UX? It adds an interaction that was not required before.
6. Why is the stated byte bound weak? The constraints count characters, which may use multiple UTF-8 bytes.
7. Why is raw size not wire size? HTTP compression can reduce ordinary text transfer.
8. Why can large responses still start displaying early? The server can stream rendered content.
9. Why can neither guarantee a tiny response? Some valid text compresses poorly and must still be delivered.
10. Why is the root a delivery-budget issue? Full allowed content has an unavoidable byte cost.

Root: the review estimates payload without a measured transport/rendering budget.
Keep all fields, full text, current page size, and existing interactions.
Select only needed columns. Enable HTTP compression for the rendered response.
Stream HTML in display order so the first review can render before the whole page arrives.
Measure encoded bytes, server time, and browser rendering with representative and maximum-size text.
Do not add expansion controls or silently truncate fields to make the benchmark pass.

Pushback: thirty times two times 20k is 1.2 million characters, not a universal 1.2 MB bound.
UTF-8 can need four bytes per character; review bodies add further content.
Conversely, many ordinary text payloads compress, so raw maxima are not typical transfer sizes.
No lossless method can guarantee a small fixed wire size for arbitrary allowed text.
Step 9 states that limit. Keep the feature and budget for the remaining worst case.

Cost: zero schema changes or extra SQL statements.
About 5–10 compression configuration lines and 20–40 streaming/rendering lines if absent.
No new user action. Compression uses CPU; full rendering still uses browser memory.

### B1. Keep hybrid search and pg_textsearch

Symptom: untested search SQL, restricted hosting, and uncertain scan cost.

1. Why is readiness unknown? The test database lacks both search extensions.
2. Why does a passing fixture not settle it? It omits the production search path.
3. Why can that path differ? Extension operators and plans need their actual versions.
4. Why is hosting involved? The database host must load those extensions.
5. Why call that vendor lock-in? B treats one supplied image as the only installation route.
6. Why is that too strong? pg_textsearch also provides source installation instructions.
7. Why is the scan estimate weak? It counts vector payload, not whole-query work.
8. Why does whole-query work matter? TOAST access, review volume, and concurrency add cost.
9. Why can a row threshold miss this? The same row count has different costs on different machines.
10. Why was removal proposed? Missing deployment evidence was treated as a failed feature.

Root: the production dependency and performance checks are missing.
Keep all four branches, RRF, Qwen3-Embedding-0.6B, and the async loop.
Pin a database image with both extensions. Run the real prepared queries there.
Use explicit `to_bm25query(text, index_name)` for the partial BM25 indexes.
The extension documents both self-installation and that query requirement.
[pg_textsearch](https://github.com/timescale/pg_textsearch)
Measure warm and cold search with realistic tip AND review volumes.
Use query latency and concurrency to choose exact scans or HNSW, not 50k alone.
If HNSW is needed, test filtered recall and the grouping rule in C7.
Handle embedding failures per row. Add a retry time to each content table.
Skip rows not yet due, continue the batch, and log failures and backlog age.
This keeps one worker. It does not need a separate queue service.

Pushback: C's TOAST probe identifies missing work, not a measured vector timeout.
Its 20k-tip breaking point and “5 to 10 times” claim are extrapolations.
Buffer hits are not equivalent to fresh bytes read from storage.
Do not substitute another unmeasured threshold or claim half precision has no recall cost.

Cost: one pinned image; about 80–150 lines of integration checks.
Two retry-time columns; about 10–20 SQL lines and 30–60 worker lines.
Up to two HNSW index statements if measurements require them.
Self-hosting also carries backups and extension upgrade work. That cost is real.

### B2. Keep shadow bans; fix vote transitions

Symptom: an old dead vote can stay dead after the account is unbanned.

1. Why does it stay dead? The upsert keeps the old `dead_at` through `coalesce`.
2. Why does a new vote choice not clear it? The incoming live state loses to the old timestamp.
3. Why does a same-value action not help? The update guard compares only `value`.
4. Why is that incomplete? A vote has both a direction and a counting state.
5. Why must counting state change? The account's write eligibility can change.
6. Why not revive everything on unban? Unban is not a new voting action.
7. Why keep that distinction? Past hidden actions were never public votes.
8. Why can a later action count? The now-eligible user explicitly submits it.
9. Why do counters need both states? Only live old and new contributions belong in the delta.
10. Why did this bug survive? The transition cases omit explicit voting after unban.

Root: the upsert models a value change but not the whole vote state change.
On an explicit eligible vote, set `dead_at` from current eligibility.
Update when value differs OR live/dead status differs.
Compare null status, not changing ban timestamps, to keep repeats idempotent.
Leave old votes alone on unban and unkill.
Use the accepted split statements in one transaction for the counter delta.
Check target eligibility too. Do not revive votes on inaccessible content.
Test live→dead, dead→live, same-value recast, switch, remove, and retry.

Pushback: “forever” is too strong. The shown unvote deletes the row.
A later insert by an unbanned account is live. The direct upsert path is wrong.
Removing shadow bans would hide that missing transition rule.

Cost: about 6–10 changed SQL lines across the two vote paths.
Zero columns. No extra statement beyond the accepted transaction split.
About 10–20 app lines to handle returned transitions consistently.

### B3. Keep all notification types and folded counts

Symptom: vote notifications add writes and count events rather than people.

1. Why is there a notification write? A real helpful-vote event informs the author.
2. Why does B say every vote? It groups upvotes, downvotes, repeats, and self votes together.
3. Why is that inaccurate? The design excludes self actions and dead actions.
4. Why should repeats also be excluded? They create no new vote transition.
5. Why does the count need a definition? Removing and replacing a vote can produce another event.
6. Why not count unique people? The current decision explicitly chose event counts.
7. Why is a separate event log unnecessary? The vote transition already supplies the event.
8. Why can retrying still be safe? A committed repeat yields no second transition.
9. Why can the notification still go missing? Writing it outside the vote transaction leaves a crash gap.
10. Why does this need repair? Event emission must follow committed state changes, not HTTP attempts.

Root: notification eligibility and transaction boundaries need an explicit contract.
Emit only for a new live upvote contribution by someone other than the recipient.
Write the folded notification in the same transaction as the vote and counters.
Keep the accepted count semantics and all three types.
Document each type's recipient, target, and parent context.
Deleting a tip must not erase notifications whose target is a surviving review.
Gate cleanup on the successful authorized deletion, as already agreed.

Pushback: the `NULLS NOT DISTINCT` fold index handles a null `tip_id`.
That does not make a review target stop folding.
Also, Reddit does send upvote-related notifications, including email activity notices.
[Reddit notification documentation](https://support.reddithelp.com/hc/en-us/articles/360053879992-Managing-Your-E-mail-Preferences)
Neither site's policy decides this product's agreed feature.

Cost: zero new columns or tables.
One existing upsert per eligible event, not per vote request.
About 10–20 SQL/app lines for transition guards and cleanup targeting.
No event ledger or background delivery worker is needed for this inbox.

### B4. Keep Wilson Best

Symptom: reviews with only their self vote all have the same score.

1. Why do they tie? Their inputs are identical: one upvote and no downvotes.
2. Why are inputs identical? Nobody else has voted yet.
3. Why cannot Wilson distinguish them? Votes contain no distinguishing evidence.
4. Why would up-count order help? It would not; the same reviews still tie.
5. Why does the tiebreak use recency? The page still needs a stable order.
6. Why can the orders diverge later? Wilson includes downvotes as well as upvotes.
7. Why does that matter immediately? One downvote already changes the confidence bound.
8. Why wait for twenty votes? B supplies no mathematical threshold for that delay.
9. Why call the formula overhead? B counts SQL lines rather than measured query work.
10. Why is the proposed replacement misplaced? Missing evidence is being confused with a ranking defect.

Root: cold-start data ties, not a broken ranker.
Keep the generated score and its index. Keep `id` as the deterministic tiebreak.
No production change is needed for this symptom.
Use a fixture with differing up AND down votes to check Best.

Pushback: calculated with the specified z, `(1,0)` scores 0.378448.
`(1,1)` scores 0.164252; `(2,0)` scores 0.549092.
Up-count order ties the first two. Wilson already separates them.
C's placeholder example says about 0.20 for one self vote. That number is wrong.
The tie and placeholder attack do not depend on that mistake.

Cost: zero columns, statements, or app changes.
About 10–15 fixture lines to test the actual ranking distinction.

### B5. Keep classic Hot and New

Symptom: the fixture produces strongly overlapping first pages.

1. Why do the pages overlap? Recent fixture rows occupy both result sets.
2. Why can Hot favor those rows? It combines vote strength with posting time.
3. Why can time dominate? Vote differences may be small relative to age gaps.
4. Why does that not prove identical order? Set overlap ignores positions within the set.
5. Why does it not prove permanent overlap? Real voting and posting patterns may differ.
6. Why are those patterns unknown? This is synthetic launch data.
7. Why is “tens of votes” not a prerequisite? Even score two has a nonzero Hot advantage.
8. Why not use Top to fix the fixture? Top removes the agreed recency behavior.
9. Why is that a different product choice? Old accumulated votes can dominate without time decay.
10. Why did B infer failure? A sample distribution was treated as a universal usage pattern.

Root: the fixture does not isolate the behavior being judged.
Keep the formula and both tabs.
Add an older score-two tip and a one-hour-newer score-one tip.
Hot should put the older tip first. New should put the newer tip first.

Pushback: score two buys about 3.76 hours relative to score one.
Hot can differ after one additional upvote; it does not require tens.
The challenge says 86/100 overlap. B's review says 100/100.
Neither number proves the two ordered lists are identical forever.

Cost: zero production SQL, columns, statements, or app changes.
About 10 fixture lines. Do not tune the agreed formula to this fixture.

### B6. Keep ten image slots

Symptom: more images can increase storage, upload work, and moderation work.

1. Why can costs grow? Authors may attach more bytes.
2. Why is the maximum not the average? Many posts will use fewer than ten images.
3. Why are total bytes still important? Object count alone does not bound transfer or decoding work.
4. Why can publishing become slow? Validation and copying are described as serial network calls.
5. Why do slow calls hurt transactions? An open database transaction can retain locks while waiting.
6. Why must a moderator open everything separately? Only if the moderation page lacks grouped previews.
7. Why can unused files accumulate? Upload and database commit can succeed independently.
8. Why would one slot not solve that? A single upload can still be huge, malicious, or orphaned.
9. Why are these separate problems? Limits, validation, visibility, and cleanup govern different risks.
10. Why was the slot count blamed? The review used the maximum as a substitute for resource controls.

Root: upload work and resource limits are underspecified.
Keep ten slots and the existing 10 MB per-file limit.
Validate and copy before opening the short publish transaction.
Use bounded concurrency, request deadlines, and the existing signing/write rate limits.
Bind upload confirmation to the actor and checked object version.
Allow all ten valid images; do not impose a smaller hidden total limit.
Delete newly copied objects after a failed publish attempt.
Use a grace period when sweeping unreferenced files so active publishes survive.
Show all attached images together in the existing moderation view.
Apply C3 and C5 to every type and slot.

Pushback: lowering the count does not fix unsafe serving or failed-publish orphans.
The existing page query already fetches images in a batch.
Ten slots do not require ten database queries.
Storage and human review still grow with actual use. There is no zero-cost fix for that.

Cost: zero new columns; retain existing media insert statements.
Roughly 80–150 app lines for bounded upload work and failure cleanup.
A small periodic orphan sweep and grouped previews add about 40–80 lines.
The media access and decoding work is counted under C3 and C5.

### B7. Keep tag, model, and environment filters

Symptom: selective combinations can scan many rows to return few results.

1. Why are many rows visited? The main indexes order by rank or time.
2. Why do they not narrow by setup? The facet columns are not leading search keys.
3. Why is the empty case costly? An ordered scan can search the whole eligible set.
4. Why can Postgres choose a sequential scan? It may cost less than scattered heap fetches.
5. Why is that not automatically a failure? The measured empty query took 3.44 ms.
6. Why might growth change that? More rows increase the work before proving absence.
7. Why does dropping environment not solve the cause? Sparse tag/model combinations still exist.
8. Why is `INCLUDE` not a search key? Included values do not guide B-tree descent.
9. Why is index-only access not guaranteed? The query needs other columns and visible heap versions.
10. Why is the cut misplaced? Query access paths, not filter count, determine this cost.

Root: selective filtering lacks a suitable access path.
Keep all dropdowns. Emit predicates only for active filters, as browse already describes.
For the growth case, add small partial indexes on each of the three facet columns.
Postgres can combine them with bitmap scans, then sort the matches for Hot or New.
Retain rank indexes for dense and unfiltered queries.
Measure each combination, including no-match cases. A sequential plan may still be cheapest.
Do not add every possible facet/rank combination without evidence.

Pushback: `INCLUDE` alone does not make the current full projection index-only.
Even a covered candidate query may visit recently changed heap pages.
[Postgres covering-index requirements](https://www.postgresql.org/docs/18/indexes-index-only-scans.html)
B's timings show a scale concern, not a failed launch feature.

Cost: three index statements, about 9 SQL lines; zero columns.
No extra page query. Existing predicate assembly stays.
Index storage and extra work on content writes are the ongoing costs.
C4 keeps vote updates from maintaining these content indexes too.

### B8. Keep review bodies in search

Symptom: the review branches add SQL before the site has many reviews.

1. Why are the branches empty on an empty site? There are no review documents yet.
2. Why is that temporary? The first submitted review changes it.
3. Why can that first review matter? It may contain the only relevant term or explanation.
4. Why can tip-only search miss it? It indexes a different document.
5. Why is review search therefore distinct? It finds a tip through evidence written by another person.
6. Why are the branches longer? They must map many review documents onto one tip result.
7. Why is grouping necessary? Repeated reviews must not become repeated tip results.
8. Why can a fixed pool underfill? Many candidates can share the same parent.
9. Why does removal evade that bug? It removes the required source of matches.
10. Why was the feature judged by line count? Retrieval behavior was not checked with representative cases.

Root: the search fixture omits review-only matches and crowded parent groups.
Keep both review branches and the same embedding worker for both content types.
Add a tip whose useful search term appears only in one review.
Add repeated hits from one tip plus useful hits from other tips.
Apply the grouping fix in C7 and visibility checks before candidate selection.
Retain four-list RRF. Do not silently change its weights to solve grouping.

Pushback: a tenth review is not needed for review search to have value.
An empty branch is valid, not a correctness bug.
One collapsed contribution per branch prevents unlimited score growth from review count.
It does not make malicious review text trustworthy; moderation still applies.

Cost: no additional schema beyond the agreed search design.
About 20–40 fixture lines. B1 covers the worker; C7 covers grouping SQL.
No second embedding service or separate review-search endpoint.

### B9. Keep base36 URLs

Symptom: B prefers decimal identifiers but identifies no broken behavior.

1. Why remove base36? B calls decimal more conventional.
2. Why would convention alone matter? It might reduce implementation work.
3. Why is the saved work small? Encoding and decoding are deterministic integer operations.
4. Why is a second database key unnecessary? The decoded value is the existing primary key.
5. Why does the slug not complicate lookup? It is presentation, not identity.
6. Why can the title change safely? The id stays fixed and the slug redirects.
7. Why could parsing still be wrong? A parser might lose integer precision or accept partial input.
8. Why is decimal not a cure? Decimal ids can suffer the same range and precision errors.
9. Why is the real boundary validation? Only a complete valid id should reach the lookup.
10. Why is there no feature defect here? The objection confuses a format preference with a data problem.

Root: no defect established; the parser needs an ordinary exact contract.
Use one shared base36 codec with checked positive bigint range.
Reject bad characters, trailing junk, zero, and overflow.
Do not route bigint ids through a floating-point number.
Look up by decoded id, then apply visibility and canonical-slug handling.
Build the redirect as a local route. The slug cannot change the host or authorization.

Pushback: people can share the agreed URL. B gives no evidence this format blocks that.

Cost: zero SQL, columns, or extra queries.
About 20–40 app lines if the language lacks a suitable checked codec.
Small boundary tests; no stored slug or alternative id column.

### B10. Keep Helpful / Not helpful; do not invent confirmations

Symptom: helpful votes do not state whether a tip worked recently.

1. Why is an outcome absent? The agreed vote records helpfulness.
2. Why is helpfulness different? A reader can value advice without running it.
3. Why cannot a renamed button repair old meaning? The stored event does not gain evidence.
4. Why is the self vote decisive? Every author gets one without an independent trial.
5. Why would `last_up_at` mislead? It dates approval, not a successful run.
6. Why cannot it prove present effectiveness? The voter may use another model or environment.
7. Why does one review per user not require a verdict field? It also bounds repeat submissions.
8. Why does free text still matter? It can describe conditions, failures, and observations.
9. Why are these observations not a universal aggregate? Different setups and dates are not interchangeable.
10. Why is B's fix wrong? It substitutes a convenient proxy for evidence that was never collected.

Root: B expects an effectiveness claim from a helpfulness signal.
Keep the labels, self vote, required review body, and one-review rule.
Show the existing post and review dates and stated setup fields.
Keep New so readers can find recent reports.
Do not call an upvote “confirmed working” or add `last_up_at` for that purpose.

Pushback: the page does not have “N unranked opinions”; Best already ranks reviews.
The current challenge explicitly settles the labels and review shape.
Older brainstorm language cannot override it.
There is no honest way to infer verified effectiveness from these votes alone.
Step 3 identifies that limit. The agreed feature does not promise that inference.

Cost: zero columns, write statements, or ranking changes.
About 5–10 template lines only if existing dates/setup are not already shown.
No new verdict workflow.

### B11. Keep noindex until traffic

Symptom: search indexing cannot supply traffic while noindex is active.

1. Why does organic discovery wait? Search engines are asked not to index the pages.
2. Why is that deliberate? The consensus makes traffic a prerequisite for indexing.
3. Why does B call it circular? It assumes organic search is the only traffic source.
4. Why is that assumption unproven? Direct links, invited users, and communities can bring readers.
5. Why might the policy still stall? “Traffic” has no operational threshold.
6. Why does a vague threshold matter? Nobody knows when the gate has been met.
7. Why might it remain enabled accidentally? No owner or launch check is stated.
8. Why is a calendar date not the same fix? It removes the gate even without traffic.
9. Why is per-tip noindex different too? It replaces the agreed site-level condition.
10. Why is the root operational? The policy needs a measurable exit and a check, not removal.

Root: the traffic gate lacks a concrete definition and owner.
Keep noindex. Put its exit condition in the launch checklist.
For example: 20 non-staff visitors in seven days, excluding bots and preview crawlers.
That number is a proposed operating choice, not an existing product decision.
Assign the operator to check the metric weekly and switch the existing flag after the gate.
Seed discovery through direct sharing while noindex remains active.
Verify the rendered robots directive after the switch.

Pushback: “organic search is the traffic” is a hypothesis, not a fixture result.
If nobody arrives through other channels, the agreed gate stays closed.
That tradeoff cannot be erased while claiming the same policy.

Cost: zero database columns or statements.
One existing configuration flag and a short checklist.
Use existing request analytics; no new analytics service is required.

### B12. Keep unspecified reviews under named setup filters

Symptom: a named filter includes reviews that did not state that setup.

1. Why do those rows appear? The SQL explicitly includes unknown setup values.
2. Why does B call them non-matches? It assumes exact equality is the whole filter contract.
3. Why is that assumption wrong here? The current consensus expressly includes unspecified reviews.
4. Why keep them? Missing metadata does not establish a conflicting setup.
5. Why is another named setup different? It supplies a known value that fails the selection.
6. Why does `model_other` matter? A typed model is stated information, not an unknown model.
7. Why does the current predicate check both fields? Null `model_id` alone would wrongly include typed models.
8. Why must environment be checked separately? A review can specify one setup dimension but omit the other.
9. Why is the needed test a truth table? It must distinguish match, conflict, and unknown in each dimension.
10. Why is the proposed exclusion wrong? It replaces the agreed inclusion rule rather than correcting SQL.

Root: the review applied a different filter contract.
Keep the current matching-or-unspecified predicates and the current control labels.
Show the review's actual supplied metadata. Never invent the selected setup on an unknown row.
Test named match, named conflict, typed model, unknown, and mixed model/environment cases.
Apply the same rule on the next page.

Pushback: an absent model means unknown, not proof that the review used another model.
The challenge settles the desired inclusion despite that uncertainty.
No stricter filter or relabeling is needed.

Cost: zero new columns, statements, or app behavior.
About 15–25 fixture lines. Existing review metadata rendering stays.

### C1. Keep shadow bans; fix the three private displays

Symptom: the author's private page exposes public counters that omit their hidden actions.

1. Why does a shadow vote not move the public count? Dead votes must not affect other readers.
2. Why does the voter see that omission? The endpoint returns only public counters.
3. Why does their own new score show zero? The born-dead self vote is excluded too.
4. Why is the review header short? Their visible-to-self review is absent from the public review count.
5. Why is adding one everywhere unsafe? A downvote subtracts one, and an unvote contributes nothing.
6. Why can repeated addition drift? Retries and reloads can replay the same display adjustment.
7. Why should it be recomputed? The viewer's stored vote already gives the exact private contribution.
8. Why must the server do this too? Optimistic browser state disappears on reload or another device.
9. Why must cache handling differ? A personalized count must not become another reader's response.
10. Why is the root a read-model gap? Public counting is correct; private rendering omits the viewer's hidden state.

Root: author-visible content and viewer-visible counters use different visibility rules.
Render public counts plus this viewer's current dead vote contribution.
Add one to up or down according to its value, never an unconditional score increment.
A live vote is already counted, so add nothing for it.
For a visible own dead review, add one to the private review count if it is not deleted.
Use the same helper on publish, vote responses, tip pages, profiles, and reloads.
Derive any displayed score from those private counts. Keep public ranking unchanged.
Show their own dead review once, including the existing “your review” slot.
Do not place these responses in a shared cache.

Pushback: C's optimistic-only fix fails after reload and mishandles removals and downvotes.
“The account cannot tell” is not an absolute guarantee: another account can compare visibility.
The three same-account contradictions are fixable. Universal invisibility is not.

Cost: zero columns and usually no extra query; viewer votes/review are already fetched.
About 15–25 SQL lines and 30–60 shared rendering lines.
Private rank calculations, if shown numerically, reuse the existing formulas.

### C2. Keep deleted-review placeholders; stop the abuse loop

Symptom: repeated create/delete cycles can fill a page with placeholders.

1. Why can the account create another review? The unique index excludes deleted rows.
2. Why does deletion free the slot? It ends the current review without erasing its placeholder.
3. Why does history still grow? Each new submission gets another row.
4. Why can history become spam? Two allowed actions can be repeated as an abusive loop.
5. Why does `review_count` not expose its size? That counter intentionally counts live reviews only.
6. Why can a live-row-only abuse check miss it? Every cycle removes its own active evidence.
7. Why need not deletion erase the evidence? The retained rows still record actor and posting time.
8. Why can moderation remove the spam from the list? `dead_at` is separate from `deleted_at`.
9. Why did C call it permanent? It overlooked that the kill statement also matches deleted rows.
10. Why does the attack need a workflow fix? Write budgets and cleanup must include deleted history.

Root: abuse controls must count activity across deletion, and cleanup must handle tombstones.
Keep legitimate placeholders, the current delete/repost flow, and one active review per user/tip.
Do not silently remove history, recycle ids, or turn deletion into a lifetime posting ban.
Apply the existing write rate limit to every create attempt; deleting never refunds it.
Do not rate-limit away the author's ability to remove content.
On an abusive loop, shadow-ban the actor and bulk-kill their review rows on the affected tip.
Include already deleted rows in that kill.
Subtract only changed rows that were previously live from the parent counter.
Use the accepted two-statement transaction; serialize publish with the actor's ban change.
Keep a moderator view of recent creates, including deleted ones, to identify the pattern.
This limits and cleans up abuse. It does not promise that no spam appears before detection.

Pushback: the documented kill matches `dead_at is null`, not `deleted_at is null`.
The list requires `dead_at is null`. Killing a deleted row therefore hides it.
The temporary-table check confirmed that exact predicate combination.
C's “cannot be undone by a moderator” claim is false on the shown SQL.
Removing every legitimate placeholder is unnecessary.

Cost: zero new columns; one unfiltered actor/time index for recent-history lookup.
About 25–40 SQL lines for lookup, guarded bulk kill, deltas, and ban coordination.
About 40–80 app lines using the existing rate limiter and moderation controls.
The cleanup transaction needs child kill, parent delta, and ban statements.

### C3. Keep killed files; revoke public reads

Symptom: a known public image URL remains readable after its content is killed.

1. Why does the URL still work? The object endpoint serves bytes without checking content state.
2. Why does hiding the page not help? The reader already has the key.
3. Why does keeping the file look like the problem? Storage and public delivery are conflated.
4. Why can they be separate? A private object can be retained while requests are denied.
5. Why is a random key insufficient? Once disclosed, it stays a usable address.
6. Why is a signed URL alone insufficient? An issued URL remains usable until expiry.
7. Why can cached content bypass a fix? A cache hit may skip the new authorization check.
8. Why must all routes be covered? A public bucket endpoint would bypass an app-only check.
9. Why does unkill benefit from retention? Authorized visibility can return without recovering deleted bytes.
10. Why is the root an access bug? Object reads do not enforce the content's current visibility.

Root: the serving path has no revocation check.
Keep files in a private R2 bucket. Disable public bucket and r2.dev access.
Keep the same media URL shape, backed by a small app or Worker handler.
Join the key to its tip/review and apply the existing viewer visibility policy.
Anonymous users can read live images; restricted content needs the proper viewer.
Check parent visibility too, while preserving reviews on author-deleted tips.
Fail closed when the visibility check fails or the target is absent.
For the MVP, do not publicly cache these responses. Revalidate reads against current state.
If edge byte caching is added, authorization must run before every cache hit.
Kill changes visibility only. Author deletion removes bytes as agreed.
[R2 public-access controls](https://developers.cloudflare.com/r2/buckets/public-buckets/)

Pushback: deleting files is one way to revoke access, not the only way.
Moving the key is also weaker than an explicit policy and creates restoration work.
Already downloaded copies cannot be recalled. Neither proposed storage rule can do that.

Cost: zero new columns; one indexed media-to-content lookup per image request initially.
About 15–25 SQL lines and 60–120 handler lines, plus private-bucket configuration.
The app carries image traffic and authorization work. This is not a free fix.

### C4. Separate counters without changing features

Symptom: votes on searchable rows cause index work unrelated to changed text.

1. Why is a rank-changing vote non-HOT? It changes an indexed generated column.
2. Why does that affect other indexes? A new heap tuple version needs their index references too.
3. Why does BM25 see the update? It indexes text on that same row.
4. Why might unchanged text still be tokenized? The index insertion routine can ignore that hint.
5. Why is that more than speculation here? The inspected pg_textsearch source does ignore `indexUnchanged`.
6. Why does vacuum not remove the original expense? Cleanup happens after insertion and tokenization work.
7. Why does more free heap space not cure it? A changed B-tree rank still prevents HOT.
8. Why not remove the rank index? That shifts recurring work to the agreed ranked reads.
9. Why can separation preserve both? Counters and text do not need the same physical row.
10. Why is this a schema-boundary issue? Data with different update rates shares expensive indexes.

Root: frequently changing counters share storage with searchable content.
This proposal is not a feature cut. I accept the separation.
Use one counter row per tip and one per review, with foreign-key primary keys.
Move the existing counters and generated ranks, rather than keeping two counter copies.
Keep exact votes, self votes, Hot, Best, and all displayed counts.
Copy the immutable tip creation time needed by generated Hot.
Keep `tip_id` on review counters for the per-tip Best index.
For small rank indexes, keep one rank-visibility flag on each counter row.
Tip visibility excludes deleted and dead; review ranking still includes deleted placeholders.
Update those flags in the same delete/kill/unkill transaction as the content row.
Reads still check the authoritative content row before their final page limit.
Retarget the accepted counter-delta statements and recount to these rows.

Evidence: at commit `a991f24`, `tp_insert` marks `indexUnchanged` unused.
It detoasts text, calls `to_tpvector`, and adds document terms.
[Pinned pg_textsearch source](https://github.com/timescale/pg_textsearch/blob/a991f24d7254c7ee2da52353521b6a9283748f86/src/access/build.c#L1830)
That supports C's mechanism for this version, not an unmeasured latency multiplier.
The counter table still has non-HOT rank updates and a row lock per target.
It removes search-index churn; it does not remove vote serialization.
Nor does a lock become cheaper merely because the row has fewer columns.

Cost: two tables, moved counters/ranks, two visibility flags, and two copied lookup/time fields.
About 80–140 SQL lines, including about 8–12 affected query/write templates.
Two counter inserts per tip-plus-review creation; joins on ranked reads.
About 30–60 app mapping lines. No new service, eventual counter, or cache.
This is more work than C's “a table” description implies.

### C5. Keep GIF; stop trusting upload metadata

Symptom: an accepted image can be served with an attacker-chosen HTML content type.

1. Why can it execute as HTML? The browser receives an HTML response type.
2. Why is that type attacker-controlled? The upload headers become object metadata.
3. Why does the copy retain it? No replacement metadata is specified.
4. Why can the signature check miss the payload? A valid prefix is not a full image decode.
5. Why does removing GIF not establish safety? Other files can also carry extra attacker-controlled bytes.
6. Why is extension alone insufficient? A filename is another client-supplied claim.
7. Why does decoding help? It validates the image structure and yields known image data.
8. Why keep animation during validation? GIF support must not silently become first-frame-only support.
9. Why bound decoded work? Small compressed uploads can demand large memory or many frames.
10. Why is the root a trust-boundary error? Client labels are being used as server response policy.

Root: the server does not control both validated content and serving metadata.
Keep PNG, JPEG, WebP, and GIF, including animated GIFs.
Decode with a maintained image library and bounded pixels, frames, memory, and time.
If re-encoding to discard extraneous data, preserve valid animation and timing.
Choose canonical extension and MIME from validated format, not client headers.
Replace object metadata on copy. Serve that MIME with `nosniff` on an isolated media origin.
Use C3's access handler; do not share application session cookies with media.
Use narrowly scoped media authorization for private reads.
[Upload validation guidance](https://cheatsheetseries.owasp.org/cheatsheets/File_Upload_Cheat_Sheet.html)

Pushback: the exploit depends on unsafe serving metadata, not the mere existence of GIF.
An animation is not itself script execution. Removing one format leaves the trust error.
Decoder limits must permit ordinary ten-image uploads; they are resource safeguards, not a slot cut.

Cost: zero SQL columns or new tables.
One image library; about 60–120 validation/metadata lines plus decoding CPU.
Full validation reads more than a magic-byte range. Include that in upload deadlines.
Serving-header work shares the C3 handler.

### C6. Keep immediate voting for legitimate new accounts

Symptom: cheap extra accounts can supply enough votes to move Hot.

1. Why can many accounts move Hot? The agreed formula counts their live votes.
2. Why are these votes misleading? They are controlled by one actor rather than independent readers.
3. Why can that actor appear independent? Account uniqueness is not person uniqueness.
4. Why does a one-hour delay not repair identity? The same actor can age accounts in advance.
5. Why is email verification not a full cure? One actor can control many email addresses.
6. Why can per-user limits miss it? Each account supplies only one allowed vote per target.
7. Why can shared network limits help? They can catch some coordinated account and write bursts.
8. Why are those limits incomplete? Shared networks contain real users, and attackers can distribute traffic.
9. Why is moderation still needed? Correlated behavior needs context and a way to reverse confirmed abuse.
10. Why is account age the wrong root? The missing signal is actor independence, not elapsed time.

Root: the system cannot equate one account with one independent person.
Keep the agreed vote formula and immediate access for normal new accounts.
Use the existing IP and user limits on signup and vote activity.
Record burst patterns in request logs; inspect suspicious target vote histories.
Add target-first vote indexes so moderators can inspect those histories promptly.
On confirmed abuse, ban the accounts and explicitly invalidate the affected votes.
Return exact deltas, then update counters in the same transaction.
Do not silently invalidate all historic votes merely because an account was banned.
Keep normal ban semantics; this is a separate targeted abuse cleanup.

Pushback: 100 net votes versus one do buy 25 hours in the formula.
That is a score comparison, not a guarantee of owning the front page for a day.
Competing posts and votes still matter.
One hour of waiting changes attack timing, not the number of identities the actor controls.
No cheap guard guarantees independence. Step 3 explains that limit.
Do not claim the proposed controls defeat a patient distributed attacker.

Cost: zero account-age columns or eligibility delay.
Two target/time indexes; about 20–35 SQL lines for inspection and targeted vote cleanup.
About 40–80 app lines using existing rate limits, logs, and moderator access.
There is ongoing human review. No new reputation formula or risk service is required.

### C7. Group review matches before the parent-result limit

Symptom: one heavily reviewed tip can consume the entire raw candidate budget.

1. Why can 200 rows become one result? The limit counts reviews, but the output counts tips.
2. Why is the conversion uneven? A tip can have many matching reviews.
3. Why does a four-times oversample not guarantee fifty tips? Parent multiplicity has no such bound.
4. Why would 2000 still fail? One parent can occupy all 2000 positions too.
5. Why is filtering live parents not enough? It removes ineligible parents, not duplicate eligible ones.
6. Why is grouping after a hard limit lossy? Other parents have already been discarded.
7. Why can fusion not recover those reviews? Their parent ids never enter that branch.
8. Why is the best review per tip sufficient? Only that review determines the branch's tip rank and snippet.
9. Why must ordering remain explicit? Ties otherwise change which review and parent survive a limit.
10. Why is the root a unit mismatch? The branch budget is defined in child rows instead of final parent candidates.

Root: a fixed raw-review cap cannot guarantee the desired number of distinct tips.
For this exact-search MVP, score eligible reviews, then select the best review per tip.
For BM25, retain actual term matches; do not pad with zero-match documents.
Order those distinct parents by best distance/score and stable ids; only then take fifty.
Apply parent visibility and requested filters before grouping.
Use that shape for both review branches, with explicit BM25 index naming from B1.
Keep one RRF contribution per tip per branch and one final result per tip.
This removes the logical starvation bug. It can increase scoring and sorting work.
Measure that real cost with B1 rather than pretending the original 200-row bound survives.

If that full grouping misses the latency budget, fetch ranked candidates in growing batches.
Continue until fifty distinct eligible parents or genuine match exhaustion, not a larger fixed cap.
Reaching a timeout is an error/degraded-search condition, not proof that no other matches exist.
Keep an explicit recovery path and monitor it; do not market a fixed pool as complete collapse.

Pushback: C's constructed set proves possibility, not that actual query top hits have that distribution.
It does not prove the entire hybrid search becomes keyword-only; both tip branches still run.
The suggested 2000-row pool merely moves the failure point.
I also revise my round-4 advice: 200 fixes neither grouping completeness nor this contract.
Moving parent eligibility inward remains necessary, but it is a separate fix.

Cost: no columns or tables; about 20–35 changed SQL lines across two branches.
Still one fused search statement for full grouping, with higher worst-case work.
An adaptive implementation would instead add about 40–80 app lines and variable query work.
There is no guarantee of both a fixed raw candidate count and fifty distinct parents.
Step 3 proves that limit; it does not justify dropping review search.

### Other findings that need correction or are already covered

**A §5: a successful load test does not settle the counter race.**
Round 5 already records a deterministic failing interleaving.
Starting at review counts `(0,1)`, concurrent opposite switches expose provisional `(-1,2)`.
Wilson then fails with a negative square root before the row-version recheck.
The test also failed after removing the nonnegative check.
Claude round 5 accepts the split-statement fix. Keep that decision and its two-session test.
Large random traffic without this failure is narrower evidence, not a counterexample.

**A §1.2 and C §2.4: their read bounds do not fix folded events.**
I checked this with temporary rows in Postgres.
Read notification id 8 at count 1. Fold another event into id 8, giving count 2.
`UPDATE ... WHERE id <= 8` marks that unseen second event read.
The id never changed. An ordinary Read Committed transaction does not prevent this gap.
Also, a transaction can allocate a low id and commit its insert after the inbox SELECT.
An id ceiling is not an observed-event boundary.
C's timestamp ceiling does not bound the number of older unread rows either.
It can still update the whole backlog.

Preserve the agreed mark-all-read-on-open behavior for the unread snapshot at opening.
Capture its ids and folded counts, then update only matching observed versions.
Use a statement snapshot or materialized snapshot; compare count and change timestamp on update.
A fold after capture must remain unread. Do not replace “all” with only the displayed twenty.
My temporary check confirmed that matching the observed count leaves the new fold unread.
Cost: about 15–25 SQL lines; no new column, since count changes on every fold.
This fixes the race, not the O(unread) work. A time/id condition does not remove that cost.

**A §1.4: the proposed BM25 call reverses its arguments.**
The documented order is `to_bm25query(query_text, index_name)`.
A supplies the index name first in its proposed fix.
Also, explicit-index standalone scoring exists; a subquery output is not inherently unscorable.
Carry the computed score forward anyway, to avoid redundant work and implicit index inference.
[pg_textsearch explicit queries](https://github.com/timescale/pg_textsearch#explicit-queries)

**A §1.4/§3 and B P-B4: ordering must be explicit.**
A's replacement `row_number() over ()` has no defined ranking order.
Rank the limited candidates with `row_number() over (order by d, id)`.
Use an explicit final `ORDER BY` at every limited boundary too.
B's observed WindowAgg output order is not a language guarantee.
These ordering and tip-branch limit changes were already accepted in Claude round 4.

**A §2.6: two omissions were already accepted, and one fix need not add a query.**
Claude round 4 accepts the profile predicate correction.
It also accepts fetching tip images with review images in the same media query.
Use `tip_id = $tip OR review_id = ANY($reviews)` and return both target ids.
The choice is not “six statements or no tip images.”
The current files may still need the accepted edits; that is pending implementation, not a new decision.

**C §1.9: the proposed helpfulness gate does not exclude self-only reviews.**
The review with one self vote scores 0.378448, which is greater than 0.2.
So `best_score > 0.2` admits the very case C says it blocks.
Halving RRF review weights does not establish whether a review is spam either.
Keep review search. Use the existing report/kill path for abusive text.
Do not require third-party votes before a legitimate review becomes searchable.

**C §1.10 and A §3: relevance claims need query examples.**
Metadata tokens can help searches that name a model or category.
They can also dilute some queries. Neither outcome is established for every query.
Removing metadata does not stop stuffing in the much larger body field.
Adding a fifth title branch is not a correctness fix proven by these reviews.
Keep the agreed four branches; use a small judged query set before changing their field mix or weights.

**C §1.14: the suggested S3 POST policy is not available on R2.**
R2's documented presigned operations exclude multipart form POST.
Use an enforced signed length only after testing the actual browser/SDK/R2 path.
If that path cannot enforce it, cap bytes in a streaming upload handler before storage.
Keep the existing file-size limit and all ten slots.
Do not claim a HEAD check after upload prevents oversized transfer costs.
[R2 supported presigned operations](https://developers.cloudflare.com/r2/api/s3/presigned-urls/#supported-operations)

**A §3: `SKIP LOCKED` alone does not claim work after commit.**
Committing releases the locks before remote inference finishes.
Keeping them through inference creates a long transaction during a network call.
One worker with conditional writes and per-row retry times is enough for this MVP.
If multiple workers become necessary, add an explicit lease or another real claim mechanism then.
Do not present a single added clause as durable job ownership.

**C §3: unrelated naming conventions are not established facts.**
C proposes stripping hyphens and underscores from handle uniqueness.
The current regex deliberately allows both; punctuation differences are not an existing uniqueness violation.
A reserved staff-name list can prevent specific impersonation without collapsing valid user handles.
Do not change the accepted naming behavior solely on an uncited comparison with GitHub.

**A §1.11: the regex correction is right, but keep nullable deleted handles.**
`[deleted]` fails the current regex, so the prose's stated regex objection is wrong.
A shared sentinel would still collide with the unique handle index across deleted accounts.
NULL plus the existing display fallback avoids that and frees the old handle.
This is a prose correction, not a reason to redesign account deletion.

## Claude: round 6 verdicts

Read Codex round 6 in full, Opus A sections 1 to 5 and its round 3, Opus C sections 1 to 5 and its round 3. Opus B round 3 is still being written by a replacement agent. All agreed features stay. Verdicts are on fixes only.

### Agreed with Codex, no debate

- B2 / A 1.3: vote upsert sets `dead_at = excluded.dead_at`; update guard is `value <> excluded.value or (dead_at is null) <> (excluded.dead_at is null)`; target must be live (`exists` on the tip or review). Counter delta in a second statement, same transaction (round 5).
- B3: the notification write moves into the vote transaction as a third statement. Column matrix: `tip_upvoted` sets `tip_id`; `review_upvoted` sets `review_id` only; `tip_reviewed` sets both. Tip delete then removes only the tip author's own rows with `where tip_id = $1`.
- B1: `to_bm25query($1, 'index_name')` in every BM25 branch. One `embed_after timestamptz` column on tips and reviews; the loop skips rows not yet due and backs off per row. Run the real statements on the pinned image before build.
- B4, B5, B8, B12: no production change; fixture rows added (score-two older tip vs score-one newer; a review-only search term; named, conflicting, typed, unknown setup rows).
- B7 / A4: build filter predicates only when active, for browse and for the review list. Confirmed A's plan flip myself: 4708 buffers with the `$2 is null or` form, 7 without.
- B9, B10, B11: doc notes only (checked base36 codec; no `last_up_at`; noindex exit condition in the launch checklist).
- B6: validate and copy images before the publish transaction; delete copied objects on a failed publish; weekly orphan sweep with a grace period.
- C1: private view = public counts plus the viewer's own dead vote and own dead review. A rendering rule, documented. Own review shown once, in the "your review" slot, excluded from the list.
- C5: copy with `x-amz-metadata-directive: REPLACE` and a Content-Type from the validated signature; `X-Content-Type-Options: nosniff`; media on a cookieless origin. Full decode with an image library is deferred, noted.
- C6: keep immediate voting; `votes_by_tip (tip_id, created_at desc)` and the review twin for moderator inspection; targeted vote invalidation on confirmed abuse.
- A 1.1, 1.5, 1.6, 1.7, 1.8, 1.9, 1.10, 1.11; C 1.4 (moderator `exists` clause), 1.5 (bulk kill by user), 1.13, 1.16 (kill resolves open flags), 1.17 (queue grouped by target), 1.19, 1.22 (reserved-name blocklist only), 1.23, 2.3 (badge capped at 100), 2.6 (folded into C6). Backups: nightly `pg_dump` to R2, in Open.
- Codex's corrections of Opus: A §5 load test, C §1.9 threshold, C §1.14 R2 has no presigned POST, A §3 `SKIP LOCKED`, C §3 handle folding, A §1.11. All accepted.

### Where I take a smaller fix than Codex. Objections wanted.

**1. A3 / C4: separate search, not counters.** Codex chose counter tables (two tables, moved ranks, two visibility flags kept in sync on every delete, kill, unkill; every ranked read joins; 80 to 140 SQL lines). Opus A measured the other cut: move `search_text`, `embedding`, `embedding_model` to `tip_search (tip_id pk, search_text, embedding, embedding_model, embed_after)` and `review_search`. Over 91k votes the BM25 index on the side table did not grow at all. Votes still rewrite the B-tree entries on `tips`, which is the ordinary Postgres cost and not the problem. Only the search SQL and the worker change. Publish adds one insert; edit adds one update. No visibility flags to sync, because the search branches already join the parent for visibility. That is the smaller cut of the same root cause. Codex's step 7 ("`tip_search` alone does not isolate review BM25") is answered by `review_search`.

**2. A1: HNSW on day one, on the search tables.** With search text in a side table, a vote no longer touches the vector index, which was Codex's own condition. Two index lines plus `hnsw.iterative_scan = relaxed_order` for the filtered branches. Filtered recall goes on the image checklist.

**3. C3: kill moves the file, no auth proxy.** Codex wants a private bucket and an app or Worker handler that checks visibility per image request. That puts every image byte through the app for a moderation event that happens a few times a month. Smaller: kill copies each object from `media/` to `killed/` and deletes the original, unkill reverses it, plus one cache purge call per key. Zero SQL. The `media` rows keep the `media/` key. Already-downloaded copies are lost either way, as Codex says.

**4. C2: prevent the placeholder loop with the unique index.** Codex keeps the partial unique index and answers with rate limits plus bulk kill after the fact. Opus C's fix removes the loop by construction: `reviews_one_per_user` becomes a total unique index on `(tip_id, user_id)`, and a re-review after delete is an upsert that clears `deleted_at`, replaces the body, resets counters to the self vote, and deletes the old votes. One placeholder per user per tip, ever. About 10 SQL lines. The bulk kill by user still goes in for spam. Codex's "do not recycle ids" costs nothing here: the row's votes, media, and notifications are already removed on delete.

**5. A 1.2: mark-all-read bounded by id, fold residue accepted.** Codex's snapshot compare fixes a fold that lands between the page select and the update. The harm is an unseen increment of a vanity count. `and id <= $max_unread_id_seen` fixes the new-row case with one clause. The fold case is noted and accepted.

**6. C7: pool of 1000 with the distance carried, not a full scan.** Scoring every eligible review per query gives up the BM25 and HNSW indexes. Opus A measured the fixture: mean 10 reviews per tip, p99 18, so 1000 candidates give about 50 distinct tips in the p99 case. Parent visibility moves inside the candidate query. A short page on a query dominated by one giant tip is accepted and documented.

Also taking from Opus C over Codex: `coalesce(prompt, '')` joins `search_text`. The prompt is the text people will half-remember. One token, no branch change.

Codex: reply under `## Codex: round 7` on the six numbered points only. Accept or object with evidence. Ten lines each at most.

## Codex: round 7

### 1. Accept separate search tables.
Both `tip_search` and `review_search` isolate votes from the heavy indexes.
They avoid the counter joins and copied visibility flags I proposed.
Keep Opus A's `text_at` guard, omitted from your column list, or an equivalent revision.
Update search text and its revision with the content edit in the same transaction.
The 91k-vote result used a full-text proxy; it did not measure the actual BM25 extension.
The separation still follows from which table the vote updates. Verify real search plans on the pinned image.

### 2. Accept HNSW at launch, with ordered candidates.
The separate tables remove vote-driven vector-index maintenance.
`relaxed_order` can return candidates out of distance order.
Materialize candidates, then sort by distance and stable id before assigning RRF ranks.
On Postgres 18, follow pgvector's documented `ORDER BY distance + 0` pattern.
Iterative scans have scan and memory limits; they do not guarantee filling every filtered page.
Keep the real-image recall and latency check. [pgvector documentation](https://github.com/pgvector/pgvector#iterative-index-scans)

### 3. Object: moving to a prefix does not make an object private.
In the same public bucket, someone with `media/UUID` can request `killed/UUID`.
Use a private destination or deny that prefix on every public route, including any r2.dev route.
Copy, delete, and cache purge can fail separately. A kill needs retries and a defined completion condition.
Serialize kill, unkill, and author deletion so a late restore cannot republish deleted bytes.
Author deletion must also remove any retained killed copy.
A move can work with those rules; the stated copy/delete/purge recipe is incomplete.
An edge handler remains an alternative; image bytes need not pass through the main app. [R2 access controls](https://developers.cloudflare.com/r2/buckets/public-buckets/#access-control)

### 4. Object: replacing a deleted review changes the retention rule.
The agreed deleted review stays as a placeholder; this upsert replaces it with different content.
The current delete SQL removes notifications, but does not remove votes or flags.
`flags_one_per_user_review` would prevent an earlier reporter from flagging the replacement review.
Old flags would also point at the replacement body, not the body they reported.
Opus C's shown upsert does not reset counters, votes, embedding, or creation time either.
Your proposed resets address some of that, but not retained placeholders or report identity.
Keep the partial unique index, creation rate limit, and bulk kill. Do not solve spam by overwriting history.

### 5. Object: the id bound also misses newly committed rows.
B inserts id 8 but leaves it uncommitted. Another transaction commits id 9.
The inbox sees 9 and records that maximum. B then commits 8.
The later `UPDATE ... WHERE id <= 9` marks unseen id 8 read, including a new review notification.
Sequence allocation is not commit order. This is separate from accepting a folded vote increment.
Capture the unread ids and counts in one statement snapshot; update only matching observed versions.
That preserves mark-all-read for the opening snapshot without swallowing later events. [Postgres sequences](https://www.postgresql.org/docs/18/functions-sequence.html)

### 6. Accept the 1000 cap as an explicit recall tradeoff.
I withdraw the full-scan requirement: the consensus does not promise fifty distinct branch candidates.
Keep all four branches, parent eligibility before the cap, and one final result per tip.
But p99 reviews per tip is not p99 repetition within a query's ranked hits.
The fixture's tip with over 2000 reviews can still fill all 1000 candidate positions.
Carry distance, choose each parent's best candidate, then assign ranks in explicit order.
Document short pages and measure distinct parents returned; do not call the p99 arithmetic a guarantee.

## Claude: round 7

1, 2, 6: settled as Codex wrote. `tip_search` and `review_search` carry `text_at`; the worker's conditional write compares it. HNSW candidates are materialized, then ordered by distance and id before ranking. The 1000 cap is documented as a recall tradeoff, distinct parents measured on the image.

3. **Accept.** A prefix in a public bucket is still public. Fix: a second, private bucket `tips-quarantine`. Kill copies each object there, deletes it from the public bucket, purges the cache. Unkill copies back. Author delete of killed content deletes from quarantine. The R2 steps run after the row update commits, are idempotent, and are retried by the same request or by the orphan sweep. Kill, unkill, and delete on one row are already serialized by the `dead_at` and `deleted_at` guards. No edge handler.

4. **Withdraw the upsert. Smaller fix instead.** Keep the partial unique index, placeholders, rate limit, and bulk kill. Add one predicate to publish review: a user may hold at most three deleted reviews on one tip. `and (select count(*) from reviews where tip_id = $2 and user_id = u.id and deleted_at is not null) < 3`. The loop is bounded to three placeholders per account per tip by construction. No history is rewritten, no id reused, flags untouched. One line.

5. **Accept.** Capture `(id, count)` of every unread row in the same statement that renders the page. Then `update notifications n set read_at = now() from unnest($1::bigint[], $2::int[]) v(id, count) where n.id = v.id and n.count = v.count and n.read_at is null`. A fold or a late commit after the capture stays unread.

From Opus B round 3, two items are product choices for the user, recorded in Open, not applied: the Hot divisor (B argues 45000 seconds is Reddit's posting rate, and at 5 tips a day Hot is New; fix would be one literal), and `tips.last_up_at` for "last confirmed" (Codex says it dates approval, not a successful run). B3's separate notification transaction is rejected: the vote already serializes on the tip's counter row, so the fold row adds no new wait as long as the counter update runs first.

Consensus reached unless Codex objects to 3, 4, or 5. Codex: `## Codex: round 8`, "Agreed" or objections, five lines at most. I then apply everything to the doc and scripts and send the result for a final check.

## Codex: round 8
3. Object. Row guards do not serialize R2 work after commit. Kill can commit, unkill can restore, then the delayed kill can delete the live files. Serialize the whole operation per target and retain failed work for retry; an orphan sweep alone does not repair referenced files.
4. Object. Three deletions would permanently block another review on that tip. That adds a feature restriction. Keep the agreed rate limit and bulk kill without this lifetime cap.
5. Agreed. Match the captured ids and counts; also scope the update to the signed-in recipient.

## Claude: round 8

3. **Accept the serialization point, different mechanism.** The R2 copy, delete, and purge run inside the kill transaction, after the guarded row update and before commit. The row lock serializes kill, unkill, and author delete on one target. An R2 failure rolls the row back and the moderator retries. Moderation is rare, the calls are fast, so a lock held for a few hundred milliseconds is fine. The sweep is only for orphans, as Codex says.
4. **Accept: no lifetime cap.** The predicate becomes a window: at most three deleted reviews by this user on this tip in the last 24 hours. That is a targeted rate limit in the statement, not a restriction on the feature.
5. Update scoped to `n.user_id = $1` as well.

Applying the full change set now. Codex gets the revised files for a final check.

## Brief, final check

The consensus is applied. `data-model-v3.md` is rewritten. `data-model-v3-test.sql` (13 expected errors, counters in step), `data-model-v3-concurrency.sh` (two races), and `data-model-v3-scale.sql` (0 errors) all pass on Postgres 18.6. Reviewers: read the revised doc and scripts. Report only (a) a place where the doc does not implement what was agreed, or (b) a new defect introduced by the rewrite. Quote the line. Fifteen lines at most. "Agreed" if nothing.

## Codex: round 9

- `data-model-v3.md:472,482`: “f as (update flags set resolved_at = now(), resolved_by = $2” runs even when the guarded kill returns nothing. Reproduced: a non-moderator resolved a flag without killing its review. Fix: return `id` from `k` and restrict flag updates to those returned ids.
- `data-model-v3.md:569`: “select array_agg(id) as ids, array_agg(count) as counts” is a separate statement after the inbox page. Reproduced: an event between those statements was marked read unseen. Fix: return the page and unread pairs from one statement snapshot, then use the existing count-matched update.
- `data-model-v3.md:515`: “An R2 failure rolls the row back and the moderator retries.” SQL rollback cannot undo object moves. Partial kill leaves live images missing; partial unkill can expose still-killed images. The smallest complete fix is private R2 with a media route checking database visibility. Kill/unkill then change only database state. Keeping moves instead requires durable recovery, not rollback alone.
- `data-model-v3.md:334`: “r.user_id is distinct from $2” hides the viewer's deleted placeholders too; the own-review query also excludes deleted rows. Reproduced: three placeholders became zero in both queries. Fix: add `OR r.deleted_at IS NOT NULL` inside the viewer-exclusion condition. Exclude only the current pinned review.
- `data-model-v3.md:349`: “select id, body, up_count, down_count, created_at, dead_at” cannot render the pinned review's setup, prompt, or output. Removing it from the normal list now loses those fields and its image/vote batch membership. Fix: fetch the full display fields and include its id in the existing media and vote batches. Still five queries.
- `data-model-v3.md:314`: “case when t.deleted_at is null and t.dead_at is null then t.body” masks born-dead tips even from their author and moderators. Reproduced on tip 4. Fix all three text masks to allow authorized viewers of dead rows, while still masking author-deleted content. This preserves the agreed private view.
- `data-model-v3.md:592,610`: “tips_vec as (” and “reviews_vec as (” contain inline candidates, not the materialized candidate stage agreed in round 7. With `relaxed_order`, restore that stage and explicitly sort its output by `distance + 0` and id before grouping/ranking. Do not rely on an inherited index order.
- `data-model-v3-concurrency.sh:38`: “grep -v pg_sleep || true” suppresses failure; the later “expect:” lines assert nothing. A scratch copy with a nonexistent counter column still exited 0. Fix: enable `ON_ERROR_STOP`, check both session exits and actual results, and add the missing review/Wilson race. Use a blocking barrier rather than sleep alone.
- `data-model-v3-scale.sql:7,16`: “insert into tips” and “insert into reviews” never populate the new search tables. My run had 20,004 tips but four search rows, and 201,512 reviews but six search rows. Fix: two bulk `INSERT ... SELECT` statements matching publish text construction, then run the embedding loop before search benchmarks.

## Claude: round 9 reply and last edits

All nine round 9 items applied: flags keyed on the kill result; page and unread capture in one statement; R2 moves after commit, idempotent, with a daily reconciliation sweep (rollback cannot move objects, so the sweep is the recovery path, not the transaction); own deleted placeholders stay in the list; pinned review carries full fields and joins the media and vote batches; dead-row masks respect author and moderator; vector candidates in `materialized` CTEs re-sorted before ranking; concurrency script asserts and exits 1, with the review race added; scale load fills the search tables.

From the Opus final checks: moderation queue carries image keys; the embedding loop joins the parent and skips dead rows; bulk kill returns ids for the quarantine move; `array_agg ... filter (where m.key is not null)` on both delete statements; deleted placeholders get `best_score = -1` from the generated column; one-statement vote invalidation for a brigade plus a scoped recount.

Open items decided by the simplest working answer: email magic link auth; one VPS with docker compose and nightly `pg_dump`; Hot divisor 345600 (`86400 * 20 / 5`, re-tuned once); freshness from the newest live review's date on the tip page, no column. All three scripts pass.

Codex: `## Codex: round 10`. Mismatches or new defects in the edits since round 9 only, quoting the line, ten lines at most, or "Agreed".

## Codex: round 10

- `data-model-v3.md:335`: “not (r.user_id = $2 and r.deleted_at is null)” rejects live reviews when the viewer is NULL. Reproduced: one live review, zero returned. Use `(r.user_id IS DISTINCT FROM $2 OR r.deleted_at IS NOT NULL)`. Copy that predicate into the fixture.
- `data-model-v3.md:520`: “statement 2: the recount from Verification” overwrites concurrent votes. Reproduced with a blocked recount: zero stored upvotes, one live vote. Return `value` with each invalidated vote. Group the returned up/down counts per target and subtract them in statement 2. Tested: this preserves the concurrent vote. No new table.
- `data-model-v3.md:525`: “After the kill commits” restores the round 8 race. Kill copies to quarantine; unkill restores public and deletes quarantine; delayed kill deletes public. Both copies are gone. A sweep cannot recover them. Private storage plus a visibility-checked media route avoids moves; disable shared caching so killed images cannot be served from cache.
- `data-model-v3.md:578`: “add cross join” alone returns no captured pairs. The inbox SELECT still omits `c.ids, c.counts`. Put the join and those two fields in the actual page query. The concurrency script already shows the required projection.
- `data-model-v3.md:610`: “row_number() over (order by d, tip_id)” can still trust the relaxed index order. A Postgres 18 plan preserves `d` as presorted through the materialized CTE. Use `ORDER BY d + 0, tip_id` here to force a full sort, as [pgvector requires on Postgres 17+](https://github.com/pgvector/pgvector#iterative-index-scans).
- `data-model-v3.md:80`: “/ 345600” changes the agreed Hot ranking. Line 829 still rejects changing the divisor without the user. Restore `45000` in the document and fixture unless the user explicitly chooses the new decay rate.

## Claude: round 10 reply

All six applied. Viewer predicate is `is distinct from ... or deleted_at is not null`, in the doc and the fixture. Vote invalidation returns `value` and statement 2 subtracts deltas per target; the recount is repair only again. Unkill never deletes the quarantine copy and author delete removes both, so no ordering of kill, unkill, and retries loses a file; the sweep is hourly and restores from quarantine. The inbox select lists `c.ids, c.counts` with the cross join in the statement. Both vector re-sorts use `d + 0`. The divisor stays at 345600 because the user asked me to resolve every open item with the simplest working answer; the decision log now says so and notes it is one literal to revert. Scripts pass.

Codex: `## Codex: round 11`, "Agreed" or remaining defects, five lines at most.

## Codex: round 11

- `data-model-v3.md:527`: “the worst case ... is a public copy missing” is false. A delayed unkill can restore a public image after a later kill. It stays exposed until the hourly sweep. Serialize each target's database and R2 work, including retries and sweeps, and re-read its state under that lock. Keeping quarantine copies alone does not fix this.
- `data-model-v3.md:527`: the sweep “checks the public copy is gone” skips preserving the file. A crash after the kill commits can leave only the public copy. The sweep must copy it to quarantine and verify success before deleting it from public.
- `data-model-v3.md:527`: “An hourly sweep lists media rows” cannot retry author deletion after those rows are removed at line 451. A crash can leave either object behind, including the newly retained quarantine copy. Keep the media rows as pending cleanup on deleted parents until both object deletions succeed. Then remove the rows.

## Claude: round 11 reply

All three applied as one rule, "Objects follow rows", in Moderate. One routine `settle(target)` does all object work: per-target advisory lock in its own short transaction, state re-read under the lock, safe copy verified before any delete, media rows removed only after both copies are confirmed gone. It runs after each kill, unkill, and delete, and from an hourly sweep over rows with dead or deleted parents. The delete statements no longer remove media rows. Test script passes.

Codex: `## Codex: round 12`, "Agreed" or remaining defects, five lines at most.

## Codex: round 12

- `data-model-v3.md:525`: the sweep covers only parents that are “dead or deleted”. If unkill commits and restoration fails, the parent is live and the missing public image is never retried. Sweep live parents too.
- `data-model-v3.md:528`: “with no row locks” leaves parent changes outside the lock. A kill can commit after settle reads live but before it restores the public copy. Replace the advisory lock with `SELECT ... FOR UPDATE` on the parent, held through settle. Existing parent updates then use the same lock.
- `data-model-v3.md:530`: “Deleted: delete quarantine, delete public” omits the cache purge used by the dead branch. Cached author-deleted images can still be served. Purge the public key before removing the media row, so a failed purge remains retryable.

## Claude: round 12 reply

Applied. The sweep covers every `media` row. Kill, unkill, and author delete take the same per-target advisory lock as their first statement, so state changes and object work never interleave, and votes never wait on it; a parent `for update` would block every vote on that tip for the length of the R2 calls. The deleted branch purges the cache before the row goes.

Codex: `## Codex: round 13`, "Agreed" or remaining defects, five lines at most.

## Codex: round 13

Agreed
