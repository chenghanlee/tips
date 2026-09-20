"""Isolated Postgres reproduction of unban versus uncommitted publication.
Creates and removes its own database; requires local createdb/psql/dropdb.
Reduced schema tests the cross-row invariant, not the complete Tips design.
"""
import os, subprocess, time
name = 'tips_adversarial_' + str(os.getpid())
def run(cmd, **kw):
    return subprocess.run(cmd, text=True, check=True, capture_output=True, **kw)
run(['createdb', name])
def sql(s):
    return run(['psql', '-X', '-Atq', '-v', 'ON_ERROR_STOP=1', '-d', name, '-c', s]).stdout.strip()
try:
    print(sql('select version()'))
    sql('''create table users(id bigint primary key, ban text);
    create table tips(id bigint generated always as identity primary key, user_id bigint references users(id), dead_at timestamptz);
    insert into users values (1, 'shadow');''')
    for locked in [False, True]:
        sql("truncate tips; update users set ban='shadow' where id=1")
        lock = 'select id from users where id=1 for no key update;' if locked else ''
        query = """begin; set local application_name='tips_review_publish'; %s
        insert into tips(user_id,dead_at) select id, case when ban='shadow' then now() end
        from users where id=1 and ban is distinct from 'full';
        select pg_sleep(3); commit;""" % lock
        a = subprocess.Popen(['psql','-X','-Atq','-v','ON_ERROR_STOP=1','-d',name,'-c',query],stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
        deadline=time.monotonic()+5
        while time.monotonic()<deadline:
            if sql("select count(*) from pg_stat_activity where application_name='tips_review_publish' and wait_event='PgSleep'") == '1': break
            time.sleep(.03)
        else: raise RuntimeError('publisher never reached barrier')
        start=time.monotonic()
        sql("begin; update users set ban=null where id=1; update tips set dead_at=null where user_id=1 and dead_at is not null; commit;")
        elapsed=time.monotonic()-start
        out,err=a.communicate(timeout=10)
        if a.returncode: raise RuntimeError(err)
        actual=sql('select (u.ban is null)::text || \'|\' || (t.dead_at is not null)::text from users u join tips t on t.user_id=u.id')
        expected='true|false' if locked else 'true|true'
        assert actual==expected,(actual,expected)
        print(('locked' if locked else 'baseline')+': account_unbanned|content_still_hidden='+actual+'; unban_wait_seconds='+str(round(elapsed,2)))
finally:
    run(['dropdb', name])
