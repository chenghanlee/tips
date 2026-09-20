# Opus review C: abuse, operations, search

Viewpoint: attacker plus on-call operator. Not product taste.

Setup: ran `data-model-v3-test.sql` against a scratch database `tips_scratch` (copy with the db name changed). It passes: 11 expected errors, no unexpected ones. Ran read-only probes against `tips_v3` (2004 users, 20004 tips, 201523 reviews, 595614 votes, 319858 notifications). pgvector and pg_textsearch are not installed, so the vector cost is measured with a stand-in column of the same width and storage class, and the BM25 claims are reasoned, not run. `tips_scratch` is left in place if you want to re-check.

Round-1 fixes are not re-reported.

---

## 1. Correctness bugs, worst first

### 1.1 A kill does not remove the images. They stay on a public unsigned URL.

- Rule: "A moderator kill keeps them." Images render as `<img src="https://media.example/{key}">`, no signature, no app in the path.
- Sequence: user posts a tip with an illegal or doxxing image. Anyone who loaded the page has the key in their HTML. Moderator kills the tip. `tips.dead_at` is set, the page 404s for strangers, and `https://media.example/media/{uuid}.png` still returns the bytes to everyone who kept the URL.
- Operator sees: the flag is resolved, the takedown request is not.
- Smallest fix: the kill statement also deletes the target's R2 objects, same as the author delete. Keep the `media` rows so an unkill knows what was there and so you have a record. If you want unkill to restore images, move the objects to a `killed/` prefix instead of deleting.
- Before PMF: yes. This is the one that is not just embarrassing.

### 1.2 One account can fill any tip's review page with "[deleted]" rows, forever.

- `reviews_one_per_user` is `unique (tip_id, user_id) where deleted_at is null`. Delete your review and you may post another. The review list filters `dead_at is null` only, on purpose, so every deleted row stays as a placeholder. Every review is born with a self up vote, so every placeholder has `best_score ≈ 0.20`, tied with every live review, and ties break on `id desc`, i.e. newest.
- Reproduced in `tips_scratch`: one account, 200 post-then-delete cycles on tip 3. Result: 200 rows on the page, 0 live, `review_count = 0`, and **30 of 30 entries on the first page of Best are placeholders**.
- Attacker sees: the tip now reads "0 reviews" above a wall of "[deleted]". It costs 200 writes and cannot be undone by a moderator, because the rows are deleted, not dead, and killing a deleted row changes nothing visible.
- Smallest fix: reviews have no replies in v1, so there is nothing to preserve. Add `and deleted_at is null` to the two review list queries and to the `reviews_best` and `reviews_new` index predicates. Reddit keeps deleted comments only to hold a thread together; Yelp, Amazon and Steam remove a deleted review. The note in the design that says the index "would not match the page query" stops being true once the page query changes.
- Before PMF: yes. It is cheap, it is silent, and it needs no ban to survive.

### 1.3 The object's `Content-Type` comes from the client, so the media domain can serve HTML.

- The browser PUTs to a presigned URL and chooses the request headers not covered by the signature. R2 stores the sent `Content-Type`. The copy step is described without `x-amz-metadata-directive`, so the copy preserves it.
- Sequence: attacker presigns `staging/{uuid}.gif`, PUTs a GIF89a/HTML polyglot with `Content-Type: text/html`. The file-signature check passes: the bytes really do start `GIF89a`. The copy preserves the type. `https://media.example/media/{uuid}.gif` now serves attacker HTML and JavaScript on the media origin.
- Smallest fix: on the copy, set `x-amz-metadata-directive: REPLACE` and derive `Content-Type` from the extension. Add `X-Content-Type-Options: nosniff` and a `Content-Disposition` at the edge. Serve media from an origin with no cookies and no shared session.
- Before PMF: yes, if images ship in v1.

### 1.4 No moderator check in any moderation statement.

- "Only a user with `role = 'moderator'` can run these. The app checks the role." Kill, unkill, ban, unban and flag resolution have nothing in SQL.
- Sequence: one route registered without the middleware, or one copy-paste of a handler. Any logged-in user kills the front page.
- Smallest fix: one clause on each statement, e.g. `update tips set dead_at = now() where id = $1 and dead_at is null and exists (select 1 from users where id = $2 and role = 'moderator' and deleted_at is null)`. Five statements, one line each.
- Before PMF: yes. It costs nothing and removes a whole class of incident.

### 1.5 There is no way to clean up after one spammer.

- Ban does not touch existing content: "Existing content is not changed." There is no statement to kill everything a user wrote, and no correct `review_count` arithmetic for doing it in bulk.
- `tips_by_user` is `where deleted_at is null`, so a moderator cannot even list a user's author-deleted rows by index. At 3 a.m. that is a sequential scan on `tips` under `statement_timeout = 2s`.
- Sequence: one account posts 200 tips overnight. You shadow-ban it at 03:10. The 200 tips are still on Hot. You now kill them one id at a time from a queue that only shows flagged ones.
- Smallest fix: (a) drop the partial predicate from `tips_by_user` so moderators can list everything by author; (b) add two bulk statements, modelled on the existing guarded kill:

```sql
-- kill every live tip by a user
update tips set dead_at = now() where user_id = $1 and dead_at is null;
-- kill every live review by a user and fix the parents' counters
with k as (update reviews set dead_at = now() where user_id = $1 and dead_at is null returning tip_id, deleted_at)
update tips t set review_count = t.review_count - c.n
from (select tip_id, count(*) n from k where deleted_at is null group by tip_id) c where t.id = c.tip_id;
```

- Before PMF: yes. A single spam flood is the most likely early incident, and this is the tool you will not have.

### 1.6 The shadow ban tells the user they are shadow banned, three ways.

The point of a shadow ban is that the account cannot tell. Here it can, in under a minute:

1. **Vote feedback.** The vote statement returns `tips.up_count, tips.down_count`. For a shadow-banned voter the row is born dead and the counters do not move, so the number on screen does not change when they click. Every other account sees it change.
2. **Own score.** A shadow-banned author's tip starts at `up_count = 0`. Every live tip starts at 1. Their own profile shows score 0 next to everyone else's 1.
3. **Own review count.** Their review does not increment `review_count`. The tip header says 2 while the page, including their own dead review shown as "your review", lists 3.

- Smallest fix, all in the view layer, no schema change: render the voter's own vote optimistically and ignore the returned counters for their own action; when the viewer is the author of a dead row, display `score + 1` and `review_count + 1` for their own contribution. Reddit and HN both fake exactly this.
- Before PMF: yes if shadow ban is meant to do anything. Otherwise delete the `shadow` state and keep only `full`, which is honest and simpler.

### 1.7 Votes land on killed and deleted content.

- The vote statement checks the voter (`u.deleted_at is null and u.ban is distinct from 'full'`). It never checks the target.
- Reproduced: a vote on tip 4 (`dead_at` set) moved `up_count` 0 → 1. A vote switch on tip 1 after `deleted_at` was set moved `up_count` 2001 → 2000 and `down_count` 0 → 1.
- Sequence: attacker's tip is killed. They keep voting on it by id, and so does anyone they hand the id to. They appeal. A moderator unkills. The tip is now sitting on Hot with a pre-built score it never earned in public.
- Second effect: the endpoint is an oracle. A killed tip returns counters, a nonexistent tip returns nothing. Anyone can map which ids were removed.
- Smallest fix: put the target in the eligibility CTE.

```sql
from users u where u.id = $1 and u.deleted_at is null and u.ban is distinct from 'full'
  and exists (select 1 from tips where id = $2 and deleted_at is null and dead_at is null)
```

- Before PMF: moderate. One predicate.

### 1.8 The review search branches starve on one popular tip.

- Both review branches take 200 candidates first, then collapse to one review per tip, then ask for 50 tips. The collapse happens after the limit, and the join to live parents also happens after the limit.
- Reproduced against `tips_v3`: tip 1 holds 2004 of 201523 reviews. A 200-row candidate set drawn from that tip's reviews collapses to **1 tip**, not 50. The branch contributes almost nothing to the fusion.
- User sees: for any query about a heavily reviewed topic, the review side of hybrid search silently disappears, and results look like keyword-only tip search.
- Smallest fix: collapse before the limit. One `distinct on` cannot do it; use a lateral over candidate tips, or just raise the candidate pool to 2000 and accept the cost, or cap contributions per tip inside the inner query with a `row_number() over (partition by tip_id)` filter before limiting. The cheapest honest version: inner `limit 2000`, outer collapse, outer `limit 50`.
- Before PMF: yes. Your own fixture already triggers it.

### 1.9 A review is a free channel into someone else's search result.

- `reviews_bm25` and `reviews_vec` feed the same RRF pool as the tip's own text, at the same weight, and `matched_review` becomes the snippet shown under the tip in search results.
- Sequence: attacker writes one review on a popular tip containing the terms they want to rank for. That tip now surfaces for those queries, with the attacker's text as the snippet under it. One account, one review, no ban triggered. Downvoting the review does not remove it from the branches, which never look at `best_score`.
- Smallest fix: weight the lists in the fusion, which is standard RRF practice: `1.0/(60+rank)` for the two tip branches, `0.5/(60+rank)` for the two review branches. And require `best_score > 0.2` (i.e. more than the author's own vote) before a review may supply a snippet.
- Before PMF: moderate. Trivial edit to the `fused` CTE.

### 1.10 `tag_id` and `model_other` inside `search_text` pollute BM25 and are a stuffing field.

- `search_text` is `title || ' ' || body || ' ' || coalesce(model_id, model_other, '') || ' ' || tag_id`.
- Effect one: every tip tagged `persona` contains the token "persona", so a search for "persona" competes against thousands of documents that only carry the tag. Short tips win on BM25 length normalisation. The one tip actually about personas does not.
- Effect two: `model_other` is 80 characters of free text the user chooses, indexed at the same weight as the title. "claude gpt opus sonnet gemini agent jailbreak system persona" is a legal `model_other`.
- Smallest fix: drop both from `search_text`. Tag, model and environment are already exposed as filters on the same queries, which is the industry answer (facets, not text blending). Keep `model_id` out too; it adds the same problem with a curated vocabulary.
- Before PMF: yes for search quality, and it makes `search_text` cheaper at the same time.

### 1.11 The embedding queue has no per-row failure handling. Fifty bad rows stop search forever.

- The worker takes 50 rows from `tips_needs_embedding` and writes back only on success. There is no attempt counter, no backoff per row, no dead-letter state.
- Sequence: one body makes the embedding server return 500 (bad unicode, a length the server rejects, whatever). The loop retries it forever. Add 49 more and the whole queue is head-of-line blocked. Every tip and review posted after that has `embedding is null`, so it never appears in either vector branch. Nobody gets paged, because search still returns keyword results.
- Operator sees: nothing. Search quality quietly decays.
- Smallest fix: add `embed_failed_at timestamptz` to both tables and to both queue predicates (`and embed_failed_at is null`), set it on a non-retryable error, and clear it on an edit. Plus one metric: `select count(*) from tips where embedding is null and deleted_at is null and dead_at is null` on a dashboard with an alarm.
- Before PMF: yes. Silent total degradation of the one feature you built two extensions for.

### 1.12 Nothing stops a fresh account from voting.

- The vote eligibility CTE checks deleted and fully banned. It does not check account age or email verification.
- The arithmetic: Hot is `log10(|score|) + age/45000`. 100 votes is 2.0 hot units, which is 90000 seconds, i.e. **25 hours of age advantage**. On a site with 20 tips a day, 100 sockpuppet upvotes own the front page for a day.
- Smallest fix: one more predicate in the CTE that already exists, no schema change if you use `created_at`:

```sql
from users u where u.id = $1 and u.deleted_at is null and u.ban is distinct from 'full'
  and u.created_at < now() - interval '1 hour'
```

Better version: an `email_verified_at` column and require it. Either way it is one clause in a statement you already wrote.
- Before PMF: the attack needs traffic first, but the fix is one line and you cannot retrofit the votes you already counted. Put it in now.

### 1.13 Deleting a tip deletes other people's notifications.

- `delete from notifications where tip_id = $1` runs on tip delete. `review_upvoted` rows carry `tip_id` (the inbox joins `tips` for the title), so they match.
- Reproduced: a reviewer with a `review_upvoted` row for review 206 on tip 3 had it deleted when tip 3's author ran the delete. The review itself is still live and still on their profile, per Rule 2.
- Smallest fix: `delete from notifications where tip_id = $1 and review_id is null`.
- Before PMF: minor, and free.

### 1.14 The presigned PUT has no size bound, so the size check happens after the bytes are paid for.

- The app HEADs the object and checks 10 MB *after* the upload. A presigned PUT with no `Content-Length` condition accepts any size R2 accepts.
- Sequence: attacker gets one presign and uploads 5 GB. Rejected on the HEAD, still stored until the `staging/` lifecycle rule fires a day later. Repeat within the signing rate limit.
- Smallest fix: sign `Content-Length` as a required header, or use a presigned POST with a `content-length-range` policy, which is the standard S3 answer for exactly this.
- Before PMF: moderate. It is a cost attack, not a compromise.

### 1.15 There is no fallback when search times out.

- The design has a fallback only for "if the query embedding call fails". With `statement_timeout = 2s` and two exact vector scans (see 2.2), the statement itself will time out well before that server does.
- User sees: a 500 on the search page.
- Smallest fix: catch the timeout and re-run the same statement with the two vector branches removed. You already have that code path.

### 1.16 Killing a target leaves its flags open.

- Kill sets `dead_at`. Nothing touches `flags`. A tip reported by 30 people leaves 30 open rows in an oldest-first queue after you handle it.
- Smallest fix: the kill statement also runs `update flags set resolved_at = now(), resolved_by = $2 where tip_id = $1 and resolved_at is null`.

### 1.17 The flag queue can be flooded, and banned users can flood it.

- Queue is `where resolved_at is null order by created_at, id limit 50`, one row per flag, no grouping. `flags` has no ban check.
- Sequence: 50 throwaway accounts each flag 10 different real tips. That is 500 rows sitting at the top of an oldest-first queue. Real reports arrive behind them and are never seen.
- Smallest fix: group the queue by target with a count and order by count desc, which is what Discourse does; and exclude reporters with a ban set.

### 1.18 `select t.*` on the tip page ships everything, and masking is left to the app.

- Measured columns returned: `id, user_id, title, body, tag_id, model_id, model_other, environment_id, prompt, output, up_count, down_count, review_count, score, hot_score, search_text, embedding_model, created_at, edited_at, deleted_at, dead_at` — plus `embedding` in production, which is about 4 KB per row.
- So every tip page transfers the body twice (`body` and `search_text`) plus a 4 KB vector, and the raw body of a deleted or dead tip reaches the app layer intact. One templating mistake or one JSON endpoint and "[deleted]" content is public.
- The inbox query already masks in SQL (`case when t.dead_at is null or t.user_id = n.user_id then t.title else '[removed]' end`). The tip page and the review list do not. Be consistent.
- Smallest fix: name the columns; wrap `body`, `prompt`, `output` in the same `case` the inbox uses.

### 1.19 The staging key is client-supplied and not bound to the uploader.

- The browser "sends the key with the form". Only the final `media/` key has a regex. Nothing in the design validates the staging key's shape or checks that the account that asked for the presign is the one submitting it.
- Smallest fix: validate `^staging/[0-9a-f-]{36}\.(png|jpg|webp|gif)$` server-side, and mint keys as `staging/{user_id}/{uuid}.{ext}` so ownership is checkable without a table.

### 1.20 `prompt` and `output` are not searchable.

- `search_text` excludes them. On a site about prompting tips, the prompt is the thing people will half-remember and type into the search box. Nothing finds it.
- Smallest fix: add `coalesce(prompt,'')` to `search_text`. Leave `output` out; it is model babble and would swamp BM25.
- Before PMF: yes, and it is one edit in the generated column, next to the two removals in 1.10.

### 1.21 The review model filter does not filter.

- `and ($2::text is null or r.model_id = $2 or (r.model_id is null and r.model_other is null))`. Filtering by "Claude Opus 5" also returns every review that named no model. Same for environment.
- If that is deliberate, label the control "Opus 5 and unspecified". If not, drop the third disjunct.

### 1.22 Reserved and confusable handles.

- Checked against `users_handle_chk`: `admin`, `moderator`, `mod`, `support`, `deleted`, `removed` are all registerable. Uniqueness is on `lower(handle)` only, so `ada`, `a-d-a` and `a_d_a` are three different users.
- Smallest fix: a ten-word blocklist, and make the unique index `lower(replace(replace(handle,'-',''),'_',''))`, which is roughly what GitHub does.
- Before PMF: low, but the blocklist is five minutes and impersonating a moderator is the cheapest social attack on a moderated site.

### 1.23 Orphaned `media/` objects.

- The copy to `media/` happens before the publish transaction commits. If the transaction fails (constraint, timeout, user closes the tab), the object is copied and no row references it. `staging/` has a lifecycle rule; `media/` does not.
- Smallest fix: a weekly sweep that lists `media/` and deletes keys with no row, or copy after commit and accept a rare broken image instead of a rare orphan.

### Operational gaps, same section

- **No backups mentioned anywhere.** One Postgres, one process. `pg_dump` nightly to R2 is the 80/20 and belongs in the design, not in your head.
- **No embedding backlog metric.** See 1.11.
- **Thirty R2 round trips inside the publish request.** Ten images times HEAD, ranged GET, COPY. `statement_timeout` does not cover HTTP. A slow R2 turns publishing into a hung request with a half-written transaction holding row locks. Do the HEAD, GET and copy at upload-confirm time, one image at a time, and have publish only insert rows.
- **No moderator query for "who voted on this".** The data exists and there is no index for it. See 2.6.

---

## 2. Performance risks before about 1M rows

### 2.1 Every vote is a non-HOT update, so every vote rewrites the tip's BM25 index entry

- `hot_score` is a stored generated column derived from `up_count`, and `tips_hot` indexes it. An update to `up_count` therefore changes an indexed column, which forbids a HOT update. Postgres must insert a new index tuple into **every** index on `tips`.
- Measured in `tips_scratch`: 2000 upvotes from 2000 distinct users on one tip.

| | before | after |
|---|---|---|
| `n_tup_hot_upd` / `n_tup_upd` | — | **0 / 2000** |
| `tips` heap | 8 KB | 786 KB |
| `tips_hot` | 16 KB | 131 KB |
| `tips_new` | 16 KB | 41 KB |
| `tips_pkey` | 16 KB | 41 KB |

- In production the index list also contains `tips_bm25`. So every single vote inserts a new BM25 posting set for the tip's whole `search_text`, which means detoasting up to 20 KB of markdown and re-tokenising it. Write amplification proportional to votes, not to edits. (I could not run pg_textsearch locally; if it does something unusual on insert this specific consequence may differ. The non-HOT behaviour itself is measured and not in doubt.) `reviews` has the identical shape via `best_score` and `reviews_bm25`.
- Autovacuum on `tips` fires at `0.2 × 20000 + 50 ≈ 4050` dead tuples, so during a front-page burst the dead tuples pile on a handful of pages while Hot keeps scanning a growing index. B-tree pages are reused but not returned, so `tips_hot` does not shrink back.
- Fix: put the mutable counters in their own narrow table.

```sql
create table tip_counters (
  tip_id bigint primary key references tips(id),
  up_count int not null default 0, down_count int not null default 0, review_count int not null default 0,
  score int generated always as (up_count - down_count) stored,
  hot_score double precision generated always as (...) stored);
create index tip_counters_hot on tip_counters (hot_score desc, tip_id desc);
```

Voting then touches a ~40-byte row with two indexes and never touches the text, the vector, or the search index. This is what Reddit does and it is the single highest-value structural change in this review. Cost: Hot browse joins `tips` on the primary key, which the query already does for `users`; the partial `deleted_at is null and dead_at is null` predicate has to move or be duplicated onto the counter table.

- Before PMF: yes if search ships in v1. Retrofitting it after the BM25 index exists is a migration; doing it now is a table.

### 2.2 The exact vector scan is 5 to 10 times more expensive than the design assumes

- The design says "at 1024 floats a row, 50k rows is about 200 MB per query, which is the point to add an HNSW index". That counts the floats. It does not count how pgvector stores them: `vector` uses `external` storage, so every 4096-byte value lives out of line in the TOAST table and is fetched through the TOAST index per row.
- Measured with a stand-in column of the same width and storage class (4096 bytes, `set storage external`), 20000 rows, fully cached, **no distance arithmetic at all** — just two `get_byte` calls per row:

```
heap 1184 kB | TOAST 106 MB
Seq Scan + top-N: shared hit=133482  (≈ 1 GB of buffer traffic)  Execution Time: 50.8 ms
```

- That is 6.7 buffer hits per row, because each value is three TOAST chunks plus an index descent. Add pgvector's actual 1024-dimension distance and the tips branch is roughly 60–80 ms warm at 20k rows. The reviews branch at the 200k rows already in your fixture is roughly ten times that, so **0.6–0.9 s warm and far worse cold**, against `statement_timeout = 2s`, twice per search, on a box that is also running the embedding model.
- So: search breaks at about 20k tips and 200k reviews, which is the scale your own script already loads, not at the 50k threshold in the doc. The threshold is the wrong number, not just an optimistic one.
- Fix, cheapest first: (a) correct the threshold and watch it; (b) use `halfvec(1024)`, which halves the bytes with negligible recall loss on Qwen3 and is a one-line column change; (c) build the HNSW index, which at 20k rows takes seconds and costs about 30 MB. I am not reopening the "no HNSW in v1" decision — I am saying the number that decision rests on is off by roughly an order of magnitude, so re-decide with the real one.

### 2.3 The unread badge is an unbounded count on every page load

- `select count(*) from notifications where user_id = $1 and read_at is null` runs on **every** page. Cost is linear in that user's unread rows, with no ceiling. The fixture's 1902-unread user costs 0.11 ms; a user who ignores the inbox for a year costs proportionally more, on every single request they make.
- Fix, one line, and it is what every site with a badge does: `select count(*) from (select 1 from notifications where user_id = $1 and read_at is null limit 100) x` and render "99+".

### 2.4 Mark-all-read is O(unread) and runs on every inbox open

- Measured in the design: 15 ms for 1902 rows, 280 buffers. That extrapolates to about 1.5 s at 200k unread, inside a 2 s timeout, while holding write locks on that many rows and generating that many dead tuples in the hottest-written table.
- Fix: cap it the same way — `where user_id = $1 and read_at is null and created_at <= $2` with `$2` the newest row on the page just rendered. That is also more correct: today, opening the inbox marks read notifications you never saw because they arrived while the page was loading.
- A read watermark on `users` would remove both this and 2.3, but it conflicts with the fold index, whose predicate is `where read_at is null`. Not worth the trade. Cap instead.

### 2.5 `search_text` stores the body a second time

- Measured on the fixture: `sum(octet_length(search_text)) = 1072 kB` against `sum(octet_length(title)+octet_length(body)) = 643 kB`. With real markdown bodies it is a straight doubling of the table's text, and pg_textsearch keeps a third copy in its index.
- Fix: dropping `tag_id`, `model_id` and `model_other` from it (see 1.10) does not fix the duplication, only the pollution. If the duplication bothers you, index `title` and `body` as two BM25 indexes and fuse them as two more RRF lists, which is also better retrieval (title matches should outrank body matches). Otherwise accept it; it is the smaller problem.

### 2.6 "Who voted on this tip" is a skip scan whose cost grows with the user count

- `votes` has exactly three indexes: `votes_pkey`, `votes_one_per_tip (user_id, tip_id)`, `votes_one_per_review (user_id, review_id)`. There is no index with `tip_id` leading.
- Measured on `tips_v3`:

```
select user_id, value, created_at from votes where tip_id = 1 and created_at > now() - interval '1 hour';
Index Scan using votes_one_per_tip ... Index Searches: 1793 ... Buffers: shared hit=3590 read=2142
Execution Time: 27.453 ms   (5.3 ms warm)
```

- Postgres 18's skip scan saves it, but `Index Searches` tracks the number of distinct `user_id` values, not the number of votes on the tip. At 2004 users it is 1793 descents and 27 ms. At 100k users it is 100k descents and seconds, under a 2 s timeout, for the one query you need during a brigade.
- Fix: `create index votes_by_tip on votes (tip_id, created_at desc);`. One index, and it is also what you need for any future "recent voters" moderation view.

### 2.7 Row-lock contention on the front-page tip

- Every vote on a tip updates that one `tips` row, so votes on the hottest item serialise. At the measured 0.5–0.8 ms per vote that is a ceiling around 1250/s for a single tip, which is fine. The point is only that 2.1's counter table also narrows what is being locked from a wide row carrying a 20 KB body and a 4 KB vector down to 40 bytes.

---

## 3. Invented conventions

| Invented thing | Industry standard that could replace it | Recommendation |
|---|---|---|
| Vote counters and derived ranks stored in the same row as the searchable text and the embedding | Reddit, Lemmy, Discourse keep vote/score state separate from the post body; scores live in a narrow row or a cache | Replace. `tip_counters` / `review_counters`. See 2.1. Highest-value change here. |
| Deleted reviews kept as "[deleted]" placeholders | Reddit keeps deleted comments only to preserve a reply thread. Yelp, Amazon, Steam, Google Maps remove a deleted review outright | Replace. Reviews have no replies in v1. See 1.2. |
| `tag_id` and `model_other` concatenated into the BM25 text | Faceted filtering (every search engine), or weighted multi-field BM25 (Elasticsearch, Solr) | Replace. Drop from `search_text`; the filters already exist on the same queries. |
| Flat RRF, all four lists at weight 1.0 | Weighted RRF is the normal extension: `w_i / (k + rank)`. Elastic and Vespa both expose per-list weights | Replace. Tip branches 1.0, review branches 0.5. See 1.9. |
| Moderation authorisation enforced only in the app | Every moderation tool of this shape puts the actor in the statement, even when middleware also checks | Add the `exists` clause. See 1.4. |
| Kill keeps the files, delete removes them | Discourse and Reddit both unlink media on removal, not only on author delete | Replace for kill. See 1.1. |
| Flag queue: one row per flag, oldest first | Discourse groups flags by post and sorts by a score; Lobsters shows a per-item count | Group by target. See 1.17. |
| Embedding queue as a bare partial index with no attempt state | Every job queue has an attempt count or a next-attempt timestamp (Sidekiq, Oban, `pgmq`, River) | Add `embed_failed_at`. See 1.11. |
| Size validated after upload, via HEAD | S3 presigned POST with `content-length-range`, or a signed `Content-Length` | Replace. See 1.14. |
| `Content-Type` accepted from the uploader | Derive it from the validated signature and set it on the copy; `nosniff` at the edge | Replace. See 1.3. |
| Unbounded badge count per page load | "99+" via a capped subquery — GitHub, Reddit, Discourse all cap | Replace. See 2.3. |
| Handle uniqueness on `lower(handle)` only | GitHub folds `-`; most sites keep a reserved-name blocklist | Add both. See 1.22. |
| `media_key_chk` regex standing in for a UUID | Store the uuid in a `uuid` column and build the key from it | Cosmetic. Leave it. |
| `epoch_of()` declared immutable over a stable function | This is the standard trick for a generated Reddit-hot column and the reasoning given is correct for `timestamptz` | Keep. |
| RRF with k = 60 | The value from the original Cormack RRF paper and the Elastic default | Keep. |
| Wilson lower bound with z = 1.281551565545 | Exactly Reddit's `_confidence` constant | Keep. |
| `deleted_at` / `dead_at` pair | Hacker News | Keep. |

---

## 4. Cut list

- **Cut `ban = 'shadow'`, or fix its three tells.** As shipped it is detectable in under a minute (1.6), so it is a feature that does not work plus a whole extra code path through publish, vote and review. Either fix the display (cheap, three places) or ship only `full`.
- **Cut deleted-review placeholders.** They buy nothing without reply threads and they are an attack surface (1.2). Removing them also lets `reviews_best` and `reviews_new` include `deleted_at is null`, which shrinks both indexes and removes the whole paragraph of explanation about why they only check `dead_at`.
- **Cut `output` from any future `search_text` change, keep `prompt`.** Model output is long and low-signal; it would dominate BM25 length normalisation.
- **Defer the `gif` upload type.** Three raster types cover the product. GIF is the one format where a valid file is also a plausible HTML polyglot and an unstoppable animation, and you gain nothing.
- **Defer search pagination.** `limit 20` with no cursor is right for v1. Say so explicitly so nobody adds an OFFSET later.
- **Defer notification retention.** 320k rows for 2k users is nothing. Revisit at 10M, not before.
- **Do not defer:** the moderator `exists` clause (1.4), the bulk kill-by-user statements (1.5), `votes_by_tip` (2.6), the account-age predicate on votes (1.12), and the `Content-Type` fix (1.3). All five are one line each and all five are things you cannot add calmly after the incident that needs them.

---

## 5. Verdict

**Ship with fixes.** The schema shape is right and nothing here needs a redesign of the nine tables. Two things must change before the first public write: killing content must remove its images from R2 (1.1), and the moderation statements must check the actor's role in SQL (1.4). Two more are cheap and structural, so do them now rather than migrate later: move the vote counters off the wide indexed row so a vote does not rewrite the BM25 index (2.1), and stop keeping deleted reviews as placeholders, which today lets one account deface any tip's review page with 200 writes (1.2, reproduced). The search design is sound in outline and wrong in three details that will show up immediately: the review branches starve on any heavily reviewed tip (1.8, reproduced against your own fixture), the tag and model text in `search_text` will make tag searches return the tag instead of the topic (1.10), and the exact vector scan is five to ten times more expensive than the number the "no HNSW in v1" decision was made against (2.2, measured) — re-decide with 20k tips and 200k reviews as the breaking point, not 50k. Everything else in section 1 is a one-line clause or a view-layer change, and the operational holes that will actually wake you up are the missing bulk kill-by-user (1.5), the silent embedding queue stall (1.11), and the fact that no backup is mentioned anywhere in the document.

---

## Round 3: root causes and fixes that keep the feature

Every feature in the consensus list stays. No cuts below. Each item: the why chain, the root cause, the fix, the cost. New claims re-verified in `tips_scratch`.

### C1. Shadow ban stays. Close the three tells.

Symptom: the banned account can detect the ban in under a minute.

Why chain:

1. Why does the banned user notice? The number on screen does not move when they act.
2. Why not? Their row is born dead, and dead rows are not counted.
3. Why not counted? `up_count`, `down_count` and `review_count` count live rows only.
4. Why only live? Because they are the public counts.
5. Why is there only one count? Counters are stored on the row, one value per row.
6. Why one value per row? Because the count was assumed to be the same for everyone.
7. Why assumed? Because for every user except a shadow-banned one, it is.
8. Why is the shadow-banned one different? A shadow ban means their write is real to them and absent to everyone else.
9. Why does that need a different number? Because the number is the visible proof that the write landed.
10. Why is the stored number the one rendered? Because the app renders whatever the query returned.
11. Why does the app render it raw? Because there is no concept of "this count, as this viewer should see it".
12. Why no such concept? Because the schema models one public count, and the read path models one viewer, and nothing joins them.
13. Root cause: **the system stores a per-row public count, but shadow ban is by definition a per-viewer truth. The read path has no place to express the difference.**

First principles: the ban works if and only if every number the banned user sees equals the number they would see if the write had counted. That is `public count + my own dead contribution`. Nothing else has to change.

Fix, three expressions, no schema change, no extra query:

- **Vote counts.** The page already runs `select tip_id, review_id, value from votes where user_id = $1 and ...`, which has no `dead_at` filter, so it already returns the viewer's dead votes. Display `up_count + (1 if my vote here is dead and value = 1)`, same for down. Also stop rendering the counters the vote statement returns; render the optimistic local value like every other site does.
- **My own tip's score.** A born-dead row always has exactly one dead self vote. Display `score + 1` when `dead_at is not null and user_id = viewer`.
- **Review count.** The tip page already runs "my review on this tip", dead included. Display `review_count + 1` when that query returned a row whose `dead_at` is set.

Cost: three display expressions in the app, about 10 lines. Zero SQL, zero columns, zero new queries.

One adjacent gap worth one statement: unban does not repair. `dead_at = coalesce(votes.dead_at, excluded.dead_at)` keeps a vote dead forever, so an unbanned account's old votes never count again. Add to the unban path:

```sql
with v as (update votes set dead_at = null where user_id = $1 and dead_at is not null returning tip_id, review_id, value)
-- then the existing recount statement, scoped to the touched tip_ids and review_ids
```

Cost: one statement plus a scoped recount, about 12 lines. Do it when you first unban someone, not before.

### C2. Deleted-review placeholders stay. Cap them at one per account per tip.

Symptom: one account minted 200 permanent "[deleted]" slots on one tip.

Why chain:

1. Why 200 slots? The account inserted 200 review rows on one tip.
2. Why allowed? Each delete let it insert again.
3. Why does delete allow a new insert? `reviews_one_per_user` is `unique (tip_id, user_id) where deleted_at is null`.
4. Why partial? So a user who deletes can review that tip again.
5. Why must they need a new row for that? Because delete is modelled as the row's terminal state.
6. Why terminal? Because `deleted_at` is a one-way marker, like `dead_at`.
7. Why one-way? The two hide markers were designed for tips, where nothing is unique per author.
8. Why reuse the shape for reviews? Rule 7 and the general preference for one shape repeated.
9. Why does it break here and not on tips? Reviews carry an identity rule — one per user per tip — and tips do not.
10. Why does an identity rule need different handling? Because identity is a property of the pair (user, tip), not of a row version.
11. Why does the current index not express that? It scopes the uniqueness to live rows, so the identity is only held while the row is live.
12. Why is releasing it harmful? Because the released row does not disappear; it stays on the page forever as a placeholder.
13. Why does it stay? Because the placeholder is the feature, and the feature assumes one placeholder marks one real review that was really there.
14. Root cause: **the "one review per user per tip" rule is enforced only while a review is live, so deleting releases an identity that the placeholder keeps occupying. Every release mints another permanent page slot from the same identity.**

First principles: the placeholder exists to hold the position of a review that existed. One user can have at most one position on a tip. So the uniqueness must be total, and re-reviewing must reuse the row rather than mint a new one.

Fix, two changes:

```sql
-- 1. the identity is total, not scoped to live rows
create unique index reviews_one_per_user on reviews (tip_id, user_id);

-- 2. re-reviewing undeletes the same row instead of inserting a second one
insert into reviews (tip_id, user_id, body, model_id, model_other, environment_id, prompt, output, up_count, dead_at)
select $2, u.id, $3, $4, $5, $6, $7, $8, case when u.ban = 'shadow' then 0 else 1 end, case when u.ban = 'shadow' then now() end
from (select id, ban from users where id = $1 and deleted_at is null and ban is distinct from 'full') u
on conflict (tip_id, user_id) do update
  set body = excluded.body, model_id = excluded.model_id, model_other = excluded.model_other,
      environment_id = excluded.environment_id, prompt = excluded.prompt, output = excluded.output,
      deleted_at = null, edited_at = now()
  where reviews.deleted_at is not null
returning id, tip_id, user_id, dead_at, (xmax = 0) as was_new;
```

`review_count` goes up when `was_new` is true or the row came back from deleted. The self vote already exists on a revived row, so its insert becomes `on conflict do nothing`.

Verified in `tips_scratch`: the same 200 post-then-delete cycles now produce **1 row and 1 placeholder**, not 200. Re-reviewing after a delete still works and reuses the row. A second live review is still refused.

Second change, free, and it fixes the ordering complaint at the same time: placeholders keep their self up vote today, so they tie at `best_score ≈ 0.20` and win the tie on `id desc`, which puts them above real reviews. Wrap the generated column:

```sql
best_score double precision generated always as (
  case when deleted_at is not null then -1
       when up_count + down_count = 0 then 0
       else <the existing Wilson expression> end) stored
```

Verified: placeholders sort last and stay on the page. `deleted_at` is a plain column, so a generated column may reference it.

Cost: one index redefinition, one statement changed from insert to upsert, one `case` wrapper on `best_score`, and the app treats "0 rows returned" instead of a unique violation as "you already reviewed this". About 20 lines.

### C3. Kill keeps the files. Stop the public URL from serving them.

Symptom: a killed doxxing image is still fetchable at its unsigned URL.

Why chain:

1. Why is it still fetchable? The URL still resolves.
2. Why does it resolve? The object is still at `media/{uuid}.ext` and that prefix is published.
3. Why published? The browser fetches R2 directly; Postgres never touches bytes (rule 8).
4. Why direct? To keep the app out of the image path.
5. Why does that break kill? Kill is a fact in Postgres, and the image path never reads Postgres.
6. Why never? Because there is nothing between the browser and the bucket.
7. Why nothing? Anything in between is an app hop or an edge worker, both of which the design avoided.
8. Why avoided? Cost, latency, and moving parts.
9. Why is the killed object still at the published key? Because kill writes `tips.dead_at` and touches no object.
10. Why touches none? "Kill keeps the files" was implemented as "do not call R2 on kill".
11. Why read that way? Because author delete removes files, and kill was defined as its opposite.
12. Why is that reading wrong? Because "keep the files" is about **retention** — evidence, and the ability to unkill — not about **continued publication**.
13. Root cause: **retention and publication are the same thing here, because the object key is the only state the public read path consults. Kill changes visibility in the database and the bucket never hears about it.**

First principles: to keep the files and stop serving them, the two must be separable. The cheapest separator that needs no app hop and no worker is the key itself.

Fix: kill moves the object; unkill moves it back. The bytes are retained, which is what the consensus asks for.

```
kill:   COPY media/{uuid}.ext -> killed/{uuid}.ext ; DELETE media/{uuid}.ext
unkill: COPY killed/{uuid}.ext -> media/{uuid}.ext ; DELETE killed/{uuid}.ext
```

`killed/` is not bound to the public custom domain, so the URL 404s. The `media` row and its `key` are unchanged, so unkill needs no bookkeeping and moderators can still see what was there. No lifecycle rule on `killed/`.

Cost: two R2 calls per image on kill and on unkill, in the moderator path only, off the read path. About 15 lines of app code. Zero SQL, zero schema, zero change to the reader's URL. Killing a tip with 10 images is 20 R2 calls, which is fine for an action a human takes.

### C4. Counters move to their own table. No feature changes at all.

Symptom: every vote is a non-HOT update and writes a new entry into every index on `tips`, including BM25.

Why chain:

1. Why does a vote rewrite every index? The update is non-HOT.
2. Why non-HOT? An indexed column changed.
3. Which one? `hot_score`, indexed by `tips_hot`.
4. Why did it change? It is generated from `up_count`.
5. Why is `up_count` on the tips row? Counters are stored on the row (rule 3).
6. Why on the row? So the counter, the score and the rank move in one transaction and cannot drift. That reason is correct and stays.
7. Why does that force the rest of the row to be rewritten? Postgres versions whole tuples, and a non-HOT version needs a pointer in every index on the table.
8. Why does that hurt here specifically? One of those indexes is BM25 over `search_text`, which is up to 20 KB of markdown that must be detoasted and re-tokenised.
9. Why is BM25 on the same table? `search_text` is a generated column on `tips`.
10. Why generated there? It is derived from `tips` columns, and a generated column cannot read another table.
11. So the text index and the counters share one tuple. Why is that bad? They change at wildly different rates: text on edit, inside a 2-hour window, at most a handful of times ever; counters on every single vote.
12. Why did they end up together? Because "one row per tip" was taken as the unit of storage.
13. Why is that the wrong unit? Because MVCC's unit is the tuple, so co-locating fields means co-locating their write rates.
14. Root cause: **two fields whose rates of change differ by three orders of magnitude share one physical tuple, so the slow field pays the fast field's write cost on every vote.**

First principles: what must be true? The counter, the derived score and the rank must move in one transaction and be index-scannable. None of that requires them to sit in the same tuple as the body, the embedding, or the BM25 text. Occam: split by rate of change, not by entity.

Fix:

```sql
create table tip_counters (
  tip_id       bigint primary key references tips(id),
  created_at   timestamptz not null,          -- copied at publish, never changes
  up_count     int not null default 0,
  down_count   int not null default 0,
  review_count int not null default 0,
  score        int generated always as (up_count - down_count) stored,
  hot_score    double precision generated always as (
                 sign(up_count-down_count)*log(greatest(abs(up_count-down_count),1))
                 + (epoch_of(created_at)-1134028003)/45000) stored,
  deleted_at   timestamptz, dead_at timestamptz);  -- mirrored, so the partial index still works
create index tip_counters_hot on tip_counters (hot_score desc, tip_id desc) where deleted_at is null and dead_at is null;
create index tip_counters_new on tip_counters (created_at desc, tip_id desc) where deleted_at is null and dead_at is null;
-- review_counters, same shape, with best_score and (tip_id, best_score desc, id desc)
```

Measured in `tips_scratch`, 2000 votes on one row, same workload as section 2.1:

| | wide `tips` row | narrow counter row |
|---|---|---|
| dead heap bytes per vote | 389 | **70** |
| index entries written per vote | 5 (pkey, hot, new, by_user, **bm25**) | **2** (pkey, hot) |
| BM25 detoast + retokenise per vote | yes, up to 20 KB | **no** |

Honest correction to my own section 2.1: the counter row is still a non-HOT update, because `hot_score` is indexed there too. The win is not HOT; it is that the non-HOT update is 5x smaller and no longer drags the search index behind it. Browse Hot is still a single index scan on the cursor (`Index Scan using tip_counters_hot`, verified).

The cost is real and I will not undersell it. The mirrored `deleted_at` / `dead_at` is the ugly part: delete and kill must write both tables in one transaction, or the partial index goes stale. Two options, pick one:

- **Mirror them** (shown above). Delete and kill each gain one more `update`. Four statements change, and the recount statement must also repair the mirror.
- **Do not mirror.** Drop the partial predicate from the two counter indexes and let browse join `tips` and filter there. Simpler to write, but Hot then walks dead and deleted rows in the index. At the fixture's rate of removals that is a handful of extra rows per page, which is the same order as the tag filter already measured at 182 rows skipped.

Take the second. Fewer moving parts, no invariant to keep in sync, and the measured cost of skipping rows in `tips_hot` is already known to be under 0.1 ms.

Cost: 2 tables, about 20 lines of DDL; 1 extra insert in each publish statement; 8 statements retargeted (vote tip, vote review, unvote tip, unvote review, publish tip, publish review, kill/unkill review, delete review); 1 join added to browse, reviews Best, profile and the tip page; the recount statement rewritten against the new tables. Roughly 60 lines touched. Zero user-visible change.

Do it now or do not do it. After `tips_bm25` exists on a live table this becomes a migration with a reindex.

### C5. GIF stays. Make the origin inert.

Symptom: a GIF that is also valid HTML can be served as HTML.

Why chain:

1. Why is it served as HTML? The response `Content-Type` says `text/html`.
2. Why does it say that? R2 stored what the uploader's PUT sent.
3. Why did it store the uploader's value? A presigned PUT signs the URL, not every header the client sends.
4. Why doesn't the copy fix it? An S3-compatible copy preserves metadata unless told to replace it.
5. Why wasn't it told? The copy was added for the ETag guarantee, not for metadata.
6. Why doesn't the file-signature check catch it? The check reads bytes, and `GIF89a/*<html>...` is a valid GIF and valid HTML at once.
7. Why does a valid GIF not protect us? The browser dispatches on the declared type, not on the bytes.
8. Why does it trust the declared type? That is the HTTP contract, and it is not going to change.
9. Why is active content on this origin dangerous? Script runs with the origin's privileges.
10. Why does the media origin have privileges worth taking? It is a domain the site's users trust, and it may be same-site with the app.
11. Why was none of this caught by the upload checks? Every check validates the bytes; none validates or re-derives the metadata.
12. Why not? Because the metadata was never treated as user input.
13. Root cause: **the file's declared type is attacker-controlled input that is never re-derived from the bytes the app validated, and the serving origin is not declared inert.**

First principles: the only type that may be served is the one the app derived from bytes it read. GIF is irrelevant to that; it is just the easiest polyglot.

Fix, no SQL, GIF keeps working:

- On the copy, send `x-amz-metadata-directive: REPLACE` and set `Content-Type` from the extension the app already validated (`image/png`, `image/jpeg`, `image/webp`, `image/gif`).
- At the media domain, add response headers: `X-Content-Type-Options: nosniff`, `Content-Security-Policy: default-src 'none'; sandbox`, `Cross-Origin-Resource-Policy: cross-origin`.
- Keep the media domain cookieless and not a subdomain that shares cookies with the app.

Cost: one request header on the copy call, three response headers in the Cloudflare rule. About 5 lines. The 10 MB cap already bounds the animation and decompression-bomb angle, so nothing else is needed.

### C6. No waiting period. Make an identity cost something instead.

Symptom: 100 sockpuppet votes buy about 25 hours of Hot ranking.

Why chain:

1. Why is 100 votes worth so much? Hot is `log10(|score|) + age/45000`, so 100 net votes is 2.0 units, and one unit is 45000 seconds.
2. Why are the first votes worth the most? log10 compresses the top, not the bottom. Votes 1 to 100 are worth as much as votes 100 to 10000.
3. Why does that matter here? On a young site nothing has more than a few dozen honest votes, so 100 is decisive.
4. Why can the attacker produce 100 votes? Because they can produce 100 accounts.
5. Why is that easy? An account costs one form submit.
6. Why that cheap? Signup has no cost and no proof of anything.
7. Why no proof? Login is by email, but nothing in the design says the email is ever proven before the account can act.
8. Why unspecified? The auth library is still listed as Open, so nobody decided.
9. Why does an unproven account still get a counted vote? The vote statement's eligibility test is only "not deleted, not fully banned".
10. Why only that? Because `ban` is the only trust state the schema has.
11. Why only ban? Trust was modelled as something a moderator removes, never as something an account starts with.
12. Why is that a gap? Because moderation is reactive, and a vote counts the instant it lands.
13. Why can't we just react afterwards? Because there is no index to find a tip's voters (section 2.6) and no statement to undo a ring.
14. Root cause: **the schema has no notion of a proven identity, so one vote costs one form submit, and Hot's log10 makes the first hundred of those decisive before any human can react.**

First principles: a vote must cost the attacker more than the vote gains. The 1-hour block I proposed was wrong: it taxes honest new users, who click Helpful and see nothing happen, and it barely taxes an attacker, who can wait. Occam says raise the cost of the identity, not the cost of the vote, and do it where the user is already spending effort.

Fix, three parts, none of which adds a step for an honest user:

1. **Settle the Open item as email-link login.** The user clicks a link in their inbox to sign in, which they were going to do anyway. A working, unique inbox per sockpuppet is roughly a hundred times the cost of a form submit, and the UX is one click instead of a password. Zero code beyond choosing the library.
2. **Cloudflare Turnstile on signup.** Invisible for almost everyone, one script tag and one server-side verify. You already have Cloudflare in front.
3. **Make the ring reversible.** Add the index from section 2.6 and one statement, so the response to a brigade is 30 seconds instead of an outage:

```sql
create index votes_by_tip on votes (tip_id, created_at desc);

-- dead every vote from a set of accounts, then recount the affected rows
update votes set dead_at = now() where user_id = any($1) and dead_at is null;
-- then the existing recount statement
```

This also matches how shadow ban already works: a dead vote is not counted, so the ring's votes vanish without telling the ring.

Cost: one index, one statement, one Turnstile integration (about 20 lines), and a decision on the auth library that you owed anyway. No change to the vote path, no waiting period, no UX for honest users.

### C7. Keep the review branches. Oversample the candidates.

Symptom: 200 candidates all belonged to one popular tip, so the branch returned 1 tip instead of 50.

Why chain:

1. Why 1 tip? All 200 candidates had the same `tip_id`.
2. Why 200? That is the inner `limit`.
3. Why does the collapse not help? `distinct on` runs on the subquery's output, after the limit.
4. Why after? Because the limit is what makes the scan affordable.
5. Why can't the collapse run inside? Neither BM25 nor pgvector exposes a grouped top-N.
6. Why not? Both index and score documents; neither knows what `tip_id` is.
7. Why is the document a review? Because reviews are indexed individually, which is the only way review text is searchable.
8. Why do we want tips out of it? The result unit is one row per tip.
9. Why the mismatch? The retrieval unit and the result unit are deliberately different, and that is the feature.
10. Why does it only bite sometimes? Only when one tip owns a large share of the top-scoring reviews.
11. Why can one tip own so many? Reviews are capped per user, not per tip, so a popular tip accumulates thousands. The fixture's tip 1 holds 2004 of 201523.
12. Why does the fixed 200 not adapt? Because 200 was chosen as a count of candidate reviews.
13. Why is that the wrong thing to count? Because what the branch needs is 50 distinct tips.
14. Root cause: **the limit is expressed in the retrieval unit (reviews) while the requirement is expressed in the result unit (tips), and no operator in either extension can express the requirement directly.**

First principles: given that neither extension can limit by the result unit, the only mechanism left is oversampling, which is exactly what Elasticsearch's field collapse does for the same reason. Pareto: the branch needs 50 distinct tips; oversampling covers every case except a tip that owns more than about 2% of the top-scoring reviews.

Fix: change `limit 200` to `limit 1000` in both review branches. Nothing else.

Why it is free: the vector branch already scans every live embedding regardless, so the limit only sets the size of a top-N heap; 1000 instead of 200 is a heap of 1000 tiny rows. The BM25 branch reads 800 more postings from an index it has already opened. The `distinct on` sorts 1000 rows instead of 200, which is microseconds.

What it does not fix, said plainly: the pathological case measured against `tips_v3`, where one tip holds 2004 reviews and the query matches most of them, still collapses to 1 tip at 1000 candidates. That is acceptable and here is the proof: a tip whose reviews dominate the top of the review ranking is, by construction, the single most relevant tip for that query, and it is already returned — both by its own two branches and by this one. The loss is the long tail of tips that match only through a review, and oversampling by 5x recovers almost all of it. Pair it with the weighted fusion from section 1.9 (review branches at 0.5) so a starved branch can never distort the ordering.

Cost: two characters. `200` becomes `1000`, twice.

---

## Round 4: final check

Three items. First a withdrawal: I suspected the new mark-all-read was a regression. It is not. Measured on a 200k-row copy, same ~2000 unread rows: the doc's capture-and-match form costs 23087 buffers and 10.3 ms, the round-1 form 21352 buffers and 10.5 ms. The 27403 in the table is inherent to updating 2000 scattered rows, not to the array. No finding.

1. **Half of C2 is missing, so placeholders still sit on top of Best.** The author-delete statement removes notifications, media and flags but not the self vote, so a deleted review keeps `up_count = 1`. Measured on `tips_v3`: a placeholder scores 0.378, a live review with no votes 0.000, and a live self-vote-only review ties at 0.378 and loses `order by r.best_score desc, r.id desc` because the repost has the newer id. The three-per-day cap slows the flood; it does not stop three fresh placeholders a day from landing above real reviews. Agreed in round 3, not in the rejected list, one `case`: `best_score ... case when deleted_at is not null then -1 when up_count + down_count = 0 then 0 else <Wilson> end`.

2. **Banning a vote ring leaves its votes counted.** "On confirmed vote abuse, the moderator bans the accounts and the app invalidates those votes with the normal unvote statements." But "ban. Existing content is not changed", and the bulk kill covers `tips` and `reviews`, not `votes`. So a 100-account brigade on 20 tips needs 2000 unvote statement pairs run by hand while the tip stays on Hot. C6 part 3 was agreed and is not in the rejected list: `update votes set dead_at = now() where user_id = any($1) and dead_at is null;` then the existing recount. One statement, and it reuses the dead-vote semantics already there.

3. **New in this rewrite: R2 network calls inside an open transaction.** "Inside the kill transaction, after the row update and before commit, the app copies each of the row's objects to the quarantine bucket, deletes it from the public bucket, and purges the cache for the key." Killing a tip with 10 images is up to 30 round trips holding a row lock and the connection, on one app process. Publish was deliberately changed the other way: "Image checks and copies happen before the transaction opens." Defenses sets `statement_timeout = '2s'`, which does not cover the gap between statements, so a hung R2 pins the lock indefinitely. Smallest fix: commit the row change first, quarantine after, retry on failure from the row's own state; and add `idle_in_transaction_session_timeout = '10s'` to the app role.

Everything else I raised in rounds 1 and 3 is implemented.
