"""Fable: full attachment edit under deferred slot constraints, and report insert vs concurrent author edit.
Isolated temp DB, dropped at the end. Postgres 18.6.
E1: one edit transaction = delete removed rows, reposition retained rows from VALUES, insert new rows.
    Retained ids survive; a new row takes a slot a retained row vacated; order-only edit works.
E2: same edit with a duplicate final position is rejected at COMMIT, not per row.
R1: report INSERT..SELECT bound to author_revision=1 while an author edit to 2 is uncommitted:
    the report commits bound to 1; the parent ends at 2. Conditional insert-select is a snapshot read, not CAS."""
import os, subprocess, time
name = 'tips_media_edit_' + str(os.getpid())
def run(cmd, **kw): return subprocess.run(cmd, text=True, capture_output=True, **kw)
def sql(s, check=True):
    r = run(['psql','-X','-Atq','-v','ON_ERROR_STOP=1','-d',name,'-c',s])
    if check and r.returncode: raise RuntimeError(r.stderr)
    return r
def bg(q, app):
    return subprocess.Popen(['psql','-X','-Atq','-d',name,'-c',"begin; set local application_name='%s'; %s" % (app,q)],
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
def wait_sleep(app):
    for _ in range(200):
        if sql("select count(*) from pg_stat_activity where application_name='%s' and wait_event='PgSleep'" % app).stdout.strip()=='1': return
        time.sleep(.03)
    raise RuntimeError('barrier')
run(['createdb',name], check=True)
try:
    sql('''create table media(id bigint generated always as identity primary key, tip_id bigint, review_id bigint,
      position smallint not null, key text,
      check (num_nonnulls(tip_id,review_id)=1), check (position between 0 and 9),
      constraint media_tip_slot unique(tip_id,position) deferrable initially immediate,
      constraint media_review_slot unique(review_id,position) deferrable initially immediate);
    insert into media(tip_id,position,key) values (1,0,'a'),(1,1,'b'),(1,2,'c');''')
    # E1: remove b(2), order c,new,a  -> c:0 new:1 a:2
    r = sql('''begin; set constraints media_tip_slot, media_review_slot deferred;
      delete from media where tip_id=1 and id not in (1,3);
      update media m set position = v.pos from (values (3,0),(1,2)) v(id,pos) where m.id=v.id and m.tip_id=1;
      insert into media(tip_id,position,key) values (1,1,'n'); commit;''')
    print('E1 edit result:', sql("select string_agg(id||':'||position||':'||key, ',' order by position) from media where tip_id=1").stdout.strip())
    # order-only edit: swap a and c
    sql('''begin; set constraints media_tip_slot deferred;
      update media m set position = v.pos from (values (3,2),(1,0)) v(id,pos) where m.id=v.id and m.tip_id=1; commit;''')
    print('E1 order-only swap:', sql("select string_agg(id||':'||position, ',' order by position) from media where tip_id=1").stdout.strip())
    # E2: duplicate final position
    r = sql('''begin; set constraints media_tip_slot deferred;
      update media m set position = v.pos from (values (3,1),(1,0)) v(id,pos) where m.id=v.id and m.tip_id=1; commit;''', check=False)
    print('E2 duplicate final position rejected at commit:', r.returncode!=0 and 'media_tip_slot' in r.stderr, '| rows unchanged:',
          sql("select string_agg(id||':'||position, ',' order by position) from media where tip_id=1").stdout.strip())
    # R1
    sql('''create table tips(id bigint primary key, author_revision int not null default 1, dead_at timestamptz, deleted_at timestamptz);
      create table flags(id bigint generated always as identity primary key, tip_id bigint, user_id bigint, author_revision int not null, resolved_at timestamptz);
      create unique index flags_open on flags(user_id, tip_id) where resolved_at is null;
      insert into tips(id) values (1);''')
    a = bg("update tips set author_revision = author_revision + 1 where id = 1 and author_revision = 1; select pg_sleep(2); commit;", 'r1edit')
    wait_sleep('r1edit')
    r = sql('''insert into flags(tip_id,user_id,author_revision)
      select t.id, 7, t.author_revision from tips t where t.id=1 and t.author_revision=1 and t.deleted_at is null
        and not exists (select 1 from flags f where f.tip_id=t.id and f.user_id=7 and f.resolved_at is null)
      returning author_revision;''')
    a.communicate(timeout=10)
    print('R1 report bound to revision', r.stdout.strip(), '| tip now at revision', sql('select author_revision from tips where id=1').stdout.strip())
finally:
    run(['dropdb',name])
