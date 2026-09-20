import subprocess, os, time
name = 'tips_holistic_' + str(os.getpid())
def run(args):
    return subprocess.run(args, text=True, capture_output=True, check=True)
def sql(q):
    return run(['psql', '-X', '-Atq', '-v', 'ON_ERROR_STOP=1', '-d', name, '-c', q]).stdout.strip()
run(['createdb', name])
try:
    sql('''create table tips(id bigint primary key, deleted_at timestamptz);
    create table flags(id bigint generated always as identity primary key, tip_id bigint references tips(id), resolved_at timestamptz);
    insert into tips values(1,null);''')
    p = subprocess.Popen(['psql','-X','-Atq','-v','ON_ERROR_STOP=1','-d',name,'-c', '''set application_name='tips_holistic_report';
    with eligible as materialized (select id, pg_sleep(1) from tips where id=1 and deleted_at is null)
    insert into flags(tip_id) select id from eligible;'''],text=True,stdout=subprocess.PIPE,stderr=subprocess.PIPE)
    deadline = time.monotonic() + 5
    while time.monotonic() < deadline:
        if sql("select count(*) from pg_stat_activity where datname=current_database() and application_name='tips_holistic_report' and wait_event='PgSleep'") == '1':
            break
        time.sleep(.02)
    else:
        raise RuntimeError('report snapshot barrier not reached')
    sql('begin; select id from tips where id=1 for no key update; update tips set deleted_at=now() where id=1; update flags set resolved_at=now() where tip_id=1 and resolved_at is null; commit;')
    out,err=p.communicate(timeout=5)
    assert p.returncode == 0, err
    print('Open reports after author deletion:', sql('select count(*) from flags join tips on tips.id=flags.tip_id where tips.deleted_at is not null and flags.resolved_at is null'))
    print('Deadline comparison after transaction crosses expiry (now accepts, wall clock rejects):', sql("begin; create temp table deadline as select clock_timestamp()+interval '0.1 seconds' as expires_at; select pg_sleep(0.2); select expires_at > now(), expires_at > clock_timestamp() from deadline; rollback;"))
    sql('''create table users(id bigint primary key);
    create table tokens(id bigint generated always as identity primary key, user_id bigint references users(id), family_id bigint);
    insert into users values(1);
    insert into tokens(user_id,family_id) values(1,10),(1,20);''')
    def background(q):
        return subprocess.Popen(['psql','-X','-Atq','-v','ON_ERROR_STOP=1','-d',name,'-c',q], text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    def barrier(app):
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            if sql("select count(*) from pg_stat_activity where datname=current_database() and application_name='" + app + "' and wait_event='PgSleep'") == '1':
                return
            time.sleep(.02)
        raise RuntimeError('missing synchronization barrier')
    def finished(proc):
        out, err = proc.communicate(timeout=5)
        assert proc.returncode == 0, err
    # A renewal commits before logout acquires the common account lock.
    p = background("begin; set application_name='tips_family_renew'; select id from users where id=1 for no key update; insert into tokens(user_id,family_id) select user_id,family_id from tokens where id=1; select pg_sleep(1); commit;")
    barrier('tips_family_renew')
    sql('begin; select id from users where id=1 for no key update; delete from tokens where user_id=1 and family_id=10; commit;')
    finished(p)
    assert sql('select count(*) from tokens where family_id=10') == '0'
    assert sql('select count(*) from tokens where family_id=20') == '1'
    # Logout commits before a waiting renewal rechecks its predecessor.
    predecessor = sql('insert into tokens(user_id,family_id) values(1,30) returning id')
    p = background("begin; set application_name='tips_family_logout'; select id from users where id=1 for no key update; delete from tokens where user_id=1 and family_id=30; select pg_sleep(1); commit;")
    barrier('tips_family_logout')
    sql('begin; select id from users where id=1 for no key update; insert into tokens(user_id,family_id) select user_id,family_id from tokens where id=' + predecessor + '; commit;')
    finished(p)
    assert sql('select count(*) from tokens where family_id=30') == '0'
    print('Session-family proposal: both renew/logout orders revoke the family; another browser family survives. Reduced SQL only.')
    sql('truncate flags; update tips set deleted_at=null where id=1;')
    p = background("begin; set application_name='tips_report_share'; select id from tips where id=1 and deleted_at is null for share; insert into flags(tip_id) values(1); select pg_sleep(1); commit;")
    barrier('tips_report_share')
    sql('begin; select id from tips where id=1 for no key update; update tips set deleted_at=now() where id=1; update flags set resolved_at=now() where tip_id=1 and resolved_at is null; commit;')
    finished(p)
    assert sql('select count(*) from flags where resolved_at is null') == '0'
    sql('truncate flags; update tips set deleted_at=null where id=1;')
    p = background("begin; set application_name='tips_delete_first'; select id from tips where id=1 for no key update; update tips set deleted_at=now() where id=1; update flags set resolved_at=now() where tip_id=1 and resolved_at is null; select pg_sleep(1); commit;")
    barrier('tips_delete_first')
    sql('with eligible as (select id from tips where id=1 and deleted_at is null for share) insert into flags(tip_id) select id from eligible;')
    finished(p)
    assert sql('select count(*) from flags') == '0'
    print('Report target SHARE lock: report-first is resolved by deletion; delete-first rejects the report. Reduced SQL only.')
finally:
    run(['dropdb', name])
