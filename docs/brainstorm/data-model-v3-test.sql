-- Data model v3, after chavruta 03. Builds the schema, loads a small fixture, checks constraints and behavior. Counters are kept by triggers; the app never writes one.
-- Run: psql -d postgres -f data-model-v3-test.sql
-- Search parts (pg_textsearch, pgvector) are created only if the extensions are available.
-- Two-session tests (counter race, mark-all-read race) are in data-model-v3-concurrency.sh.
drop database if exists tips_v3; create database tips_v3;
\c tips_v3
\set ON_ERROR_STOP on

select exists (select 1 from pg_available_extensions where name = 'vector')        as has_vector \gset
select exists (select 1 from pg_available_extensions where name = 'pg_textsearch') as has_bm25   \gset
\if :has_vector
create extension vector;
\endif
\if :has_bm25
create extension pg_textsearch;
\endif

-- ===== domains =====
create domain user_role         as text check (value in ('user', 'moderator'));
create domain ban_status        as text check (value in ('shadow', 'full'));
create domain flag_reason       as text check (value in ('spam', 'harmful', 'wrong', 'other'));
create domain notification_type as text check (value in ('tip_upvoted', 'review_upvoted', 'tip_reviewed'));

-- epoch seconds do not depend on the session time zone, but Postgres marks extract() as stable. This wrapper says so, which generated columns need.
-- Do not reuse it for any other extract() field: those do depend on the time zone.
create function epoch_of(timestamptz) returns double precision language sql immutable parallel safe
  return extract(epoch from $1);

-- ===== lookup tables =====
create table models       (id text primary key, label text not null, sort_order int not null, active boolean not null default true);
create table environments (id text primary key, label text not null, sort_order int not null, active boolean not null default true);
create table tags         (id text primary key, label text not null, sort_order int not null, active boolean not null default true);

-- ===== users =====
create table users (
  id          bigint generated always as identity primary key,
  handle      text,                          -- NULL only on a deleted account
  email       text,                          -- NULL only on a deleted account
  role        user_role not null default 'user',
  ban         ban_status,                    -- NULL = not banned. shadow = writes born dead. full = writes refused.
  banned_at   timestamptz,
  created_at  timestamptz not null default now(),
  deleted_at  timestamptz,                   -- account deleted. handle and email NULL, content stays.
  constraint users_handle_chk check (handle ~ '^[A-Za-z0-9][A-Za-z0-9_-]{2,29}$'),   -- 3 to 30 characters
  constraint users_email_chk  check (email ~ '^[^@[:space:]]+@[^@[:space:]]+$' and length(email) <= 254),
  constraint users_handle_del check ((deleted_at is null) = (handle is not null)),
  constraint users_email_del  check ((deleted_at is null) = (email  is not null)),
  constraint users_ban_chk    check ((ban is null) = (banned_at is null))
);
create unique index users_handle_unique on users (lower(handle));
create unique index users_email_unique  on users (lower(email));

-- ===== tips =====
create table tips (
  id              bigint generated always as identity primary key,
  user_id         bigint not null references users(id),
  title           text not null,
  body            text not null,                        -- markdown
  tag_id          text not null references tags(id),
  model_id        text references models(id),
  model_other     text,
  environment_id  text references environments(id),
  prompt          text,
  output          text,
  up_count        int not null default 0,
  down_count      int not null default 0,
  review_count    int not null default 0,
  score           int generated always as (up_count - down_count) stored,
  hot_score       double precision generated always as (
                    sign(up_count - down_count) * log(greatest(abs(up_count - down_count), 1))
                    + (epoch_of(created_at) - 1134028003) / 345600
                  ) stored,
  created_at      timestamptz not null default now(),
  edited_at       timestamptz,
  deleted_at      timestamptz,                          -- author deleted
  dead_at         timestamptz,                          -- moderator killed, or born dead under shadow ban
  constraint tips_title_chk       check (title ~ '[^[:space:]]' and length(title) between 3 and 140),
  constraint tips_body_chk        check (body ~ '[^[:space:]]' and length(body) between 3 and 20000),
  constraint tips_model_one_chk   check (num_nonnulls(model_id, model_other) <= 1),
  constraint tips_model_other_chk check (model_other is null or (model_other ~ '[^[:space:]]' and length(model_other) <= 80)),
  constraint tips_prompt_chk      check (prompt is null or (prompt ~ '[^[:space:]]' and length(prompt) <= 20000)),
  constraint tips_output_chk      check (output is null or (output ~ '[^[:space:]]' and length(output) <= 20000)),
  constraint tips_counts_chk      check (up_count >= 0 and down_count >= 0 and review_count >= 0)
);

-- ===== reviews =====
create table reviews (
  id              bigint generated always as identity primary key,
  tip_id          bigint not null references tips(id),
  user_id         bigint not null references users(id),
  body            text not null,
  model_id        text references models(id),
  model_other     text,
  environment_id  text references environments(id),
  prompt          text,
  output          text,
  up_count        int not null default 0,
  down_count      int not null default 0,
  score           int generated always as (up_count - down_count) stored,
  best_score      double precision generated always as (                              -- deleted placeholders sort last
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
  created_at      timestamptz not null default now(),
  edited_at       timestamptz,
  deleted_at      timestamptz,
  dead_at         timestamptz,
  constraint reviews_body_chk        check (body ~ '[^[:space:]]' and length(body) between 1 and 20000),
  constraint reviews_model_one_chk   check (num_nonnulls(model_id, model_other) <= 1),
  constraint reviews_model_other_chk check (model_other is null or (model_other ~ '[^[:space:]]' and length(model_other) <= 80)),
  constraint reviews_prompt_chk      check (prompt is null or (prompt ~ '[^[:space:]]' and length(prompt) <= 20000)),
  constraint reviews_output_chk      check (output is null or (output ~ '[^[:space:]]' and length(output) <= 20000)),
  constraint reviews_counts_chk      check (up_count >= 0 and down_count >= 0)
);
create unique index reviews_one_per_user on reviews (tip_id, user_id) where deleted_at is null;   -- one undeleted review per user per tip

-- ===== search side tables: text and vectors live away from the vote counters, so a vote never touches a search index =====
create table tip_search (
  tip_id          bigint primary key references tips(id),
  search_text     text not null,                        -- title, body, prompt, model, tag. Written by publish and edit.
  text_at         timestamptz not null default now(),   -- bumped on edit. The worker writes a vector only if unchanged.
  embed_after     timestamptz                           -- set on a failed embedding call. The loop skips rows not yet due.
);
create table review_search (
  review_id       bigint primary key references reviews(id),
  search_text     text not null,                        -- body and prompt
  text_at         timestamptz not null default now(),
  embed_after     timestamptz
);
\if :has_vector
alter table tip_search    add column embedding vector(1024);
alter table review_search add column embedding vector(1024);
\endif

-- ===== votes =====
create table votes (
  user_id     bigint not null references users(id),
  tip_id      bigint references tips(id),
  review_id   bigint references reviews(id),
  value       smallint not null,
  created_at  timestamptz not null default now(),
  dead_at     timestamptz,
  constraint votes_one_target check (num_nonnulls(tip_id, review_id) = 1),
  constraint votes_value_chk  check (value in (-1, 1))
);
create unique index votes_one_per_tip    on votes (user_id, tip_id)    where tip_id    is not null;
create unique index votes_one_per_review on votes (user_id, review_id) where review_id is not null;
create index votes_by_tip    on votes (tip_id, created_at desc)    where tip_id    is not null;   -- moderator: who voted on this
create index votes_by_review on votes (review_id, created_at desc) where review_id is not null;

-- ===== media =====
create table media (
  id          bigint generated always as identity primary key,
  tip_id      bigint references tips(id),
  review_id   bigint references reviews(id),
  position    smallint not null,
  key         text not null,
  created_at  timestamptz not null default now(),
  constraint media_one_parent  check (num_nonnulls(tip_id, review_id) = 1),
  constraint media_position_chk check (position between 0 and 9),
  constraint media_key_chk     check (key ~ '^media/[0-9a-f-]{36}\.(png|jpg|webp|gif)$'),
  constraint media_key_unique  unique (key),
  constraint media_tip_slot    unique (tip_id, position),
  constraint media_review_slot unique (review_id, position)
);

-- ===== flags =====
create table flags (
  id            bigint generated always as identity primary key,
  tip_id        bigint references tips(id),
  review_id     bigint references reviews(id),
  user_id       bigint not null references users(id),     -- reporter. Login required.
  reason        flag_reason not null,
  detail        text,
  created_at    timestamptz not null default now(),
  resolved_at   timestamptz,
  resolved_by   bigint references users(id),
  constraint flags_one_target check (num_nonnulls(tip_id, review_id) = 1),
  constraint flags_detail_chk check (detail is null or length(detail) <= 1000)
);
create unique index flags_one_per_user_tip    on flags (user_id, tip_id)    where tip_id    is not null;
create unique index flags_one_per_user_review on flags (user_id, review_id) where review_id is not null;

-- ===== notifications =====
-- one target. tip_upvoted: tip_id. review_upvoted and tip_reviewed: review_id; the tip comes from the review.
create table notifications (
  id          bigint generated always as identity primary key,
  user_id     bigint not null references users(id),   -- recipient
  type        notification_type not null,
  actor_id    bigint references users(id),            -- latest actor
  tip_id      bigint references tips(id),
  review_id   bigint references reviews(id),
  count       int not null default 1,                 -- helpful-vote events folded into this row
  updated_at  timestamptz not null default now(),     -- bumped when folded
  read_at     timestamptz,
  constraint notifications_one_target   check (num_nonnulls(tip_id, review_id) = 1),
  constraint notifications_type_target  check ((type = 'tip_upvoted') = (tip_id is not null)),
  constraint notifications_count_chk    check (count > 0)
);
create unique index notifications_fold   on notifications (user_id, type, tip_id, review_id) nulls not distinct where read_at is null;
create index notifications_inbox         on notifications (user_id, updated_at desc, id desc);
create index notifications_by_tip        on notifications (tip_id)    where tip_id    is not null;
create index notifications_by_review     on notifications (review_id) where review_id is not null;

-- ===== indexes =====
create index tips_hot          on tips    (hot_score desc, id desc)           where deleted_at is null and dead_at is null;
create index tips_new          on tips    (created_at desc, id desc)          where deleted_at is null and dead_at is null;
create index tips_hot_by_tag   on tips    (tag_id, hot_score desc, id desc)   where deleted_at is null and dead_at is null;   -- browse with a tag filter
create index tips_new_by_tag   on tips    (tag_id, created_at desc, id desc)  where deleted_at is null and dead_at is null;
create index tips_by_user      on tips    (user_id, created_at desc, id desc);      -- profile and moderator history, deleted rows included
create index reviews_best      on reviews (tip_id, best_score desc, id desc)  where deleted_at is null and dead_at is null;
create index reviews_new       on reviews (tip_id, created_at desc, id desc)  where deleted_at is null and dead_at is null;
create index reviews_by_user   on reviews (user_id, created_at desc, id desc);
create index flags_open        on flags   (created_at, id)                    where resolved_at is null;
\if :has_bm25
create index tips_bm25    on tip_search    using bm25 (search_text) with (text_config = 'english');
create index reviews_bm25 on review_search using bm25 (search_text) with (text_config = 'english');
\endif
\if :has_vector
create index tips_embedding    on tip_search    using hnsw (embedding vector_cosine_ops);
create index reviews_embedding on review_search using hnsw (embedding vector_cosine_ops);
create index tip_search_queue    on tip_search    (tip_id)    where embedding is null;
create index review_search_queue on review_search (review_id) where embedding is null;
\endif

-- ===== views and triggers =====
create view live_tips    as select * from tips    where deleted_at is null and dead_at is null;
create view live_reviews as select * from reviews where deleted_at is null and dead_at is null;

create function vote_counts() returns trigger language plpgsql as $$
declare d_up int := 0; d_down int := 0; tip bigint; rev bigint;
begin
  if tg_op in ('UPDATE', 'DELETE') and old.dead_at is null then
    if old.value = 1 then d_up := d_up - 1; else d_down := d_down - 1; end if; end if;
  if tg_op in ('INSERT', 'UPDATE') and new.dead_at is null then
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

-- ===== seed lists =====
insert into models (id, label, sort_order) values
 ('claude-opus-5', 'Claude Opus 5', 10), ('claude-sonnet-5', 'Claude Sonnet 5', 20), ('gpt-5', 'GPT-5', 30), ('gemini-2-5-pro', 'Gemini 2.5 Pro', 40);
insert into environments (id, label, sort_order) values
 ('chatgpt', 'ChatGPT', 10), ('claude', 'Claude', 20), ('claude-code', 'Claude Code', 30), ('codex', 'Codex', 40), ('pi-agent', 'Pi Agent', 50), ('api', 'API', 60), ('other', 'Other', 70);
insert into tags (id, label, sort_order) values
 ('phrase', 'Phrase', 10), ('persona', 'Persona', 20), ('system-prompt', 'System prompt', 30), ('examples', 'Examples', 40),
 ('task-structure', 'Task structure', 50), ('output-format', 'Output format', 60), ('workflow', 'Workflow', 70), ('cost-speed', 'Cost and speed', 80);

-- ===== fixture =====
insert into users (handle, email, role) values ('ada', 'ada@example.com', 'moderator'), ('bob', 'bob@example.com', 'user'), ('cyd', 'cy@example.com', 'user'), ('dee', 'dee@example.com', 'user');
update users set ban = 'shadow', banned_at = now() where handle = 'dee';

-- ===== the write statements, as the app runs them =====
-- publish tip: one statement. Refuses a fully banned or deleted author. A shadow-banned author's row is born dead with a dead self vote.
-- The trigger sets up_count from the self vote. $9 is the search text, built by the app.
prepare publish_tip(bigint, text, text, text, text, text, text, text, text) as
  with u as (select id, ban from users where id = $1 and deleted_at is null and ban is distinct from 'full'),
       t as (insert into tips (user_id, title, body, tag_id, model_id, model_other, environment_id, prompt, dead_at)
             select u.id, $2, $3, $4, $5, $6, $7, $8, case when u.ban = 'shadow' then now() end from u
             returning id, user_id, dead_at),
       s as (insert into tip_search (tip_id, search_text) select id, $9 from t)
  insert into votes (user_id, tip_id, value, dead_at) select user_id, id, 1, dead_at from t returning tip_id as id;

execute publish_tip(1, 'Stop the LinkedIn voice', E'Add this line:\n\n> Write this like a text message to a colleague you respect, not a post.', 'phrase', 'claude-opus-5', null, 'claude', 'Write this like a text message to a colleague you respect, not a post.', 'Stop the LinkedIn voice Add this line ... claude-opus-5 phrase');
execute publish_tip(1, 'No summary at the end', 'Do not add a summary paragraph at the end.', 'output-format', 'claude-opus-5', null, 'claude-code', null, 'No summary at the end Do not add a summary paragraph at the end. claude-opus-5 output-format');
execute publish_tip(2, 'Keep the same look across image generations', 'Reuse this seed and style: ...', 'workflow', null, 'Midjourney v7', 'other', null, 'Keep the same look across image generations Reuse this seed and style: ... Midjourney v7 workflow');
execute publish_tip(4, 'A shadow-banned tip', 'Nobody but dee and moderators should see this.', 'phrase', null, null, null, null, 'A shadow-banned tip Nobody but dee and moderators should see this. phrase');
-- backdate tip 1 so hot ranking has something to work with
update tips set created_at = now() - interval '3 days' where id = 1;
update votes set created_at = now() - interval '3 days' where tip_id = 1;

-- publish review: one statement. The tip must be live. The trigger adds a live review to review_count. $6 is the search text.
prepare publish_review(bigint, bigint, text, text, text, text) as
  with u as (select id, ban from users where id = $1 and deleted_at is null and ban is distinct from 'full'),
       p as (select id from live_tips where id = $2),
       r as (insert into reviews (tip_id, user_id, body, model_id, environment_id, dead_at)
             select p.id, u.id, $3, $4, $5, case when u.ban = 'shadow' then now() end from u, p
             returning id, user_id, dead_at),
       s as (insert into review_search (review_id, search_text) select id, $6 from r)
  insert into votes (user_id, review_id, value, dead_at) select user_id, id, 1, dead_at from r returning review_id as id;

execute publish_review(2, 1, 'Worked great on Claude.', 'claude-opus-5', 'claude', 'Worked great on Claude.');
execute publish_review(3, 1, 'In Claude Code no difference', 'claude-opus-5', 'claude-code', 'In Claude Code no difference');
execute publish_review(4, 1, 'shadow-banned review', null, null, 'shadow-banned review');
execute publish_review(2, 2, 'question only', null, null, 'question only');

-- vote: one statement. The trigger moves the counters. The app reads them in the next statement.
prepare vote_tip(bigint, bigint, int) as
  insert into votes (user_id, tip_id, value, dead_at)
  select u.id, $2, $3, case when u.ban = 'shadow' then now() end
  from users u where u.id = $1 and u.deleted_at is null and u.ban is distinct from 'full'
    and exists (select 1 from live_tips t where t.id = $2)
  on conflict (user_id, tip_id) where tip_id is not null
  do update set value = excluded.value, dead_at = excluded.dead_at
  where votes.value <> excluded.value or (votes.dead_at is null) <> (excluded.dead_at is null)
  returning value, dead_at;
prepare vote_review(bigint, bigint, int) as
  insert into votes (user_id, review_id, value, dead_at)
  select u.id, $2, $3, case when u.ban = 'shadow' then now() end
  from users u where u.id = $1 and u.deleted_at is null and u.ban is distinct from 'full'
    and exists (select 1 from live_reviews r where r.id = $2)
  on conflict (user_id, review_id) where review_id is not null
  do update set value = excluded.value, dead_at = excluded.dead_at
  where votes.value <> excluded.value or (votes.dead_at is null) <> (excluded.dead_at is null)
  returning value, dead_at;
prepare tip_counts(bigint) as select up_count, down_count, score from tips where id = $1;
prepare review_counts(bigint) as select up_count, down_count, round(best_score::numeric, 3) as best from reviews where id = $1;

-- notification fold: repeated upvotes on the same target become one unread row with a count
prepare notify(bigint, text, bigint, bigint, bigint) as
  insert into notifications (user_id, type, actor_id, tip_id, review_id) values ($1, $2::notification_type, $3, $4, $5)
  on conflict (user_id, type, tip_id, review_id) where read_at is null
  do update set count = notifications.count + 1, actor_id = excluded.actor_id, updated_at = now()
  returning id, count;

-- ===== negative tests: each must fail =====
\set ON_ERROR_STOP off
\echo '--- expect 15 errors below'
insert into tips (user_id, title, body, tag_id) values (1, 'no tag', 'valid body', null);
insert into tips (user_id, title, body, tag_id) values (1, 'bad tag', 'valid body', 'bogus');
insert into tips (user_id, title, body, tag_id, model_id, model_other) values (1, 'two models', 'valid body', 'phrase', 'gpt-5', 'GPT-5');
insert into reviews (tip_id, user_id, body) values (1, 2, 'second review by bob');
insert into votes (user_id, tip_id, value) values (3, 1, 2);
insert into votes (user_id, tip_id, review_id, value) values (3, 1, 1, 1);
insert into media (review_id, position, key) values (1, 10, 'media/8d0f2c2e-5b6e-4f3a-9c1d-2a4b6c8e0f12.png');
insert into media (review_id, position, key) values (1, 0, 'media/8d0f2c2e-5b6e-4f3a-9c1d-2a4b6c8e0f12.svg');
insert into users (handle, email) values ('ADA', 'x@example.com');
insert into users (handle, email) values ('ab', 'ab@example.com');            -- handle too short
update users set ban = 'full' where id = 3;                                    -- banned_at missing
insert into flags (tip_id, reason) values (3, 'wrong');                        -- anonymous flag
insert into notifications (user_id, type, tip_id) values (1, 'bogus', 1);      -- unknown type
insert into notifications (user_id, type, tip_id, review_id) values (1, 'tip_reviewed', 1, 1);   -- two targets
insert into notifications (user_id, type, tip_id) values (1, 'tip_reviewed', 1);                 -- wrong target for the type
\echo '--- end expected errors'
\set ON_ERROR_STOP on

-- ===== row tests =====
\echo '--- fully banned user cannot publish or vote: expect 0 rows twice'
update users set ban = 'full', banned_at = now() where id = 3;
execute publish_tip(3, 'banned tip', 'should not insert', 'phrase', null, null, null, null, 'x');
execute vote_tip(3, 1, 1);
update users set ban = null, banned_at = null where id = 3;

\echo '--- publish set the counters through the trigger: tip 1 up=1, review 1 up=1, tip 1 review_count=2 (dead review 3 not counted)'
select 'tip' as kind, id, up_count, review_count from tips where id = 1
union all select 'review', id, up_count, null from reviews where id = 1;

\echo '--- shadow-banned tip 4 and review 3 are born dead with up_count 0: expect dead=t, up=0 for both'
select 'tip' as kind, id, dead_at is not null as dead, up_count from tips where id = 4
union all select 'review', id, dead_at is not null, up_count from reviews where id = 3;

\echo '--- votes on dead or deleted targets insert nothing: expect 0 rows'
execute vote_tip(2, 4, 1);

\echo '--- reviews on a dead tip insert nothing: expect 0 rows'
execute publish_review(2, 4, 'review on a dead tip', null, null, 'x');

\echo '--- browse hot through live_tips: expect 3, 2, 1 (newest first because all have score 1), no tip 4'
select id, title, score, round(hot_score::numeric, 2) as hot from live_tips order by hot_score desc, id desc limit 20;

\echo '--- hot math: tip 1 is 3 days old, so it is 0.75 age units behind tip 2. Each unit costs 10x the votes, so 6 net votes catch up 3 days.'
select id, score, round(hot_score::numeric, 3) as hot, round(((extract(epoch from now()) - extract(epoch from created_at)) / 345600)::numeric, 3) as age_units from tips where id in (1,2) order by id;

\echo '--- hot with negative scores, same age: score 5 first, -10 last. Scores 0 and -1 tie (log of 1 is 0), so newest id wins. Expect 5, -1, 0, -10'
insert into tips (user_id, title, body, tag_id, up_count, down_count, dead_at) select 1, 'hot probe ' || s, 'probe', 'phrase', greatest(s, 0), greatest(-s, 0), now() from unnest(array[5, 0, -1, -10]) s;
select id, score from tips where title like 'hot probe%' order by hot_score desc, id desc;
delete from tips where title like 'hot probe%';

\echo '--- hot vs new: an older score-2 tip beats a newer score-1 tip on Hot, loses on New. Expect old first, then new first.'
insert into tips (user_id, title, body, tag_id, up_count, created_at, dead_at) values
  (1, 'probe old score 2', 'probe', 'phrase', 2, now() - interval '2 hours', now()), (1, 'probe new score 1', 'probe', 'phrase', 1, now() - interval '1 hour', now());
select title from tips where title like 'probe %' order by hot_score desc, id desc;
select title from tips where title like 'probe %' order by created_at desc, id desc;
delete from tips where title like 'probe %';

\echo '--- vote tip: cy upvotes tip 1 (expect up=2), switches to down (expect up=1 down=1), removes (expect up=1 down=0)'
execute vote_tip(3, 1, 1);   execute tip_counts(1);
execute vote_tip(3, 1, -1);  execute tip_counts(1);
delete from votes where user_id = 3 and tip_id = 1;  execute tip_counts(1);
\echo '--- same vote twice is a no-op: expect one row then 0 rows, up=2 both times'
execute vote_tip(3, 2, 1);  execute tip_counts(2);
execute vote_tip(3, 2, 1);  execute tip_counts(2);

\echo '--- shadow-banned dee upvotes tip 3: vote is born dead, counters untouched: expect up=1 down=0'
execute vote_tip(4, 3, 1);  execute tip_counts(3);
\echo '--- dee is unbanned and votes up again with the same value: the vote comes alive, expect up=2'
update users set ban = null, banned_at = null where id = 4;
execute vote_tip(4, 3, 1);  execute tip_counts(3);
\echo '--- dee is shadow-banned again and switches to down: the vote goes dead, her live up vote is subtracted. Expect up=1 down=0, dead=t'
update users set ban = 'shadow', banned_at = now() where id = 4;
execute vote_tip(4, 3, -1);  execute tip_counts(3);
select value, dead_at is not null as dead from votes where user_id = 4 and tip_id = 3;
delete from votes where user_id = 4 and tip_id = 3;  execute tip_counts(3);   -- removing a dead vote leaves the counters alone: expect up=1 down=0

\echo '--- my votes on a page of tips: expect (2, 1) for cy'
select tip_id, value from votes where user_id = 3 and tip_id = any('{1,2,3}');

\echo '--- reviews on tip 1, Best, first page, no filters: expect review 1 and 2 (self-upvoted, best equal), not 3 (dead). Own review excluded for viewer 2.'
prepare reviews_best(bigint, bigint) as
  select r.id, u.handle, r.body, r.up_count, r.down_count, round(r.best_score::numeric, 3) as best
  from live_reviews r join users u on u.id = r.user_id
  where r.tip_id = $1 and r.user_id is distinct from $2
  order by r.best_score desc, r.id desc limit 30;
execute reviews_best(1, null);
execute reviews_best(1, 2);
\echo '--- filters are added to the SQL only when set: model filter keeps stated matches and unspecified rows. Expect reviews 1 (opus) and 2 (opus); with gpt-5 expect none'
select r.id from live_reviews r where r.tip_id = 1 and (r.model_id = 'claude-opus-5' or (r.model_id is null and r.model_other is null)) order by r.best_score desc, r.id desc limit 30;
select r.id from live_reviews r where r.tip_id = 1 and (r.model_id = 'gpt-5' or (r.model_id is null and r.model_other is null)) order by r.best_score desc, r.id desc limit 30;
\echo '--- ada downvotes review 2, bob upvotes review 1: expect review 1 best > review 2 best. Wilson separates (2,0)=0.549 from (1,1)=0.164'
execute vote_review(1, 2, -1);  execute review_counts(2);
execute vote_review(1, 1, 1);   execute review_counts(1);
execute reviews_best(1, null);

\echo '--- own dead review visible to its author: expect review 3'
select id, body from reviews where tip_id = 1 and user_id = 4 and deleted_at is null;

\echo '--- review count on tip 1: expect 2 (dead review not counted)'
select id, review_count from tips where id = 1;

\echo '--- media: 10 images on review 1 (expect 10), 11th rejected above; one image on tip 1'
insert into media (review_id, position, key) select 1, g, 'media/' || gen_random_uuid() || '.png' from generate_series(0, 9) g;
insert into media (tip_id, position, key) values (1, 0, 'media/' || gen_random_uuid() || '.webp');
select count(*) from media where review_id = 1;
\echo '--- media for a tip page in one query: the tip and its page of reviews. Expect 11 rows'
select count(*) from media where tip_id = 1 or review_id = any('{1,2}');

\echo '--- notifications: ada (tip 1 author) gets 3 upvotes folded into 1 row with count 3; a review notification is its own row with review_id only'
execute notify(1, 'tip_upvoted', 2, 1, null);
execute notify(1, 'tip_upvoted', 3, 1, null);
execute notify(1, 'tip_upvoted', 4, 1, null);
execute notify(1, 'tip_reviewed', 2, null, 1);
\echo '--- inbox for ada: expect 2 rows, the review row resolves tip 1 through the review; unread 2 (badge capped at 100)'
select n.id, n.type, n.count, n.actor_id, n.tip_id, n.review_id, t.id as resolved_tip
from notifications n left join reviews r on r.id = n.review_id left join tips t on t.id = coalesce(n.tip_id, r.tip_id)
where n.user_id = 1 order by n.updated_at desc, n.id desc limit 20;
select count(*) as unread from (select 1 from notifications where user_id = 1 and read_at is null limit 100) x;
\echo '--- mark all read: page and capture share one repeatable-read snapshot; a fold after it stays unread. Expect 1 row updated, then 1 still unread with count 4'
begin isolation level repeatable read read only;
select id from notifications where user_id = 1 order by updated_at desc, id desc limit 20;
select array_agg(id) as ids, array_agg(count) as counts from notifications where user_id = 1 and read_at is null \gset
commit;
execute notify(1, 'tip_upvoted', 2, 1, null);                            -- lands after the snapshot
update notifications n set read_at = now() from unnest(:'ids'::bigint[], :'counts'::int[]) v(id, count)
where n.user_id = 1 and n.id = v.id and n.count = v.count and n.read_at is null returning n.id;
select id, count from notifications where user_id = 1 and read_at is null;

\echo '--- edit inside 2 hours: expect 1 row, search text replaced. Edit after 2 hours (tip 1, backdated): expect 0 rows'
with e as (update tips set body = body || ' (edited)', edited_at = now() where id = 2 and user_id = 1 and deleted_at is null and created_at > now() - interval '2 hours' returning id)
update tip_search s set search_text = 'edited text from the app', text_at = now(), embed_after = null from e where s.tip_id = e.id returning s.tip_id;
update tips set body = body || ' (edited)', edited_at = now() where id = 1 and user_id = 1 and deleted_at is null and created_at > now() - interval '2 hours' returning id;

\echo '--- embedding retry: a failure write for stale text is a no-op (0 rows), for current text it sets embed_after (1 row)'
select text_at from tip_search where tip_id = 2 \gset cur_
update tip_search set embed_after = now() + interval '10 minutes' where tip_id = 2 and embed_after is null and text_at = :'cur_text_at'::timestamptz - interval '1 second' returning tip_id;
update tip_search set embed_after = now() + interval '10 minutes' where tip_id = 2 and embed_after is null and text_at = :'cur_text_at'::timestamptz returning tip_id;

\echo '--- author deletes tip 2 (not user 4): expect 0 rows and notifications untouched; then as user 1: 1 row, its notifications gone (including the review one, found through the review), reviews stay'
execute notify(1, 'tip_reviewed', 2, null, 4);                          -- bob reviewed tip 2 (review 4)
with d as (update tips set deleted_at = now() where id = 2 and user_id = 4 and deleted_at is null returning id)
delete from notifications where tip_id in (select id from d) returning tip_id;
select count(*) as notifications_before from notifications where review_id = 4;
with d as (update tips set deleted_at = now() where id = 2 and user_id = 1 and deleted_at is null returning id),
     n as (delete from notifications n where n.tip_id in (select id from d)
              or (n.type = 'tip_reviewed' and exists (select 1 from reviews r join d on d.id = r.tip_id where r.id = n.review_id))),
     m as (delete from media where tip_id in (select id from d) returning key)
select d.id, (select array_agg(key) from m) as keys from d;
select count(*) as notifications_after from notifications where review_id = 4;
select count(*) as reviews_on_deleted_tip from reviews where tip_id = 2 and deleted_at is null;
\echo '--- deleted tip page still renders: expect 1 row with deleted=t'
select id, title, deleted_at is not null as deleted from tips where id = 2;
\echo '--- browse hot after delete: expect 3, 1'
select id from live_tips order by hot_score desc, id desc;

\echo '--- author deletes review 4 (on tip 2): the trigger takes it off review_count (1 then 0). It leaves the list. Its row, votes stay. A re-review is a new row.'
select review_count from tips where id = 2;
with d as (update reviews set deleted_at = now() where id = 4 and user_id = 2 and deleted_at is null returning id),
     n as (delete from notifications where review_id in (select id from d)),
     f as (update flags set resolved_at = now() where review_id in (select id from d) and resolved_at is null),
     m as (delete from media where review_id in (select id from d) returning key)
select (select array_agg(key) from m) as keys from d;
select review_count from tips where id = 2;
select count(*) as in_list from live_reviews where tip_id = 2;
select count(*) as votes_kept from votes where review_id = 4;
update tips set deleted_at = null where id = 2;        -- undelete for the test only
execute publish_review(2, 2, 'again', null, null, 'again');
select id, deleted_at is not null as deleted from reviews where tip_id = 2 and user_id = 2 order by id;
select review_count from tips where id = 2;

\echo '--- brigade cleanup: invalidate every live vote by users 2 and 4 in one statement; the trigger subtracts each. Expect counters in step (checked below)'
update votes set dead_at = now() where user_id = any('{2,4}') and dead_at is null and exists (select 1 from users where id = 1 and role = 'moderator') returning tip_id, review_id, value;

\echo '--- moderator kills review 2 twice, unkills once. Only a moderator may. Expect 0 rows (bob), then 1 row, 0 rows, 1 row. review_count on tip 1: 1 then 2'
with k as (update reviews set dead_at = now() where id = 2 and dead_at is null and exists (select 1 from users where id = 2 and role = 'moderator') returning id) select * from k;
with k as (update reviews set dead_at = now() where id = 2 and dead_at is null and exists (select 1 from users where id = 1 and role = 'moderator') returning id),
     f as (update flags set resolved_at = now(), resolved_by = 1 where review_id in (select id from k) and resolved_at is null)
select id from k;
select review_count from tips where id = 1;
with k as (update reviews set dead_at = now() where id = 2 and dead_at is null and exists (select 1 from users where id = 1 and role = 'moderator') returning id) select * from k;
update reviews set dead_at = null where id = 2 and dead_at is not null and exists (select 1 from users where id = 1 and role = 'moderator') returning id;
select review_count from tips where id = 1;

\echo '--- bulk kill everything live by user 3 (spam cleanup): expect tips 0 (cy has none), reviews 1, tip 1 review_count 1'
update tips    set dead_at = now() where user_id = 3 and deleted_at is null and dead_at is null and exists (select 1 from users where id = 1 and role = 'moderator') returning id;
update reviews set dead_at = now() where user_id = 3 and deleted_at is null and dead_at is null and exists (select 1 from users where id = 1 and role = 'moderator') returning id;
select review_count from tips where id = 1;

\echo '--- destroy files of review 1 (moderator): expect 10 keys, then 0 media rows'
delete from media where review_id = 1 and exists (select 1 from users where id = 1 and role = 'moderator') returning key;
select count(*) from media where review_id = 1;

\echo '--- account deletion, reddit style: handle and email set to NULL, content stays, shown as [deleted]'
update users set deleted_at = now(), handle = null, email = null where id = 3 returning id, coalesce(handle, '[deleted]') as shown_as;
select count(*) as cy_reviews_still_there from reviews where user_id = 3;

\echo '--- flags: one per user per target, login required. Resolve is guarded: second resolve is a no-op'
insert into flags (review_id, user_id, reason) values (1, 2, 'spam');
insert into flags (tip_id, user_id, reason) values (3, 4, 'wrong');
\echo '--- queue grouped by target, most reported first'
select coalesce(f.tip_id, 0) as tip_id, coalesce(f.review_id, 0) as review_id, count(*) as reports, min(f.created_at) as first_at
from flags f where f.resolved_at is null group by f.tip_id, f.review_id order by reports desc, first_at limit 50;
update flags set resolved_at = now(), resolved_by = 1 where id = (select min(id) from flags) and resolved_at is null returning id;
update flags set resolved_at = now(), resolved_by = 1 where id = (select min(id) from flags) and resolved_at is null returning id;

\echo '--- hard check, before any repair: every counter equals its live votes and reviews, dead rows included. Raises if not.'
do $$
declare bad int;
begin
  select count(*) into bad from tips t
  where (t.up_count, t.down_count, t.review_count) is distinct from (
    (select count(*) from votes where tip_id = t.id and value = 1 and dead_at is null),
    (select count(*) from votes where tip_id = t.id and value = -1 and dead_at is null),
    (select count(*) from reviews where tip_id = t.id and deleted_at is null and dead_at is null));
  if bad > 0 then raise exception 'tip counters out of step on % rows', bad; end if;
  select count(*) into bad from reviews r
  where (r.up_count, r.down_count) is distinct from (
    (select count(*) from votes where review_id = r.id and value = 1 and dead_at is null),
    (select count(*) from votes where review_id = r.id and value = -1 and dead_at is null));
  if bad > 0 then raise exception 'review counters out of step on % rows', bad; end if;
  raise notice 'counters in step';
end $$;

\echo '--- recount, for repair: expect 0 rows changed for tips and for reviews'
with v as (select tip_id, count(*) filter (where value = 1) as up, count(*) filter (where value = -1) as down
           from votes where tip_id is not null and dead_at is null group by tip_id),
     r as (select tip_id, count(*) as n from reviews where deleted_at is null and dead_at is null group by tip_id)
update tips t set up_count = coalesce(v.up, 0), down_count = coalesce(v.down, 0), review_count = coalesce(r.n, 0)
from tips x left join v on v.tip_id = x.id left join r on r.tip_id = x.id
where t.id = x.id and (t.up_count, t.down_count, t.review_count) is distinct from (coalesce(v.up, 0), coalesce(v.down, 0), coalesce(r.n, 0))
returning t.id;
with v as (select review_id, count(*) filter (where value = 1) as up, count(*) filter (where value = -1) as down
           from votes where review_id is not null and dead_at is null group by review_id)
update reviews r set up_count = coalesce(v.up, 0), down_count = coalesce(v.down, 0)
from reviews x left join v on v.review_id = x.id
where r.id = x.id and (r.up_count, r.down_count) is distinct from (coalesce(v.up, 0), coalesce(v.down, 0))
returning r.id;

-- Plans are in data-model-v3-scale.sql, on real row counts. A 12-row fixture proves nothing about plans.
