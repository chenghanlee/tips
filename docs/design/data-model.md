# Data model

PostgreSQL through Ecto. Timestamps are `inserted_at` and `updated_at` as
`utc_datetime`, the Phoenix default.

## Rules

- Migrations are append-only timestamped files. One per story. Never edit a merged one.
- Column changes are additive: add nullable, backfill, then set `null: false`.
- A story adds an index when its query needs it. No speculative indexes.
- Changesets check user input. The database enforces `null: false`, unique indexes and
  foreign keys. No CHECK constraints until a second writer exists.
- Primary keys are `bigint` auto-increment.

## Posts

A post is a tip in code and the database. Users see the word "tip".

| Column | Type | Rules |
|---|---|---|
| `id` | bigint | primary key, auto-increment |
| `uid` | text | 12-character Nanoid, set by `Tips.Content.create_post/1`, unique index |
| `slug` | text | made from the title at create time, max 80 characters cut at a whole word, not unique |
| `title` | text | 3 to 300 characters, must contain a non-space character |
| `body` | text | 3 to 20,000 characters, plain text |
| `inserted_at`, `updated_at` | utc_datetime | |

Every column is `null: false`. Indexes: primary key, unique on `uid`. No author column
yet; the accounts story adds `user_id`.

Queries today: insert one post; read one post by `uid`.
