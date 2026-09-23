# Schema and lock-graph gate (#38)

Evidence for [issue #38](https://github.com/chenghanlee/tips/issues/38): the assembled
schema on one integrated revision, checked against the
[data model](../design/data-model.md) and the
[backend database contract](../design/backend-design.md#database-implementation).
This gate verifies. It does not repair; gaps go back to their P1 owner.

## Verdict

**Pass on the integrated revision.** Every canonical table, check, FK, index, view,
trigger, generated column and extension is present and matches the design, apart from
the accepted deviations below. Migrations run from empty, roll back fully and reapply to
an identical schema. Report insertion versus author deletion is covered by the #252
ExUnit fixture and by the direct schedules.

| Acceptance | Result |
|---|---|
| No canonical invariant or search extension skipped; versions, revision and test names listed | **Pass.** [Checklist](#schema-checklist). Rows backed only by catalog queries say so. |
| Report insertion/deletion and review liveness/counter schedules with real trigger/FK locks and deterministic synchronization | **Pass.** [Lock schedules](#lock-schedules). |
| Request timeout stays 2 s after maintenance/migration; no generic deadlock retry | **Pass.** Client timeout per the accepted #31 decision; design wording aligned. [Timeout](#request-timeout). |

## Revision and versions

| Item | Value |
|---|---|
| Source revision | Merge `c59fc2f9bfbde11b47376639b5c5e5f92c14a622` of `origin/main` `eb650f4d06aeae721fc18648d7f470f56adc8aa0` (includes #252) into this branch. No migration changed since the first run on `81501387eb77b220c95693f58076f7f8255da1b0`. |
| Local database image | `ghcr.io/chenghanlee/tips-postgres:18.6-pgvector0.8.6-textsearch1.4.0`, image ID `sha256:3409e546c7c1646ad211b30cba66070ce2d5c03fde8edcd1432f5dbc854516cd` (local build, no repo digest) |
| PostgreSQL | 18.6 (Debian 18.6-1.pgdg13+2), aarch64; `shared_preload_libraries = pg_textsearch` |
| Extensions | `vector` 0.8.6, `pg_textsearch` 1.4.0, `plpgsql` 1.0 |
| Toolchain | Elixir 1.20.4, OTP 29; ecto 3.14.2, ecto_sql 3.14.0, postgrex 0.22.4, oban 2.24.1, phoenix 1.8.14 |
| Oban schema | version 14 (`oban_jobs` table comment), equal to Oban 2.24.1's current version |
| Migrations | `20260920192551` auth, `20260920192753` Oban, `20260920210000` extensions, `20260921150000` content, `20260921160000` votes/counters, `20260921170000` flags/notifications, `20260921190000` media, `20260921200000` search |
| Local database | `tips_test_team1_dev` on port 5433, dropped and recreated for this run |

## Migration lifecycle

Local run in the isolated test database, on the merge revision:

1. `unbuffer mix ecto.drop`, then confirmed the database was absent from `pg_database`.
2. `unbuffer mix ecto.create`; 0 relations in `public` before migrating.
3. `unbuffer mix ecto.migrate`: all 8 migrations applied.
4. `unbuffer mix ecto.rollback --all`: all 8 reverted. Left only `schema_migrations` (0 rows) and `plpgsql`; no extension, function, type, table, view or index remained.
5. `unbuffer mix ecto.migrate`: all 8 reapplied. `pg_dump --schema-only` after step 3 and step 5 are identical, and identical to the first gate run on `8150138`.

Release migration, from CI on integrated `main` `eb650f4`
([Checks run 35911931510](https://github.com/chenghanlee/tips/actions/runs/35911931510),
`release` job): `scripts/release_smoke.sh --skip-build` against the published database
image. It printed revision `eb650f4d06aeae721fc18648d7f470f56adc8aa0`, release image ID
`sha256:00fea2bb0a42617443137c526c6e26d8579f7bbdb2c7f77c3f2f80a7748ed671`, ran `bin/migrate`
(8 migrations), and passed health, stopped-database 503 and restart-preserves-8-migrations.
The same run's `checks` job migrated, rolled back all 8 and reapplied them. This branch
adds only documentation to that revision; its own PR CI runs the same jobs. The local
smoke was not run: the fixed smoke project must not collide with other teams' runs.

## Schema checklist

Catalog queries: `pg_attribute`, `pg_attrdef`, `pg_constraint`, `pg_indexes`, `pg_trigger`,
`pg_views`, `pg_proc`, `pg_extension`. "Catalog" means the object is present with the
designed definition but no ExUnit test asserts its behavior.

| Area | Canonical objects | Evidence |
|---|---|---|
| Users | columns; `users_handle_chk`, `users_email_chk`, `users_handle_del`, `users_email_del`, `users_ban_chk`, `users_role_vals`, `users_ban_vals`; `users_handle_unique`, `users_email_unique` on `lower()` | `identity_schema_test.exs` "database identity constraints" (every check, case-variant uniqueness, boundaries) |
| Tokens | `users_tokens_session_family_chk`; `user_id` FK `ON DELETE CASCADE`; `users_tokens_context_token_index` unique; `users_tokens_user_id_index`; `users_tokens_session_family_index` partial | "session rows require a family", "#{context} rows reject a family", "physical deletion cascades tokens and preserves another account's tokens". The three indexes: catalog |
| Vocabularies | `models`, `environments`, `tags`: text PK, label, sort order, `active default true` | `schema_test.exs` vocabulary seed tests; FK tests "#{table}_#{field}_fkey rejects unknown references" |
| Tips, reviews | every column, default and nullability; title/body/model/prompt/output/count checks; submission uniqueness; `reviews_one_per_user`; FKs without cascade | `schema_test.exs` "database checks", "submission identity and one undeleted review", "foreign keys" |
| Generated ranks | `score`, `hot_score` (divisor 345600, `epoch_of` immutable), `best_score` (Wilson, z = 1.281551565545) | "generated tip scores match Hot reference across signs, dates and database time zones", "generated review scores match Wilson reference and refresh after counter updates" |
| Live views | `live_tips`, `live_reviews` (both markers NULL) | "live_#{table} excludes author-deleted and moderator-hidden rows", "a hidden parent does not hide its live reviews" |
| Content indexes | `tips_hot`, `tips_new`, `tips_hot_by_tag`, `tips_new_by_tag`, `tips_by_user`, `reviews_best`, `reviews_new`, `reviews_by_user` | "#{name} has the designed order and visibility predicate" |
| Votes, counters | `votes_one_target`, `votes_value_chk`, `votes_one_per_tip`, `votes_one_per_review`, `votes_by_tip`, `votes_by_review`; `votes.created_at default now()`; `vote_counts()` and `review_counts()` AFTER row triggers | `counters_test.exs` (exact deltas, invalidation, liveness, "partial indexes and row triggers are installed on their actual targets", recount) and `counters_concurrency_test.exs` |
| Flags | `flags_one_target`, `flags_detail_chk`, `flags_reason_vals`, `flags_open_tip`, `flags_open_review`, `flags_open`; FKs | `flag_test.exs` (all checks, open-report uniqueness, FKs, "flag indexes have the designed keys, uniqueness, and predicates") |
| Notifications | `notifications_one_target`, `notifications_type_target`, `notifications_count_chk`, `notifications_type_vals`; `notifications_fold` NULLS NOT DISTINCT where unread; inbox/by-tip/by-review indexes | `notification_test.exs` (all checks, fold including the null-target case, index definitions) |
| Media | `media_one_parent`, `media_position_chk`, `media_description_chk`, `media_key_chk`, `media_kind_vals`, `media_state_vals`, `media_storage_chk`, `media_ready_chk`, `media_lifecycle_chk`, `media_reconcile_chk`; `media_key_unique`, `media_stream_unique`; `media_tip_slot`, `media_review_slot` DEFERRABLE INITIALLY IMMEDIATE; `media_expiry` static predicate | `media_schema_test.exs` "media constraint matrix", "deferrable attachment slots" (immediate collision, deferred swap, invalid final duplicate), "media_expiry uses only static predicates" |
| Search | `tip_search`, `review_search` (`vector(1024)`, `text_at default now()`); `tips_bm25`, `reviews_bm25` (`text_config=english`); `tips_embedding`, `reviews_embedding` (HNSW cosine); queue indexes | `repo_extensions_test.exs` "fresh migrations install the pinned extensions"; `search_schema_test.exs` "migration installs both index families on the pinned image", "BM25 and cosine queries run on the side tables" |
| Oban | `oban_jobs`, `oban_peers`, `oban_job_state` enum, 6 `oban_jobs` indexes; version 14 | Catalog; `oban_config_test.exs` covers supervision only |

### Accepted deviations

These differ from the design SQL by earlier readiness decisions. They are not failures.

- Identity columns are `GENERATED BY DEFAULT`, not `ALWAYS` (Ecto `:identity`). [#25 A5](https://github.com/chenghanlee/tips/issues/25#issuecomment-5761998475).
- Ecto-written timestamps have no database `DEFAULT now()`: `users.inserted_at/updated_at`, `users_tokens.inserted_at`, `tips/reviews/media/flags.created_at`, `notifications.updated_at`. [#25 A4](https://github.com/chenghanlee/tips/issues/25#issuecomment-5761998475), [#26 Q1](https://github.com/chenghanlee/tips/issues/26#issuecomment-5762594107), [#28](https://github.com/chenghanlee/tips/issues/28#issuecomment-5764672357). Statement-written columns keep the default: `votes.created_at`, `tip_search/review_search.text_at`. Any raw-SQL writer must supply the others, including the notification fold.
- Submission uniqueness uses unique indexes, not table constraints; the names match. [#26 A3](https://github.com/chenghanlee/tips/issues/26#issuecomment-5762594107).
- `users.hashed_password varchar(255)` is a recorded deferral, not canonical password behavior: the design has no password. Open P2 [#160](https://github.com/chenghanlee/tips/issues/160) drops the column with the generated password code; [#25 Q1](https://github.com/chenghanlee/tips/issues/25#issuecomment-5761998475) set that order.

## Lock schedules

### Review liveness and counters

Existing tests in `counters_concurrency_test.exs` open two real transactions on separate
backends and wait for `pg_blocking_pids` before releasing the first. They passed:

- "overlapping committed votes keep tip counters correct" / "... review counters correct"
- "overlapping value change and deletion of the same tip vote stay correct" / "... review vote ..."
- "a review vote does not wait on a locked parent tip" (`lock_timeout = '300ms'` proves no ancestor lock)
- "review liveness and bulk locks commit when hide takes the parent first" / "... bulk_restore ..."

No generic deadlock retry exists: no `rescue` or retry on `deadlock_detected` in `lib/`.

### Report insertion versus author deletion

`test/tips/content/report_delete_concurrency_test.exs` (#252) runs the database slice of
the design's lock sets on real independent transactions, with flag FKs and counter
triggers active and observed `pg_blocking_pids` synchronization:

- Report: lock the reporter `FOR NO KEY UPDATE` and check confirmed, unbanned and undeleted; select the live direct target `FOR SHARE`; insert the flag.
- Author deletion: lock the author, the tip, then the review if the target is a review; set `deleted_at`. A review deletion fires `reviews_counts`, which writes the tip.

All 8 passed: "tip|review report/delete report_first|delete_first with confirmed|unconfirmed reporter".
Each asserts the flag outcome, deletion, visibility of the other item, vote and review
counters, and a clean `Counters.recount!()`.

[report_delete_schedules.exs](schema-lock-gate/report_delete_schedules.exs) repeats the
schedules directly and adds an FK-only control. It passed again on the merge revision:

| Schedule | Tip | Review |
|---|---|---|
| `report_insert_first`, confirmed | deleter waits (`Lock:transactionid ShareLock`); 1 flag; tip deleted | same wait; 1 flag; review deleted; `review_count` 1 → 0 |
| `author_delete_first`, confirmed | reporter's `FOR SHARE` waits; after commit, READ COMMITTED recheck returns 0 rows; 0 flags | same |
| both orders, unconfirmed reporter | reporter ineligible, takes no target lock; deleter never waits; 0 flags | same |
| control: flag insert without `FOR SHARE` | insert does not wait; flag lands on the deleted tip | same on the review |

The control shows why `FOR SHARE` is required: the flag FK check takes only
`FOR KEY SHARE` on the target, which does not conflict with the deleter's
`FOR NO KEY UPDATE`.

## Request timeout

- Mechanism: `config :tips, Tips.Repo, timeout: 2_000`, a client-side DBConnection deadline. On expiry Postgrex sends a cancel request and the pool connection is closed. The server's `statement_timeout` is `0`.
- This is the accepted [#31 decision](https://github.com/chenghanlee/tips/issues/31#issuecomment-5752476343): client timeout on the repo, no connection-level `statement_timeout` or `SET LOCAL`, per-call maintenance overrides. Error and timing contract: [#31](https://github.com/chenghanlee/tips/issues/31#issuecomment-5752515996). It records that mechanism; it does not claim client and server timers are equivalent.
- `Repo.maintenance_query!/3` passes `timeout: :infinity` (or a given timeout) per call and changes no session setting, so nothing can leak into the pool. `Ecto.Migrator` runs migrations at `timeout: :infinity`.
- Tests: `repo_timeout_test.exs` "request deadline survives a maintenance query on the pool" (a 3 s maintenance query succeeds, then a request query is cut off between 2.0 and 2.5 s); `release_test.exs` "release migration is idempotent and preserves the request timeout".
- Design wording aligned in this PR: [Defenses](../design/data-model.md#defenses), the data-model search section and the backend search section no longer name a server `statement_timeout`.

## Returned gaps

| Gap | Owner | State |
|---|---|---|
| No ExUnit regression fixture for report insertion versus author deletion | #28, repaired by [#252](https://github.com/chenghanlee/tips/issues/252) | Resolved: integrated in `eb650f4`, passed on the merge revision |

## Checks run

On merge `c59fc2f9bfbde11b47376639b5c5e5f92c14a622`:

- `unbuffer mix test --trace`: 540 passed, 4 excluded (3 browser features, 1 real-provider), seed 229776. All contract-named tests above passed. CI on `eb650f4` ran the browser features: 543 passed, 1 excluded.
- `unbuffer mix compile --warnings-as-errors`, `unbuffer mix format --check-formatted`, `unbuffer mix credo --strict`, `python3 scripts/check_docs.py`: pass.
- `unbuffer mix run --no-start docs/development/schema-lock-gate/report_delete_schedules.exs`: 8 schedules and 2 controls pass; test rows removed; no compiler warnings.
- The script is outside `.formatter.exs` inputs and default Credo runs, so it is checked explicitly: `unbuffer mix format --check-formatted docs/development/schema-lock-gate/report_delete_schedules.exs` and `unbuffer mix credo --strict docs/development/schema-lock-gate/report_delete_schedules.exs` both pass. Expert LSP diagnostics reported 0 without a document version, so they cannot certify the current file.
