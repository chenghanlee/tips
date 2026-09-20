"""Test slot swaps against the documented media uniqueness shape in an isolated DB."""
import os, subprocess
name = 'tips_media_order_' + str(os.getpid())
def run(cmd): return subprocess.run(cmd, text=True, check=True, capture_output=True)
def sql(statement, check=True):
    return subprocess.run(['psql','-X','-Atq','-v','ON_ERROR_STOP=1','-d',name,'-c',statement],text=True,check=check,capture_output=True)
run(['createdb',name])
try:
    sql('''create table media(id bigint primary key, tip_id bigint, review_id bigint, position smallint not null,
    check (num_nonnulls(tip_id,review_id)=1), check(position between 0 and 9),
    constraint media_tip_slot unique(tip_id,position), constraint media_review_slot unique(review_id,position));
    insert into media values (1,1,null,0),(2,1,null,1);''')
    baseline=sql('update media set position=1-position where tip_id=1',False)
    assert baseline.returncode != 0 and 'media_tip_slot' in baseline.stderr, baseline.stderr
    print('baseline: swapping two retained attachments fails media_tip_slot uniqueness')
    sql('''alter table media drop constraint media_tip_slot;
    alter table media add constraint media_tip_slot unique(tip_id,position) deferrable initially immediate;
    begin; set constraints media_tip_slot deferred;
    update media set position=1-position where tip_id=1; commit;''')
    actual=sql("select string_agg(id::text || ':' || position::text, ',' order by id) from media").stdout.strip()
    assert actual=='1:1,2:0',actual
    print('deferred constraint: swap succeeds preserving attachment ids: '+actual)
    invalid=sql('begin; set constraints media_tip_slot deferred; update media set position=0; commit;',False)
    assert invalid.returncode != 0 and 'media_tip_slot' in invalid.stderr,invalid.stderr
    print('deferred constraint: invalid final duplicate positions still rejected at commit')
finally:
    run(['dropdb',name])
