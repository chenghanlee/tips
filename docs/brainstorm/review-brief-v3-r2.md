# Brief: adversarial review of data-model-v3, round 2

Date: 2026-09-19. Files: `data-model-v3.md` (the design), `data-model-v3-test.sql` and `data-model-v3-scale.sql` (what was verified, both pass on Postgres 18.6). Round 1 record: `chavruta-02-v3-review.md`.

## The product

Urban Dictionary for LLM prompting tips. A tip has a title, markdown body, one curated tag, optional model and environment, optional prompt and output, up to 10 images. Users write one review per tip. Helpful and Not helpful votes on tips and reviews. Tips sort by Hot (classic Reddit) and New. Reviews sort by Best (Wilson lower bound) and New. Hybrid search (BM25 plus vectors, RRF). In-app notifications. Moderators kill, unkill, and ban. Greenfield MVP looking for product-market fit. Not enterprise software. Do not review it as enterprise software.

Stack: Postgres 18 on the timescaledb-ha image (pg_textsearch, pgvector), Cloudflare R2 for images, Qwen3-Embedding-0.6B for vectors, one app process, one small embedding loop.

## What round 1 already fixed. Do not re-report these.

Hot sign placement; `returning old/new` for vote deltas; vote insert selects from an eligible user; guarded kill, unkill, and delete; born-dead rows start at zero; nullable handle and email on deletion; conditional embedding write on `edited_at`; one review per tip per search branch; search order kept with `array_position`; review ranking indexes on `dead_at` only; no HNSW in v1; flags need login; `data jsonb` dropped; inbox masks killed content; ETag on upload check and copy; cursor columns selected. Notification count kept and defined as an event count. This was the user's decision.

## What to do

1. Focus on correctness and performance. If they conflict, correctness wins.
2. Check industry standards and conventions. Find every invented convention or algorithm. For each one ask: (a) is there an industry standard or convention we can follow instead? (b) if not, is there a better convention than the invented one?
3. Use first principles, Occam's razor, and Pareto 80/20 to derive the simplest working and elegant solution.
4. This is an MVP. Every finding must matter before product-market fit, or say plainly that it can wait.

## Output format

1. **Correctness bugs**, ordered by severity. For each: what breaks, a concrete input or sequence that triggers it, and the smallest fix. Quote the SQL line or constraint name.
2. **Performance risks** that matter before about 1M rows. Which query, why, the fix.
3. **Invented conventions**: a table with columns invented thing | industry standard that could replace it | recommendation.
4. **Cut list**: what to drop or defer, with the reason.
5. **Verdict**: ship as is, ship with fixes, or redesign. One paragraph.

Rules: do not repeat the design back. Do not praise. Every claim about SQL must be checkable. If you can run Postgres locally, run the scripts and reproduce before you claim. Plain simple English. Short sentences. Lists over paragraphs.
