-- Run after data-model-v3-test.sql. Loads 2k users, 20k tips, 200k reviews (tip 1 gets one from nearly every user, the max under one review per user), 600k votes, 320k notifications,
-- then explains the doc's queries as written. Tip counters come from the vote trigger; review counters are synthetic.
\c tips_v3
\timing off

insert into users (handle, email) select 'user' || g, 'u' || g || '@example.com' from generate_series(1, 2000) g;

insert into tips (user_id, title, body, tag_id, model_id, environment_id, created_at)
select u.ids[1 + (random() * (cardinality(u.ids) - 1))::int], 'Tip number ' || g, 'Body for tip ' || g,
       (array['phrase','persona','system-prompt','examples','task-structure','output-format','workflow','cost-speed'])[1 + (random() * 7)::int],
       (array['claude-opus-5','claude-sonnet-5','gpt-5',null])[1 + (random() * 3)::int],
       (array['claude','claude-code','chatgpt',null])[1 + (random() * 3)::int],
       now() - (random() * interval '365 days')
from generate_series(1, 20000) g, (select array_agg(id) ids from users where deleted_at is null) u;

insert into reviews (tip_id, user_id, body, model_id, environment_id, up_count, down_count, created_at)
select t.ids[1 + (random() * (cardinality(t.ids) - 1))::int], u.ids[1 + (random() * (cardinality(u.ids) - 1))::int], 'review ' || g,
       (array['claude-opus-5','claude-sonnet-5','gpt-5',null])[1 + (random() * 3)::int],
       (array['claude','claude-code','chatgpt',null])[1 + (random() * 3)::int],
       1 + (random() * random() * 30)::int, (random() * random() * 10)::int,
       now() - (random() * interval '365 days')
from generate_series(1, 200000) g, (select array_agg(id) ids from users) u, (select array_agg(id) ids from tips where deleted_at is null) t
on conflict do nothing;

insert into reviews (tip_id, user_id, body, up_count, down_count, created_at)
select 1, u.ids[1 + (random() * (cardinality(u.ids) - 1))::int], 'hot ' || g,
       1 + (random() * random() * 30)::int, (random() * random() * 10)::int, now() - (random() * interval '365 days')
from generate_series(1, 50000) g, (select array_agg(id) ids from users) u
on conflict do nothing;

-- search rows, as publish writes them. Embeddings stay NULL here: the loop needs the model server.
insert into tip_search (tip_id, search_text)
select id, title || ' ' || body || ' ' || coalesce(prompt, '') || ' ' || coalesce(model_id, model_other, '') || ' ' || tag_id from tips
on conflict do nothing;
insert into review_search (review_id, search_text) select id, body || ' ' || coalesce(prompt, '') from reviews on conflict do nothing;

-- votes: enough rows to make the unique indexes real
insert into votes (user_id, tip_id, value)
select u.ids[1 + (random() * (cardinality(u.ids) - 1))::int], t.ids[1 + (random() * (cardinality(t.ids) - 1))::int], (array[1,1,1,-1])[1 + (random() * 3)::int]
from generate_series(1, 600000) g, (select array_agg(id) ids from users) u, (select array_agg(id) ids from tips) t
on conflict do nothing;

-- notifications: 300k spread over users, one heavy inbox
insert into notifications (user_id, type, actor_id, tip_id, updated_at, read_at)
select u.ids[1 + (random() * (cardinality(u.ids) - 1))::int], 'tip_upvoted', 1, t.ids[1 + (random() * (cardinality(t.ids) - 1))::int],
       now() - (random() * interval '90 days'), case when random() < 0.8 then now() end
from generate_series(1, 300000) g, (select array_agg(id) ids from users) u, (select array_agg(id) ids from tips) t
on conflict do nothing;
insert into notifications (user_id, type, actor_id, tip_id, updated_at, read_at)
select 1, 'tip_upvoted', 2, t.ids[1 + (random() * (cardinality(t.ids) - 1))::int], now() - (random() * interval '90 days'), case when random() < 0.9 then now() end
from generate_series(1, 20000) g, (select array_agg(id) ids from tips) t
on conflict do nothing;

vacuum analyze users; vacuum analyze tips; vacuum analyze reviews; vacuum analyze tip_search; vacuum analyze review_search; vacuum analyze votes; vacuum analyze notifications;
select (select count(*) from users) users, (select count(*) from tips) tips, (select count(*) from reviews) reviews, (select count(*) from tip_search) tip_search, (select count(*) from review_search) review_search,
       (select count(*) from votes) votes, (select count(*) from notifications) notifications;

\echo '=== browse hot, first page'
explain (analyze, buffers, costs off, timing off)
select t.id, t.title, t.tag_id, t.model_id, t.model_other, t.environment_id, t.score, t.review_count, t.created_at, t.hot_score, coalesce(u.handle, '[deleted]') as handle
from live_tips t join users u on u.id = t.user_id
order by t.hot_score desc, t.id desc limit 20;

\echo '=== browse hot, next page after 10000 tips'
select hot_score as h, id as i from tips where deleted_at is null and dead_at is null order by hot_score desc, id desc offset 10000 limit 1 \gset
explain (analyze, buffers, costs off, timing off)
select t.id, t.title, t.tag_id, t.model_id, t.model_other, t.environment_id, t.score, t.review_count, t.created_at, t.hot_score, coalesce(u.handle, '[deleted]') as handle
from live_tips t join users u on u.id = t.user_id
where (t.hot_score, t.id) < (:h, :i) order by t.hot_score desc, t.id desc limit 20;

\echo '=== browse hot with a tag filter (tips_hot_by_tag), full page select'
explain (analyze, buffers, costs off, timing off)
select t.id, t.title, t.tag_id, t.model_id, t.model_other, t.environment_id, t.score, t.review_count, t.created_at, t.hot_score, coalesce(u.handle, '[deleted]') as handle
from live_tips t join users u on u.id = t.user_id where t.tag_id = 'persona' order by t.hot_score desc, t.id desc limit 20;

\echo '=== browse hot, tag + model + environment, full page select'
explain (analyze, buffers, costs off, timing off)
select t.id, t.title, t.tag_id, t.model_id, t.model_other, t.environment_id, t.score, t.review_count, t.created_at, t.hot_score, coalesce(u.handle, '[deleted]') as handle
from live_tips t join users u on u.id = t.user_id where t.tag_id = 'persona' and t.model_id = 'gpt-5' and t.environment_id = 'chatgpt' order by t.hot_score desc, t.id desc limit 20;
\echo '=== browse hot, a combination with no matches, full page select'
explain (analyze, buffers, costs off, timing off)
select t.id, t.title, t.tag_id, t.model_id, t.model_other, t.environment_id, t.score, t.review_count, t.created_at, t.hot_score, coalesce(u.handle, '[deleted]') as handle
from live_tips t join users u on u.id = t.user_id where t.tag_id = 'persona' and t.model_id = 'gpt-5' and t.environment_id = 'codex' order by t.hot_score desc, t.id desc limit 20;

\echo '=== browse new, next page deep, full page select'
select created_at as c, id as i from live_tips order by created_at desc, id desc offset 10000 limit 1 \gset
explain (analyze, buffers, costs off, timing off)
select t.id, t.title, t.tag_id, t.model_id, t.model_other, t.environment_id, t.score, t.review_count, t.created_at, t.hot_score, coalesce(u.handle, '[deleted]') as handle
from live_tips t join users u on u.id = t.user_id where (t.created_at, t.id) < (:'c', :i) order by t.created_at desc, t.id desc limit 20;

\echo '=== tip 1 (2004 reviews, one per user), reviews by Best, first page with handles'
explain (analyze, buffers, costs off, timing off)
select r.id, r.model_id, r.model_other, r.environment_id, r.up_count, r.down_count, r.best_score, r.created_at, r.edited_at, r.body, r.prompt, r.output,
       coalesce(u.handle, '[deleted]') as handle, (r.user_id = t.user_id) as by_author
from live_reviews r join tips t on t.id = r.tip_id join users u on u.id = r.user_id
where r.tip_id = 1 and r.user_id is distinct from 5 order by r.best_score desc, r.id desc limit 30;

\echo '=== tip 1, reviews by Best, model filter built into the SQL (matching or unspecified)'
explain (analyze, buffers, costs off, timing off)
select r.id, r.model_id, r.model_other, r.environment_id, r.up_count, r.down_count, r.best_score, r.created_at, r.edited_at, r.body, r.prompt, r.output,
       coalesce(u.handle, '[deleted]') as handle, (r.user_id = t.user_id) as by_author
from live_reviews r join tips t on t.id = r.tip_id join users u on u.id = r.user_id
where r.tip_id = 1 and r.user_id is distinct from 5 and (r.model_id = 'gpt-5' or (r.model_id is null and r.model_other is null))
order by r.best_score desc, r.id desc limit 30;

\echo '=== tip 1, reviews by Best, next page after 1500'
select best_score as b, id as i from live_reviews where tip_id = 1 order by best_score desc, id desc offset 1500 limit 1 \gset
explain (analyze, buffers, costs off, timing off)
select r.id, r.model_id, r.model_other, r.environment_id, r.up_count, r.down_count, r.best_score, r.created_at, r.edited_at, r.body, r.prompt, r.output,
       coalesce(u.handle, '[deleted]') as handle, (r.user_id = t.user_id) as by_author
from live_reviews r join tips t on t.id = r.tip_id join users u on u.id = r.user_id
where r.tip_id = 1 and r.user_id is distinct from 5 and (r.best_score, r.id) < (:b, :i)
order by r.best_score desc, r.id desc limit 30;

\echo '=== my votes on a page of 20 tips'
select array_agg(id) as page from (select id from tips order by hot_score desc limit 20) x \gset
explain (analyze, buffers, costs off, timing off)
select tip_id, value from votes where user_id = 5 and tip_id = any(:'page');

\echo '=== media for the tip and a page of reviews (few rows here, shape only)'
explain (analyze, buffers, costs off, timing off)
select tip_id, review_id, position, key from media where tip_id = 1 or review_id = any('{1,2,3}') order by tip_id, review_id, position;

\echo '=== vote on tip: one statement, the trigger moves the counters'
select id as voter from users where ban is null and deleted_at is null and id > 4 order by id limit 1 \gset
explain (analyze, buffers, costs off, timing off)
insert into votes (user_id, tip_id, value, dead_at)
select u.id, 1, 1, case when u.ban = 'shadow' then now() end from users u where u.id = :voter and u.deleted_at is null and u.ban is distinct from 'full'
  and exists (select 1 from live_tips t where t.id = 1)
on conflict (user_id, tip_id) where tip_id is not null
do update set value = excluded.value, dead_at = excluded.dead_at
where votes.value <> excluded.value or (votes.dead_at is null) <> (excluded.dead_at is null)
returning value, dead_at;
\echo '=== vote response: the counters, next statement'
explain (analyze, buffers, costs off, timing off)
select up_count, down_count from tips where id = 1;

\echo '=== who voted on tip 1 in the last day (moderator)'
explain (analyze, buffers, costs off, timing off)
select user_id, value, created_at from votes where tip_id = 1 and created_at > now() - interval '1 day' order by created_at desc limit 100;

\echo '=== inbox for the heavy user (20k rows): page and capture in one repeatable-read transaction'
begin isolation level repeatable read read only;
explain (analyze, buffers, costs off, timing off)
select n.id, n.type, n.count, n.updated_at, n.read_at,
       case when t.deleted_at is not null then '[deleted]' when t.dead_at is null or t.user_id = n.user_id then t.title else '[removed]' end as title,
       case when r.deleted_at is not null then '[deleted]' when r.dead_at is null or r.user_id = n.user_id then r.body  else '[removed]' end as body,
       coalesce(u.handle, '[deleted]') as actor
from notifications n
left join reviews r on r.id = n.review_id
left join tips t on t.id = coalesce(n.tip_id, r.tip_id)
left join users u on u.id = n.actor_id
where n.user_id = 1 order by n.updated_at desc, n.id desc limit 20;
\echo '=== unread capture, same snapshot'
explain (analyze, buffers, costs off, timing off)
select array_agg(id) as ids, array_agg(count) as counts from notifications where user_id = 1 and read_at is null;
select array_agg(id) as ids, array_agg(count) as counts from notifications where user_id = 1 and read_at is null \gset
commit;

\echo '=== unread badge, capped, served by notifications_fold'
explain (analyze, buffers, costs off, timing off)
select count(*) from (select 1 from notifications where user_id = 1 and read_at is null limit 100) x;

\echo '=== mark all read for the heavy user, count-matched'
explain (analyze, buffers, costs off, timing off)
update notifications n set read_at = now()
from unnest(:'ids'::bigint[], :'counts'::int[]) v(id, count)
where n.user_id = 1 and n.id = v.id and n.count = v.count and n.read_at is null;

\echo '=== profile: a user''s reviews, next page'
select user_id as heavy from reviews group by user_id order by count(*) desc limit 1 \gset
select created_at as c, id as i from reviews where user_id = :heavy and deleted_at is null order by created_at desc, id desc offset 60 limit 1 \gset
explain (analyze, buffers, costs off, timing off)
select r.id, t.title from reviews r join tips t on t.id = r.tip_id
where r.user_id = :heavy and r.deleted_at is null and (r.created_at, r.id) < (:'c', :i)
order by r.created_at desc, r.id desc limit 30;
