"""Report retry versus resolution: partial open uniqueness alone is insufficient.
Reduced schema, independent temporary database, removed after the run.
"""
import os, subprocess, time
name='tips_report_race_'+str(os.getpid())
def run(args): return subprocess.run(args,text=True,capture_output=True,check=True)
def sql(q): return run(['psql','-X','-Atq','-v','ON_ERROR_STOP=1','-d',name,'-c',q]).stdout.strip()
run(['createdb',name])
try:
    sql('''create table tips(id int primary key, author_revision int not null);
    create table flags(id bigint generated always as identity primary key, user_id int not null,
      tip_id int references tips(id), author_revision int not null, resolved_at timestamptz);
    create unique index one_open on flags(user_id,tip_id) where resolved_at is null;
    insert into tips values(1,1);''')
    for permanent in [False, True]:
        sql('truncate flags')
        if permanent: sql('alter table flags add constraint one_revision unique(user_id,tip_id,author_revision)')
        q='''set application_name='tips_report_delayed';
        with eligible as materialized (
          select t.id,t.author_revision,pg_sleep(3) from tips t
          where t.id=1 and t.author_revision=1 and not exists
            (select 1 from flags f where f.user_id=7 and f.tip_id=t.id
             and f.author_revision=t.author_revision and f.resolved_at is not null))
        insert into flags(user_id,tip_id,author_revision)
        select 7,id,author_revision from eligible;'''
        a=subprocess.Popen(['psql','-X','-Atq','-v','ON_ERROR_STOP=1','-d',name,'-c',q],stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
        deadline=time.monotonic()+5
        while time.monotonic()<deadline:
            if sql("select count(*) from pg_stat_activity where datname=current_database() and application_name='tips_report_delayed' and wait_event='PgSleep'")=='1': break
            time.sleep(.03)
        else: raise RuntimeError('missing snapshot barrier')
        sql('insert into flags(user_id,tip_id,author_revision) values(7,1,1)')
        sql('update flags set resolved_at=now() where user_id=7 and tip_id=1')
        out,err=a.communicate(timeout=10)
        count=sql('select count(*) from flags')
        if permanent:
            assert a.returncode != 0 and 'one_revision' in err and count=='1',(count,err)
            print('permanent revision uniqueness: duplicate rejected; original receipt retained')
        else:
            assert a.returncode == 0 and count=='2',(count,err)
            print('partial open uniqueness only: second same-revision report accepted after first resolved')
finally:
    run(['dropdb',name])
