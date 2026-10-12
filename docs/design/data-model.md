# Data model (Postgres)

This document defines the schema and database behavior. Ecto migrations own the executable schema; keep this contract aligned with them.

Use established patterns from Reddit, Hacker News, Google Maps, Steam, Discourse, and Instagram.

Follow the [architecture's MVP design constraints](software-architecture.md#mvp-design-constraints): accept necessary complexity when it makes the user's experience simpler. Retain state and invariants needed for reliable saving, recovery, ordering and permissions. Fewer columns or states is not sufficient justification if the resulting workflow makes users repeat or repair their work.

Postgres stores the data and runs search with two extensions. Two views select live content, and two triggers maintain counters. A background worker generates embeddings. Cloudflare R2 stores images/GIFs and Stream stores videos. Anyone can read public content; contributions require a confirmed account.

Ecto migrations own tables, generated columns, views, triggers, constraints and Oban setup. Use `execute` where needed and explicit down steps; tests run all migrations against pinned, extension-enabled Postgres in development and CI. The SQL here specifies database behavior and selected query shapes; it is not a standalone migration or a replacement for generated authentication/Oban migrations. Keep documents aligned with those migrations. No backwards-compatibility path is required.

## Rules

1. **Deletion and moderation use separate columns.** `deleted_at` means the author deleted the content. `dead_at` records deliberate moderator hiding. Shadow bans are deferred. The document calls hiding content a "kill" and restoring it an "unkill." A content row is live only when `deleted_at` and `dead_at` are both NULL. Public content indexes check both. The `live_tips` and `live_reviews` views select these rows for browse and search. Only the author and moderators can see hidden content itself. A hidden tip still has a public placeholder page with its existing visible reviews; hiding the parent does not hide its reviews.
2. **Authors can edit tips and reviews at any time, and delete any time.** A full ban blocks edits and contributions, but still allows deletion of the author's own content or account. Edits can change text and ordered media and set `edited_at`. There is no edit history. A deleted tip keeps its page and reviews, with "[deleted]" in place of the content. A deleted review leaves the list because it has no replies to preserve.
3. **Two triggers maintain counters.** `up_count`, `down_count`, and `review_count` are stored on the row. An `AFTER` row trigger on `votes` and one on `reviews` calculate the change from `OLD` and `NEW` and update the parent. App code must not write counters. `score`, `hot_score`, and `best_score` are generated from the counters. An operator can run a recount if needed. A vote's target and a review's `tip_id` never change. Staged media can acquire its parent once; retained attachments never move between content items.
4. **Generated columns store ranking scores.** Hot uses the classic Reddit formula for tips. Best uses the Wilson lower bound for reviews. Votes update the counters that determine these indexed scores. The front page uses an index scan. The Hot divisor controls the balance between age and votes. For positive scores, multiplying the score by ten offsets an age difference equal to the divisor in seconds. Reddit uses 45000. This site uses `86400 * 20 / 5 = 345600`, based on 20 tips per page and five new tips per day. Adjust it once the posting rate is known by dropping and recreating the generated column and its index.
5. **Fixed vocabularies are text columns with named CHECK constraints; editable lists use tables.** `users.role`, `users.ban`, `flags.reason`, `notifications.type`, `media.kind` and `media.state` are `text` with a named column CHECK and `Ecto.Enum` in the schema. No PostgreSQL domains. `models`, `environments`, and `tags` are tables with an active flag and a sort order.
6. **A model can be selected, entered as text, or left unspecified.** Use `model_id` for a selection and `model_other` for text. At most one can be set. NULL means unspecified. A fresh review form prefills the tip’s model and environment, but stores the reviewer’s submitted values independently. Clearing a field stores NULL; neither publishing nor later tip edits inherit values again. For a review comparing setups, these fields identify its optional primary setup. Other setups belong in the body; model/environment filters match only the primary fields, not mentions in text. No multi-model join table or per-attempt records are needed.
7. **Each vote and flag has one target.** Exactly one of `tip_id` and `review_id` is set. Live attached media has one parent; staged videos have none. Cleanup records may retain their former parent but have no live position.
8. **The app validates images/GIFs and uploads them to R2.** Built-in LiveView uploads transfer them on publish or edit submission. Videos upload directly to Stream through authorized tus URLs before submission and stay private at Stream for their whole life; the app signs short-lived playback and poster URLs per request after checking current visibility. The app checks each image's size, then parses its content with Pillow in a bounded child process, uploads each file under a generated key, and stores the key in Postgres. Files stay at that key. Kill and unkill only update database rows; no provider write follows a visibility change.
9. **Notifications combine events when written.** This is called folding. A second up vote on the same tip adds 1 to the unread notification's count. One insert statement handles this without a background job.
10. **Search data uses separate tables.** `tip_search` and `review_search` hold search text and vectors. A vote changes counters on the content row and updates its indexes. Keeping BM25 and vector indexes in separate tables avoids rebuilding search entries on each vote.
11. **Lock related eligibility before writing.** Transactions lock participating users, tips, reviews and dependent rows in that order, each group sorted by id. Lock and recheck the author and applicable parent; an unlocked subquery alone cannot serialize against unban or deletion. Guarded writes retain ownership, version and deletion checks. Evaluate upload and registration deadlines using current wall time after acquiring the required row locks; transaction-start `now()` is unsuitable for these decisions. This is a decision-time guarantee, not a guarantee that commit precedes the passing deadline. Ordinary changeset inserts are valid after locked eligibility checks. Interpret affected-row counts and map expected constraint errors after rollback; zero rows is not automatically success or the same error for every operation.

12. **Add filter conditions only when a filter is set.** Add the selected predicates directly; generic optional predicates such as `$1 is null or col = $1` can prevent index use.
13. **Publishing has a stable submission key.** The client supplies one UUID for each intended new tip or review and reuses it on retries. Each content table enforces uniqueness on `(user_id, submission_key)`, including deleted and killed rows. A retry returns the original publication's identity and current state, plus equivalent/different/unknown comparison against complete submitted intent; identity alone never acknowledges local draft values. It does not edit, restore or repeat side effects. This protection is limited to publishing.

### Visibility and transaction boundaries

Moderator hide/restore changes only `dead_at`. Author deletion always wins and cannot be undone by restoration. Accounts are normal or fully banned; banning does not retroactively hide content. Deliberate bulk hiding uses `dead_at`, and lifting a ban changes account eligibility only. Invalidating votes deletes their rows under the existing locks and counter trigger; unban never recreates them. A later explicit eligible vote is a new vote.

Use `FOR NO KEY UPDATE` where sufficient. Lock order within a write transaction: participating accounts by id, then tips by id, then reviews by id, then dependents. The order includes locks that triggers and foreign keys take implicitly. Operation lock sets:

| Operation | Locks, in order |
|---|---|
| Publish tip | author |
| Publish review | author, live parent tip |
| Edit tip / review text, setup, media | account, the content row; a review edit that does not change liveness takes no tip lock |
| Author delete, moderator hide/restore of a review | account(s), parent tip, review; the review counter trigger writes the tip |
| Vote | voter, direct target only; a review vote takes no ancestor tip lock |
| Report | confirmed eligible reporter, then direct target FOR SHARE in the eligible selection; no ancestor-tip lock for a review and no author-revision parameter |
| Bulk hide, vote invalidation | subject accounts **first**, then discover the mutable affected content set, then all trigger targets (tips, then reviews) in id order, then child rows |

Locking subject accounts before discovering their content serializes bulk operations against concurrent publication. Recheck eligibility under the locks. Provider calls stay outside transactions. No generic deadlock retry wrapper is required; diagnose and correct violations, preserving caller input. One focused two-transaction test covers an opposing single-review liveness change and a bulk operation.

Mutations and privileged reads resolve the current session through generated Accounts code at operation admission, using the server-held `users_tokens.id` obtained at mount as the session reference and one shared validity definition; no bearer token lives in LiveView assigns. Business rules recheck current account state under the locks above. Family-topic disconnects are UI feedback, not the sole protection against revoked sessions. Public reads and renders need no token query; already-admitted work may finish. The [backend admission contract](backend-design.md#admission-locking-and-returned-data) owns the web/context boundary.

### Durable jobs and search pages

Oban migrations install its tables in the same database. Required cleanup jobs are inserted in the originating business transaction. The `media` row retains provider identifiers independently of job pruning. Pending video state is refreshed through bounded asynchronous editor requests and, when needed for expiry, the scheduled cleanup worker. Both use the same guarded Media transition. There is no global readiness scan or webhook. See [Upload](#upload) and the backend's [durable work contract](backend-design.md#durable-background-work).

Embeddings use one periodic bounded scan with active-job uniqueness, queue concurrency 1 and `max_attempts: 1`. `embed_after` is the scan's only per-row cooldown; no per-row Oban jobs or enqueue hooks are needed. Rerun bounded search ranking for every requested page, with a validated final offset and no saved-order table. Current visibility applies during retrieval and hydration.

## Tables

```sql
-- Fixed vocabularies are text columns with named CHECK constraints (rule 5). Ecto.Enum mirrors the allowed values.
-- No database default (Ecto writes them): users.inserted_at/updated_at, users_tokens.inserted_at,
-- tips/reviews/media/flags.created_at, notifications.updated_at.
-- Raw-SQL writers must supply these timestamps, including the notification fold.
-- `default now()` stays on votes.created_at and tip_search/review_search.text_at.

-- Epoch seconds do not depend on the time zone, but Postgres marks extract() as stable.
-- This wrapper declares the epoch extraction immutable, as generated columns require. Do not use it for other extract() fields.
create function epoch_of(timestamptz) returns double precision language sql immutable parallel safe
  return extract(epoch from $1);

create table models       (id text primary key, label text not null, sort_order int not null, active boolean not null default true);
create table environments (id text primary key, label text not null, sort_order int not null, active boolean not null default true);
create table tags         (id text primary key, label text not null, sort_order int not null, active boolean not null default true);

create table users (
  id          bigint generated by default as identity primary key,
  handle      text,                          -- public name, 3 to 30 characters; fixed after signup. NULL only on a deleted account.
  email       text,                          -- login identity. Never shown. NULL only on a deleted account.
  role        text not null default 'user',
  ban         text,                          -- NULL = not banned. full = contributions refused; own content/account deletion allowed.
  banned_at   timestamptz,
  inserted_at timestamptz not null,              -- original registration time; immutable
  updated_at  timestamptz not null,
  confirmed_at timestamptz,                     -- generated authentication confirmation state
  deleted_at  timestamptz,                   -- account deleted. Handle and email set to NULL, content stays as "[deleted]".
  constraint users_handle_chk check (handle ~ '^[A-Za-z0-9][A-Za-z0-9_-]{2,29}$'),
  constraint users_email_chk  check (email ~ '^[^@[:space:]]+@[^@[:space:]]+$' and length(email) <= 254),
  constraint users_handle_del check ((deleted_at is null) = (handle is not null)),
  constraint users_email_del  check ((deleted_at is null) = (email  is not null)),
  constraint users_ban_chk    check ((ban is null) = (banned_at is null)),
  constraint users_role_vals  check (role in ('user', 'moderator')),
  constraint users_ban_vals   check (ban is null or ban = 'full')
);
create unique index users_handle_unique on users (lower(handle));
create unique index users_email_unique  on users (lower(email));

-- Adapt the pinned phx.gen.auth migration and queries; retain token formats and add browser-session families.
-- Use UTC timestamps consistently in Ecto; this document expresses them as timestamptz.
create table users_tokens (
  id               bigint generated by default as identity primary key,
  user_id          bigint not null references users(id) on delete cascade,
  token            bytea not null,
  context          text not null,
  sent_to          text,
  authenticated_at timestamptz,
  session_family_id uuid,                 -- server-generated group for session rows only; no root-token FK
  inserted_at      timestamptz not null,
  constraint users_tokens_session_family_chk check (
    (context = 'session') = (session_family_id is not null))
);
create index users_tokens_user_id_index on users_tokens(user_id);
create unique index users_tokens_context_token_index on users_tokens(context, token);
create index users_tokens_session_family_index on users_tokens(user_id, session_family_id)
  where context = 'session';

create table tips (
  id              bigint generated by default as identity primary key,
  user_id         bigint not null references users(id),
  submission_key  uuid not null,                        -- supplied by the client and reused on publish retries; immutable
  edit_version    int not null default 1,               -- compare and increment on text, selection, or attachment edits
  title           text not null,
  body            text not null,                        -- markdown
  tag_id          text not null references tags(id),    -- one tag, required
  model_id        text references models(id),
  model_other     text,
  environment_id  text references environments(id),
  prompt          text,                                 -- optional example, verbatim
  output          text,
  up_count        int not null default 0,
  down_count      int not null default 0,
  review_count    int not null default 0,
  score           int generated always as (up_count - down_count) stored,
  hot_score       double precision generated always as (                              -- classic Reddit hot: sign * log10(|score|) + age. Divisor tuned to this site, see Rules
                    sign(up_count - down_count) * log(greatest(abs(up_count - down_count), 1))
                    + (epoch_of(created_at) - 1134028003) / 345600
                  ) stored,
  created_at      timestamptz not null,
  edited_at       timestamptz,
  deleted_at      timestamptz,                          -- author
  dead_at         timestamptz,                          -- deliberate moderator hiding
  constraint tips_title_chk       check (title ~ '[^[:space:]]' and length(title) between 3 and 300),
  constraint tips_body_chk        check (body ~ '[^[:space:]]' and length(body) between 3 and 20000),
  constraint tips_model_one_chk   check (num_nonnulls(model_id, model_other) <= 1),
  constraint tips_model_other_chk check (model_other is null or (model_other ~ '[^[:space:]]' and length(model_other) <= 80)),
  constraint tips_prompt_chk      check (prompt is null or (prompt ~ '[^[:space:]]' and length(prompt) <= 20000)),
  constraint tips_output_chk      check (output is null or (output ~ '[^[:space:]]' and length(output) <= 20000)),
  constraint tips_counts_chk      check (up_count >= 0 and down_count >= 0 and review_count >= 0)
);
create unique index tips_submission_unique on tips (user_id, submission_key);

create table reviews (
  id              bigint generated by default as identity primary key,
  tip_id          bigint not null references tips(id),
  user_id         bigint not null references users(id),
  submission_key  uuid not null,                        -- a new key for an intentional re-review after deletion
  edit_version    int not null default 1,               -- independent of votes and counters
  body            text not null,                        -- required
  model_id        text references models(id),           -- optional
  model_other     text,
  environment_id  text references environments(id),
  prompt          text,
  output          text,
  up_count        int not null default 0,
  down_count      int not null default 0,
  score           int generated always as (up_count - down_count) stored,
  best_score      double precision generated always as (                              -- Wilson lower bound, z = 1.28 (80%)
                    case when up_count + down_count = 0 then 0 else
                      ( (up_count::float / (up_count + down_count))
                        + 1.281551565545 * 1.281551565545 / (2 * (up_count + down_count))
                        - 1.281551565545 * sqrt(
                            ( (up_count::float / (up_count + down_count)) * (1 - up_count::float / (up_count + down_count))
                              + 1.281551565545 * 1.281551565545 / (4 * (up_count + down_count)) )
                            / (up_count + down_count) )
                      ) / (1 + 1.281551565545 * 1.281551565545 / (up_count + down_count))
                    end
                  ) stored,
  created_at      timestamptz not null,
  edited_at       timestamptz,
  deleted_at      timestamptz,
  dead_at         timestamptz,                          -- deliberate moderator hiding
  constraint reviews_body_chk        check (body ~ '[^[:space:]]' and length(body) between 1 and 20000),
  constraint reviews_model_one_chk   check (num_nonnulls(model_id, model_other) <= 1),
  constraint reviews_model_other_chk check (model_other is null or (model_other ~ '[^[:space:]]' and length(model_other) <= 80)),
  constraint reviews_prompt_chk      check (prompt is null or (prompt ~ '[^[:space:]]' and length(prompt) <= 20000)),
  constraint reviews_output_chk      check (output is null or (output ~ '[^[:space:]]' and length(output) <= 20000)),
  constraint reviews_counts_chk      check (up_count >= 0 and down_count >= 0)
);
create unique index reviews_submission_unique on reviews (user_id, submission_key);
create unique index reviews_one_per_user on reviews (tip_id, user_id) where deleted_at is null;   -- one undeleted review per user per tip. A re-review after delete is a new row.

-- Separate search tables prevent vote updates from changing search indexes. See rule 10.
create table tip_search (
  tip_id          bigint primary key references tips(id),
  search_text     text not null,                        -- title, body, prompt, output, model/environment labels or free text, tag label; shared writer on publish/edit/retag.
  text_at         timestamptz not null default now(),   -- changed on searchable edit/retag; worker writes require the same freshness token.
  embedding       vector(1024),                         -- NULL until the worker stores the vector
  embed_after     timestamptz                           -- set after a failed embedding call. The loop skips rows not yet due.
);
create table review_search (
  review_id       bigint primary key references reviews(id),
  search_text     text not null,                        -- body, prompt, output, own model/environment labels or free text
  text_at         timestamptz not null default now(),
  embedding       vector(1024),
  embed_after     timestamptz
);

-- A vote is identified by its user and target. No other table references a vote, so no surrogate id is needed.
create table votes (
  user_id     bigint not null references users(id),
  tip_id      bigint references tips(id),
  review_id   bigint references reviews(id),
  value       smallint not null,                        -- 1 = helpful, -1 = not helpful
  created_at  timestamptz not null default now(),
  constraint votes_one_target check (num_nonnulls(tip_id, review_id) = 1),
  constraint votes_value_chk  check (value in (-1, 1))
);
create unique index votes_one_per_tip    on votes (user_id, tip_id)    where tip_id    is not null;
create unique index votes_one_per_review on votes (user_id, review_id) where review_id is not null;

-- One table: committed images, provisioning/staged/attached videos, and durable cleanup.
create table media (
  id                bigint generated by default as identity primary key,
  user_id           bigint not null references users(id),
  tip_id            bigint references tips(id),
  review_id         bigint references reviews(id),
  kind              text not null,
  description       text,                              -- optional image/GIF alternative; blank input becomes NULL
  is_animated       boolean,                           -- trusted image/GIF classification; NULL for videos
  key               text,                              -- R2 image/GIF object key
  stream_uid        text,                              -- NULL only until the reservation uid is persisted; never cleared afterwards
  state             text,                              -- video processing only: uploading | processing | ready | failed
  duration_s        double precision,
  target            text,                              -- server-encoded typed video target: stable content identity, no version
  position          smallint,                          -- live attachment slot, 0..9
  created_at        timestamptz not null,              -- authorization time for staged videos
  expires_at        timestamptz,                       -- unattached video only: upload deadline, then recovery deadline
  reconcile_after   timestamptz,                       -- uncertain expiry retry cooldown; not user expiry
  cleanup_at        timestamptz,                       -- terminal removal; keep identifiers
  constraint media_one_parent check (num_nonnulls(tip_id, review_id) <= 1),
  constraint media_position_chk check (position between 0 and 9),
  constraint media_description_chk check (description is null or description ~ '[^[:space:]]'),
  constraint media_key_chk check (key is null or key ~ '^media/[0-9a-f-]{36}\.(png|jpg|webp|gif)$'),
  constraint media_kind_vals check (kind in ('image', 'video')),
  constraint media_state_vals check (state is null or state in ('uploading', 'processing', 'ready', 'failed')),
  constraint media_storage_chk check (
    (kind = 'image' and is_animated is not null and key is not null and stream_uid is null and state is null
      and target is null and duration_s is null
      and expires_at is null and reconcile_after is null
      and num_nonnulls(tip_id, review_id) = 1)
    or
    (kind = 'video' and description is null and is_animated is null and key is null and target is not null and state is not null
      and (state not in ('processing', 'ready') or stream_uid is not null))
  ),
  constraint media_ready_chk check (state is distinct from 'ready'
    or (duration_s is not null and duration_s > 0 and duration_s <= 180 and stream_uid is not null)),
  -- A known-uid row that left 'uploading' has completed its transfer and holds the recovery deadline.
  constraint media_deadline_chk check (expires_at is null or expires_at = created_at +
    case when stream_uid is not null and state <> 'uploading' then interval '49 hours' else interval '1 hour' end),
  constraint media_lifecycle_chk check (
    (cleanup_at is not null and position is null)
    or (cleanup_at is null and (
      (num_nonnulls(tip_id, review_id) = 0 and kind = 'video'
        and position is null and expires_at is not null)
      or (num_nonnulls(tip_id, review_id) = 1 and position is not null and expires_at is null
        and (kind = 'image' or state = 'ready'))
    ))
  ),
  constraint media_reconcile_chk check (reconcile_after is null or
    (kind = 'video' and cleanup_at is null and tip_id is null and review_id is null)),
  constraint media_tip_slot unique (tip_id, position) deferrable initially immediate,
  constraint media_review_slot unique (review_id, position) deferrable initially immediate
);
create unique index media_key_unique on media (key);
create unique index media_stream_unique on media (stream_uid);

-- Reports concern rule violations. 'fabricated' means suspected invented experience or evidence;
-- ineffective or outdated techniques belong in reviews and votes, not this queue.
-- At most one open report per reporter/target. Resolution permits a new report on unchanged content.

create table flags (
  id            bigint generated by default as identity primary key,
  tip_id        bigint references tips(id),
  review_id     bigint references reviews(id),
  user_id       bigint not null references users(id),   -- reporter. Confirmed login required.
  reason        text not null,
  detail        text,
  created_at    timestamptz not null,
  resolved_at   timestamptz,
  resolved_by   bigint references users(id),
  constraint flags_one_target check (num_nonnulls(tip_id, review_id) = 1),
  constraint flags_detail_chk check (detail is null or length(detail) <= 1000),
  constraint flags_reason_vals check (reason in ('spam', 'harmful', 'fabricated', 'other'))
);
create unique index flags_open_tip on flags(user_id, tip_id) where tip_id is not null and resolved_at is null;
create unique index flags_open_review on flags(user_id, review_id) where review_id is not null and resolved_at is null;

-- Each notification has one target. tip_upvoted uses tip_id. review_upvoted and tip_reviewed use review_id; join the review to find its tip.
create table notifications (
  id          bigint generated by default as identity primary key,
  user_id     bigint not null references users(id),     -- recipient
  type        text not null,
  actor_id    bigint references users(id),              -- latest actor
  tip_id      bigint references tips(id),
  review_id   bigint references reviews(id),
  count       int not null default 1,                   -- folded events; internal mark-read race guard, not a displayed numeric total
  updated_at  timestamptz not null,                     -- updated when events are combined, so the row sorts first
  read_at     timestamptz,
  constraint notifications_one_target check (num_nonnulls(tip_id, review_id) = 1),
  constraint notifications_type_target check ((type = 'tip_upvoted') = (tip_id is not null)),
  constraint notifications_count_chk check (count > 0),
  constraint notifications_type_vals check (type in ('tip_upvoted', 'review_upvoted', 'tip_reviewed'))
);
create unique index notifications_fold on notifications (user_id, type, tip_id, review_id) nulls not distinct where read_at is null;

-- Views select live content for browse and search. Postgres inlines them and can use the partial indexes. See rule 1.
create view live_tips    as select * from tips    where deleted_at is null and dead_at is null;
create view live_reviews as select * from reviews where deleted_at is null and dead_at is null;

-- counters, rule 3. Every stored vote counts; invalidation deletes it. A live review has both visibility markers NULL.
create function vote_counts() returns trigger language plpgsql as $$
declare d_up int := 0; d_down int := 0; tip bigint; rev bigint;
begin
  if tg_op in ('UPDATE', 'DELETE') then
    if old.value = 1 then d_up := d_up - 1; else d_down := d_down - 1; end if; end if;
  if tg_op in ('INSERT', 'UPDATE') then
    if new.value = 1 then d_up := d_up + 1; else d_down := d_down + 1; end if; end if;
  if d_up = 0 and d_down = 0 then return null; end if;
  if tg_op = 'DELETE' then tip := old.tip_id; rev := old.review_id; else tip := new.tip_id; rev := new.review_id; end if;
  if tip is not null then update tips    set up_count = up_count + d_up, down_count = down_count + d_down where id = tip;
  else                    update reviews set up_count = up_count + d_up, down_count = down_count + d_down where id = rev; end if;
  return null;
end $$;
create trigger votes_counts after insert or update or delete on votes for each row execute function vote_counts();

create function review_counts() returns trigger language plpgsql as $$
declare was int := 0; is_ int := 0;
begin
  if tg_op in ('UPDATE', 'DELETE') and old.deleted_at is null and old.dead_at is null then was := 1; end if;
  if tg_op in ('INSERT', 'UPDATE') and new.deleted_at is null and new.dead_at is null then is_ := 1; end if;
  if was = is_ then return null; end if;
  update tips set review_count = review_count + is_ - was where id = coalesce(new.tip_id, old.tip_id);
  return null;
end $$;
create trigger reviews_counts after insert or update or delete on reviews for each row execute function review_counts();
```

The trigger's `update tips` runs after the vote row's lock wait ends. The trigger function is volatile, so the update takes its own snapshot. Read counters in the statement after changing a vote or review.

Authentication adapts Phoenix's generated email magic-link migration. The [backend authentication contract](backend-design.md#authentication) owns token lifetimes, session families, renewal, logout, [signup](backend-design.md#first-time-signup), registration expiry and email change. Schema rules:

- No password column and no second registration table. Login is by email. The app reads `users` for id, handle, role and ban.
- `users.confirmed_at` records confirmation. `users.inserted_at` is the immutable registration time.
- An unconfirmed registration expires at `inserted_at + 7 days`. Cleanup, reclaim and verification lock the user row, then compare that deadline with `clock_timestamp()` (rule 11).
- Cleanup and reclaim delete the expired user row with its tokens. This releases `users_handle_unique` and `users_email_unique`. It never cascades to contributions; an unexpected foreign-key failure is an invariant error, not a uniqueness conflict.
- `users_tokens.session_family_id` groups one browser login's session rows. Renewal and same-account reauthentication keep the family. There is no family table and no root-token reference.
- A pending email change is a `users_tokens` row. `users.email` changes only when confirmation commits, checked against `users_email_unique`. The user id, handle, contributions and ban state stay.
- Account updates never change `handle`. Account deletion clears it.

### Text columns and how they are displayed

| Column | Format | How it is displayed |
|---|---|---|
| `tips.body` | Markdown | Markdown renderer with raw HTML off, links get `rel="nofollow noopener"`, no images. Text preview is deferred; render Markdown after publication or a saved edit. |
| `reviews.body` | Markdown | Same. |
| `prompt`, `output` | Text as typed | `<pre>` block, escaped. A prompt may contain markdown that the reader needs to see as written. |
| `title`, `detail`, `media.description` | Plain text | Escaped; image descriptions supply the image alternative. Missing descriptions get a generic fallback, not a claim of equivalent access. |

The changesets limit a title to 3–300 characters and a body, prompt or output to 10,000 characters, and the forms state these limits. The database checks above allow 20,000 for body, prompt and output because the search gate loads its fixed corpus directly (`Tips.SearchGate.split_body/1`). A tip or review whose search document would exceed 30,000 UTF-8 bytes is not saved (see [Publish a tip or review](#publish-a-tip-or-review)). Limits are initial estimates. Increase a limit when a valid submission needs it. Public queries select named columns to avoid returning unnecessary data.

## Indexes

```sql
create index tips_hot         on tips    (hot_score desc, id desc)           where deleted_at is null and dead_at is null;
create index tips_new         on tips    (created_at desc, id desc)          where deleted_at is null and dead_at is null;
create index tips_hot_by_tag  on tips    (tag_id, hot_score desc, id desc)   where deleted_at is null and dead_at is null;   -- browse with a tag filter
create index tips_new_by_tag  on tips    (tag_id, created_at desc, id desc)  where deleted_at is null and dead_at is null;
create index tips_by_user     on tips    (user_id, created_at desc, id desc);        -- profile and moderator history, deleted rows included
create index reviews_best     on reviews (tip_id, best_score desc, id desc)  where deleted_at is null and dead_at is null;
create index reviews_new      on reviews (tip_id, created_at desc, id desc)  where deleted_at is null and dead_at is null;
create index reviews_by_user  on reviews (user_id, created_at desc, id desc);
create index votes_by_tip     on votes   (tip_id, created_at desc)    where tip_id    is not null;   -- moderator: who voted on this
create index votes_by_review  on votes   (review_id, created_at desc) where review_id is not null;
create index flags_open       on flags   (created_at, id)                    where resolved_at is null;
create index notifications_inbox     on notifications (user_id, updated_at desc, id desc);
create index notifications_by_tip    on notifications (tip_id)    where tip_id    is not null;
create index notifications_by_review on notifications (review_id) where review_id is not null;
-- Expiry is independent of whether an editor is open. No readiness-scan index.
-- Keep this predicate static; expiry/reconcile_after due checks belong in the runtime query.
create index media_expiry on media (expires_at, id)
  where kind = 'video' and cleanup_at is null and tip_id is null and review_id is null;
-- search, on the side tables
create index tips_bm25         on tip_search    using bm25 (search_text) with (text_config = 'english');
create index reviews_bm25      on review_search using bm25 (search_text) with (text_config = 'english');
create index tips_embedding    on tip_search    using hnsw (embedding vector_cosine_ops);
create index reviews_embedding on review_search using hnsw (embedding vector_cosine_ops);
create index tip_search_queue    on tip_search    (tip_id)    where embedding is null;   -- the embedding loop
create index review_search_queue on review_search (review_id) where embedding is null;
```

These indexes supplement the unique indexes defined above. The `by_user` indexes include all rows. Profile queries filter `deleted_at`; moderators need deleted rows to find repeated creation and deletion by a user.

The unread badge and unread capture use `notifications_fold`. It starts with `user_id` and has the required `read_at is null` predicate. Add a narrower `(user_id) where read_at is null` index if logs show the badge query needs it.

Two indexes support filtering by the curated tags. Model and environment filters are applied to rows found through the tag index.

Use HNSW from launch. An exact scan reads every vector; a 1024-float vector takes 4 KB in TOAST. Keeping vectors in separate tables prevents votes from updating the HNSW graph. Filtered search branches set `hnsw.iterative_scan = relaxed_order` and sort candidates by distance and id before ranking.

### Pagination

All reading lists use URL Previous/Next pages and validated positive page numbers. Offset is `(page - 1) * page_size`, checked for integer overflow. Hold only the current page; no cursor, accumulated rows or seen-id sets. Browse, profiles, inbox and moderation return twenty rows plus one lookahead; normal reviews return thirty plus one. Search returns twenty and uses `total_in_window` from its bounded ranking. Only search has a fixed discovery window; do not cap history in other lists.

| List | Deterministic ordering |
|---|---|
| Browse, Hot / New | `(hot_score DESC, id DESC)` / `(created_at DESC, id DESC)` |
| Reviews, Best / New | `(best_score DESC, id DESC)` / `(created_at DESC, id DESC)` |
| Combined profile, optionally filtered by type | `(created_at DESC, kind ASC, id DESC)` |
| Inbox | `(updated_at DESC, id DESC)` |
| Moderation cases | report count descending, earliest report ascending, target kind and id |

Apply filters before offset; changing filters/sort/query resets page one. Clear filters removes the current browse/search/review filter group, retains the submitted query and applicable sort, and resets page one; the profile's All kind removes its single predicate. Only browse and normal reviews offer selectable sort parameters. Search, profiles, inbox and moderation use their fixed orderings. Fetch a URL page again on Back or remount, preserving useful reading position where possible without promising a frozen ranking. Rankings can cause cross-page repeats or omissions. A successful empty page retains Previous when page > 1. Use one-row lookahead for Next, without total-count queries outside bounded search. Measure deep offsets. Use separate parameterized shapes for active filter combinations (rule 12).

### Read groups per page

These are logical read groups, not fixed statement counts. Include fresh admission for privileged reads, excerpt/selected-review hydration and projection work in measurements. Batch media and vote reads across loaded ids instead of querying once per result.

| Page | Read groups |
|---|---|
| Browse | Live tip summaries and applicable viewer votes/capabilities; no media fetch |
| Tip page | Tip context plus either a ranked page or, for `/reviews/:id`, one selected review; lightweight own-review id/capabilities; media and votes only for displayed content |
| Search | Fused ids, current visible tip summaries, applicable viewer votes/capabilities and matching excerpts; no media fetch |
| Profile | Current combined or type-filtered contributions page, with projected parent links and type-aware identity |
| Inbox | Page/target hydration and all unread pairs in one repeatable-read snapshot; one guarded mark-read per connected visit, plus badge read |
| Moderation | Grouped queue or a reviewed case with versions, report ids/details and authorized media |

Queries join users for handles; the app may cache the three small label tables. Every returned content shape goes through the shared projection, including author markers on reviews of an unavailable parent.

## Queries

### Browse

Hot/New uses the URL page contract in the [backend design](backend-design.md#main-feed-and-clickable-filters). Each page queries current rankings and visibility; no frozen snapshot, duplicate suppression or continuation cursor.

The home page and clickable technique/model tags use these browse queries with Hot/New ordering. Search remains available from the same discovery interface. Keep environment filtering. Model filters match only the tip author's selected model; a review's model does not expand eligibility. Retain the existing tip-level browse predicate and apply the same rule in search. Curated tip tag/model links set that dimension on the current browse/search page, preserving other filters and submitted query or browse sort, with page reset to one. From tip/profile metadata, open browse with that single filter and default Hot. Free-text model names render as plain text, not exact-filter links; reviewer setup remains distinct from parent-tip filtering. See the [backend discovery contract](backend-design.md#main-feed-and-clickable-filters).

```sql
-- Hot, requested page: $1 is validated nonnegative offset; return twenty rows plus lookahead
select t.id, t.title, t.tag_id, t.model_id, t.model_other, t.environment_id, t.score, t.review_count, t.created_at, t.hot_score,
       coalesce(u.handle, '[deleted]') as handle
from live_tips t join users u on u.id = t.user_id
order by t.hot_score desc, t.id desc limit 21 offset $1;

-- New: same with created_at in place of hot_score and the tips_new index.
-- Filters: add parameterized WHERE predicates for t.tag_id, t.model_id and t.environment_id before ORDER BY, only when selected. Assign placeholders for each actual query shape.

-- the signed-in user's votes for the shared compact Helpful / Not helpful controls
select tip_id, value from votes where user_id = $1 and tip_id = any($2);
```

A tip URL is `/tips/{id in base36}/{slug}`. One decoder lowercases and validates the id. Invalid characters, trailing characters, zero, or overflow return 404. The app generates the slug from the projected title/state when rendering the page. It does not store the slug. An incorrect slug redirects to the current URL. For an author-deleted tip use `deleted-tip` for everyone. For a hidden tip, use `removed-tip` for ordinary readers; never generate redirects, page titles, social previews, or other metadata from its original title for them. Existing links still resolve by id. Already shared URLs cannot be recalled. Profile and inbox links use the same viewer-aware title rule, including moderator access.

### Tip page

Read the tip by id, including ownership, versions and all visibility markers, then pass it through the shared Content projection before returning any value to the web layer. A raw query result is internal data, not the page contract.

| Current state | Returned tip fields |
|---|---|
| Author-deleted, every viewer | "Deleted tip", neutral `deleted-tip` slug, no original title/text/setup/author/media or derived metadata |
| Moderator-hidden, ordinary reader | "Removed tip", neutral `removed-tip` slug, no original text/setup/author/media or derived metadata |
| Hidden, authorized author/moderator | Authorized content and media; deliberate removal may show the generic notice |
| Live | Public content and available attachments |

Apply deletion first. The same function projects profile/inbox parent labels, nested associations, selected-review notices, search hydration and metadata. No raw struct, original title in a redirect, or attachment identifier escapes through an alternate return shape. Hidden/deleted parents do not hide independently visible reviews. New reviews require a live parent; existing reviews retain their own permissions. Previously shared image URLs keep the retention policy; video playback tokens already issued remain valid until they expire, and new authorization follows current visibility, with hidden-content access limited to eligible authors/moderators and no original deleted-content access.

Read `latest_review_at` as `max(created_at)` from `live_reviews` for the tip. A selected-review URL returns tip context and only that authorized review, ignoring review-list filter/sort/page parameters. Show all reviews opens the tip permalink with reviewer model/environment filters and review page cleared, returning to unfiltered page one with the current/default sort; selected mode has no list controls. Do not also fetch a ranked page or pin an own-review body. A normal page keeps the viewer’s live review at its ranked position with a Your review badge; a lightweight own-review id/capability lookup provides the header link, including access to an authorized hidden own review.

For readable tip context, also return `has_earlier_reviews` from an existence query for a currently visible, nondeleted review with `created_at < tip.edited_at`. Apply the viewer-aware review policy; do not expose an unreadable review’s date or an unavailable tip’s edit metadata. No extra stored column or full review hydration is needed for this note.

The page displays `latest_review_at` as "Latest review posted N days ago" under the title. It is a publication timestamp, not proof of when the technique was last tested. This shows when someone last reported using the tip, which may become outdated as models change. The query reads `reviews_new` to get the date; no extra column is stored.

```sql
-- Normal reviews, Best, requested page. Include the viewer's own live review at its rank.
select r.id, r.model_id, r.model_other, r.environment_id, r.up_count, r.down_count, r.best_score, r.created_at, r.edited_at,
       r.body, r.prompt, r.output,
       coalesce(u.handle, '[deleted]') as handle, (r.user_id = t.user_id) as by_author,
       (r.user_id = $2) as is_own
from live_reviews r
join tips t on t.id = r.tip_id
join users u on u.id = r.user_id
where r.tip_id = $1
order by r.best_score desc, r.id desc limit 31 offset $3;
-- $2 is the viewer id, NULL when signed out; $3 is the validated offset.
-- New: created_at in place of best_score
-- Model filter, appended only when set:        and r.model_id = $4
-- Environment filter, appended only when set:  and r.environment_id = $5
-- Filters require explicit matches. Combined model/environment filters use AND.
-- Clear filters resets both reviewer filters, preserving sort and returning to page one; never broaden silently.

-- Lightweight own-review lookup; Content derives link/edit capabilities from current scope/state.
select id, dead_at from reviews where tip_id = $1 and user_id = $2 and deleted_at is null;

-- Selected-review mode (/reviews/:id) uses these instead of the ranked-page query.
-- Read the review by id first; no row is not found. Then load its parent by r.tip_id.
-- Project deletion/visibility of both before hydrating any text, media or vote.
select r.* from reviews r where r.id = $1;
select t.* from tips t where t.id = $1; -- $1 is the review's tip_id

-- Internal media read for already authorized parent/review ids. Never return directly.
-- Content projects current parent visibility. Video playback and poster URLs are app routes
-- that sign a short-lived Stream token at request time; the uid never appears in a page.
select m.id, m.user_id, m.tip_id, m.review_id, m.kind, m.position, m.key,
       m.stream_uid, m.state, m.duration_s, m.description, m.is_animated
from media m
where m.cleanup_at is null and m.position is not null
  and (m.tip_id = $1 or m.review_id = any($2))
order by m.tip_id, m.review_id, m.position;

-- my votes on the tip and on these reviews, my review included
select tip_id, review_id, value from votes where user_id = $1 and (tip_id = $2 or review_id = any($3));
```

A deleted review leaves the normal list; retain its row, votes and flags for references. The unique index permits a new review after deletion. A selected deleted/removed review produces the safe notice specified in the backend, not a body leak. Static images render lazily with the supplied description or generic fallback. Animated images use a labelled Play/Hide control and never autoplay; editor thumbnails are static. Videos use a thumbnail and load `/media/{id}/watch` as the inline iframe source on Play, obtaining fresh signed authorization from the server. Watch and thumbnail routes recheck access and redirect with `private, no-store`.

Each displayed review projection includes current action capabilities so its author sees the same permitted Edit/Delete actions in ranked and selected views.

Stored vote rows determine all visible counts; there are no shadow-vote adjustments. Hidden own reviews remain accessible through the authorized selected-review destination, without a second full review slot on normal pages.

### Publish retries

Before uploading files or validating required fields/files, look up the submission key for the authenticated author in the appropriate content table. The identity queries below begin reconciliation; they do not prove the current draft was saved. For a review, require its stored `tip_id` to match the requested parent. Use the backend’s shared normalized whole-edit comparator to return existing-equivalent, existing-different or existing-unknown against complete submitted intent, including explicit blanks, descriptions and full ordered media. Missing recovered image slots or files without known identities mean unknown, not an empty selection. Identity-only lookup and deleted originals return unknown; hidden originals require current author access. Only newly created or established-equivalent content permits clearing the submitted browser revision. No digest columns or request-log table are added.

```sql
select id, deleted_at, dead_at from tips where user_id = $1 and submission_key = $2;
select id, tip_id, deleted_at, dead_at from reviews where user_id = $1 and submission_key = $2;
```

An absent row allows an attempt at the guarded insert; it is not proof that an earlier request cannot still commit. The unique constraint is the concurrency protection. If a submission-key conflict aborts the publishing transaction, roll back the whole transaction, then read the original row using a new statement and apply the same intent comparison. For reviews, a `reviews_one_per_user` conflict can occur first; after rollback, check the submission key before deciding that this is a different review. An existing matching key returns the original publication; an existing review with a different key remains an "already reviewed" error.

Only a new insert runs the self vote, search-row, media, and notification writes. A losing concurrent attempt removes only its own new unattached image objects; reusable staged videos retain their normal recovery window. A retry never uses an upsert that updates existing content. Reusing a committed key with changed form values still refers to the original publication; changes must use the edit operation. Deleted rows retain their key so an old retry cannot recreate deleted content. A deliberate new post or re-review uses a new key.

This applies [Mastodon's submission-key convention](https://docs.joinmastodon.org/methods/statuses/) using the existing Postgres content rows. [Postgres Read Committed](https://www.postgresql.org/docs/current/transaction-iso.html#XACT-READ-COMMITTED) supplies a fresh snapshot for the read after rollback. There is no separate request log or expiry worker.

### Publish a tip or review

After fresh admission, submission-key lookup and image preparation, use one transaction:

1. Lock the participating account rows in id order. Require the author to be undeleted, confirmed and not fully banned. For a review, lock its parent tip next and require both live markers to be NULL. Keep these locks through commit; an unlocked INSERT SELECT does not replace them.
2. Insert content using an Ecto changeset with the actual constraints `tips_submission_unique`, `reviews_submission_unique` and `reviews_one_per_user`. Leave `dead_at` NULL and initialize `edit_version` to 1. A key conflict rolls back before lookup of the original publication.
3. Insert the search row, self vote and new image rows; lock, validate and attach selected staged video rows. Triggers update counters; app code does not duplicate those changes.
4. Fold `tip_reviewed` only for a new live review by someone other than the parent author. Commit before reporting success. No provider write follows publication: attached videos become playable through the signed routes as soon as the content is live.

Build tip search text from title, body, prompt, output, tag and model/environment labels or free text; build review text from body, prompt, output and its own model/environment labels or free text. The shared writer refuses a document over 30,000 UTF-8 bytes, the embedding provider's input limit; the publish, edit, retag or label rebuild transaction then rolls back, and the editor shows how many words to remove. Only a new content insert runs the side effects. A same-key retry returns the original identity/state and comparison outcome, including unknown after deletion. A different key for an existing undeleted review returns "already reviewed" after the key check; link to edit. The embedding scan finds committed search rows without a per-row job.

### Vote

Votes measure perceived helpfulness. Any eligible signed-in reader may vote without having tried the technique or written a review. Firsthand use remains a requirement for authored tips and reviews. No additional voter-experience field or review-existence predicate is needed. Browse and search summaries offer the same Helpful / Not helpful controls, selected/pending behavior and authentication flow as detail pages, while showing net score instead of two counts. Batch viewer-vote and capability hydration for visible summary ids; this does not change ranking or re-sort the current page after a vote. The context accepts a desired vote value or removal, as specified in the [backend voting contract](backend-design.md#voting); the UI's toggle must not become a retry-sensitive toggle command.

Lock the actor account and direct target before writing the vote and its notification in one transaction; a review vote needs no ancestor-tip lock. The statement checks confirmed, undeleted, unbanned user eligibility and live target visibility. Invalidation deletes vote rows under the same ordered locks; unban cannot recreate them.

The upsert changes only a differing value; an unchanged vote returns no row and creates no notification. Distinguish unchanged desired state from failed eligibility after the guarded write. The trigger updates counters for insert, value change and delete.

```sql
insert into votes (user_id, tip_id, value)
select u.id, $2, $3
from users u where u.id = $1 and u.deleted_at is null and u.confirmed_at is not null and u.ban is distinct from 'full'
  and exists (select 1 from live_tips t where t.id = $2)
on conflict (user_id, tip_id) where tip_id is not null
do update set value = excluded.value
where votes.value <> excluded.value
returning value;

-- the response: counters are read in the next statement, not in the same command as the vote
select up_count, down_count from tips where id = $2;

-- only for a new live up vote by someone other than the author: the notification fold, see Notifications.

-- remove a vote
delete from votes where user_id = $1 and tip_id = $2
  and exists (select 1 from users u where u.id = $1 and u.deleted_at is null and u.confirmed_at is not null and u.ban is distinct from 'full');
```

Review votes use the same statements with `review_id` and `live_reviews`. The trigger updates counters after the vote row changes. Votes on the same tip therefore wait for the tip's row lock. The notification update follows that lock, avoiding a separate wait between those votes.

### Edit

Authors can edit tips and reviews at any time while eligible, including moderator-hidden content they own. Keep one undeleted review per author/tip; edits replace its existing fields and attachments. Show original created time and Updated after a real edit. Tip pages note that earlier reviews may describe an older version. Edits preserve created time, votes and ranking inputs, do not emit vote or new-review notifications, and do not reset inbox state. New ordering remains `(created_at, id)`, not edited time. Reject ineligible writes and preserve `dead_at`; an edit never restores moderated content. Rebuild changed searchable text and invalidate its embedding in the same transaction as the edit; no edit-history table is added.

The editor reads editable fields, attachments and `edit_version` from one consistent snapshot. The [frontend](frontend-design.md#saving-and-recovery) owns local draft CAS and a complete immutable editable base; browser references grant no upload authority. Submit the retained expected version as `$12`; the write compares and increments it atomically. A stale version rejects the whole edit, including attachments. Preserve input. If the latest authorized editable fields equal the complete original base under Content’s shared normalization, the author may explicitly Save at current version through the same guard; absent/incomplete base or changed editable fields uses explicit latest-version/manual-reapply recovery. Never automatically replace the expected version or replay an edit. Votes, counters and embeddings do not increment `edit_version`. Lock the author and direct content row, then recheck eligibility; a review edit that does not change liveness takes no parent-tip lock. Check the expected version before accepting a no-op. Compare the entire intended edit, including tag, setup, descriptions and media membership/order. An actual author change increments once; an unchanged current-version submission changes no version or dates. Moderator hide/restore and other content changes retain this single version, preserving the stale-moderator/ABA guard; no second author revision is added.

Prefer `Ecto.Changeset.optimistic_lock(:edit_version)` on a changeset built from the editor's expected version, with `stale_error_field: :edit_version`, for these single-record edits; the eligibility checks run under the locks above before the changeset write. Use a guarded `Repo.update_all` where a conditional or set-shaped write is clearer, as in the SQL below. Use one version mechanism per write; never combine an Ecto lock increment with a second manual compare-and-increment. Never substitute the freshly loaded row's version for the editor's.

```sql
-- Guarded-SQL form, equivalent to the optimistic-lock changeset. After ordered eligibility locks
-- and a comparison proving an actual author change. An unchanged authorized submission at the current version skips this write.
with e as (update tips set title = $3, body = $4, prompt = $5, output = $6, model_id = $7, model_other = $8, environment_id = $9, tag_id = $10, edited_at = now(), edit_version = edit_version + 1
           where id = $1 and user_id = $2 and deleted_at is null
             and edit_version = $12
             and exists (select 1 from users u where u.id = $2 and u.deleted_at is null and u.confirmed_at is not null and u.ban is distinct from 'full')
           returning id, edit_version)
update tip_search s set search_text = $11, text_at = now(), embedding = null, embed_after = null
from e where s.tip_id = e.id returning s.tip_id, e.edit_version;
```

The worker writes a vector only if `text_at` still matches. After the guarded edit succeeds, defer `media_tip_slot` and `media_review_slot` for this transaction with `SET CONSTRAINTS ... DEFERRED`. Keep retained media ids, mark removed rows `cleanup_at = now(), position = NULL`, update retained positions, attach ready owned video rows and insert new image rows. Validate one unique ordered selection of at most ten; duplicate final slots fail at commit and roll back the entire edit. Deferrable constraints support swaps without delete/reinsert or temporary out-of-range positions.

Insert cleanup jobs for removed assets in that same transaction; retain their provider identifiers until confirmed deletion/purge. A confirmed failed attempt cleans up only its new unattached images. Unknown commit outcomes retain uncertain objects and reconcile references before cleanup or retry. Apply the same version guard to review edits. Moderator media destruction advances only `edit_version`; stale editors cannot resurrect removed assets. Author deletion needs no editor version and cannot be undone by an edit.

### Delete, by the author

Under the shared lock order, require a current authenticated undeleted account and ownership; a full ban does not block deletion. Set `deleted_at` only on the matched nondeleted target. In the same transaction, resolve its open flags, remove the applicable notifications, mark its live media `cleanup_at = now(), position = NULL`, and enqueue cleanup jobs. A rejected delete changes no dependents. Retain media rows and provider identifiers until deletion/cache purge succeeds. The review trigger removes only a formerly live review from its parent's count.

Deleting a tip removes its `tip_upvoted` notifications and `tip_reviewed` notifications found through its reviews, but only its own media. Existing reviews and review media remain independently visible and editable. The Content projection masks the deleted tip's title, content, attribution, links and metadata for everyone. No undo or restoration operation is provided.

### Moderate

Require fresh moderator admission and lock participating accounts/content in the shared order. Recheck current role, confirmation, deletion and full-ban state inside the transaction. `dead_at` is deliberate moderator hiding; deletion remains independent and takes precedence. An author can inspect eligible hidden content with a generic deliberate-removal notice, without report details or invented removal reasons.

| Operation | Transaction contract |
|---|---|
| Hide / restore | Compare the loaded `edit_version`, visibility and reviewed report state. Change only `dead_at`, advance `edit_version` on a change, leave author dates alone. Do not restore deleted content. Resolve only the reviewed report ids for an action that resolves reports. |
| Retag | Require a nondeleted tip and active tag; compare/increment `edit_version`, use the shared search-text writer to rebuild text, advance `text_at`, clear `embedding` and reset `embed_after`. Preserve author fields, `edited_at` and visibility; unchanged tag is a no-op. |
| Dismiss reports | Compare target version and every captured report's open state; resolve only that reviewed id set. New reports stay open. Change neither visibility nor the content edit version. |
| Destroy selected media | Compare/increment target `edit_version`; validate every selected id belongs to live media on that target. Mark only those rows for cleanup, clear positions and enqueue cleanup. Preserve other attachments and text. |
| Bulk hide | Prelock affected users, tips and reviews in order; set deliberate `dead_at` on eligible nondeleted content. Advance affected edit versions. Counter triggers apply the resulting live-state changes once. |
| Ban / unban | Lock moderator and subject accounts in id order. Setting a restriction does not retrospectively hide content. Lifting a full ban changes account eligibility only. Preserve deliberate hiding/deletion and do not recreate invalidated votes. |
| Invalidate votes | Lock participating users and all affected parents before vote rows; delete selected vote rows and let triggers subtract counts. Do not restore those votes when unbanning. |

Moderator restoration allows the embedding scan to find newly eligible rows and makes attached videos signable under current visibility. Unban only changes account eligibility. Neither operation replays publication notifications or changes author dates. No provider activation or media job follows restoration.

A signed-out Report action returns through authentication to the validated local target/report interaction; recheck eligibility and require explicit submission. Authentication never inserts a flag, and expired admission preserves input for explicit retry. In the transaction, first lock the reporter account and require confirmation, undeleted status and no full ban. Then select the reportable direct target `FOR SHARE` before insertion. This conflicts with author deletion’s row lock: report-first is resolved by deletion; delete-first fails the reportable predicate after waiting. No author revision is supplied. The review variant checks and locks the direct review, without an ancestor-tip lock:

```sql
insert into flags(user_id, tip_id, reason, detail)
select $1, t.id, $3, $4 from tips t
where t.id = $2 and t.deleted_at is null and t.dead_at is null
for share of t
returning id;
```

Keep only partial `flags_open_tip` and `flags_open_review` uniqueness per reporter/target. The direct-target lock lasts through commit; it does not impose a report-specific content version. Measure contention rather than assuming fixed latency. On expected uniqueness conflict, roll back and return the existing report's actual receipt/state, never claim newly supplied detail was stored. If resolution races receipt lookup, preserve input and return uncertainty when no receipt can be established; no automatic insertion loop. After resolution the reporter may create a new report on unchanged content. An explicit delayed retry can therefore create an additional report after the first resolves; accept that queue-work tradeoff. Reports never automatically hide, rank or penalize content. Keep moderator content-version and reviewed-report-set guards.

Moderation reads group open flags by target (report count descending, earliest report first, target kind/id tie-breakers), returning twenty cases plus lookahead at the requested offset, then load the reviewed case with version, visibility, individual report ids/details and authorized media. Apply the same deletion-first Content projection even for moderators. Vote-investigation reads return voter identity, value and date only through privileged admission. No moderator read may expose deleted original content through a raw join.

**File storage.** Images use one public R2 bucket behind the media domain. Hiding does not move files or revoke already-shared URLs. Provider deletion and R2 cache purge run after commit through cleanup jobs. Both are repeat-safe; keep the cleanup row until both succeed. Until M4 the job deletes the cleanup row after Stream and R2 deletion: purge is an M4 requirement that needs the cookie-free media domain and purge access ([#178](https://github.com/chenghanlee/tips/issues/178)), and the development `r2.dev` host cannot be purged. `Cache-Control: public, max-age=3600, must-revalidate` limits stale cached access if purge is delayed or not yet built. The weekly orphan sweep handles objects uploaded before a committed media row; it does not replace durable cleanup records. Videos stay private at Stream; hiding stops new playback tokens, tokens already issued remain valid until they expire, and deletion removes the asset through cleanup. See [Playback and cleanup](#playback-and-cleanup).

### Account deletion

A recently authenticated user can delete their own account after explicit confirmation, even while fully banned. Require Phoenix sudo mode in the account-deletion operation; after reauthentication, return to confirmation rather than deleting automatically. Authentication tokens must be revoked with account deletion; the single-row SQL below is only the identity-clearing part of that operation. The account id comes from the authenticated scope. Deleting the account does not delete its tips or reviews; authors who want those removed must delete them before deleting the account.

Account deletion keeps the user row to preserve foreign keys, as Reddit does. Set the handle and email to NULL; the two `_del` checks allow this only for deleted accounts. A shared replacement handle would violate `users_handle_unique`, while generating a unique replacement for each account would add a naming rule. Queries display NULL handles with `coalesce(u.handle, '[deleted]')`. The old handle and email can be registered again. The auth library revokes the account's sessions.

```sql
update users set deleted_at = now(), handle = null, email = null, updated_at = now()
where id = $1 and deleted_at is null;
```

### Profile

Default to a combined newest-first contributions list with optional `kind=all|tips|reviews` in the URL. Use `UNION ALL` over nondeleted tips/reviews, project author/moderator visibility and parent labels, then order by `(created_at DESC, kind ASC, id DESC)` and apply the validated offset with twenty rows plus lookahead. Filter by kind before paging. Row identity is `(kind, id)` because ids can overlap. Changing kind resets page one; no inactive-tab cache. Visible reviews of removed/deleted tips retain masked parent links. Account registration uses `users.inserted_at`; contributions use `created_at`.

```sql
-- Example public-profile candidate page; privileged own/moderator reads use the shared visibility policy.
with contributions as (
  select 'tip'::text as kind, id, created_at from live_tips where user_id = $1
  union all
  select 'review'::text as kind, id, created_at from live_reviews where user_id = $1
)
select kind, id, created_at from contributions
order by created_at desc, kind asc, id desc limit 21 offset $2;
-- Add an explicit kind predicate before ORDER BY only when selected; project/hydrate current visibility.
```

### Notifications

The inbox uses URL Previous/Next pages of twenty notifications, with one-row lookahead at a validated offset and `(updated_at DESC, id DESC)` ordering. Disconnected mount is read-only. Capture all unread pairs and mark once on the connected visit; later page changes only read. A true remount is a new visit. Mark all captured unread rows, including unloaded rows, while later arrivals/folds stay unread. Keep one current page, not appended batches.

Write the notification in the same transaction as the vote or review. If the recipient already has an unread row for that type and target, add 1 to its count and update its timestamp so it sorts first. Skip the insert if the actor is the recipient or the action is ineligible. The count records helpful-vote events. A user who votes, removes the vote, and votes again counts twice; this is intended.

```sql
-- updated_at has no default: the insert supplies it.
insert into notifications (user_id, type, actor_id, tip_id, review_id, updated_at) values ($1, $2, $3, $4, $5, now())
on conflict (user_id, type, tip_id, review_id) where read_at is null
do update set count = notifications.count + 1, actor_id = excluded.actor_id, updated_at = now();

-- badge, on every page load, capped like GitHub. Served by notifications_fold.
select count(*) from (select 1 from notifications where user_id = $1 and read_at is null limit 100) x;

-- inbox: two reads in one repeatable-read transaction, so both see the same snapshot. Close it before rendering.
begin isolation level repeatable read read only;
-- The page captures notification identity; hydrate targets through the shared Content
-- projection within this snapshot before returning them. Do not expose joined raw text.
select n.id, n.type, n.count, n.updated_at, n.read_at,
       n.tip_id, n.review_id, n.actor_id
from notifications n
where n.user_id = $1 order by n.updated_at desc, n.id desc limit 21 offset $2;
-- On connected-visit capture only: every unread (id, count) in the same snapshot for mark-read.
-- Ordinary page navigation omits this capture and the subsequent mark-read update.
select array_agg(id) as ids, array_agg(count) as counts from notifications where user_id = $1 and read_at is null;
commit;

-- mark all read, own transaction. Only rows still at the captured count are marked, so a fold or a new row after the snapshot stays unread.
-- Reproduced: a review notification that commits between the page and an unconditional update would be marked read unseen.
update notifications n set read_at = now()
from unnest($2::bigint[], $3::int[]) v(id, count)
where n.user_id = $1 and n.id = v.id and n.count = v.count and n.read_at is null;
```

The three notification types are `tip_upvoted` ("Your tip got new helpful votes"), `review_upvoted` ("Your review got new helpful votes"), and `tip_reviewed` ("handle reviewed your tip", or "Your tip got a review" while the recipient cannot read that review, so a hidden review's author stays unnamed). Vote notifications show activity time, without actor names or numeric event totals. Keep the internal count for folding and race-safe mark-read; it is not a count of distinct voters.

### Search

The hybrid query follows the Tiger Data guide.

One shared search-text writer handles publication, searchable edits and tip retagging in the content transaction. Set the current `search_text` and fresh `text_at`, clear `embedding`, and reset `embed_after`. Curated labels remain stable for the MVP; a label change rebuilds affected documents through this helper. A worker’s success or failure write with an older `text_at` must not change the new row. One Oban cron singleton processes up to 50 rows per scan, alternating tips and reviews, with active-state uniqueness, queue concurrency 1 and `max_attempts: 1`. `embed_after` is its only per-row cooldown. Make one bounded provider request per row, disable nested HTTP retries, classify errors and continue past poison rows. Crashed scans resume at the next tick. Select eligible pending tips with `tip_search s join live_tips t on t.id = s.tip_id where s.embedding is null and (s.embed_after is null or s.embed_after < clock_timestamp())`; use corresponding review/parent visibility for reviews. Order each kind by `s.embed_after nulls first`, then id: never-attempted and text-reset rows come first, then due retries with the oldest cooldown first, so slow failures take turns instead of the lowest ids winning every scan. Steady new or edited documents can still delay retries, and no progress bound is promised; the sort covers the due backlog, which the partial queue index does not order. Admit each selected row with one guarded update that rechecks those conditions and the `text_at` read, sets the ten-minute `embed_after`, and returns the stored `search_text` as the provider input. Admission commits before the request. A row that crashes the scan during its request stays cooling, so the next scan moves past it instead of retrying it first. Measure throughput rather than assuming a batch finishes in a minute; 50 requests at the 30-second limit take up to 25 minutes.

The worker skips killed and deleted content. The queue index checks only `embedding is null`, because a partial index cannot check the parent table. The join checks whether the content is live.

Both worker updates require the same `text_at` value the worker read:

- Success: `update tip_search set embedding = $2 where tip_id = $1 and embedding is null and text_at = $3`.
- Failure: `update tip_search set embed_after = clock_timestamp() + interval '10 minutes' where tip_id = $1 and embedding is null and text_at = $3`.

If the text changes during the call, neither update changes the row. The worker processes the new text later. A failure restarts the cooldown, so the row retries ten minutes later without delaying other rows in the batch. No attempt count is stored. Observe eligible missing-vector work, including never-attempted and cooling-down rows. The [backend independent progress check](backend-design.md#independent-background-progress-checks) uses bounded recency/oldest-age queries and is invoked independently of Oban; the basic app/DB probe alone is insufficient.

Vectors are 1024 dimensions. Production runs one embedding runtime: Qwen3-Embedding-8B through [OpenRouter](https://openrouter.ai/qwen/qwen3-embedding-8b), served only by Nebius, with 1024 requested dimensions. Documents are plain text. Queries carry the model card's retrieval prefix, `Instruct: Given a web search query, retrieve relevant passages that answer the query\nQuery: {text}`. `config/config.exs` sets the implementation, model, host, dimensions and query instruction; `Tips.Content.Search.EmbeddingProvider` documents the input limits, deadline and errors. Run one model on one host at a time. Never mix vectors from two models or hosts; changing either sets every `embedding` to NULL, and changing the dimensions also needs a migration. The embedding runtime receives eligible public document text and reader queries. Eligibility is checked when the scan admits a row; a hide or deletion committed after admission does not recall an in-flight call, and no retroactive recall exists. Browser drafts never reach it. Development, CI and deployment verification exercise the selected runtime with the same configuration, including long-document inference.

To change the embedding model, host or implementation while retaining 1024 dimensions:

1. Drain the embedding queue, then stop every instance of the old release, so no scan or query uses the old model.
2. In one transaction, set every `embedding` and `embed_after` to NULL and advance every `text_at`, including hidden and deleted rows. A write from a request started before the clear then fails its guard. This protects against a missed process; it does not replace step 1.
3. Change the configuration in `config/config.exs`.
4. Start the new release.

`Tips.Release.clear_embeddings/0` performs step 2; `Tips.Content.Search.Embeddings` documents the commands.

```sql
-- keyword hits on tips and on reviews. pg_textsearch scores are negative, so ascending order is best first.
-- Keyword candidate subqueries retain their bounded top-k ordering; filter nonmatches before rank/group/fusion.
-- ORDER BY alone is not a match predicate.
with q as (select to_bm25query($1, 'tips_bm25') as qt, to_bm25query($1, 'reviews_bm25') as qr, $2::vector(1024) as vec),
tips_bm25 as (
  select tip_id, d from (
    select s.tip_id, s.search_text <@> (select qt from q) as d
    from tip_search s join live_tips t on t.id = s.tip_id
    order by d, s.tip_id limit 50) x where d < 0),
-- vector branches: with hnsw.iterative_scan = relaxed_order the index can return candidates slightly out of order,
-- so the candidates are materialized and sorted again before ranking, as the pgvector docs show.
tips_vec as materialized (
    select s.tip_id, s.embedding <=> (select vec from q) as d
    from tip_search s join live_tips t on t.id = s.tip_id
    where s.embedding is not null
    order by d limit 50),
-- review branches: 1000 candidates from the index with live parents, then the best review per tip, then re-rank.
-- The cap counts reviews. If many matches belong to one tip, fewer distinct tips are returned.
reviews_bm25 as (
  select tip_id, review_id, d, row_number() over (order by d, tip_id) as rank from (
    select distinct on (r.tip_id) r.tip_id, r.review_id, r.d from (
      select s.review_id, r.tip_id, s.search_text <@> (select qr from q) as d
      from review_search s
      join live_reviews r on r.id = s.review_id
      join live_tips t on t.id = r.tip_id
      order by d, s.review_id limit 1000) r
    where r.d < 0
    order by r.tip_id, r.d, r.review_id) x
  order by d, tip_id limit 50),
reviews_vec_c as materialized (
      select s.review_id, r.tip_id, s.embedding <=> (select vec from q) as d
      from review_search s
      join live_reviews r on r.id = s.review_id
      join live_tips t on t.id = r.tip_id
      where s.embedding is not null
      order by d limit 1000),
reviews_vec as (
  select tip_id, review_id, d, row_number() over (order by d + 0, tip_id) as rank from (
    select distinct on (tip_id) tip_id, review_id, d from reviews_vec_c order by tip_id, d + 0, review_id) x
  order by d + 0, tip_id limit 50),
-- one list per modality: each tip once, by the better score of the tip and its best review.
keyword as (
  select tip_id, row_number() over (order by d, tip_id) as rank from (
    select tip_id, min(d) as d from (select tip_id, d from tips_bm25 union all select tip_id, d from reviews_bm25) c
    group by tip_id) x),
vector as (
  select tip_id, row_number() over (order by d, tip_id) as rank from (
    select tip_id, min(d) as d from (select tip_id, d from tips_vec union all select tip_id, d from reviews_vec) c
    group by tip_id) x),
ranked as (
  select tip_id, sum(1.0 / (60 + rank)) as score
  from (select tip_id, rank from keyword union all select tip_id, rank from vector) fused
  group by tip_id),
matched as (
  select distinct on (tip_id) tip_id, review_id
  from (select tip_id, review_id, rank from reviews_bm25 union all select tip_id, review_id, rank from reviews_vec) r
  order by tip_id, rank, review_id)
select tip_id, m.review_id as matched_review, score, count(*) over () as total_in_window
from ranked left join matched m using (tip_id) order by score desc, tip_id limit 20 offset $3;
-- $3 is a validated multiple of 20, from 0 through 180, into the final <=200-tip window.
```

The keyword branches exclude zero/nonnegative scores outside their bounded candidate subqueries and before ranking/grouping/fusion. Standalone scoring may return zero for nonmatching documents; those are not lexical hits. Vector branches have no cutoff.

A tip ranks by how well the tip or its best review matches. Each modality merges the tip and review branches into one list that ranks each tip once by the better of the two scores, so having reviews adds no score by itself. Summing four branch ranks did: a reviewed tip collected review-vector score for any query, and the [#60 gate run 3](https://github.com/chenghanlee/tips/blob/d3026ac1a973f0e62512453a53dfa1dedfdbcbb9/test/fixtures/search_probe/evidence/60-integrated-run-3.json) missed q03 and q06 ([#349](https://github.com/chenghanlee/tips/issues/349)). Cosine distances share one embedding space. BM25 scores come from two indexes with their own corpus statistics, as in Elasticsearch `best_fields` across fields, so the keyword comparison is approximate. Each list holds up to 100 tips, so the window stays at most 200.

Search returns one result per tip, as Hacker News does. If a review matches, `matched_review` identifies the best matching review: the best ranked review in either review branch, whether or not it beat the tip in its list, and the result shows its snippet under the tip. Return a matching review excerpt's source as Review (body), Prompt, Result, or Reviewer setup. Hydrate tip ids, viewer votes/capabilities and matching excerpts with current visibility checks, then apply the shared projection; an old hit id does not authorize hidden text. Preserve returned ranking order. `total_in_window` determines whether the current bounded ranking has another page; an empty page has none. Candidate limits do not grow with offset. Cross-page repeats/omissions are accepted, and each request may independently fall back to keywords.

If query embedding fails or the hybrid statement times out, retry without the vector branches only within the remaining total operation budget. The [backend search contract](backend-design.md#task-first-discovery) bounds provider request concurrency, queue wait and the complete operation; retain the two-second request query timeout. Failure of the keyword path or overall budget returns a search error, not no matches. Put tag, model, and environment filters inside all four branches. Model filters always use the parent tip's `t.model_id`, including review branches; do not substitute or OR in `r.model_id`. `search_text` includes the tag label and each contribution’s own model/environment labels or free text so words such as "persona" and "opus" can match. Strict quoted-phrase search is deferred: the app treats input as ordinary text and must escape or normalize engine syntax consistently rather than pass through raw query operators. Include Result text (`output`) in both tip and review search documents. Uploaded image/video contents are not transcribed or indexed. Publication, searchable edits and retagging use the shared search-text writer and freshness guard above.

## Upload

One `media` table holds committed R2 images/GIFs, staged and attached Stream videos, and cleanup records. There is no second staging or cleanup table. Stable ids survive attachment and reordering. One server-owned encoder turns `{:new_tip, submission_key}`, `{:new_review, tip_id, submission_key}`, `{:edit_tip, tip_id}` or `{:edit_review, review_id}` into `target`. The target is stable content identity without an edit version; there is no rebind operation, and the edit transaction checks the editor's expected version independently. Possessing an id or supplying a target string grants no access.

The backend owns the upload flows, provider requests and size limits: [Managed video](backend-design.md#managed-video) and [Image/GIF upload integration](backend-design.md#imagegif-upload-integration). This section owns the `media` row states, guards and queries.

### Video states and deadlines

Create the owned row before requesting the Stream tus URL; initially `stream_uid` is NULL, `state = 'uploading'`, no parent/position is set, and `expires_at = created_at + interval '1 hour'`. The Stream reservation `expiry` equals that deadline. After acquiring the media-row lock, persist the returned uid in a subsequent conditional statement, `where id = $1 and stream_uid is null and state = 'uploading' and cleanup_at is null and created_at + interval '1 hour' > clock_timestamp()`, and return the upload URL to the browser only after that write commits. Zero rows means the URL is never returned; the unused reservation expires at the provider. A persisted uid is never cleared. A failed or timed-out creation call is not retried against the same row; a fresh upload uses a new row. A creation call that fails outright sets `state = 'failed'` at once with a NULL uid; a row whose uid is still NULL at its deadline is retired locally by the expiry branch. Both need no provider lookup and no deletion job, because no browser ever received an endpoint and there is no identifier to delete: set `cleanup_at`, keep `state` as `failed`, and delete the row directly. The schema permits `failed` with a NULL uid, and the guard above excludes failed, cleanup-marked and expired rows so a late provider response cannot revive them. Such rows never require provider-status reads.

Editors refresh pending video state through `get_video_uploads` ([Managed video](backend-design.md#managed-video)). Timeouts preserve committed facts and do not mean encoding failure. Ready rows require no provider refresh on Publish; reconcile the submission key first. No global readiness worker, scan-rotation column or webhook exists.

Stream records no completion time: `uploaded` is the reservation time, `modified` the last change and `readyToStreamAt` processing readiness. It does give a trusted completion fact: the video leaves `pendingupload` only after the last byte. Stream refuses a `PATCH` started after the reservation `expiry`, which equals the upload deadline `created_at + interval '1 hour'`. Whether it can complete a `PATCH` still sending at that instant is unproven; three such requests were refused (400, code 10017) when their bodies finished ([probe](../development/stream-completion-probe.md)). So the recovery deadline is fixed from the upload deadline, not from completion: an upload that completed is recoverable until `created_at + interval '49 hours'`. That is at least 48 hours after its last byte, or at least 47 hours 50 minutes if Stream completes an upload inside the 10-minute margin below. No completion time is stored, and observation or readiness time never sets a deadline.

The first trusted provider state other than `pendingupload` moves a known-uid row out of `uploading` (to `processing`, `ready` or `failed`) and sets `expires_at = created_at + interval '49 hours'` in the same guarded statement, `where state = 'uploading' and stream_uid is not null and cleanup_at is null and tip_id is null and review_id is null`. That statement needs no wall-clock check: any completion Stream reports counts, including one inside the margin. A cleanup-marked row is never revived. `media_deadline_chk` keeps `expires_at` equal to one of the two deadlines. A `failed` row with a uid completed its transfer and failed processing, for example on duration; it keeps the recovery deadline so the author sees why.

A separate bounded periodic expiry worker selects at most fifty due unattached rows through `media_expiry`, checking `expires_at <= clock_timestamp()` and `(reconcile_after IS NULL OR reconcile_after <= clock_timestamp())` at runtime. Never put a time-dependent expression in the partial-index predicate. The worker handles each due row by kind of upload:

| Upload | Due at | Worker action |
|---|---|---|
| Unfinished, NULL uid | upload deadline | Retire locally; no provider call or job. |
| Unfinished, known uid | upload deadline | Read Stream. Any state other than `pendingupload` is a completion: apply the transition above, which moves the row to the recovery deadline. `pendingupload` is definitive only for a read that starts at least 10 minutes after the upload deadline: then retire and enqueue deletion. An earlier `pendingupload` read sets `reconcile_after = expires_at + interval '10 minutes'`. |
| Uncertain: the read times out, is rate limited or fails | upload deadline | Set `reconcile_after` to wall time after the attempt plus ten minutes initially, guarded against attachment, cleanup or state changes. The user-facing deadline does not change. |
| Completed: `processing`, `ready` or `failed` with a uid | recovery deadline | Retire and enqueue deletion, whatever the processing state. |

The 10-minute margin covers a `PATCH` still sending at the deadline, whose outcome is unproven. An upload that completes after a definitive `pendingupload` read is not recovered: its row is already in cleanup and is never revived. The cooldown lets later rows progress without changing user expiry. Clear it on definitive progress, attachment or cleanup; it survives restarts. No per-row expiry jobs or global readiness scanner are needed. Editor and expiry results use the same guarded transition, never regress terminal state, revive cleanup or restore expiry after attachment. Provider calls run outside row locks; recheck current eligibility and current wall-clock deadlines in a statement after acquiring the lock when applying results. The deadline decision, not a promised future commit time, is the linearization point.

Processing state is `uploading | processing | ready | failed`; Ready means trusted playable media within the duration limit. Provider-result writes mutate only known rows with `cleanup_at IS NULL` through guarded Media operations; readiness never publishes. Publication/edit locks the row, verifies author/target/readiness/deadline and unique selection, attaches it once, assigns its position and clears `expires_at` and `reconcile_after`. After an edit conflict, explicit reapplication reuses the same owned staged assets because their target is the content id, not a version; the edit transaction still checks the editor's original expected version. Never silently advance the saved version.

An explicit edit may claim a video staged for a new-submission target only when its stored author, kind and submission key resolve to the exact edited item, with the same parent for a review. Evaluate this from immutable stored facts at claim time, with the ownership, readiness, unexpired-deadline and non-cleanup guards. Never rewrite `target`. The backend's [video upload contract](backend-design.md#video-upload-before-publication) and the [frontend handoff](frontend-design.md#publication-to-edit-handoff) own the flow.

### Playback and cleanup

Every Stream asset stays private for its whole life. There is no activation column, job or status; visibility is a database fact checked on each request. `/media/{id}/watch` and `/media/{id}/thumbnail` load the row, reject cleanup-marked or ineligible assets and apply the shared visibility policy: public for live content, owner for staged and authorized previews, author/moderator for hidden content. No table stores playback tokens. Do not persist provider ids or tokens in browser drafts or storage. After deletion, confirmed provider removal ends serving regardless of token expiry. [Managed video](backend-design.md#managed-video) owns signing, redirects and cache headers.

Removal, explicit discard and expiry lock/recheck the same row as attachment claims, set `cleanup_at` and clear `position` and `reconcile_after`, then enqueue cleanup in the transaction for rows that have a provider identifier (`key` or `stream_uid`). NULL-uid video rows have nothing to delete at the provider and are retired locally without a job, as described above. Keep parent/provider identifiers until confirmed provider deletion and applicable R2 cache purge. Provider results and claims cannot revive a cleanup row. After success delete that row. A pruned cleanup job can be reconstructed from it; job arguments are never the sole retained deletion record. Deletion is terminal and never recreates an asset.

### Image/GIF attempts

One ordered mixed-media selection allows at most ten attachments (`position` 0..9), including retained media and multiple videos. [Image/GIF upload integration](backend-design.md#imagegif-upload-integration) owns the byte limits and LiveView entry handling.

Validate PNG/JPEG/WebP/GIF content and sizes with a maintained parser; derive trusted `is_animated` including animated WebP/APNG, bound parsing resources, and reject unclassifiable content with preserved input. Normalize a blank image `description` to NULL and persist it with the attachment. Upload under server-generated `media/{uuid}.{ext}` keys with trusted Content-Type, then open the content transaction. Never keep page-only R2 keys as long-lived staging.

A confirmed rejected attempt cleans up only its new unattached image objects. Unknown commit outcomes reconcile publication/edit and committed references; do not delete because confirmation was lost, the page closed or a draft was discarded. The weekly sweep deletes objects older than one hour with no media row (cleanup rows count as references). Bound active upload/transaction attempts below that grace period. A retry after known rejection makes a fresh R2 attempt from retained entries; it never reuses an orphan-eligible old key.

Serve media from a cookie-free origin with `X-Content-Type-Options: nosniff`, server-derived Content-Type and the documented cache policy. Full image transformation, OCR and automatic descriptions are deferred.

## Defenses

- Contributions and edits need a confirmed, signed-in user who is not fully banned. This includes publishing, voting (including removal), reporting, and moderation actions. Author deletion and account deletion remain available during a full ban. Use operation-specific guards rather than blocking all authenticated routes. Publish and vote insertion also check that the target is live where applicable.
- Apply one rate limit per IP at Cloudflare and one per user in the app to writes and uploads. Deleting content does not reduce the write count. Use Turnstile on sign-up. Before token creation/mail delivery, also apply the app limiter by normalized destination address and trusted client IP for sign-in, resend and email-change requests, including LiveView events. An in-process limiter is sufficient for this single-node deployment; see the backend authentication contract.
- Request queries time out after two seconds through the `Tips.Repo` client timeout (`timeout: 2_000`), not a server `statement_timeout` or `SET LOCAL`. A timed-out call cancels its query and closes that pool connection. Migrations and maintenance calls pass a longer or `:infinity` timeout per call; no session setting changes, so nothing leaks into the request pool. Test actual release, backup, restore and repair commands.
- Moderation writes lock the actor's user row and recheck its role in Elixir.
- Disable raw HTML in Markdown. Limit upload bytes and validate supported image content and trusted motion classification with bounded parsing. Serve them from an origin without cookies, using server-set Content-Type and nosniff.
- Reserved handles: a short blocklist in the app (`admin`, `moderator`, `mod`, `staff`, `support`, `deleted`, `removed`).
- Include `<meta name="robots" content="noindex">` until direct sharing brings 20 non-staff visitors in one week. Record this condition in the launch checklist. The operator checks it weekly.
- Limit search input length before running the query.
- Run `pg_dump` nightly from cron and store the backup in private R2 storage. Retain backups for seven days using a backup-scoped R2 lifecycle rule. Test a restore before launch. This is daily recovery, not point-in-time recovery; see the software architecture's retention policy.

## Counter repair

An operator can run these statements to repair counters. Pause writes and wait for open write transactions to finish first. Otherwise, the recount can overwrite a concurrent vote's counter update:

```sql
with v as (select tip_id, count(*) filter (where value = 1) as up, count(*) filter (where value = -1) as down
           from votes where tip_id is not null group by tip_id),
     r as (select tip_id, count(*) as n from reviews where deleted_at is null and dead_at is null group by tip_id)
update tips t set up_count = coalesce(v.up, 0), down_count = coalesce(v.down, 0), review_count = coalesce(r.n, 0)
from tips x left join v on v.tip_id = x.id left join r on r.tip_id = x.id
where t.id = x.id and (t.up_count, t.down_count, t.review_count) is distinct from (coalesce(v.up, 0), coalesce(v.down, 0), coalesce(r.n, 0));

with v as (select review_id, count(*) filter (where value = 1) as up, count(*) filter (where value = -1) as down
           from votes where review_id is not null group by review_id)
update reviews r set up_count = coalesce(v.up, 0), down_count = coalesce(v.down, 0)
from reviews x left join v on v.review_id = x.id
where r.id = x.id and (r.up_count, r.down_count) is distinct from (coalesce(v.up, 0), coalesce(v.down, 0));
```

## Patterns used

| Part | Pattern | Where it is used |
|---|---|---|
| `deleted_at`, `dead_at` | Author deletion and deliberate moderation | Hacker News `deleted` and `dead`, Reddit `[deleted]` and `[removed]` |
| Deleted post keeps its page and comments | Placeholder in place of content | Reddit |
| Tips and reviews editable at any time | Updated date, no new ranking boost or notification | Selected Tips UX contract |
| `role`, normal/full ban | Explicit contribution restriction, deletion rights preserved | Selected Tips moderation scope |
| Account deletion keeps content | Clear the author's handle and email | Reddit |
| Base36 id plus slug in the URL | Readable URL, id is the key | Reddit, Stack Overflow |
| One review per user per item | Natural unique key | Yelp, Google Maps, Steam, Amazon |
| `votes` with value plus or minus 1 | Up and down votes | Reddit, Lemmy |
| Auto up vote on your own post | Author's first vote | Reddit |
| Stored counters on the row | Denormalized score and comment count | Reddit, Hacker News |
| Generated `score`, `hot_score`, `best_score` | Counters determine the rank | Reddit's formulas, computed by Postgres |
| Classic Reddit hot | log of net votes plus age | Reddit, Lemmy |
| Wilson lower bound for reviews | Reddit "Best" for comments | Reddit, Evan Miller's essay |
| Helpful and Not helpful buttons | Vote on a review | IMDb, Amazon, Steam |
| URL Previous/Next pages | Current-page offset reads with deterministic ordering | Selected Tips UX contract |
| Lookup tables with active and sort order | Curated lists | Most admin panels |
| One tag per tip, curated, required | Flair | Reddit |
| `media` with a position and a slot limit | Ordered attachments | Twitter (4), Instagram (10) |
| Upload through the app, server key, files never move | Validate in memory, put once | Discourse default (`enable_direct_s3_uploads: false`) |
| Killed post keeps its files, orphan sweep with a grace period | Retain files when content is hidden | Discourse `clean_up_uploads` |
| Search text in a side table | Store counters and search data in separate tables | Discourse `post_search_data` |
| `flags` with reporter and resolver, queue grouped by target | Reports table | Discourse, Lobsters |
| `notifications` with fold on conflict | One row per recipient per event, consolidated | Discourse, GitHub, Rails Noticed |
| Read per row, mark all on open, badge capped | Inbox read state | Reddit, Instagram, GitHub |
| BM25 plus vectors with reciprocal rank fusion | Hybrid search in Postgres | Tiger Data guide |
| Bounded candidates, then one per parent | Group results by parent after retrieval | Elasticsearch collapse, on a fixed pool |
| Async embedding with per-row retry | Nullable vector, backfill loop, flat retry delay | Common in pgvector deployments; Celery `default_retry_delay` |
| Counters by `AFTER` row trigger | Delta from `OLD` and `NEW`, applied to the parent | Lemmy `post_aggregates`, Rails `counter_cache` |
| Vote keyed by user and target, no surrogate id | Identify a vote by its user and target | Lemmy `PostLike` |
| Views for the live row set | Named predicate, inlined | Standard SQL |
| SQL checks write conditions; the app checks the row count | Conditional write | Read Committed isolation |
| Two reads in a repeatable-read transaction | One snapshot for page plus capture | Postgres isolation levels |

## Deferred features

| Feature | When to add it |
|---|---|
| Top sort on tips | When readers want an all-time ranking. Use `score` and add an index. |
| Edit history | When an edit dispute happens. Stack Overflow style revisions. |
| Several tags per tip | When a tip needs two labels. Add `tip_tags` and move the column. |
| A roles table | When one user needs two roles. Create `user_roles` and move the column. |
| Muted notification types | When requested. Add one array column to users. |
| Email notifications | When requested. Read the existing notifications table. |
| Mark one notification as read | When requested. Use the existing `read_at` column. |
| Replies to reviews | When reviews start quoting each other. Add `parent_id` to reviews. |
| Moderation log table | When a dispute requires a full moderation history. Until then, use `resolved_by` and `dead_at`. |
| Review count in hot | Not planned. Counting reviews would increase the ranking even for negative reviews. |
| Counts by setup and the 90-day window | Not planned in this form. Votes do not record a setup. |
| Visible image captions | Optional descriptions for image alternatives are included; separate visible captions are deferred. |
| Shadow bans | When observed abuse warrants covert restrictions; MVP uses full bans only. |
| Cross-device/server drafts | When observed recovery needs justify synchronization; local drafts remain. |
| Handle rename | Separate future product option; fixed handle remains. |
| Markdown preview and whole-tip export | Deferred; Copy prompt/result is included. |
| Counter tables separate from `tips` and `reviews` | When index updates from votes cause measurable vacuum overhead on `tips`. Search indexes already use separate tables. |
| Killed images stop serving to new requests | When saved URLs to killed images cause a problem. Use one private bucket and an app route that checks the content row on each request. This routes all image traffic through the VPS without a CDN. |
| `[deleted]` placeholders for reviews | When reviews have replies that need a parent placeholder. |
| Per-user per-tip cap on deleted reviews | When users repeatedly create and delete reviews. Until then, use write rate limits and bulk kill by user. |
| `notifications_unread` index | When logs show that the unread badge query needs the index. |
| Exponential embedding retry | When retries every ten minutes cause excessive load during an outage. This requires an attempt-count column. |
| Search fusion in the app | After testing the extensions on the Docker image, if combining results in the app requires less code. |
| Image transformation pipeline | Required bounded format/motion parsing is included; resizing, transcoding and exhaustive image processing remain deferred. |
| Weighted RRF, title branch | When query evaluation on the Docker image shows poor ranking with equal weights across the keyword and vector lists. |
| pgvectorscale DiskANN | Above a million vectors. |
| Promote a common `model_other` into the list | When a moderator sees the same text often. Add a model entry and update matching content rows. |

## Other decisions

- **Authentication uses Phoenix-generated email magic links.** Adapt `phx.gen.auth` and its token queries/migrations to the account schema and seven-day confirmation lifecycle above. Use Turnstile on signup. Passwords, OAuth and a second authentication system are excluded.
- **Hosting uses one VPS and one `compose.yaml`.** Run the app and a pinned Postgres 18 image with pg_textsearch and pgvector. Run nightly `pg_dump` backups to R2 from cron and test a restore before launch. Use Tiger Cloud if the database needs separate hosting. Managed hosts without pg_textsearch are excluded while that extension is used; native PostgreSQL text search is the fallback only for a concrete extension blocker.
- **The Hot divisor is 345600.** This is based on the estimated posting rate. Adjust it once the actual rate is known; see rule 4.
- **The tip page shows the latest live review date.** The tip query returns `latest_review_at`. A review records when someone reported using the tip. No `last_up_at` column is needed.

## Implementation acceptance

- Run revised migrations in pinned extension-enabled development/CI databases. Verify normal/full account states, two-marker content visibility and counter triggers. Reproduce publication versus ban/deletion and ordered bulk invalidation; no generic deadlock retry wrapper.
- Verify vote insertion/value changes/deletion and invalidation update counters once. Unban never recreates a vote; a later explicit vote follows normal notification rules. Retain both helpfulness directions.
- Verify one-open-report uniqueness per reporter/target, receipt honesty, fresh reports after resolution on unchanged content and the accepted delayed-retry duplicate. Retain moderator content-version and reviewed-report-set guards while new reports arrive.
- Verify stable media identity and optional descriptions through draft recovery/reorder/edit, trusted GIF/WebP/APNG motion classification, deferrable slot constraints, upload ownership and claims racing expiry/discard. Test NULL-uid local expiry, conditional uid persistence, the fixed recovery deadline set once on leaving `uploading`, and durable cleanup after job pruning.
- Exercise asynchronous bounded editor refresh, timeout/429 backoff, nonoverlapping cycles, no false failure or ready-state regression, and recovery of off-screen completion. Ready uploads can publish during a status-provider outage; prior publication keys reconcile before media work.
- Verify fresh signed inline-player and thumbnail redirects, current visibility, owner-only staged access, authorized hidden-content access, cleanup rejection, fixed destinations and private/no-store responses. Tokens necessarily reach the browser network stack but never draft storage. Test long-open-page playback and real provider URLs.
- Test revoked-session admission even if disconnect delivery is lost, seven-day confirmation versus cleanup/reclaim, old tokens against replacement accounts, one-form signup errors and fixed handles.
- Verify late edits to both tips and reviews, including eligible hidden content; preserve hiding, votes, original dates and ranking inputs. Actual edits show Updated; no-op edits change no version/date/search data. Review notifications are not replayed. Retagging preserves authored fields and rejects stale/unauthorized operations.
- Verify same-version competing edits and media-only edits; text/media/search effects commit together. Moderator file destruction invalidates stale editors, deletion cannot be undone, full bans reject edits while preserving own-content/account deletion.
- Verify same-key publication races and lost confirmations, retries after deletion, different keys for an existing review, and exactly one successful set of self-vote/media/search/notification effects. Retain original-version local draft CAS and uncertain-outcome reconciliation.
- Verify selected-review mode reads no ranked page or pinned own-review body; normal lists keep the own live review at rank. Hidden/deleted tip context never leaks original text, links or media; independently visible reviews remain readable. Own-review header lookup is lightweight and current-authorized.
- Verify page offsets, one-row lookahead, empty deep pages and Previous, current-page Back position, mixed-profile type/id ordering and type filters. No arbitrary cap outside bounded search. Inbox marks once per connected visit with the captured-count guard, not on each page.
- Run search SQL on the pinned extensions, test empty matches, stopword-only input, fewer-than-limit matches, excerpt attribution, current visibility and exact parent-tip setup filters in every branch, filtered HNSW recall, keyword fallback, final bounded offset and matched-review hydration. Measure deep offsets and warm/cold latency on the target corpus.
- Use the selected embedding runtime: Qwen3-Embedding-8B through OpenRouter on Nebius, with 1024 requested dimensions. Cover model/environment text, verbatim output/error-message queries, long-input behavior and no mixed-model vectors.
- Verify 10 MB per image/GIF, 50 MB total new image/GIF bytes, ten total mixed attachments, 1 GB and 180 seconds per video. Limits are enforced server-side; retained images do not consume the new-byte allowance.
- Verify cross-page query/filter preservation, Clear filters and unfiltered Show all reviews, summary/detail viewer vote state, current own-review action capabilities, review excerpt source labels and authentication without automatic report insertion.
- Verify one-time review setup prefill, including free-text model, explicit changes/clears, blanks on restore and independence from later tip edits. No Same-as-tip button or confirmation gate.
- Verify media cache headers and purge, Turnstile/write/upload limits, nightly backup/restore, and the noindex exit condition in the launch checklist. Browser accessibility and provider integration checks remain implementation work.

### Cross-layer acceptance

- Publication receipts distinguish created/equivalent/different/unknown. Test same-key divergent tabs, fixed retries, missing file identities, authorized hidden/deleted originals and comparison after rollback; no identity-only draft clear.
- Test report insertion versus author deletion in both lock orders on the full schema, including trigger/FK locks and unconfirmed reporters. Verify registration and media deadlines after lock waits; transaction-start time must not extend them.
- Exercise both renewal/logout schedules, concurrent successors, late cookies, another browser’s family, account switches, genuine-authentication recency, email-change revocation, token pruning and failed disconnect delivery. UUID family groups have no root-token lifetime dependency.
- Delay an embedding worker across retagging and verify its stale success/failure writes fail the freshness guard. Verify keyword nonmatches never gain RRF rank under actual sequential/index plans.
- Put fifty uncertain expired uploads before later due rows; verify cooldown fairness, restart persistence, fixed author deadlines and attachment/cleanup guards. Observe stalled jobs and never-attempted embeddings independently of Oban.
- Verify exact-publication target equivalence for recovered ready videos and all rejection cases; test the frontend’s complete-base conflict shortcut without weakening hide/restore versions.
- Measure atomic bulk moderation on ten thousand reviews with concurrent votes before changing its execution model. Do not infer a need for chunks, partial-progress state or automatic bans.