# Opus review B: product, simplicity, conventions

Date: 2026-09-19. Reviewer viewpoint: founder-engineer who has shipped two community sites. Focus per the brief: invented conventions, over-engineering, what an MVP does not need, and whether borrowed conventions were borrowed correctly.

Everything marked "reproduced" was run against the local `tips_v3` database (20,004 tips, 200k reviews, 600k votes) on Postgres 18.6. Nothing was modified; all writes were in rolled-back transactions.

I read `chavruta-02-v3-review.md` rounds 1 to 4 first. I do not re-report C1–C14, F1–F6, or Codex's P1/P2. Where my finding touches one of theirs I say so.

---

## 1. Correctness bugs

### C-B1. An unbanned user's vote is dead forever. Before PMF.

`do update set value = excluded.value, dead_at = coalesce(votes.dead_at, excluded.dead_at)` (v3:362).

Sequence, reproduced:

1. User is shadow-banned. They vote on tip X. The row is born dead. Correct.
2. A moderator unbans them: `update users set ban = null, banned_at = null`.
3. They change their vote on tip X.

Result from the `returning` clause: `old_live = f, new_live = f`. The new vote is dead. `coalesce` can only ever turn a vote dead, never alive. That user's vote on that tip can never count again, on any future switch, forever. The counters are silently wrong and nothing in the design or the test script covers this path.

The doc justifies stickiness only for a self vote after an unkill (v3:435). Nothing justifies it for an unbanned voter.

Smallest fix: `dead_at = excluded.dead_at`. Reproduced: the same sequence then returns `old_live = f, new_live = t`, and the existing delta arithmetic handles it correctly (old was dead, so nothing is subtracted; new is live, so 1 is added). This is a one-token change that also removes a `coalesce`.

### C-B2. Your own review renders twice on every tip page. Before PMF.

The tip page runs two review queries (v3:296–316). The list query has no `and r.user_id <> $2`. The "your review" query returns the same row. A signed-in author of a review sees their review in the pinned block and again in the list.

Smallest fix: add `and r.user_id is distinct from $2` to the list query, or drop the pinned block and mark the row in place, which is what Reddit and Discourse do.

### C-B3. Deleting your tip can delete other people's notifications. Before PMF.

`delete from notifications where tip_id = $1` (v3:403). The design never says which notification types set `tip_id`.

- If `review_upvoted` sets `tip_id` (natural, since the inbox joins `tips` for the title), then a tip author deleting their own tip wipes the "your review got N helpful votes" rows belonging to every reviewer on that tip.
- If `review_upvoted` leaves `tip_id` null, the inbox's `left join tips` gives no context row and the fold key degenerates.

`tip_reviewed` has the same ambiguity: with `review_id` set, each review is a separate row and the fold never fires; with it null, folding works but `delete from notifications where review_id = $1` (v3:400) never cleans up.

This is a specification gap, not a typo, and it decides whether two statements are correct. Smallest fix: write down the column matrix per type, and change the tip-delete cleanup to `where tip_id = $1 and user_id = <tip author>`.

Related to Codex F3, which guards the *trigger* of the cleanup. This is about its *blast radius*.

### C-B4. A named-setup review filter returns unspecified-setup reviews. Before PMF.

```sql
and ($2::text is null or r.model_id = $2 or (r.model_id is null and r.model_other is null))
```
(v3:303, and the same shape for environment on v3:304.)

Filtering the review list to "GPT-5" also returns every review whose author did not say which model they used. No review site I know does this: Amazon's star filter, Google Maps' rating filter and Steam's language filter all return only matching rows. It also directly contradicts the signed chavruta consensus: "Unknown-setup reports remain visible but never enter named-setup counts."

Smallest fix: drop the third disjunct. If you want the unspecified ones, make it a separate checkbox.

### C-B5. The tip page ships the embedding and a second copy of the body. Before PMF.

`select t.*` (v3:287). `tips.*` includes `embedding vector(1024)` (about 4 KB of text on the wire per page view) and `search_text`, which is `title || body || model || tag` — a full duplicate of the body. Both are useless to the renderer.

Round 16 of `chavruta-01.md` already accepted "every public query lists its columns" after the `select r.*` finding. It has regressed.

Smallest fix: an explicit column list. Same change fixes a needless 8 KB per tip view.

### C-B6. `.jpeg` fails after the R2 copy has already happened. Can wait, but it is one line.

`media_key_chk check (key ~ '^media/[0-9a-f-]{36}\.(png|jpg|webp|gif)$')`.

`.jpeg` is the extension most macOS and Windows screenshots and most camera exports carry, and uppercase `.JPG` is common from phones. The upload flow copies `staging/` to `media/` *before* inserting the row (v3:538). So a `.jpeg` upload: passes the type sniff, gets copied, then the insert raises a check violation. The user sees a 500 and R2 keeps an orphan.

Smallest fix: the app normalizes the extension from the sniffed MIME type, not the filename, and the regex adds `jpeg`.

### C-B7. You can review a killed or deleted tip, and its counter moves. Can wait.

The publish-review statement (v3:340–345) checks the author's ban state but never the tip's. The FK only proves the tip exists. So a review can be attached to a tip that was killed by a moderator, and `review_count` on that dead tip increments.

Smallest fix: `join tips p on p.id = $2 and p.dead_at is null and p.deleted_at is null` inside the CTE. Reddit locks comments on removed posts; this is the same rule.

### C-B8. A dead review blocks a re-post with a raw unique violation. Can wait.

`reviews_one_per_user on reviews (tip_id, user_id) where deleted_at is null` (v3:131) does not exclude `dead_at`. A shadow-banned user's second attempt raises a constraint error rather than silently succeeding. Every other shadow-ban path in the design is silent. Shadow bans that tell you you are shadow-banned are not shadow bans.

This is one more reason to cut shadow ban from v1 (see section 4) rather than patch it.

### C-B9. Handles can be 31 characters, not 30. Trivial.

`'^[A-Za-z0-9][A-Za-z0-9_-]{1,30}$'` is 1 leading character plus 1 to 30 more, so 2 to 31. The comment says 30. Also the minimum is 2, so no single-character handles. Decide which you meant.

---

## 2. Performance risks before ~1M rows

Codex's round-4 P1 (sort shape in the vector branch) and P2 (the scale script's profile query) stand. I reproduced P2 independently: the script's version at `scale:122` plans a Parallel Seq Scan over 200k reviews, 3,131 buffers, 14.3 ms; the version documented at `v3:458` uses `reviews_by_user`, 123 buffers, 0.079 ms. The Verification table's row "Profile reviews, next page | Index scan reviews_by_user | 90 | 0.19 ms" is not what the committed script produces.

### P-B1. A browse filter combination with no matches falls off the index entirely. Before PMF.

The doc's mitigation for filters is a single measurement: "134 pages, under 0.1 ms" for one tag filter (v3:229). That is the best case. Measured on the same 20k-tip fixture:

| Filter | Plan | Buffers | Time |
|---|---|---|---|
| tag only | Index scan `tips_hot` | 140 | 0.40 ms |
| tag + model | Index scan `tips_hot`, 438 rows skipped | 461 | 0.85 ms |
| tag + model + environment | Index scan `tips_hot`, 1,266 rows skipped | 1,293 | 4.16 ms |
| a combination with zero matches | **Seq Scan on tips + Sort**, 20,004 rows filtered | 529 | 3.44 ms |

Two things matter. First, the three-filter case is ten times the buffers the doc quotes. Second, when the combination matches nothing the planner abandons `tips_hot` and reads the whole table. The browse UI has three dropdowns, 8 tags times 4 models times 4 environments, so users generate empty and near-empty combinations constantly — that is what dropdowns are for. At 1M tips the empty case is roughly 26k buffers of sequential read plus a sort, per request, on a path a bored user can hammer. `statement_timeout = 2s` is the only thing standing behind it.

This is the same family as Codex's round-1 P2, which the doc answered with the single-filter number. The answer is not sufficient.

Fixes, cheapest first:
1. Cut the environment filter from browse. Two facets instead of three (see the cut list). Removes the worst combinations for free.
2. Add `include (tag_id, model_id, environment_id)` to `tips_hot` and `tips_new`. The filter is then applied index-only and the heap is touched only for the 20 winners.
3. If you keep three facets at scale, add one composite index per facet you actually offer, e.g. `(tag_id, hot_score desc, id desc) where deleted_at is null and dead_at is null`.

### P-B2. `select t.*` on the tip page. Before PMF.

See C-B5. Every tip view moves a 1024-dimension vector and a duplicate of the body out of Postgres. At a few thousand views a day this is wasted bandwidth and buffer cache, and it is free to fix.

### P-B3. `statement_timeout = 2s` versus the exact vector scan. Before PMF, if search ships.

The doc plans for an exact sequential scan over every live embedding until about 50k rows, and estimates about 200 MB read per query at that point. 2 seconds is not much headroom for two such branches (tips and reviews) plus BM25 plus the fusion, on a box that may also be running the embedding server. Either raise the timeout for the search role, or do not ship vector search in v1 (see the cut list).

### P-B4. Window ordering in the review search branches. Not a bug today.

Codex's round-4 table already flags the missing explicit `order by` on the review branches' `limit 50`. For the record: I ran the same shape on real rows and Postgres does emit `WindowAgg` output in the window's sort order, so the top 50 by distance are the ones kept. The plan is `Limit -> WindowAgg -> Sort`. It works; it is just not guaranteed. Adding `order by rank` costs nothing.

---

## 3. Invented conventions

### 3a. The product-level inventions

These are the ones that matter most. They are not SQL bugs; they are the design drifting away from both the industry pattern it names and the project's own signed consensus.

**I1. A one-per-user review with no verdict. Before PMF. This is the big one.**

Rule 7 of the Patterns table claims "One review per user per item — Yelp, Google Maps, Steam, Amazon". That constraint was borrowed; the thing that makes it work was not. Every one-per-user review system I am confident about *requires* an outcome from the reviewer: Steam requires Recommended or Not Recommended, Google Maps requires a star rating, Amazon requires a star rating, Yelp requires a star rating. The rating is why one-per-user is the right constraint — it is a ballot, and each person gets one.

v3 has the ballot rule with no ballot. A review is free markdown with no verdict field. The consequence:

- A tip page shows N unranked opinions and no aggregate. The reader cannot tell at a glance whether the tip works.
- `review_count` on browse means "comment count", nothing more.
- Meanwhile the discussion affordances of a comment system are absent too: no replies (deferred), one per person, no threading.

So the design has the *constraint* of a review system and the *payload* of a comment system, and neither system's benefit. I do not know a site that does this.

Back-reference: `chavruta-01.md` closing summary names the verdict and the setup fields as the two things that "turned out to be load-bearing and nearly got cut". The decision log for v3 records `worked` as dropped, with no recorded reason, and the signed amendment "Report counts are always labeled by model and environment and scoped to the selected setup. An unlabeled total is never shown" is reversed with no entry in the decision log at all. v3 shows exactly an unlabeled global total.

Cheapest repair, zero schema change: **relabel the tip vote from "Helpful / Not helpful" to "Worked / Didn't work".** The vote *is* the verdict. `up_count` becomes "12 people said this worked". You get the product's differentiator back for the cost of two strings, and the Hot ranking becomes an honest effectiveness ranking instead of a karma score wearing a "helpful" label.

Second cheapest, one column: `tips.last_up_at timestamptz`, set in the vote statement when the vote is a live up vote. The tip page then shows "last confirmed 3 days ago". This addresses the founding observation of the whole project — "slang definitions don't expire, LLM tips do" — which v3 currently does not address at all. There is no freshness signal in the model. Hot decays by *post* age, not by *evidence* age, so a tip that stopped working a year ago looks identical to one confirmed yesterday.

Third, optional, defer: `votes.model_id` so a vote carries the voter's setup. The doc's stated reason for dropping setup-scoped counts is "Votes have no setup" (v3:654). That is a property of the current schema, not a law. One nullable column fixes it. I would defer this, but I would not pretend the objection is structural.

**I2. Pick a label that means what it does. Before PMF.**

"Helpful / Not helpful" is a *review-quality* label everywhere I know it: Amazon, Steam ("Was this review helpful? Yes / No / Funny"), IMDb. It is attached to a review, not to the item. v3 puts the identical pair of buttons on the tip and on the review, meaning two different things, next to each other on the same page.

Item-level conventions: up/down arrows (Reddit, Lemmy), thumbs up/down (Urban Dictionary — which is the product's own stated analogy), recommend/not recommend (Steam), stars (Maps, Amazon, Yelp). Use one of those on the tip. Keep Helpful on the review.

**I3. Hot is the wrong default sort for this site, and at launch it is literally New. Before PMF.**

The formula is copied correctly. Reddit's `_hot` is `sign * log10(max(|s|,1)) + (epoch - 1134028003) / 45000`, and v3 matches it including the 2005 epoch constant. That is the problem: the 45,000-second divisor was tuned for a firehose where a front-page post collects thousands of votes in hours.

Measured on the fixture (scores up to 196, one year of tips):

- The top 100 by `hot_score` and the top 100 by `created_at` are **the same 100 rows**. Overlap: 100/100.
- Scores of -1, 0 and +1 all produce a hot term of exactly 0.0 — they are indistinguishable.
- A score of 10 buys 12.5 hours of head start. A score of 200 buys 28.8 hours.

So "Hot" and "New" are two tabs showing the same list, and they will stay that way until a tip reliably collects tens of votes within a day. At MVP volume that is never.

Worse, this is backwards for the product. This is a reference site — Urban Dictionary for prompting. Urban Dictionary leads with the top-rated definition, not the newest. Stack Overflow's default question sort on a tag page is not recency-decayed either. People arrive with a problem and want the best answer, not this morning's answer.

Recommendation: ship **New** and **Top** (`order by score desc, id desc`, one index on the `score` column that already exists). The "What was left out" table defers Top with the trigger "when readers want all-time best". Readers want all-time best on day one; that is what a reference site is. Defer Hot instead, with the trigger "when a tip collects more than 100 votes in a day".

**I4. Wilson "Best" on reviews is also New in disguise. Before PMF.**

Computed exactly as written: a review with the author's self up vote and nothing else scores 0.378448. Every such review ties, and the tiebreak is `id desc`, i.e. newest first. A review with one up and one down scores 0.164; with zero up and one down, 0.0, which ties with an unvoted born-dead review.

Wilson is the right answer at Reddit's comment volume and is pure overhead at zero. `order by up_count desc, id desc` gives the identical ordering today for 24 fewer lines of generated-column SQL, and it is what Amazon and Steam call "Most helpful". Add Wilson when a review routinely gets 20 votes.

**I5. `noindex` until there is traffic. Before PMF. This is self-defeating.**

`<meta name="robots" content="noindex">` until there is traffic (v3:546). For a reference site, organic search *is* the traffic. Urban Dictionary, Stack Overflow and every wiki-shaped UGC site live on Google. Waiting for traffic before allowing indexing is waiting for the thing that indexing produces. Indexing also has a lag of weeks.

Recommendation: noindex during a closed beta with a known end date, then remove it at launch. If the worry is thin pages, noindex tips with zero reviews, not the whole site.

**I6. The copy target is not in the schema. Before PMF.**

`chavruta-01.md` round 4 reduces the whole product to three verbs: find, copy, trust. The copy button is called "the one lifted object on every screen" in the prototype's design intent. The reconciled v1 tip is "Title. Instructions, with where to apply them stated inside."

In v3 a tip is `title` plus a markdown `body` plus an optional `prompt` documented as "optional example, verbatim". So the pasteable text is either the whole markdown body (which includes prose, caveats and links) or an optional example field. There is no field whose contract is "this is the text you paste".

Recommendation: decide, and write it down. Either the copy button copies the whole `body` (then say so, and tell authors the body is the instruction), or add a required short `instruction` field and keep `body` for the explanation. This is a form-design decision, not a schema problem, but the schema currently does not encode it either way.

### 3b. Table

| Invented thing | Industry standard that could replace it | Recommendation |
|---|---|---|
| One review per user with no verdict field | Steam, Google Maps, Amazon, Yelp all require a rating or recommend/not-recommend on a one-per-user review | Relabel the tip vote "Worked / Didn't work". Zero schema change. See I1 |
| "Helpful / Not helpful" on the *tip* | Thumbs up/down (Urban Dictionary), up/down arrows (Reddit), recommend (Steam), stars (Maps) | Relabel. "Helpful" stays on reviews only |
| Hot as the default sort at zero volume | Top/score-ordered lists on reference sites (Urban Dictionary, Stack Overflow tag pages) | Ship New + Top. Defer Hot until a tip gets 100 votes in a day |
| Wilson lower bound on reviews that have one self vote each | "Most helpful" = up-count order (Amazon, Steam) | `order by up_count desc, id desc`. Drop `best_score` for now |
| No freshness signal at all on content that expires | Steam's "Recent reviews", Google Maps' review dates | One column: `tips.last_up_at`. Show "last confirmed N days ago" |
| Facet values (`tag_id`, `model_id`) concatenated into the BM25 text | Facets are filters, not free text, in every search stack | Remove them from `search_text`. You already have the dropdowns |
| Unweighted RRF summing 2 tip branches and 2 review branches | Weighted RRF | A tip with reviews can score up to 4 contributions, a tip without at most 2. Halve the review branches, or drop them in v1 |
| Named-setup filter that also returns unspecified setups | Amazon, Maps, Steam filters return only matches | Drop the third disjunct. See C-B4 |
| `pg_textsearch`, which pins hosting to the Tiger image | Stock Postgres `tsvector` + GIN with `setweight` for title boost | Stock FTS in v1. Keeps Neon, Supabase, RDS and Fly open. See the cut list |
| Base36 ids in the URL | Decimal id + slug (Stack Overflow `/questions/{id}/{slug}`, Discourse `/t/{slug}/{id}`) | Use the decimal id. Reddit's base36 is a 2005 legacy, not a convention to copy. You also cannot say "tip 42" to anyone |
| Reddit's 2005 epoch constant `1134028003` | Your own launch epoch | Cosmetic. Keeps hot_score readable. Optional |
| `epoch_of()` declared IMMUTABLE over a STABLE builtin | A plain `created_epoch bigint` column set at insert | The wrapper is safe for epoch specifically. Keep it, but add a comment forbidding any other `extract` field. It is a foot-gun for the next person |
| `noindex` until there is traffic | Index from launch; noindex only a closed beta | Remove at launch. See I5 |
| Notifications for up votes | Reddit sends none for votes. HN sends none at all. Discourse does notify on likes | Keep `tip_reviewed`, defer the two vote types. See the cut list |
| Ten image slots per tip *and* per review | The project's own interaction model is one prompt, one output | One image each. Keep the `position` column for later |
| Upload-only images, no link path | The signed round-13 consensus kept "a link accepted as the alternative for any of them" | One nullable `url` column on `media`. Cheap escape hatch that was dropped without a decision-log entry |
| `create domain` for three small enums | Postgres `create type ... as enum`, or a plain text check on the column | Cosmetic, no action. Domains are fine |

---

## 4. Cut list

Ordered by how much complexity each removes per unit of user value lost.

**1. Hybrid search. Cut the vectors and `pg_textsearch` from v1. Before PMF.**

What this removes: pgvector, `pg_textsearch`, two `embedding` columns, two `embedding_model` columns, two BM25 indexes, two queue indexes, the background embedding worker (the only background job in the system), the MLX dev server, the re-embed-on-edit conditional write, the 4B migration plan, the HNSW trigger, the 200 MB-per-query scan, the RRF CTE, the four search branches with their collapse logic, and the hosting constraint that rules out Neon, Supabase and RDS.

What replaces it: `to_tsvector('english', title)` with `setweight('A')` plus the body at `'B'`, one GIN index, `websearch_to_tsquery`, `ts_rank_cd`. Stock Postgres. Runs anywhere. Roughly fifteen lines.

Why it is the right cut:
- The doc says plainly that this SQL "is not yet run" and the extensions are not installed locally. It is the largest and least verified block in the design.
- `chavruta-01.md`'s reconciled v1 says "Search is full text over title and instructions, sorted by relevance, with one filter: model." Hybrid search was never in the signed v1. It appeared in v3 with no trigger.
- The project's own deferral discipline has a trigger for exactly this: "Problem pages and synonym consolidation — build when search logs show readers failing to find tips that exist." Vectors are the answer to synonym failure. You do not have the logs yet.
- With a few hundred short tips, BM25 versus `ts_rank_cd` is a rounding error. With a few hundred tips, the vector branch is a solution to a vocabulary problem that a few hundred tips cannot have.

If you disagree on vectors, at minimum cut `pg_textsearch`: pgvector is available on Neon, Supabase and RDS, so keeping stock FTS plus pgvector preserves the hybrid idea *and* hosting portability. Choosing an extension that forces one vendor, for a feature that has never been executed, is the wrong order of decisions.

**2. Shadow ban. Ship `full` only. Before PMF.**

Keep the `ban_status` domain and the `dead_at` columns. Do not implement the `'shadow'` branch at launch.

What this removes: the born-dead `case when u.ban = 'shadow'` in the publish-tip, publish-review and vote statements; `votes.dead_at` and its interaction with the counter deltas (which is the entire reason the vote statement needs `old.dead_at`/`new.dead_at`); C-B1 above; the dead-self-vote-after-unkill reasoning; four of the behavior tests; and the C-B8 leak that makes the shadow ban announce itself anyway.

Reddit, HN and Lobsters all shadow-ban, but they added it after they had a spam problem worth automating against. You will have fewer than five bad actors before PMF and a `full` ban plus a kill button handles all of them in thirty seconds each. The column stays, so adding it later is a day of work.

**3. Vote notifications. Keep `tip_reviewed` only. Before PMF.**

Drop `tip_upvoted` and `review_upvoted`.

What this removes: one notification upsert on the hottest write path in the system (every vote); the `count` column and the whole event-count-versus-people-count argument; most of the fold index's purpose; and one of the two cleanup deletes.

Reddit does not notify you about up votes. HN does not notify you about anything. Discourse does notify on likes, so there is a precedent, but Discourse is a forum where a like is a rarer and more personal act. "Your tip got 14 helpful votes" is a karma push notification; it is the gamification the chavruta explicitly put out of scope, not deferred.

What survives — "handle reviewed your tip" — is the one notification that causes a user to come back and do something. It needs no folding (each review is a distinct target), no count column, and no masking argument for votes.

**4. `best_score` (Wilson). Before PMF.** See I4. Replace with `up_count desc, id desc`. The `reviews_best` index becomes `(tip_id, up_count desc, id desc) where dead_at is null`.

**5. `hot_score`. Before PMF.** See I3. Replace with a Top sort on the existing `score` column. This also deletes `epoch_of()` and its IMMUTABLE problem entirely.

**6. Ten image slots, on both tips and reviews. Before PMF.** The interaction model the project signed is one prompt and one output. Ten images per tip and ten per review is 20 objects per tip-plus-one-review, all of which a human moderator may have to look at. Set the limit to one and keep the `position` column. This also shrinks the R2 bill, the moderation surface, and the "images for the page" query to a trivial lookup.

**7. The environment filter on browse. Can wait, but it is free.** Two facets (tag, model) instead of three cuts the worst filter combinations, which is P-B1's cheapest fix. Keep `environment_id` on the row; just do not offer it as a browse dropdown until someone asks.

**8. The review branches in search. Before PMF, if you keep search at all.** `reviews_bm25` and `reviews_vec` plus their collapse logic are half the search SQL. They exist to surface a tip because someone's *review* mentioned the query term. On day one there are no reviews. Ship tip-only search; add review search when a tip page routinely has ten reviews.

**9. Base36 ids. Before PMF, costs nothing to drop.** See the conventions table.

### What to add back, because it is cheap and it is the product

- Relabel the tip vote "Worked / Didn't work". Zero schema change.
- `tips.last_up_at timestamptz`, set in the vote statement. One column. Restores the freshness story the project was founded on.
- A Top sort. One index on an existing generated column.

That is one column and two strings to get back the two things `chavruta-01.md` named load-bearing.

---

## 5. Verdict

**Ship with fixes, but cut before you fix.** The schema itself is sound and small — nine tables is right, the generated-column trick for ranking is genuinely elegant, and the two-marker moderation model is borrowed correctly from HN. The problem is not the tables, it is the machinery bolted to them and the product that machinery serves. Two subsystems — hybrid search with an embedding worker, and vote notifications — plus two ranking formulas account for most of the design's operational surface, and all four are calibrated for traffic the site does not have: Hot and Best both reduce to New at launch (measured: the top 100 by `hot_score` and by `created_at` are the same 100 rows), the vector branches have never been executed, and `pg_textsearch` is buying a hosting lock-in for an unrun query. Meanwhile the thing the project's own brainstorm twice identified as load-bearing — a verdict on whether a tip actually worked, and some signal of when it last worked — was dropped without an entry in the decision log, leaving a one-review-per-user constraint borrowed from Steam and Google Maps with the rating that justifies it removed. The result reads as a competent Reddit clone for prompting tips, which is a thing a subreddit already is. Cut items 1 through 5 on the list, relabel the tip vote, add `last_up_at`, fix C-B1 through C-B5 and Codex's F1 through F6, and you have a smaller system that is also a more distinctive product. No redesign.

---

## Round 3: root causes and fixes that keep the feature

Date: 2026-09-19. Second pass on my own cut list, under the rule that nothing in the consensus is removed, deferred, or relabelled.

Everything marked "measured" was run today against `tips_v3` on Postgres 18.6 (20,004 tips, 201,523 reviews, 595,614 votes, 319,858 notifications). Reads only. The two write experiments ran in transactions that were rolled back. Neither `pg_textsearch` nor `vector` is in `pg_available_extensions` on this box, so no search SQL could be run; where I needed a number for a search branch I measured the same shape without the extension and said so.

Three of my round-1 symptoms were overstated. I correct them in B4, B5, and B8, and I withdraw B12 as a cut because it contradicts the consensus.

### B1. Hybrid search stays. pg_textsearch and pgvector both stay.

Symptom: the search SQL has never been executed, `pg_textsearch` rules out Neon, Supabase, and RDS, and the vector branches plan an exact scan.

Whys:

1. Why is the search SQL a risk? It has never run.
2. Why has it never run? The extensions are not installed on the dev machine.
3. Why not installed? Measured: `pg_available_extensions` lists neither. They are not even packaged for this Homebrew build.
4. Why is the dev box a Homebrew Postgres? The schema work started there, and the schema needs no extensions.
5. Why did it stay the dev box after search was added? Schema and search were written in one document but verified to two different standards: the schema against a running server, the search against a vendor guide.
6. Why two standards? No rule says the dev database must match production.
7. Why no such rule? Production is undecided. The Open list says so.
8. Why undecided? Hosting was framed as "which managed Postgres", and `pg_textsearch` removes the managed options.
9. Why does that block it? The design is asking two questions at once: which search engine, and who operates the database.
10. Why are they one question? The engine lives inside the database.
11. Why does that bite here and not for pgvector? pgvector ships on Neon, Supabase, and RDS. `pg_textsearch` does not. One of the two extensions is portable, one is not.
12. Why was the non-portable one picked? The whole hybrid recipe came from one vendor's guide, written for that vendor's image.
13. Why was one guide enough? Nothing forced a second source or a local run.

Root cause: there is no single environment that is both the development database and the production shape. The unrun SQL, the open hosting question, and the unmeasured vector cost are all downstream of that one gap. The extension choice is not the problem.

Fix, keeping hybrid search exactly as decided:

- Make `timescaledb-ha` the dev database. One docker-compose service. Restore the DDL the test script currently skips: two `embedding vector(1024)` columns, two `embedding_model` columns, two BM25 indexes, two `needs_embedding` indexes. Re-run both existing scripts against it. This answers the Open item about whether `<@>` accepts a subselect, and it settles hosting by default: production runs the same image on a VPS, which the Open list already lists as option one.
- Vector scan cost: add HNSW at launch instead of at 50k rows. The doc's own trigger is "about 50k embedded rows, about 200 MB per query". Reviews are the 10x table and the fixture already holds 201,523 of them. 201,523 x 1024 x 4 bytes is 825 MB of vector payload for one exact scan, and pgvector stores `vector` as EXTERNAL, so that is 200k TOAST fetches, not one sequential read. Measured floor on the same table without any vector: a full scan plus a top-1000 heapsort over 200k live reviews is 3,065 buffers and 131 ms. Two branches of that plus BM25 plus the fusion, under `statement_timeout = 2s`, has no headroom. So the "no HNSW in v1" decision contradicts the doc's own trigger the moment reviews are embedded.

Cost: about 10 lines of docker-compose, about 8 lines of DDL restored to `data-model-v3-test.sql`, two `create index ... using hnsw` statements. No change to the design, no change to the query.

### B2. Shadow ban stays.

Symptom: the born-dead branch runs through three statements, and an unbanned user's vote is dead forever (C-B1).

Whys:

1. Why is the vote dead forever? `dead_at = coalesce(votes.dead_at, excluded.dead_at)`.
2. Why a coalesce? To keep a dead self vote dead after an unkill.
3. Why must it stay dead? The born-dead tip started at `up_count = 0`, so counting the self vote later would show a vote that was never counted.
4. Why does the self vote share a path with other people's votes? It is an ordinary row in `votes`.
5. Why is the rule written on the vote upsert? That is the only statement that touches `votes.dead_at` after insert.
6. Why not handle it on the unkill path? Unkill only writes `tips` and `reviews`.
7. Why does unkill not write votes? Because the counter is already right after an unkill without touching them.
8. So the coalesce guards a case the unkill statement never creates. Why was it added? Because "dead" was treated as a property that can be acquired but not lost.
9. Why treated that way? For tips and reviews a moderator reverses it explicitly, so there is always an explicit reverse. For votes there is none.
10. Why is there no reverse for votes? Unbanning is `update users set ban = null`, and nothing re-evaluates existing votes.
11. Why does nothing re-evaluate them? Because `dead_at` on a vote records the state of the *voter at write time*, while `dead_at` on a tip records whether the *row* is hidden now.
12. Why does one column name carry two meanings? Because rule 1 defines `dead_at` once, for rows, and votes reused it.

Root cause: `dead_at` means "born under a ban" on votes and "hidden right now" on tips and reviews. The coalesce is correct for the second meaning and wrong for the first. Shadow ban is not the cause; a name collision is.

Fix, keeping shadow ban:

- `dead_at = excluded.dead_at`. One token. A vote's deadness is recomputed from the voter's current ban state on every write, which is what the column means on votes. The existing delta arithmetic already handles the transition in both directions.
- The case the coalesce guarded cannot arise. Confirmed by reading the Moderate block: no unkill statement writes `votes`.
- The second tell, reproduced today: a shadow-banned user's second review on the same tip raises `duplicate key value violates unique constraint "reviews_one_per_user"`. The UI path never reaches it, because the "my review" query has no `dead_at` filter and already shows the banned user their own dead review, so the form says "you already reviewed this". Only an API client hits the raw error. Map that one constraint name to the same response the UI gives.

Cost: one token of SQL, one exception mapping in app code. Nothing is removed. I withdraw the C-B8 argument for cutting shadow ban.

### B3. Both vote notification types stay. My symptom was the wrong one.

Symptom, corrected. The upsert is not expensive. Measured today: the fold path is 8 buffers and 0.31 ms; the first insert of a fold group is 46 buffers and 1.85 ms, of which most is four indexes and four foreign-key checks. The doc puts the vote statement itself at 40 buffers and 0.5 to 0.8 ms. So the notification roughly doubles a vote, in a request that has a 2 s budget. That is not a reason to cut anything.

The real symptom is contention, and I missed it. Reproduced with two sessions: session A folds a `tip_upvoted` row and holds its transaction open; session B folds the same row and waits 2,978 ms. The app role's `statement_timeout` is 2 s.

Whys:

1. Why did the second voter wait? `on conflict do update` takes a row lock on the conflicting row.
2. Why the same row? The fold key is `(user_id, type, tip_id, review_id)`. That is one row per tip author per tip.
3. Why one row? Folding is the feature: "your tip got 14 helpful votes", one line, not fourteen.
4. Why did the wait last three seconds? A row lock is held until the enclosing transaction commits.
5. Why was the transaction that long? Because it was told to sleep, but in production the vote and the notification are in one transaction and the whole request holds the lock.
6. Why one transaction? Nothing says they must be separate.
7. Why should they be? They have different consistency needs. The counter must be exact. The notification is advisory.
8. Why was the difference not noticed? Because the fold was designed as a write-time optimisation, and write-time optimisations were assumed to be free.
9. Why assumed free? The doc measures per-statement cost, never contention.
10. Why never contention? Both verification scripts run in one session.
11. Why one session? There is no concurrency test anywhere in the design.
12. Why not? Every other write in the system touches a row that only one user owns. The notification row is the first write shared by many users at once.

Root cause: folding deliberately funnels every voter on a tip through one row, and that row is locked inside the voter's own transaction. Nothing in the verification plan can see a serialization point, because it is single-session throughout.

Fix, keeping `tip_upvoted` and `review_upvoted` and the fold:

- Write the notification in its own short transaction, after the vote transaction commits. The lock is then held for about 0.3 ms instead of for the whole request. A notification lost to a crash is an acceptable loss; a vote lost to a lock wait is not.
- Wrap it in `set local lock_timeout = '200ms'` and drop the notification on timeout. A queued advisory can never eat the 2 s statement budget.
- Event count versus people count: the decision log accepts events, so it stays. The one place it is visibly wrong is when "your tip got 14 helpful votes" is larger than the `12` shown on the tip page. Cap it in the inbox select: `least(n.count, t.up_count)`. One expression, no schema change.

Cost: one transaction boundary in app code, one `set local`, one `least()`. No SQL statements removed, no columns dropped.

### B4. Wilson stays. My symptom was half wrong.

Symptom, corrected. The first half holds: computed today, a review with the author's self up vote and nothing else scores 0.3784475032252061, and every such review is exactly tied. The second half does not. I claimed `up_count desc, id desc` gives "the identical ordering today". It does not once any down vote exists. Measured: (5,0) scores 0.7527 and (10,1) scores 0.7395, so Wilson puts the smaller unanimous review first. On tip 1, the top 30 by `best_score` and the top 30 by `up_count` share only 9 ids and none at the same position. Replacing Wilson with `up_count` is a behaviour change, not a simplification. That kills my own cut on its merits.

Whys, on the part that is real:

1. Why does every fresh review tie? Its counts are (1, 0).
2. Why (1, 0)? Auto up vote on your own post, which is decided.
3. Why does that make the score constant? Wilson is a function of `up_count` and `down_count` and nothing else.
4. Why nothing else? A confidence bound is defined on a sample. That is what makes it a Wilson bound rather than a heuristic.
5. Could a different counts-based formula break the tie? No. Equal inputs give equal outputs, for every function.
6. Could a non-counts term break it? Yes, but then it is not Wilson, and Wilson is the decided feature.
7. So the tie is a property of the data. Why does it read as a defect? Because the tab is labelled "Best" and shows the same order as "New".
8. Why the same order as New? The tiebreak is `id desc`, and ids are chronological.
9. Why `id desc`? Keyset pagination needs a unique last sort column, and `id` is the only one.
10. Why not a different tiebreak? Any other candidate column is `created_at`, which is also chronological.
11. Why is there no non-chronological column to break ties with? A review carries no quality signal other than its votes.
12. Why not? That is what a review is. The signal has to be collected.

Root cause: at launch there is no evidence about review quality, and no ranking function can manufacture evidence. Best equals New because the two questions have the same answer when the sample is empty. This is the same behaviour as Reddit's Best on a two-minute-old post.

Fix: none in SQL. Keep `best_score` and `reviews_best` as written. The tie breaks on the first vote by anyone other than the author: (2,0) scores 0.5491 against (1,0) at 0.3784.

One note, not a fix. Wilson at (0,1) evaluates to -4.2e-17, not 0, so a single downvoted review does sort below an unvoted one. That is the direction you want, but it arrives by float rounding. Never compare `best_score = 0`.

Cost: zero.

### B5. Hot stays, and it is the default. One constant changes.

Symptom, corrected. I wrote that the top 100 by `hot_score` and the top 100 by `created_at` are "the same 100 rows". Measured today: they share 86 of 100, and page one shares 12 of 20. My number was wrong.

But the fixture flatters Hot. Its tips have median score 29, mean 41, max 196, spread over 365 days. At launch a tip has 0 to 3 net votes. Re-measured with scores capped at 3 and the real timestamps kept: overlap becomes 94 of 100, and 16 of 20 on page one. Capped at 10: 92 of 100. So the convergence is real and my exaggeration hid the actual size of it.

Whys:

1. Why do Hot and New converge? The age term dominates the vote term.
2. Why? One order of magnitude of net votes buys 45,000 seconds, which is 12.5 hours.
3. Why 45,000? It is Reddit's divisor, copied with the formula.
4. Why does 12.5 hours work at Reddit? A front-page post there collects on the order of 1,000 votes in hours, so the vote term moves about 3 units, or 37 hours.
5. Why does it not move here? A tip collects 0 to 3 votes on its first day. Measured: 912 of 20,002 fixture tips sit in score -1 to 1, and at launch nearly all of them will.
6. Why do scores -1, 0 and 1 all give the same vote term? `log(greatest(abs(score),1))` is log10(1), which is 0.
7. So below score 2 there is no vote signal at all. Why was that accepted? The behaviour test says "Scores 0 and -1 tie, because log of 1 is 0. That matches Reddit."
8. Why does it matter more here than at Reddit? At Reddit almost nothing on the front page has score below 2. Here almost everything will.
9. Why? Post rate and vote rate are both about three orders of magnitude lower.
10. Why does the divisor not scale with that? It is a literal constant in a generated column.
11. Why should it scale at all? Hot compares votes against *positions in the New list*. A 12.5 hour head start is worth however many posts arrive in 12.5 hours.
12. How many arrive here? At 5 tips a day, 2.6 tips.
13. Why is 2.6 not enough? A page is 20 rows. A head start worth less than half a page is invisible.
14. Why did copying the formula not copy that? Because the formula is dimensionless and the constant is not. 45,000 has units of seconds per order of magnitude of votes, and it only means something relative to a posting rate.

Root cause: 45,000 is not a property of the formula. It is a property of Reddit's posting rate. The formula was borrowed correctly and the calibration was not.

Fix, keeping classic Reddit Hot as the default sort:

- Change the one constant. Set it so an order of magnitude of votes outranks roughly one page of new tips: divisor = 86,400 x page size / tips per day. At 20 per page and 5 tips a day that is 345,600, meaning 10x the votes buys 4 days.
- Measured on the fixture with launch-scale scores (capped at 3) and real timestamps, overlap with the top 100 by New: 45,000 gives 94; 90,000 gives 87; 172,800 gives 80; 345,600 gives 76; 691,200 gives 74.
- Re-tune it once, when the real posting rate is known. It is the only knob, and it is one number.

Cost: before launch, one literal in the `hot_score` generated column. Zero. After launch, `drop column hot_score`, `add column hot_score ... generated`, `create index tips_hot` again: a table rewrite of 4 MB today, a few seconds at 1M tips.

Optional, and it deviates from Reddit, so take it only if you want the first vote to count: `log(greatest(abs(score),1))` to `sign(score) * log(abs(score)+1)`, which gives score 1 a term of 0.301 and score 2 a term of 0.477. One token.

I withdraw the proposal to ship Top in place of Hot. Top is deferred by the consensus and that stands.

### B6. Ten images per tip and per review stay.

Symptom: moderation surface and R2 cost.

Whys:

1. Why is 10 a problem? Up to 20 objects per tip-plus-one-review that a human moderator may have to open.
2. Why would a moderator open all of them? A flag points at the tip or the review, never at an image.
3. Why not at an image? `flags` has `tip_id` and `review_id` only, by rule 7.
4. Why does that matter? The moderation queue select returns `t.title` and `r.body`. It does not join `media`.
5. Why not? It was written for text.
6. Why does that make 10 worse than 1? The cost is per image opened, and the queue gives no hint which one to open, so the moderator opens all of them.
7. Why is there no hint? Nothing records which image was reported, and nothing shows the images at all.
8. Why is that the real driver? Moderation cost is flags x images per flagged item. Only the second factor is in the schema, so only the second factor got noticed.
9. Why was the R2 bill argued from the slot count? Because 10 slots reads as 10 images.
10. Why is that wrong? The slot count is a ceiling, not a mean. Instagram allows 10 and the median post has one.
11. What actually drives the R2 bill? Uploads per user per hour, which is a rate limit, not a slot limit.
12. Is that rate limit already in the design? Yes. Defenses says "one rate limit per user in the app, on writes and upload signing."

Root cause: the cost is in the moderation workflow, not in the slot limit. Cutting to one image lowers a ceiling almost nobody reaches and does not touch the queue.

Fix, keeping ten:

- Show the images in the moderation queue. Add one lateral to the queue select: `left join lateral (select array_agg(m.key order by m.position) as keys from media m where m.tip_id = f.tip_id or m.review_id = f.review_id) m on true`. The moderator sees thumbnails and resolves in one screen.
- Keep the existing per-user upload rate limit. That is the R2 control.

Cost: three lines in one moderator-only query. Ten slots stay on both tables.

### B7. All three browse filters stay.

Symptom, re-measured today. `tag + model + environment` is an index scan on `tips_hot` that skips 899 rows to return 20: 923 buffers, 1.47 ms. A combination with no matches falls off the index entirely: Seq Scan plus Sort, 523 buffers, 4.6 ms, 20,004 rows filtered. And empty combinations are reachable with real ids, not just typos: the active lists hold 8 tags, 4 models, 7 environments, so the UI offers 224 three-way combinations, and the fixture fills 129 of them. `examples + claude-opus-5 + api` returns zero rows.

Whys:

1. Why is the three-filter case slow? The filter is applied after the index hands over the row.
2. Why after? `tag_id`, `model_id`, `environment_id` are not in `tips_hot`.
3. Why not? `tips_hot` is `(hot_score desc, id desc)` and nothing else.
4. Why only those? It was built for the unfiltered front page.
5. Why did that look sufficient? The doc measured one filter and got 134 buffers.
6. Why does one look fine and three look bad? Selectivity multiplies: 1/8, then 1/32, then about 1/224.
7. Why does the heap get touched for rows that are thrown away? The filter columns are not in the index, so each candidate needs a heap fetch before it can be rejected. 899 fetches to return 20.
8. Why does an empty combination abandon the index? The planner estimates 0 matching rows, so it knows it must examine everything either way, and a sequential scan is the cheapest way to examine everything.
9. Can an index beat that? Measured with `enable_seqscan = off` on a covering index: 341 buffers and 1.97 ms against 523 buffers and 1.84 ms. No.
10. Why not? Proving a set is empty costs a full pass unless the filter columns lead the index.
11. Why do they not lead? Keyset pagination requires the sort key to lead.
12. Why can they not both lead? One btree has one column order. Three independent facets would need one index per leading facet.
13. Why is the empty case reachable at all? The UI offers 224 combinations and the data fills a fraction of them.
14. Why does the UI offer combinations with no rows? Each dropdown lists all active rows of its own table, independent of the other two.
15. Why independent? Because no query tells the UI which combinations exist.

Root cause: two separate causes wearing one symptom. The non-empty slowdown is a missing covering index. The empty case is a UI that offers questions the data cannot answer, and no index can make "prove nothing matches" cheap.

Fix, keeping tag, model and environment:

- Add `include (tag_id, model_id, environment_id)` to `tips_hot` and to `tips_new`. Measured on the same fixture, in a rolled-back transaction: `tag + model + environment` drops from 923 buffers and 1.47 ms to 20 buffers and 0.11 ms, an index-only scan with 11 heap fetches. Tag alone drops from 140 buffers to 5. That is 46x on the worst live case, from one clause on each of two index definitions.
- Do not make the empty query fast. Stop asking it. Compute the facet counts and grey out the zero-count values, which is what every faceted store does. Measured: `select tag_id, model_id, environment_id, count(*) from tips where deleted_at is null and dead_at is null group by 1,2,3` is 523 buffers and 6.0 ms and returns 129 rows. Cache it for 60 seconds. The empty combination becomes unreachable, and the counts are useful to the reader on their own.

Cost: one `include` clause on each of two indexes, one `group by` query, one 60 second cache. Three facets stay.

### B8. Both review branches stay in search. My symptom was a fixture artifact.

Symptom, reproduced and then corrected. Reproduced: a 200-row candidate pool whose rows all sit on one tip collapses to exactly 1 result. Measured with a token that matches 1,991 of tip 1's 2,004 review bodies, the pool of 200 yields 1 distinct tip.

Corrected: tip 1 is a loader artifact. Excluding it, reviews per tip in the fixture are median 10, 99th percentile 18, maximum 24. So in the realistic case a 200-row pool yields between 9 and 20 distinct tips. Not 50, and not 1.

Whys:

1. Why does the branch return fewer than 50 tips? The collapse runs after `limit 200`.
2. Why after? The BM25 or vector index hands back a ranked top-N and nothing else.
3. Why not collapse inside the index scan? `distinct on (tip_id)` needs rows sorted by `tip_id`, which means reading them all.
4. Why is reading them all unacceptable? 200k reviews. Measured floor without any vector: a full scan plus a top-1000 heapsort is 3,065 buffers and 131 ms.
5. Why 200 and not another number? The doc says "200 candidates from the index, then one review per tip". No derivation is given.
6. Why is there no derivation? Reviews per tip was never measured against it.
7. Why does it need to be? The yield of the collapse is the pool size divided by the reviews-per-tip inside the pool.
8. Why is that ratio fragile? One review per user per tip caps a tip at the user count, which is large.
9. Why does the cap not save it? A tip that is about the query term attracts reviews about the query term, so the pool concentrates exactly where the query is answered.
10. Why is that actually acceptable? If 1,991 of the 2,000 best-matching reviews sit on one tip, that tip is the right answer. The pool is saturated, not wrong.
11. Why does saturation still cost something? The other 49 slots go empty, so a tip with one strong review loses its place.
12. Why is that not fatal? The two tip branches still return 50 each, and RRF fuses four branches.
13. Is there a pool size that guarantees 50 distinct tips? No. Step 10 is the proof: a single tip can own any bounded prefix of a relevance ranking.

Root cause: 200 is an unjustified constant, and the yield of the collapse depends on a distribution nobody measured.

Fix, keeping both review branches:

- Raise the pool from 200 to 1,000 in `reviews_bm25` and in `reviews_vec`. At the measured distribution that lifts the yield from 9 to 20 distinct tips up to 40 to 100, which covers the `limit 50`.
- Add the explicit `order by rank` on the outer `limit 50` that Codex flagged, so the 50 that are kept are defined by the query rather than by the plan.
- Accept that no constant guarantees 50. A saturated pool means the dominant tip is the answer, and the tip branches supply the rest.

Cost: two numbers, two `order by` clauses. I withdraw the cut.

### B9. Base36 stays.

Symptom: none. I listed it in the conventions table with no defect behind it.

Whys:

1. Why did I propose a cut? Because "you cannot say tip 42 to anyone".
2. Why would that matter? People quote ids in support threads.
3. Do they, on Reddit? Yes, and they quote the base36 form.
4. Why did I call it a 2005 legacy? Reddit chose it to shorten URLs.
5. Is that reason obsolete? No. `/tips/1f9k/how-to-x` is shorter than `/tips/85412/how-to-x`, and it stays short as ids grow.
6. Does it cost anything in SQL? No. The id is `bigint` in the database. The conversion is entirely in the app.
7. Does it cost anything in app code? One encode and one decode, about ten lines each, no dependency.
8. Does it risk anything? Ambiguity, if the decoder accepts mixed case and the encoder emits lower case.
9. Does it hide ids from enumeration? No, and the design never claims it does.
10. Is there any gap at all? One. The design does not say what happens for a malformed id in the URL.

Root cause: there is no symptom. This was a style preference, and it was out of scope.

Fix: keep base36 exactly as decided. Add one rule to the route: lowercase before decoding, and any string that is not valid base36 is a 404, not a 500.

Cost: one line in the route handler. No SQL.

### B10. The vote label is the user's call. The freshness column is one column.

Symptom: no verdict on whether a tip worked, and no freshness signal.

The label is out of scope for me. The consensus fixes "Helpful / Not helpful" on tips and on reviews, so a relabel is a change to a decided thing and belongs to the user, not to this review. I note only what I found and leave the decision there: the same two words appear on the tip and on the review, on the same page, meaning two different things.

The freshness signal is a gap nothing in the consensus covers, so I can fix it without touching anything decided.

Whys:

1. Why is there no freshness signal? No column records when a tip was last confirmed to work.
2. Why not? The counters are cumulative and `created_at` is the only timestamp that ranks.
3. Why is `created_at` not enough? Hot decays by post age, not by evidence age.
4. Why does that matter here and not at Reddit? A Reddit post's claim does not expire. A prompt tip's does, when the model changes under it.
5. Why does the model change matter? The site's own filters are model and environment. The design already assumes the setup is what makes a tip work.
6. Why is that not in the ranking? Votes carry no signal the tip row can see.
7. Do votes carry a timestamp? Yes, `votes.created_at`.
8. Why not read it on the tip page? It needs `select max(created_at) from votes where tip_id = $1 and value = 1 and dead_at is null`, which is a second query per tip and cannot serve a list page at all.
9. Why not store it on the tip row? Nothing prevents it. The vote statement already updates that row.
10. Does that add a write? No. A vote already changes `up_count`, which changes `score` and `hot_score`, both indexed. The update is already non-HOT and already rewrites every index entry for the row.
11. So what does the column cost? Eight bytes per tip and one more assignment in a statement that already runs.
12. Why was it not there? Because the only timestamp anyone asked about was the post's.

Root cause: the vote is the only evidence this site collects, and its timestamp is discarded at the tip level.

Fix, adding nothing the consensus rules out and removing nothing:

- `tips.last_up_at timestamptz`.
- In the vote statement's `update tips`, add `last_up_at = case when v.value = 1 and v.dead_at is null then now() else last_up_at end`.
- Show "last confirmed N days ago" on the tip page and in the browse row.
- Do not put it in `hot_score`. That formula is decided.

Cost: one column, one `case` expression in one existing statement, one line in two templates. About 8 MB at 1M tips.

### B11. `noindex` stays. The trigger changes.

Symptom: a reference site lives on organic search, and the trigger for removing `noindex` is the thing indexing produces.

Whys:

1. Why is `noindex` there? It sits in Defenses, next to the rate limits and the markdown sanitizer.
2. Why is it a defense? Indexed spam is much harder to undo than unindexed spam.
3. Why is spam the concern? Anyone with an account can write, and moderation is one person with a kill button.
4. Why does indexing make that worse? A killed page can survive in search results and in caches for weeks.
5. Why weeks? Removal needs a recrawl or a manual removal request.
6. So `noindex` buys time to find out how bad the spam is. Why did I read it as a growth mistake? Because the trigger is "until there is traffic".
7. Why is that circular? Organic search is the traffic, so the condition is the outcome.
8. Why was it written that way? Same shape as the rest of the "bring it back when" table, but every other row names an observable condition.
9. What observable condition is actually wanted? Enough content that an indexed page is worth a click, and enough moderation coverage that spam does not get indexed before it is killed.
10. Can both be true before there is traffic? Yes. Seeded content and one active moderator give you both.
11. Is the tag needed at all once those hold? No, at the site level. Yes, per page, for content nobody has looked at yet.

Root cause: the rule is right and the trigger is unmeasurable. Nothing about `noindex` is wrong.

Fix, keeping `noindex`:

- Replace the trigger with two conditions you can check: 50 live tips exist, and a human has emptied the flag queue at least once. Then remove the site-wide tag.
- Keep it per page after that, which is the standard UGC pattern. `noindex` a tip when `dead_at is not null`, when `deleted_at is not null`, or when `created_at > now() - interval '24 hours'`. The last one gives a moderator a full day before Google sees anything.

Cost: one condition in the page template. No SQL. All three columns are already selected on the tip page.

### B12. Withdrawn. The named-setup filter is decided behaviour, and the defect is in the rendering.

I proposed dropping the third disjunct. That is a cut against the consensus line "Reviews with no stated model or environment show under a named-setup filter." I withdraw it. C-B4 above should be read as a rendering bug, not a query bug.

Symptom, measured. On tip 1, filtering reviews to `gpt-5` returns 1,997 rows, of which 6 state gpt-5 and 1,991 state nothing. Tip 1 is a loader artifact; across all live reviews the real unspecified rate in the fixture is 35,150 of 201,522, or 17%.

Whys:

1. Why does the filter return rows that do not match? The third disjunct admits unspecified reviews under every named filter.
2. Why admit them? Consensus: an unspecified review must not vanish when a filter is on.
3. Why must it not vanish? A review that did not state its model may still be about that model, and hiding it loses information.
4. Why is that a problem in practice? The unspecified rows can outnumber the matching rows and the reader cannot tell them apart.
5. Why can the reader not tell? The row renders `model_id` or `model_other`, so a null renders as nothing at all.
6. Why is nothing ambiguous? It reads as "the author did not say" and as "matches your filter", at the same time.
7. Why do both readings exist? One list is answering two questions: "reviews for GPT-5" and "reviews that might be for GPT-5".
8. Why one list? One query, one sort.
9. Why not two lists? The consensus asks for one filter, not two lists.
10. Does the consensus conflict with the complaint? No. It says unspecified reviews *show*. It does not say they must be mixed in with no label.
11. So what is missing? A label, not a predicate.
12. Could sorting the matches first fix it instead? It would, but the cursor is `(best_score, id)` and `reviews_best` is `(tip_id, best_score desc, id desc)`. Adding a leading boolean breaks keyset pagination and forces a sort of the whole tip's reviews. Not worth it.

Root cause: the predicate is correct and the rendering is not. The list mixes "stated GPT-5" and "did not state" with no visible difference and no count.

Fix, keeping the decided predicate exactly:

- Badge every row where `model_id` and `model_other` are both null with "setup not stated". The query already selects both columns, so this costs nothing.
- Put a count line above the list when a filter is on: "6 reviews state GPT-5. 1,991 did not state a model." One extra aggregate: `select count(*) filter (where model_id = $2) as named, count(*) filter (where model_id is null and model_other is null) as unstated from reviews where tip_id = $1 and dead_at is null`. Measured on the 2,004-review tip: 594 buffers, 3.5 ms, a bitmap scan on `reviews_new`. Run it only when a filter is on. On a normal tip with 10 reviews it is a few buffers.
- Same shape for environment.

Cost: one badge in the template, one aggregate query behind a condition. Zero schema change, and the query in the design is unchanged.

### Summary of round 3

Nothing is cut. What changes:

| Item | Fix | Cost |
|---|---|---|
| B1 | timescaledb-ha as the dev database; restore the skipped DDL; HNSW at launch | ~10 lines compose, ~8 lines DDL, 2 index statements |
| B2 | `dead_at = excluded.dead_at`; map the one constraint name to the normal message | 1 token, 1 exception handler |
| B3 | Notification in its own transaction after commit, `lock_timeout 200ms`, `least(n.count, t.up_count)` | 1 transaction boundary, 1 setting, 1 expression |
| B4 | Nothing | 0 |
| B5 | One constant in `hot_score`: 45,000 to 86,400 x page / tips per day | 1 literal before launch |
| B6 | Images in the moderation queue | 3 lines, 1 lateral |
| B7 | `include (tag_id, model_id, environment_id)` on two indexes; cached facet counts in the UI | 2 clauses, 1 query, 1 cache |
| B8 | Pool 200 to 1,000 in both review branches; explicit `order by rank` | 2 numbers, 2 clauses |
| B9 | Lowercase before decode, malformed id is a 404 | 1 line |
| B10 | `tips.last_up_at`, set in the existing vote update | 1 column, 1 `case` |
| B11 | Checkable trigger; per-page `noindex` for dead, deleted, and under-24-hour tips | 1 template condition |
| B12 | "Setup not stated" badge and a count line | 1 badge, 1 conditional query |

Two root causes account for most of the list. B1, B3 and B5 all come from copying a recipe without copying its operating conditions: a vendor guide written for a vendor image, a fold designed without a concurrency test, a constant tuned for Reddit's posting rate. B7 and B12 both come from the UI asking the database a question it should not have asked. The schema is not the problem in any of the twelve.

## Round 4: final check

Three items. Codex round 9's nine findings are not repeated.

1. **B6 is not implemented.** Round 6 agreed "Show all attached images together in the existing moderation view." The queue is `data-model-v3.md:499`: `select f.tip_id, f.review_id, count(*) as reports, min(f.created_at) as first_at, array_agg(distinct f.reason) as reasons, t.title, r.body`. No `media` join anywhere in the file; grep for "preview" finds only the markdown form. Ten slots stay, and the moderator still opens images one URL at a time. Fix: one lateral `array_agg(m.key order by m.position)` on `media` keyed by `f.tip_id`/`f.review_id`, added to the existing group.

2. **New defect: the embedding queue lost its visibility filter.** Old index: `where embedding is null and deleted_at is null and dead_at is null`. New, `data-model-v3.md:246`: `create index tip_search_queue on tip_search (tip_id) where embedding is null;`, and the loop at `:582` takes rows `where embedding is null and (embed_after is null or embed_after < now())`. `tip_search` has no visibility column and the loop joins nothing, so the only background job now embeds deleted and killed rows. A spam flood that a moderator kills still goes through the embedding server, and killed text lands in the HNSW graph. Search is safe because the branches join the parent, but the cost and the graph are not. Fix: join `tips`/`reviews` in the loop's select, and put `deleted_at is null and dead_at is null` back in the two queue indexes by making them partial on the parent through the join instead.

3. **New defect: bulk kill leaves the images public.** `data-model-v3.md:488`: `update tips set dead_at = now() where user_id = $1 and deleted_at is null and dead_at is null and moderator($2);`. Single kill moves objects to quarantine in the same request (`:516`). Bulk kill, the tool made for an image spam flood, has no move. Recovery is the daily sweep, so the images stay on the public URL for up to 24 hours. Fix: return the killed ids, then run the same quarantine move over their `media` keys.
