# Embedding gate v1 and v2 results

Both reports are kept as written. Neither result is relabelled.

- v1: [run-2-26398ff-failed.json](run-2-26398ff-failed.json). Gate `54-gate-v1`, code `26398ff`, 16,384-byte head/tail truncation. **Failed.**
- v2: [v2-run-1.json](v2-run-1.json). Gate `234-gate-v2` (sha256 `dab46a25…248b`), clean code `12f42023126e83096af7463291e076b7049e08fa`, full documents up to 30,000 bytes. Run 2026-09-23 12:48:48–12:50:07 UTC. **Passed.**

Both runs use the same corpus, queries, judgments, model (`Qwen/Qwen3-Embedding-8B` from DeepInfra through OpenRouter), 1,024 requested dimensions, query instruction, k=5, gates and budgets.

## Side by side

Values were recomputed from each report's raw scores, timings and per-request usage. They match the reports.

| Measure | Gate | v1 | v2 |
|---|---|---|---|
| Queries with a relevant top-5 hit | all 10 | 10 | 10 |
| Macro recall@5 | ≥ 0.80 | 0.95 | 1.00 |
| Long-input queries (q06, q07, q08) with a hit | all 3 | 3 | 3 |
| Long-input recall: prepared / full reference | — | 0.8333 / 1.00 | 1.00 / 1.00 |
| Long-input recall loss | ≤ 0.10 | **0.1667 (fail)** | 0.00 |
| q07 recall@5 | — | 0.5 (`long-02` missing) | 1.0 (`long-02` rank 2) |
| Query p95, nearest rank over 30 | ≤ 5,000 ms | **6,614 ms (fail)** | 987 ms |
| Slowest query | ≤ 10,000 ms | 8,758 ms | 3,394 ms |
| Slowest document | ≤ 30,000 ms | 8,086 ms | 9,186 ms |
| Incremental client RSS (sampled) | ≤ 256 MiB | 8.4 MiB | 8.8 MiB |
| Requests | ≤ 100 | 77 | 77 |
| Provider prompt tokens | ≤ 500,000 | 73,428 | 85,997 |
| Provider-reported cost | ≤ US$0.10 | US$0.00073 | US$0.00086 |
| Failed requests | 0 | 0 | 0 |
| Dimensions | 1,024 | requested, 1,024 returned | requested, 1,024 returned |

v2 query passes (10 queries each): max / mean ms 732 / 525.8, 987 / 603.1, 3,394 / 835.0.

## Reading

- **Recall:** the root cause was confirmed. v1's head/tail cut removed the `long-02` middle passage, and q07 lost it. With full text, `long-02` ranks second for q07 and long-input loss is 0.
- **Full-input reference in v2:** the prepared and reference texts are identical, so v2's 0.00 loss measures only repeatability, not truncation.
- **Latency:** v2 passed, but its cause is unknown. v1 and v2 used the same request pattern. Latency rose in later passes in both runs, and the v2 third pass still had a 3,394 ms query. One passing run does not remove the earlier 6,614 ms p95. Hosted latency varies, and this probe does not explain why.
- **Scope:** this is an isolated probe. It is not integrated search acceptance (#60).
