"""Variants on Codex's race script. Isolated temp DB, removed at the end.
T1: unban vs uncommitted publish, lock inside the insert-select with FOR NO KEY UPDATE.
T2: two concurrent review inserts on one tip, parent read FOR SHARE, counter trigger -> deadlock?
T3: same with FOR NO KEY UPDATE on the parent.
T4: review insert vs concurrent tip deletion, parent read FOR NO KEY UPDATE -> insert dropped?
"""
import os, subprocess, time
name = 'tips_lockvar_' + str(os.getpid())
def run(cmd, **kw):
    return subprocess.run(cmd, text=True, capture_output=True, **kw)
def sql(s):
    r = run(['psql', '-X', '-Atq', '-v', 'ON_ERROR_STOP=1', '-d', name, '-c', s])
    if r.returncode: raise RuntimeError(r.stderr)
    return r.stdout.strip()
def bg(query, app):
    return subprocess.Popen(['psql','-X','-Atq','-d',name,'-c',
        "begin; set local application_name='%s'; %s" % (app, query)],
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
def wait_sleep(app):
    deadline=time.monotonic()+5
    while time.monotonic()<deadline:
        if sql("select count(*) from pg_stat_activity where application_name='%s' and wait_event='PgSleep'" % app) == '1': return
        time.sleep(.03)
    raise RuntimeError('never reached barrier: '+app)
run(['createdb', name], check=True)
try:
    sql('''create table users(id bigint primary key, ban text);
    create table tips(id bigint generated always as identity primary key, user_id bigint references users(id), review_count int not null default 0, deleted_at timestamptz, dead_at timestamptz);
    create table reviews(id bigint generated always as identity primary key, tip_id bigint references tips(id), user_id bigint references users(id), dead_at timestamptz);
    create function review_counts() returns trigger language plpgsql as $$
    begin update tips set review_count = review_count + 1 where id = new.tip_id; return null; end $$;
    create trigger reviews_counts after insert on reviews for each row execute function review_counts();
    insert into users values (1,'shadow'),(2,null),(3,null);
    insert into tips(user_id) values (2);''')

    # T1
    a = bg("""insert into tips(user_id,dead_at) select id, case when ban='shadow' then now() end
        from users where id=1 and ban is distinct from 'full' for no key update;
        select pg_sleep(2); commit;""", 't1pub')
    wait_sleep('t1pub')
    sql("begin; update users set ban=null where id=1; update tips set dead_at=null where user_id=1 and dead_at is not null; commit;")
    a.communicate(timeout=10)
    print('T1 no-key-update in insert-select: hidden_after_unban =', sql("select (dead_at is not null) from tips where user_id=1"))

    # T2 / T3
    for label, lock in [('T2 FOR SHARE', 'for share'), ('T3 FOR NO KEY UPDATE', 'for no key update')]:
        q = """with p as (select id from tips where id=1 and deleted_at is null and dead_at is null %s)
               insert into reviews(tip_id,user_id) select p.id, %%d from p; select pg_sleep(2); commit;""" % lock
        # each session: lock parent, insert (trigger updates parent), sleep. Interleave: A locks, B locks, A inserts... need the sleep BEFORE insert.
        q = """select id from tips where id=1 and deleted_at is null and dead_at is null %s; select pg_sleep(2);
               insert into reviews(tip_id,user_id) values (1, %%d); commit;""" % lock
        a = bg(q % 2, 'rA'); b = bg(q % 3, 'rB')
        outs = [p.communicate(timeout=20) for p in (a,b)]
        errs = [e for _, e in outs if 'deadlock' in e]
        print(label + ': deadlocks =', len(errs), '| reviews =', sql('select count(*) from reviews'), '| review_count =', sql('select review_count from tips where id=1'))
        sql('truncate reviews; update tips set review_count=0')

    # T4
    a = bg("""with p as (select id from tips where id=1 and deleted_at is null and dead_at is null for no key update)
        select pg_sleep(2) from p; commit;""", 't4x')  # placeholder to hold lock? no: run deletion first, then review waits
    a.communicate(timeout=10)
    d = bg("update tips set deleted_at=now() where id=1 and deleted_at is null; select pg_sleep(2); commit;", 't4del')
    wait_sleep('t4del')
    r = run(['psql','-X','-Atq','-d',name,'-c', """with p as (select id from tips where id=1 and deleted_at is null and dead_at is null for no key update)
        insert into reviews(tip_id,user_id) select p.id, 3 from p returning id;"""])
    d.communicate(timeout=10)
    print('T4 review vs concurrent delete: inserted rows =', repr(r.stdout.strip()), '| reviews =', sql('select count(*) from reviews'))
finally:
    run(['dropdb', name])
