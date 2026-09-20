# Opus review A: database correctness

Reviewer viewpoint: transactional correctness, concurrency, constraint semantics, NULL handling, plans, and whether the scripts prove the claims.

Setup: Postgres 18.6 (Homebrew, arm64). Scratch database `tips_review_a` built from a copy of `data-model-v3-test.sql`. Scale checks run read-only against `tips_v3` (20004 tips, 201523 reviews, 595614 votes, 319858 notifications), with writes wrapped in `begin ... rollback`. pgvector and pg_textsearch are not installed, so search SQL was reviewed by reading and the vector cost was measured with a same-size TOASTed proxy column.

Each finding is marked **Reproduced** or **By reading**.

## What I tried to break and could not

Listing this first so nobody re-litigates it.

- **Vote counters under concurrency. Reproduced sound.** pgbench, 16 clients, 20 s, 173897 transactions mixing upvote / downvote / switch / remove across 300 users on one tip, 8702 tps, 0 failures. Final `up_count, down_count` = `106, 88`, actual live votes = `106, 88`. No drift. `returning old./new.` does what the doc claims.
- **Moderator kill racing an author delete of the same review. Reproduced sound.** Session A holds the kill open 3 s, session B deletes. Net `review_count` change is -1, not -2. Read-committed EPQ re-reads the row, so B's `returning ... dead_at` sees A's write and the guard `d.dead_at is null` correctly blocks the second decrement.
- **Two concurrent `publish_review` on one tip. Reproduced sound.** `review_count` = 2, live reviews = 2.
- **Notification fold racing mark-all-read. Reproduced sound.** The folding insert does not error and does not fold into a row that just became read; it inserts a fresh unread row. No lost count.

## 1. Correctness bugs

### 1.1 The tip-page review filters lose the index. Severity: high. Reproduced.

The design's own Pagination section says:

> A cursor written as `$1 is null or ...` loses the index under a generic plan.

The tip-page reviews query then does exactly that with the filters:

```sql
  and ($2::text is null or r.model_id = $2 or (r.model_id is null and r.model_other is null))
  and ($3::text is null or r.environment_id = $3 or r.environment_id is null)
```

On `tips_v3`, tip 1 (2003 live reviews), the query as written in the doc, prepared and executed repeatedly:

| execution | plan | buffers | time |
|---|---|---|---|
| 1st to 5th (custom plan) | `Index Scan using reviews_best` | 125 | 0.13 ms |
| 6th onward (generic plan) | `Bitmap Index Scan on reviews_new` + `Bitmap Heap Scan` + `Sort` over all 2003 rows | 6590 | 7.0 ms |

53x more buffers, and it flips silently on the sixth call of a prepared statement. The next page is the same story:

| next page after 1500 | plan | buffers | time |
|---|---|---|---|
| filters present, generic plan | Bitmap + top-N sort | 161 | 1.33 ms |
| filters removed from the SQL | `Index Only Scan using reviews_best`, cursor in the Index Cond | 4 | 0.05 ms |

40x. "Page 1 and page 1000 cost the same" stops being true.

Smallest fix: apply the rule the doc already states. Build the filter clause into the SQL string only when the filter is set, the same way `and t.tag_id = $3` is handled on Browse. Three statements, or one string append. Do not use `$n is null or`.

Second-order: the same query also shows up in the verification table as "Tip with 2004 reviews, Best, first page | 90 | 0.18 ms". The scale script runs it **without** the two filters. See 2.6.

### 1.2 Opening the inbox marks unseen notifications read. Severity: high. Reproduced.

The inbox is a select followed by:

```sql
update notifications set read_at = now() where user_id = $1 and read_at is null;
```

There is no bound. Anything that arrives between the select and the update is marked read and never shown, and the badge goes to zero.

Reproduced with two sessions. Session A selects the inbox (one row, id 8), waits, then marks all read. Session B folds a new `review_upvoted` notification (id 9) in the gap. Result:

```
 id |      type      | count | isread
  8 | tip_upvoted    |     1 | t
  9 | review_upvoted |     1 | t      <- never rendered
 badge = 0
```

Smallest fix: bound the update by what was shown.

```sql
update notifications set read_at = now() where user_id = $1 and read_at is null and id <= $2;
```

with `$2` the largest id from the page just selected. Run both in one transaction.

### 1.3 A vote cast while shadow-banned stays dead forever. Severity: medium. Reproduced.

```sql
do update set value = excluded.value, dead_at = coalesce(votes.dead_at, excluded.dead_at)
where votes.value <> excluded.value
```

`coalesce(votes.dead_at, ...)` is a one-way latch. Once a vote row is dead it can never become live again. The doc says this is intended for a born-dead self vote after an unkill. It is not stated for the case where a moderator lifts a shadow ban, and there is no statement anywhere that repairs it.

Reproduced. Shadow-banned user upvotes tip 15, vote is born dead, `up_count` stays 1. Ban lifted. User switches to down, then back to up. Vote is still `dead = t`, `up_count` still 1. The user's vote never counts again on that tip. The only escape is the remove-then-vote path, which drops the latch by deleting the row.

Also note `where votes.value <> excluded.value`: if the unbanned user re-votes the same value, the update does not fire at all.

Smallest fix, verified on the scratch database:

```sql
do update set value = excluded.value, dead_at = excluded.dead_at
where votes.value <> excluded.value
   or (votes.dead_at is null) <> (excluded.dead_at is null)
```

`excluded.dead_at` already carries the voter's current shadow state, so plain assignment is both simpler than `coalesce` and correct in every direction. Verified: shadow vote stays uncounted; after unban the same-value vote revives and `up_count` goes 1 to 2; after re-banning it goes back to 1; a true no-op still returns 0 rows.

### 1.4 The review BM25 branch recomputes `<@>` where no index exists. Severity: high for search. By reading.

```sql
reviews_bm25 as (
  select tip_id, review_id, row_number() over (order by d) as rank from (
    select distinct on (r.tip_id) r.tip_id, r.id as review_id, r.body <@> (select text from q) as d
    from (select id, tip_id, body from reviews where deleted_at is null and dead_at is null
          order by body <@> (select text from q) limit 200) r
    ...
```

The inner subquery returns `body` and throws the score away. The outer query then applies `r.body <@> q` again, this time to the output of a subquery, where there is no BM25 index to scan. pg_textsearch's `<@>` is an index-backed ranking operator, not a general scoring function. This will either error out or fall back to something unusable. The doc's own Open list already asks whether `<@>` takes a bare text argument at all or needs `to_bm25query($1, 'reviews_bm25')`; that question applies twice here.

Smallest fix: carry the distance out of the inner subquery and never recompute it.

```sql
from (select id, tip_id, body <@> to_bm25query('reviews_bm25', (select text from q)) as d
      from reviews where deleted_at is null and dead_at is null order by d limit 200) r
```

Two more problems in the same four CTEs:

- `row_number() over (order by search_text <@> q)` is computed over the whole filtered relation before `limit 50` is applied. Whether the planner can stream an ordered BM25 index scan into the WindowAgg and let the Limit stop early is unknown and untested. The standard RRF shape avoids the question: `select id, row_number() over () as rank from (select id from tips where ... order by ... limit 50) s`. Same result, guaranteed top-k.
- The two review branches end with `... from (...) x limit 50` with no `order by` on the outer select. Which 50 rows survive is not defined by the language. It happens to work because the WindowAgg emits in window order. Add `order by rank`.

### 1.5 `select t.*` on the tip page ships the body twice plus the vector. Severity: medium. Reproduced (column list).

```sql
select t.*, coalesce(u.handle, '[deleted]') as handle from tips t join users u on u.id = t.user_id
```

`t.*` on `tips` is: `id, user_id, title, body, tag_id, model_id, model_other, environment_id, prompt, output, up_count, down_count, review_count, score, hot_score, search_text, embedding_model, created_at, edited_at, deleted_at, dead_at` — plus `embedding vector(1024)` in production.

`search_text` is a generated copy of `title || body || model || tag`. So every tip page transfers the body twice, and 4 KB of float32 that the page never uses. A 20 KB tip becomes a ~44 KB row over the wire. Smallest fix: name the columns, the same as every other query in the doc does.

### 1.6 Author delete does not delete `media` rows. Severity: low. By reading.

Prose: "Notifications about the row are deleted. R2 files are deleted." The SQL deletes notifications and nothing else. The `media` rows survive, pointing at object keys that no longer exist in R2. Nothing serves them today because a deleted tip hides its images, but the row and the R2 object are now out of step and the "eleven images" slot constraint still counts them if the row is ever undeleted.

Smallest fix: add `delete from media where tip_id = $1;` (and the review variant) to the same transaction, after the app has collected the keys for the R2 delete.

### 1.7 `publish_review` does not check the parent tip. Severity: low. Reproduced.

```sql
t as (update tips set review_count = review_count + 1 from r where tips.id = r.tip_id and r.dead_at is null)
```

The guard is on the review's liveness, not the tip's. Reproduced: inserted a tip with `deleted_at` set, ran the publish-review statement against it, `review_count` went 0 to 1 on an author-deleted tip. The same holds for a moderator-killed tip. Only the app's own check stands between a user and a review on dead content.

Smallest fix: put the tip in the CTE and guard there.

```sql
with u as (...),
     p as (select id from tips where id = $2 and deleted_at is null and dead_at is null),
     r as (insert into reviews (...) select p.id, u.id, ... from u, p returning ...)
```

### 1.8 The recount repairs half of what the check tests. Severity: low. By reading.

The `do` block in the test checks tip counters **and** review counters. The recount statement in Verification updates `tips` only, and only `from (select id from tips where dead_at is null) x`. So:

- `reviews.up_count` / `reviews.down_count` have no repair path at all. If they ever drift, `best_score` is wrong forever.
- A killed tip's counters are never repaired, so an unkill restores a stale score.

Also worth knowing the failure mode of a drift: `tips_counts_chk check (up_count >= 0 ...)`. If a counter drifts low, the next remove-vote drives it to -1 and the statement aborts. The user gets a 500 on every unvote until somebody runs the recount by hand. There is no job.

Smallest fix: add the mirror recount for reviews, and drop the `dead_at is null` restriction from the tips one.

### 1.9 `flags` resolve has no guard. Severity: low. By reading.

```sql
update flags set resolved_at = now(), resolved_by = $2 where id = $1;
```

Every other moderator statement in the doc is guarded so that a repeat is a no-op. This one is not. A second moderator clicking resolve overwrites `resolved_by` and `resolved_at`. Add `and resolved_at is null`, consistent with the kill and unkill statements.

### 1.10 `notifications.type` breaks the design's own rule 5. Severity: low. By reading.

Rule 5: "Lists we control are domains." `user_role`, `ban_status` and `flag_reason` are domains. `type text not null, -- the app validates` is not. It is a list of exactly three values that the project controls. One line:

```sql
create domain notification_type as text check (value in ('tip_upvoted','review_upvoted','tip_reviewed'));
```

### 1.11 The stated reason for the nullable handle is wrong. Severity: none, but fix the prose. Reproduced.

> A placeholder handle would need a value no live user can register, and the handle check cannot promise that.

`users_handle_chk check (handle ~ '^[A-Za-z0-9][A-Za-z0-9_-]{1,30}$')` anchors the first character to alphanumeric. Checked: `'[deleted]' ~ '^[A-Za-z0-9][A-Za-z0-9_-]{1,30}$'` is **false**, `'deleted'` is true. The constraint already guarantees any bracketed sentinel is unreachable. The nullable design is still fine and `coalesce` is already everywhere, so do not change the schema. Just drop the sentence, or note that account deletion also frees the handle and email for immediate re-registration, which is the real consequence and is not mentioned anywhere.

## 2. Performance risks before 1M rows

### 2.1 Every vote is a non-HOT update on `tips`, and one BM25 index insert per vote

`hot_score` and `score` are stored generated columns, and `tips_hot` indexes `hot_score`. Both change on every vote. So no vote can ever be a HOT update, and each one inserts a new tuple into **every** index on `tips` — including `tips_bm25`, whose entry is a tokenized copy of `search_text`, which contains the whole body, up to 20 KB.

Measured on the scratch database, 13 live tips, 236953 vote updates from the pgbench run:

| stat | value |
|---|---|
| `n_tup_hot_upd / n_tup_upd` | 4.6 % |
| `tips_hot` size | 7152 kB |
| `tips_ft` (GIN on `search_text`, proxy for `tips_bm25`) | 4552 kB |
| `tips_new` (key never changes) | 48 kB |
| live rows | 13 |

`tips_new` stayed at 48 kB because its key never moves, so vacuum reclaims into the same pages. `tips_hot` grew to 7 MB for thirteen rows because every vote writes a new key. The full-text index grew to 4.5 MB from pure churn, even though the indexed text never changed once.

Throughput impact was small in this test: adding the GIN index cost 4 % of vote tps (9368 to 8965), because GIN has a pending list. pg_textsearch BM25 may not, and the write path re-tokenizes an up-to-20 KB body on each vote. **Measure this on the timescaledb-ha image before shipping.** If it costs anything, the fix is the one Discourse uses: keep search text in a side table (`post_search_data`, `topic_search_data`) so the hot-write row and the search-indexed row are different rows.

Cheapest version of that fix here: move `search_text` to `tip_search (tip_id bigint primary key references tips(id), text text not null)` and put `tips_bm25` on that. Votes then stop touching the BM25 index, and the `tips` heap stops storing a second copy of every body.

### 2.2 The vector branches with no index are worse than the doc's estimate

A `vector(1024)` is 4104 bytes. That is above the ~2 KB TOAST threshold and float32 does not compress, so every embedding lives out of line. An exact scan has to detoast every row.

Measured with a 4128-byte incompressible text column, all in cache:

| rows | TOAST size | scan reading the column | same scan not reading it |
|---|---|---|---|
| 20000 | 104 MB | 66797 buffers, 115 ms | 128 buffers, 0.8 ms |

That is just reading the bytes, before any distance math. Scaling the doc's own fixture:

- `tips_vec` over 20k live tips: ~104 MB, ~115 ms.
- `reviews_vec` over 200k live reviews: ~825 MB, ~1.1 s.

Both run in the same search statement, and `statement_timeout = '2s'` is set on the app role. One concurrent search is already marginal; two are not.

The doc says "At 1024 floats a row, 50k rows is about 200 MB per query, which is the point to add an HNSW index." That counts tips only, ignores reviews, and ignores detoast. The real crossover is well under 20k rows once reviews are embedded. Either ship HNSW from the first day or cut the vector branches (see section 4).

### 2.3 Browse filters cost far more than the doc's 8x, and can lose the index

On `tips_v3`, 20k tips, first page of Hot:

| filters | plan | buffers |
|---|---|---|
| none (doc's number) | Index Scan `tips_hot` | 60 |
| `tag_id` + `model_id` | Index Scan `tips_hot`, 438 rows removed | 461 |
| `tag_id` + `model_id` + `environment_id` | Index Scan `tips_hot`, 2539 rows removed | 2557 |

42x for three filters, not 8x. The doc only measured one tag filter.

Worse, a narrow filter on a later page drops the ordered scan. For `cost-speed` + `gpt-5` + `chatgpt` (159 matching tips), the last page plans as `Bitmap Index Scan on tips_hot` + `Bitmap Heap Scan` + `Sort`, 528 buffers to return 18 rows. At 1M tips that bitmap covers a much larger slice of the index and the sort is no longer free.

Fix, if the filter dropdowns are a real feature: `create index tips_hot_by_tag on tips (tag_id, hot_score desc, id desc) where deleted_at is null and dead_at is null`. That covers the common case (tag is the curated axis, 8 values). Do not index all three combinations.

### 2.4 Mark-all-read spends 44 % of its time on foreign keys it does not change

Measured on `tips_v3`, one user with 20000 unread, inside a rolled-back transaction:

```
Update on notifications (actual time=185.984..185.984)
  Buffers: shared hit=281626 dirtied=403 written=401
  ->  Bitmap Heap Scan (rows=20000) Buffers: shared hit=272
Trigger for constraint notifications_user_id_fkey:   time=48.859 calls=20000
Trigger for constraint notifications_actor_id_fkey:  time=45.584 calls=20000
Trigger for constraint notifications_tip_id_fkey:    time=52.458 calls=20000
Execution Time: 335.223 ms
```

335 ms, 281626 buffer hits for 20000 rows (14 per row, because the update is non-HOT across six indexes), and 147 ms of that is RI trigger overhead on three columns the statement never touches. This runs on every inbox open. At 100k unread it crosses `statement_timeout = '2s'`.

Fix, and it also fixes correctness bug 1.2: bound the update by the last id shown, and cap the badge.

```sql
select count(*) from (select 1 from notifications where user_id = $1 and read_at is null limit 100) x;
```

GitHub and Reddit both show a capped badge. Nobody needs an exact 20000.

### 2.5 The review page ships up to 1.2 MB

The Best page selects `r.prompt, r.output` for 30 reviews. Both are capped at 20000 characters. Worst case is 1.2 MB of text for one page fold. Truncate server-side or fetch prompt/output on expand.

### 2.6 What the scripts do not prove

- **No concurrency test at all.** Every claim about counters not drifting is single-session. I ran the concurrency tests separately and the design holds (see the section above), but the scripts do not establish it, and any future change to the vote statement will not be caught.
- **The test script's plan section is decoration.** It runs `set enable_seqscan = off;` first, on a 12-row fixture. With the default setting, the same browse-hot-next plan on the same fixture is `Sort -> Merge Join -> Bitmap Heap Scan on tips`, not the index scan the script prints. Those four EXPLAINs prove nothing. The scale script's plans are the real evidence; delete the test script's.
- **The scale script benchmarks different SQL than the design.** The tip-page reviews query is run without its two `($n::text is null or ...)` filters, which is exactly the thing that breaks (1.1). The profile-reviews query filters `r.dead_at is null`, while the design filters `r.deleted_at is null and ($2 or r.dead_at is null)` — different predicate, different index match.
- **The tip page's own images are never fetched.** The query-count table says "Tip page | 5", and lists media only for reviews. There is no `select ... from media where tip_id = $1`. Either it is 6 statements or tip images do not render.
- **Search is entirely unverified.** Neither extension is installed here or on the author's machine. Four CTEs, two index definitions, the operator syntax, and the whole hybrid path are unrun.
- **Untested behaviours that matter:** deleting a review then posting a new one on the same tip (the partial unique index allows it, the counters should net to zero); removing a vote on a review; the image edit path (delete and re-insert `media` rows under `media_key_unique`); an account deletion followed by someone registering the freed handle and email.

## 3. Invented conventions

| Invented thing | Industry standard that could replace it | Recommendation |
|---|---|---|
| `search_text` as a stored generated column on `tips`, with `tips_bm25` on it | Search text in its own table keyed by the parent id: Discourse `post_search_data` / `topic_search_data` | Move it. Halves the `tips` heap and takes the BM25 index off the vote write path (2.1). |
| Counters + generated ranking on the same row as the searched text and the vector | Same split, or Reddit-style counters in a side store | At minimum, measure BM25 index write cost on the real image before shipping. |
| Wilson lower bound written inline, `1.281551565545` repeated six times | One `immutable` SQL function, as in Evan Miller's essay and every implementation of it | `create function wilson_lb(up int, down int) returns double precision language sql immutable`; the generated column then reads `wilson_lb(up_count, down_count)`. One place to change z, and testable. Also fix the comment: Φ(1.281551565545) = 0.90, so this is a **one-sided 90 % lower bound** (80 % two-sided interval). "z = 1.28 (80%)" reads as a one-sided 80 %. |
| `notifications.type text not null -- the app validates` | The design's own rule 5 | `create domain notification_type`. One line. |
| Fold key as 4 columns plus `nulls not distinct` | A single `group_key`/`dedupe_key` text column: Rails Noticed, Discourse | Either works. The 4-column form breaks the first time a notification type has a target shape that is not (tip, review). Not urgent. |
| Badge as an exact `count(*)` of unread rows on every page load | Capped count, "99+": GitHub, Reddit, Instagram | Cap it at 100. Free, and it pairs with the mark-all-read fix. |
| Mark-all-read as an unbounded per-row UPDATE on inbox open | Same pattern, bounded by the last item shown | Bound by id. Fixes 1.2 and 2.4 together. |
| `row_number() over (order by <col> <@> q)` then `limit 50` | `row_number() over ()` over an already-limited subquery — the standard RRF shape | Change it. It is also the only form that reliably keeps the top-k index scan. |
| BM25 over one flat concatenated field | Field weighting: tsvector `setweight`, BM25F, or separate title and body indexes fused | A title match currently scores the same as a body match. Cheapest fix inside the existing design: add a fifth RRF branch on the title. |
| Embedding worker takes 50 rows from an index with no claim | `select ... for update skip locked`, the standard Postgres queue idiom | One clause. Lets you ever run two workers, and survives an overlapping restart. |
| Model switch = "set every `embedding` to null" | A new column, or a versioned embeddings side table | A 220k-row UPDATE on the hot table, each row non-HOT across every index including BM25, plus TOAST churn. Put embeddings in `tip_embeddings (tip_id, model, vec)` and the switch becomes an insert plus a delete. |
| `epoch_of()` immutable wrapper for a generated column | Same trick is common in the wild | Keep. `extract(epoch from timestamptz)` really is immutable. Add a comment that the argument type must stay `timestamptz`; on plain `timestamp` this function would be lying. |
| Base36 id + slug, two hide markers, 2-hour edits, one review per user, ±1 votes, keyset pagination, presigned PUT with ETag, RRF k=60, classic Reddit hot | Reddit, HN, Yelp, Discourse, Cormack et al. 2009 | All check out against the cited sources. Keep. |

## 4. Cut list

- **Cut the vector half of search for v1.** It buys: an embedding server, a background job, a retry loop, a model-switch procedure, 4 KB per row of out-of-line storage, and 115 ms of pure detoast per 20k rows per query (2.2). It costs correctness risk in 1.4 and the largest unverified surface in the design. BM25 alone is a complete search feature for a corpus of short English prompting tips. Bring vectors back when "search does not find X" is a top complaint and there is traffic to tune against.
- **If vectors stay, cut `reviews.embedding` first.** Reviews are 10x the rows and the branch is collapsed to one hit per tip anyway, so it contributes the least per byte scanned.
- **Cut `search_text` as a stored column** in favour of `tip_search`. This is the highest-leverage structural change in the whole design (2.1).
- **Defer the model and environment filter dropdowns on Browse.** They are what breaks the keyset claim (2.3), and on a young corpus with 4 models they partition almost nothing. Keep the tag filter, and give it its own index.
- **Defer `prompt` and `output` on `reviews`.** Same fields as the parent tip, rarely filled, and they are what makes a review page up to 1.2 MB (2.5). The review body already allows 20000 characters.
- **Keep** the three domains, the three `num_nonnulls(...) = 1` child tables, the media position/slot rule, `flags`, the two hide markers, and keyset pagination. All of these are cheap and match a named precedent.
- **Add, do not cut:** a recount for `reviews` (1.8), and a scheduled or on-call invocation of both. A drift today turns into 500s on unvote and nobody would know why.

## 5. Verdict

**Ship with fixes.** The core is sound and I could not break it where it matters most: the vote path held 174k concurrent transactions with zero counter drift, and the kill/delete/unkill guards survive every interleaving I threw at them. The generated-column approach to ranking does what it claims. Five things must change before the build starts. Two are a few characters each: bound the mark-all-read update by the last id shown (1.2), and replace `coalesce(votes.dead_at, excluded.dead_at)` with `excluded.dead_at` plus a liveness clause in the conflict guard (1.3). One is a code-shape rule the doc already wrote down and then broke: build the tip-page review filters into the SQL string instead of `$n is null or`, which is a 53x plan difference that only appears on the sixth execution and would be invisible in any single-shot test (1.1). One is the search SQL, which has a real bug in the review BM25 branch and has never been run at all; that whole path needs an afternoon on the Docker image before anyone relies on it (1.4). The last is a judgement call: the vector branches cost roughly a second of pure detoast at the fixture's own scale against a 2 s statement timeout, so either add HNSW on day one or ship BM25 only and add vectors when there is traffic to justify them. Everything else here can wait.

## Round 3: root causes and fixes that keep the feature

Every cut in section 4 is withdrawn. Below, for A1 to A5: the why chain, the root cause, the fix that keeps the feature exactly as decided, and the cost.

New measurements in this round were run on `tips_review_a2`, a `createdb -T tips_v3` clone (20004 tips, 201523 reviews). `tips_v3` was not touched. Both scratch databases were dropped afterwards.

The five items are not five problems. A1, A2 and A3 share one root cause, and A4 is that same root cause pushing on the read side. A5 is separate.

### A1. Vector search with no index

Symptom: the vector branches read every live embedding; ~1.1 s for 200k reviews against a 2 s statement timeout.

1. Why slow? The branch reads every live row's embedding.
2. Why every row? No vector index, so it is a scan plus a sort.
3. Why no index? The doc says exact search is fine until about 50k embedded rows.
4. Why did 50k look safe? The estimate was 1024 floats x rows = bytes, and assumed bytes read is the cost.
5. Why is that wrong? A `vector(1024)` is 4104 bytes, above the ~2 KB TOAST threshold, so each one is a separate out-of-line fetch.
6. Why does that change the cost? Measured: 20k rows of that size cost 66797 buffer lookups and 115 ms fully cached. The cost is per-row chunk lookups, not bandwidth.
7. Why can't the scan skip rows? Every candidate must be detoasted and compared. Nothing lets you skip one.
8. Why can nothing skip one? Nothing in the table orders rows by distance to this query.
9. Why does nothing order them? An ordering by an arbitrary query vector exists only inside an approximate-nearest-neighbour index.
10. Why was the ANN index deferred? It was treated as a scale-time optimisation with a build cost, memory cost and recall cost.
11. Why is that framing wrong? At MVP row counts the build takes seconds and tens of MB. The cost of having it is near zero at small N.
12. Why is the cost of not having it not near zero at small N? Because the scan is O(N) per query from the very first query, while HNSW is O(log N) from the very first query. The two are not "the same algorithm, one tuned".
13. **Root cause: the design treated the ANN index as an optimisation of vector search. For vector search the index is the algorithm. A sequential scan is not the simple version of the feature; it is a different, linear algorithm that happens to give the same answer.**

Fix, keeping hybrid search exactly as decided: build the index on day one instead of at 50k rows.

```sql
create index tips_hnsw    on tip_search    using hnsw (embedding vector_cosine_ops);
create index reviews_hnsw on review_search using hnsw (embedding vector_cosine_ops);
```

Two supporting points, both one line:

- Liveness and the tag/model/environment filters are post-filters on an ANN result, so a filtered query can under-return. pgvector 0.8 solves this: `set hnsw.iterative_scan = 'relaxed_order';` in the search session. Verified as a plan shape below (A3): an ordered index scan feeding a nested loop to `tips` with the liveness filter, with the Limit stopping early, fetched 52 rows to emit 50.
- The embedding worker takes rows with no claim. Add `for update skip locked` so an overlapping restart does not embed the same rows twice.

Cost: 2 `create index` lines, 1 session GUC, 1 clause in the worker's select. `maintenance_work_mem` raised for the initial build. No schema change, no feature change, no app change. The index must exist from the first row so it grows incrementally; adding it later means a multi-minute build on a live box.

Note: A1's fix makes A3's fix mandatory, not optional. See A3.

### A2. `reviews.embedding` and the review branches

Symptom: reviews are 10x the rows and the branch collapses 200 candidates to one hit per tip.

1. Why did the branch look wasteful? It ranks 200 reviews to emit up to 50 tips.
2. Why 200 for 50? Because the collapse to one review per tip happens after the top-k.
3. Why after? Because the index ranks reviews, and the feature wants tips.
4. Why can't the index rank tips? "Best review for this query" depends on the query, so it cannot be precomputed.
5. So over-fetch is inherent. Why is 200 the right amount of over-fetch? It is not derived anywhere.
6. Why does the amount matter? Because the yield is pool size divided by reviews per matching tip.
7. What is that divisor? Measured on the fixture: mean 10.07 reviews per tip, p99 18, max 2003.
8. So what does a pool of 200 actually yield? About 20 distinct tips on average, not 50. The branch under-delivers by 60% before any pathological case.
9. Why is the pathological case worse? A query matching the vocabulary of the 2003-review tip can fill all 200 slots from that one tip and yield 1 result. (Same as C7.)
10. Why was 200 not raised? Because a bigger pool looked expensive.
11. Why did it look expensive? Because the inner subquery selects `body`: `select id, tip_id, body from reviews ... limit 200`. At 20000 characters a body, a 200-row pool is up to 4 MB materialised, and 1000 rows would be 20 MB.
12. Why does it select `body`? Because the outer query recomputes `r.body <@> q` instead of carrying the score out. That is bug 1.4.
13. **Root cause: the branch materialises the wrong payload. It carries 20 KB bodies it does not need, which made the pool look costly, which froze the pool at a size that cannot deliver the 50 tips the feature asks for. The recall problem and the cost problem are the same bug.**

Fix, keeping review vectors and review BM25 as decided:

- Carry the score, drop the body. The pool row becomes `(review_id, tip_id, d)` — about 24 bytes, not 20 KB.
- Raise the pool from 200 to 1000. Derived, not guessed: 50 tips x p99 of 18 reviews per tip = 900.

At 24 bytes a row, a 1000-row pool is 24 KB — a hundred and sixty times less memory than today's 200-row pool of bodies. The collapse sort runs over 1000 materialised rows, about 1 ms. With the HNSW and BM25 indexes from A1, fetching k=1000 instead of k=50 is logarithmic in N, not linear.

Cost: one column removed from two inner subqueries, one constant changed from 200 to 1000 in two places, and the `<@>` / `<=>` expression moved into the inner select so it is computed once. About 6 lines edited across the two review CTEs. No schema change. `reviews.embedding` stays.

### A3. Stored `search_text` on `tips`

Symptom: every vote rewrites the tip's BM25 index entry.

1. Why? A vote UPDATEs `tips`, and the update is non-HOT.
2. Why non-HOT? HOT requires that no indexed column changes.
3. Which one changes? `hot_score` and `score`, both indexed by `tips_hot`.
4. Why are they indexed? Because Hot is the front page and must be one index scan. Decided; stays.
5. Why does a non-HOT update touch the BM25 index, whose column did not change? Postgres writes a new heap tuple at a new TID, and every index must point at the new TID.
6. Why must every index follow? Index entries store the TID, not a row identity. A moved row is re-pointed everywhere. There is no per-index skip.
7. Can the row stay put instead? Only under HOT, which requires step 3 to be false. It is not.
8. Can `tips_hot` be made HOT-friendly? No. An index on a value that changes must be updated when it changes.
9. So is the problem the vote, or the index? Neither alone. It is that they share a tuple.
10. Why do they share a tuple? `search_text` is a generated column of `tips`, and `embedding` is a column of `tips`.
11. Why generated columns? Rule 3: generated columns cannot drift and need no trigger. A correctness argument.
12. Why did the cost stay invisible? Because "cannot drift" is reasoning about values, and write amplification is a consequence of physical tuple layout. Value-level reasoning never surfaces it.
13. Why does it matter more after A1? Because HNSW then becomes one of the indexes that must follow. An HNSW insert does `ef_construction` (default 64) distance computations at 1024 dimensions plus graph page writes — on the order of 0.1 to 1 ms, against a current whole-vote latency of 0.5 to 0.8 ms. One per vote, forever, with graph quality degrading as dead entries accumulate.
14. **Root cause: `tips` is simultaneously the fastest-changing row in the system (one update per vote) and the carrier of the heaviest indexes (BM25, and after A1, HNSW). Postgres's tuple model multiplies write frequency by index weight. The design put the fastest-moving value and the most expensive index on the same tuple.**

That cause is not "the feature exists". Both features stay. They must not share a tuple.

Fix: move the two heavy, rarely-changing, index-backed columns off the hot row. Move the text, not the counters — the counters are read by the front page on every request and must not gain a join.

```sql
create table tip_search (
  tip_id          bigint primary key references tips(id),
  text            text not null,
  text_at         timestamptz not null default now(),
  embedding       vector(1024),
  embedding_model text
);
-- review_search is the same five columns keyed on review_id.
create index tip_search_bm25 on tip_search using bm25 (text) with (text_config = 'english');
create index tip_search_hnsw on tip_search using hnsw (embedding vector_cosine_ops);
create index tip_search_queue on tip_search (tip_id) where embedding is null;
```

Verified on the clone, both halves:

- **The liveness join does not break the top-k.** With the ordering operator standing in as a btree, `select s.tip_id from tip_search s join tips t on t.id = s.tip_id where t.deleted_at is null and t.dead_at is null order by <operator> limit 50` plans as `Limit -> Nested Loop -> Index Scan on tip_search + Index Scan tips_pkey (Filter: deleted_at, dead_at)`. It read 52 index rows to emit 50. 0.07 ms.
- **Vote churn no longer touches the search index.** 91883 vote transactions (61059 `tips` updates, 2.6 % HOT) on the clone: the full-text index on `tip_search` stayed at exactly 1408 kB, zero growth, while `tips_hot` grew from 824 kB to 3224 kB from the same churn. In round 2 the same index sitting on `tips` grew to 4552 kB from churn alone.

Two details that fall out for free:

- The queue predicate loses `deleted_at is null and dead_at is null`, because those columns are no longer on this table. Embed everything. Dead rows are a small fraction, embedding is idempotent, the branches filter liveness anyway, and an unkill then needs no re-queue. One fewer moving part.
- The worker's conditional write no longer needs `tips`: `update tip_search set embedding = $2, embedding_model = $3 where tip_id = $1 and embedding is null and text_at = $4`. Same guarantee, one table.

Cost:
- 2 tables, 5 columns each. ~14 lines of DDL.
- 6 columns removed (`search_text`, `embedding`, `embedding_model` from `tips` and from `reviews`).
- 6 index definitions retargeted, not added.
- Publish tip and publish review: +1 CTE each, +2 lines each.
- Edit: `embedding = null` becomes one extra update on the side table in the same transaction, ~3 lines.
- The four search CTEs: +1 join on the two tip branches; the two review branches already join `tips`, so they only change which table supplies the text. ~4 lines.
- The one real loss: the concatenation moves out of a generated column and could drift between publish and edit. Fix with one immutable SQL function `tip_search_text(title, body, model_id, model_other, tag_id)` called from both. +3 lines, drift impossible again.

Total: about 30 lines of SQL, two tables, six columns removed. No app-visible change, no feature change. It also fixes finding 1.5 for free: `select t.*` on the tip page stops returning a second copy of the body and a 4 KB vector.

### A4. The model and environment browse filters

Symptom: a three-filter browse page touches 2557 buffers instead of 60, and a narrow filter at depth drops the ordered scan for bitmap plus sort.

1. Why 2557? The scan walks `tips_hot` in hot order and throws away 2539 rows that fail the filter.
2. Why throw them away? The filter is not in the index.
3. Why not? `tips_hot` is keyed on `(hot_score, id)` only.
4. Why only those? One index was chosen to serve every browse variant.
5. Why one? The doc reasoned "eight tags, so a tag filter walks about eight times more rows".
6. Why was that wrong? Filters compose. 8 tags x 4 models x 7 environments is about 224x in the worst case, not 8x. Measured 42x for the three-way combination that exists in the fixture.
7. Why does the plan then flip to bitmap plus sort? When the estimated match count is small, collecting matches and sorting beats walking the whole ordered index.
8. Why is that bad? Sorting is O(matches past the cursor), so the keyset promise "page 1 and page 1000 cost the same" holds only for the unfiltered list.
9. Why was the promise believed? It was measured once, with one filter, on the first page.
10. Why not just add indexes for the filtered variants? Because each index on `tips` costs write amplification on every vote.
11. Why does it cost that? A3, steps 5 and 6: every index on `tips` takes a new tuple on every non-HOT update.
12. Why does that make the design ration indexes? Because the write cost of an index on `tips` is paid per vote, and votes are the highest-volume write in the system.
13. **Root cause: the same one as A3, one level up. Write amplification on the hot row taxes every index, so indexes get rationed, so read-side filters get pushed into scan-time predicates, so filter cost becomes multiplicative and the keyset guarantee breaks. The filters are not the problem. The index budget is, and the index budget is set by the hot row's write cost.**

Fix, keeping all three filters: spend one index, on the axis that is mandatory and curated.

```sql
create index tips_hot_by_tag on tips (tag_id, hot_score desc, id desc) where deleted_at is null and dead_at is null;
create index tips_new_by_tag on tips (tag_id, created_at desc, id desc) where deleted_at is null and dead_at is null;
```

`tag_id` is `not null` on every tip and has eight curated values. Model and environment are optional and nullable, so they make poor leading columns. Putting the mandatory axis first turns the other two into a residual inside one tag's slice.

Measured on the clone, 20k tips, first page:

| filters | before (`tips_hot`) | after (`tips_hot_by_tag`) |
|---|---|---|
| none | 60 | 60, unchanged |
| tag | 134 | **3**, index-only scan |
| tag + model | 461 | **64** |
| tag + model + environment | 2557 | **176** |

Deep pages, which is where the keyset promise lives:

| page | before | after |
|---|---|---|
| tag only, page 121 | walks the whole hot index | **3 buffers**, index-only, cursor in the Index Cond |
| narrow 3-filter, last page | 528 buffers, bitmap over the whole index, unbounded sort | **143 buffers**, bitmap bounded to one tag's slice (156 rows) |

Tag-only paging is now exactly flat at any depth. The three-filter case still plans as bitmap plus sort, but the sort is now bounded by one tag's rows past the cursor instead of the whole table, so it shrinks with depth instead of growing with corpus size.

Model-only or environment-only with no tag falls back to `tips_hot` with a filter: 4x to 7x, the same as today, and acceptable.

Cost: 2 index definitions, 944 kB and 824 kB on 20k tips. Zero app change — the app already appends `and t.tag_id = $3` rather than using `$n is null or`. Two more index tuples per vote on `tips`, which is why A3 should land first: after A3 the tips row carries only cheap btrees, so the marginal write cost of these two is small.

### A5. `prompt` and `output` on reviews

Symptom: a Best page of 30 reviews can reach 1.2 MB.

1. Why 1.2 MB? 30 reviews x 2 fields x 20000 characters.
2. Why the full text? The page select takes the columns whole.
3. Why whole? The page renders them in a `<pre>` block.
4. Why render all 30 expanded? Nothing in the design says otherwise.
5. Why a 20000-character cap on a review's prompt at all? The tip's prompt has that cap and the review reuses the shape.
6. Why is the same cap fine on tips and not on reviews? A tip page shows one tip. A review list shows thirty.
7. Why did the multiplication go unnoticed? The limits table says "Length limits match the form. The numbers are guesses." The guesses were made per field.
8. Why is a per-field guess the wrong unit? Because the thing that has to be bounded is a response, and a response is a list.
9. Why does nothing bound the response? Because the page size (30) and the field cap (20000) are decided in different places and never multiplied.
10. **Root cause: limits are set per column; the unit that has to be bounded is the page. Any list page multiplies every per-row cap by the page size, and nothing in the design bounds a response.**

Fix, keeping `prompt` and `output` on reviews with the same 20000-character cap: send a bounded prefix in the list, fetch the whole thing on expand. This is what Stack Overflow and GitHub do with long code blocks.

```sql
-- in the Best / New review page select, replace r.prompt, r.output with:
       left(r.prompt, 600) as prompt_head, length(r.prompt) > 600 as prompt_more,
       left(r.output, 600) as output_head, length(r.output) > 600 as output_more,

-- new, one line, on expand:
select prompt, output from reviews where id = $1;
```

Page bound goes from 1.2 MB to 36 KB. 3 % of the bytes, 100 % of the feature.

Measured, and better than expected: `left()` on a TOASTed 20000-character value does not detoast the whole value. On 2000 such rows, `sum(length(v))` cost 11346 buffers and 43.6 ms; `sum(length(left(v,600)))` cost 6680 buffers and 8.2 ms. So the fix is 5.3x cheaper inside the database as well as 33x smaller on the wire.

Cost: 4 expressions changed in one existing select (and the same in the New variant), 1 new one-line statement, 1 "show more" toggle in the template. No schema change, no column change, no cap change.

If the remaining detoast cost ever matters, `prompt` and `output` move to a side table — the same remedy as A3, for the same reason. Not now.

### What the five items add up to

One structural change (A3) and three index or constant changes (A1, A2, A4), plus one query change (A5). Nothing is removed. In order:

1. A3 first. Two tables, six columns moved. Everything else depends on it.
2. A1 next. Two `create index`, one GUC. Only safe after A3.
3. A4. Two `create index`. Cheap once A3 has freed the index budget on `tips`.
4. A2 and A5. Constants and a column list. No dependencies.

Roughly 40 lines of SQL and two tables in total.

## Round 4: final check

Not Agreed. Two findings. Everything else from my round 3 is in and reads correctly: HNSW from day one (A1), review pool 1000 with the distance carried out of the inner subquery and no body materialised (A2), `tip_search` and `review_search` (A3), the two tag indexes (A4). Rule 12 and the split counter statements are right.

**(a) A5 was dropped, not decided.** The review list still ships both long fields whole for 30 rows: line 328, `case when r.deleted_at is null then r.prompt end as prompt,` and the `output` line under it. The agreed fix was `left(r.prompt, 600)` with a `_more` flag and a one-line fetch on expand. It is absent from the doc and absent from the "Rejected as cuts" list at line 806, so it looks lost rather than declined. The numbers stand: page bound 1.2 MB down to 36 KB, and measured 5.3x cheaper inside Postgres, because `left()` slices TOAST — 6680 buffers and 8.2 ms against 11346 and 43.6 ms on 2000 rows of 20000 characters. Cost: 2 expressions changed in each of the two review-list shapes, 1 one-line statement added.

**(b) New defect: the delete statements return `{NULL}`, not an empty array, when the row has no images.** Line 451: `select d.tip_id, d.dead_at, array_agg(m.key) as keys from d left join m on true group by d.tip_id, d.dead_at;`. With no media rows, `left join m on true` still yields one row, so `array_agg` builds a one-element array holding NULL. Reproduced verbatim against the rebuilt `tips_v3`, in a rolled-back transaction, on a review with no media: `keys = {NULL}`, `array_length = 1`. Line 443 says "R2 files are deleted after commit, from the keys the statement returned", so an app looping that array issues a delete for a null key on every image-free delete, which is the common case. Same bug in the tip variant at line 459. Fix: `array_agg(m.key) filter (where m.key is not null)`. One clause, twice.

**Minor, same area.** The bulk kill at line 487, `update tips set dead_at = now() where user_id = $1 and deleted_at is null and dead_at is null and moderator($2);`, has no `returning`. The quarantine step at line 515 ("the app copies each of the row's objects to the quarantine bucket") then has no ids to work from, and a spam flood is exactly when images need quarantining. Add `returning id`.
