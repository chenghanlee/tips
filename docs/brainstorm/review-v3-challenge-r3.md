# Challenge, round 3: no cuts. Find the root problem.

Date: 2026-09-19. From the user, verbatim: "do not accept any cuts that affect the functionalities, features, and ux from our agreed consensus. instead, challenging codex and opus to identify the root problem by ask 10 to 15 whys, then use 1st principle, occams razor, and pareto's 80/20 to derive the simplest working and elegant solution fit for a greenfield MVP project looking for PMF."

## The consensus that stays

These are decided. Do not propose removing, deferring, or relabeling them.

- Hot (classic Reddit) and New for tips. Best (Wilson) and New for reviews. No Top yet.
- Helpful / Not helpful votes on tips and on reviews. Auto up vote on your own post.
- Hybrid search in v1: pg_textsearch BM25 plus pgvector, on tips and on review bodies, RRF, one result per tip. Qwen3-Embedding-0.6B. Async embedding loop.
- Shadow ban and full ban. Born-dead writes under shadow ban.
- Deleted reviews stay in the list as "[deleted]". Deleted tips keep their page and reviews.
- Notifications: `tip_upvoted`, `review_upvoted`, `tip_reviewed`, folded, with the count.
- Up to 10 images per tip and per review. Kill keeps the files, delete removes them.
- Browse filters: tag, model, environment.
- URL `/tips/{base36 id}/{slug}`.
- One review per user per tip. Review body required.
- Reviews with no stated model or environment show under a named-setup filter.
- `noindex` until there is traffic.

## What to do with each cut you proposed

For each item below that you proposed cutting, deferring, or replacing:

1. Ask "why" 10 to 15 times, starting from the symptom you found, until you reach a cause that is not "the feature exists". Write the chain down. Short lines.
2. From that root cause, derive the simplest fix that keeps the feature as decided. First principles: what must be true for the feature to work? Occam: fewest moving parts. Pareto: the 20% of the fix that removes 80% of the problem.
3. Say what the fix costs: lines of SQL, columns, statements, app code.
4. If you believe no fix exists that keeps the feature, say so and show which "why" step proves it.

## The cut proposals on the table

From Codex (rounds 1 and 4): none open. Codex's split-statement fix for the counter race is accepted.

From Opus B:
- B1. Cut hybrid search, or cut pg_textsearch. Symptom: unrun SQL, hosting lock-in, vector scan cost.
- B2. Cut shadow ban. Symptom: complexity in publish and vote statements, one dead-forever vote bug.
- B3. Cut vote notifications. Symptom: an upsert on every vote, event-count semantics.
- B4. Replace Wilson with up_count order. Symptom: every review ties at one self vote.
- B5. Replace Hot with Top. Symptom: top 100 by Hot and by New overlap 86 of 100 on the fixture.
- B6. One image instead of ten. Symptom: moderation surface, R2 cost.
- B7. Drop the environment browse filter. Symptom: three-filter and zero-match combinations seq-scan.
- B8. Drop the review branches from search. Symptom: no reviews on day one, half the search SQL.
- B9. Drop base36. Symptom: none stated beyond convention.
- B10. Relabel the tip vote "Worked / Didn't work" and add `last_up_at`. Symptom: no verdict, no freshness signal.
- B11. Remove `noindex`. Symptom: a reference site needs organic search.
- B12. Named-setup filter should exclude unspecified reviews. Symptom: filter returns non-matching rows.

From Opus C:
- C1. Cut shadow ban or fix its three tells. Symptom: counters do not move for the banned voter, own score starts at 0, own review count off by one.
- C2. Cut deleted-review placeholders. Symptom: one account can fill a tip's review page with 200 "[deleted]" rows.
- C3. Kill deletes the images. Symptom: killed doxxing image stays on a public URL.
- C4. Move counters to a separate table. Symptom: every vote is a non-HOT update and rewrites every index on tips, including BM25.
- C5. Defer GIF uploads. Symptom: GIF/HTML polyglot.
- C6. Fresh accounts cannot vote for one hour. Symptom: sockpuppet votes buy 25 hours of Hot.
- C7. Review search branches: raise the candidate pool. Symptom: 200 candidates from one popular tip collapse to 1 result.

From Opus A:
- A1. Cut the vector half of search for v1. Symptom: embedding server, background job, TOAST cost, unrun SQL.
- A2. If vectors stay, cut `reviews.embedding`. Symptom: reviews are 10x the rows and collapse to one hit per tip.
- A3. Replace stored `search_text` with a separate `tip_search` table. Symptom: every vote rewrites the BM25 index entry.
- A4. Defer the model and environment browse filters. Symptom: `$2 is null or ...` predicates lose the index under a generic plan.
- A5. Defer `prompt` and `output` on reviews. Symptom: a review page can reach 1.2 MB.

## Output

Append your answers to your own review file under a heading `## Round 3: root causes and fixes that keep the feature`. One subsection per item. Plain simple English. Short sentences. No praise, no repetition of the symptom beyond one line.
