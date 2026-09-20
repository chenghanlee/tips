#!/bin/sh
# Two-session tests for data model v3. Run after data-model-v3-test.sql. Exits 1 on any failed expectation.
# 1. Tip: the same user votes up in session A (held open) and down in session B. One statement per vote; the trigger
#    moves the counters after B's lock wait ends, from its own snapshot. Expect (0 up, 1 down), vote -1.
# 2. Review: same race starting at (0 up, 1 down). A statement that computed the parent from its own snapshot
#    would try (-1, 2) and fail Wilson's sqrt. Expect (0 up, 1 down).
# 3. Session A reads the inbox page and the unread capture in one repeatable-read transaction. Session B folds one
#    more event between the two reads. A marks read with the captured counts. Expect the folded row still unread, count 2.
set -eu
DB=${DB:-tips_v3}
Q() { psql -X -q -At -v ON_ERROR_STOP=1 -d "$DB" "$@"; }
fail=0
check() { # $1 label $2 got $3 want
  if [ "$2" = "$3" ]; then echo "ok   $1: $2"; else echo "FAIL $1: got '$2' want '$3'"; fail=1; fi
}

USR=$(Q -c "select id from users where ban is null and deleted_at is null order by id limit 1")
TIP=$(Q -c "insert into tips (user_id, title, body, tag_id) values ($USR, 'race probe', 'probe body', 'phrase') returning id")
REV=$(Q -c "insert into reviews (tip_id, user_id, body) values ($TIP, $USR, 'race review') returning id")
Q -c "insert into votes (user_id, review_id, value) values ($USR, $REV, -1)" >/dev/null
check "review starts at (0,1) by trigger" "$(Q -c "select up_count||','||down_count from reviews where id=$REV")" "0,1"

# vote TARGETCOL VIEW ID USER VALUE SLEEP : the vote statement from the doc, then a pause before commit
vote() {
cat <<SQL
\\set ON_ERROR_STOP on
begin;
insert into votes (user_id, $1, value, dead_at)
select u.id, $3, $5, case when u.ban = 'shadow' then now() end
from users u where u.id = $4 and u.deleted_at is null and u.ban is distinct from 'full'
  and exists (select 1 from $2 t where t.id = $3)
on conflict (user_id, $1) where $1 is not null
do update set value = excluded.value, dead_at = excluded.dead_at
where votes.value <> excluded.value or (votes.dead_at is null) <> (excluded.dead_at is null);
select pg_sleep($6);
commit;
SQL
}
race() { # col view id
  vote "$1" "$2" "$3" "$USR" 1 2  | Q -f - >/dev/null & A=$!
  sleep 0.5
  vote "$1" "$2" "$3" "$USR" -1 0 | Q -f - >/dev/null & B=$!
  wait $A; wait $B
}

race tip_id live_tips "$TIP"
check "tip race counters" "$(Q -c "select up_count||','||down_count from tips where id=$TIP")" "0,1"
check "tip race vote"     "$(Q -c "select value from votes where user_id=$USR and tip_id=$TIP")" "-1"

race review_id live_reviews "$REV"
check "review race counters" "$(Q -c "select up_count||','||down_count from reviews where id=$REV")" "0,1"

# 3. inbox: repeatable-read page + capture, a fold in between, count-matched mark read
Q -c "delete from notifications where user_id=$USR" >/dev/null
NID=$(Q -c "insert into notifications (user_id, type, actor_id, tip_id) values ($USR, 'tip_upvoted', $USR, $TIP) returning id")
Q <<SQL > /tmp/tips_v3_capture.$$ &
begin isolation level repeatable read read only;
select id from notifications where user_id = $USR order by updated_at desc, id desc limit 20;
select pg_sleep(1.5);
select array_agg(id)::text || ' ' || array_agg(count)::text from notifications where user_id = $USR and read_at is null;
commit;
SQL
A=$!
sleep 0.5
Q -c "insert into notifications (user_id, type, actor_id, tip_id) values ($USR, 'tip_upvoted', $USR, $TIP)
      on conflict (user_id, type, tip_id, review_id) where read_at is null
      do update set count = notifications.count + 1, updated_at = now()" >/dev/null
wait $A
CAPTURE=$(tail -1 /tmp/tips_v3_capture.$$); rm -f /tmp/tips_v3_capture.$$
IDS=${CAPTURE%% *}; COUNTS=${CAPTURE##* }
check "capture saw the pre-fold count" "$COUNTS" "{1}"
Q -c "update notifications n set read_at = now() from unnest('$IDS'::bigint[], '$COUNTS'::int[]) v(id, count)
      where n.user_id = $USR and n.id = v.id and n.count = v.count and n.read_at is null" >/dev/null
check "folded row still unread with count 2" "$(Q -c "select count from notifications where id=$NID and read_at is null")" "2"

Q -c "delete from votes where tip_id=$TIP or review_id=$REV; delete from notifications where tip_id=$TIP; delete from review_search where review_id=$REV; delete from reviews where id=$REV; delete from tip_search where tip_id=$TIP; delete from tips where id=$TIP" >/dev/null
exit $fail
