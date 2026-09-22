#!/usr/bin/env python3
"""Real Git + fake Herdr integration; never controls a live pane or model client."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import tomllib
import unittest

TEAMS = Path(__file__).resolve().parent
LSP_WRAPPER = TEAMS.parents[1] / "agent/lsp/elixir_lsp.sh"
# Deliberately fixed test data: changing production defaults must not rewrite tests.
CONFIG = """\
# Agent launch settings. Changes apply to newly started sessions.
# An empty model uses the client's configured default.
[team]
max_teams = 6
workspace_prefix = "tips-team"
port_base = 4100
port_stride = 10
postgres_port = 5433
db_suffix_prefix = "_t"

[timeouts]
launch_seconds = 120
shutdown_seconds = 15
shell_seconds = 15
mcp_startup_seconds = 60
mcp_tool_seconds = 120
checks_minutes = 30

[launch]
codex_approval = "never"
codex_lsp_approval_mode = "approve"
claude_permission_mode = "bypassPermissions"

[roles.dev]
kind = "codex"
model = "fixture-dev"
effort = "xhigh"
db_suffix = ""
port_offset = 0

[roles.test]
kind = "claude"
model = "fixture-test"
effort = "xhigh"
db_suffix = "r"
port_offset = 1

[roles.lead]
kind = "codex"
model = "fixture-lead"
effort = "high"
db_suffix = "l"
port_offset = 2

[roles.tpm]
kind = "claude"
model = ""
effort = "medium"
compaction_percent = 35

[roles.lead_tpm]
kind = "claude"
model = ""
effort = "high"
compaction_percent = 35
"""
FAKE_HERDR = r'''#!/usr/bin/env python3
import json, os, subprocess, sys
from pathlib import Path
p = Path(os.environ['FAKE_HERDR_STATE']); state = json.loads(p.read_text())
a = sys.argv[1:]; state['events'].append(a)
def reply(result, code=0):
 p.write_text(json.dumps(state)); print(json.dumps({'result':result})); sys.exit(code)
if a == ['agent','list']: reply({'agents':state['agents']})
if a[:2] == ['agent','get']:
 matches=[x for x in state['agents'] if x['pane_id']==a[2] or x.get('name')==a[2]]
 reply({'agent':matches[0]} if matches else {}, 0 if matches else 1)
if a[:2] == ['agent','rename']:
 for x in state['agents']:
  if x['pane_id']==a[2]: x['name']=a[3]
 reply({})
if a[:2] == ['pane','get']:
 reply({'pane':{'pane_id':a[2],'cwd':state['cwd'],'foreground_cwd':state['cwd'],'agent':None}})
if a[:2] == ['pane','process-info']:
 pid=999 if state.get('busy') else 100
 reply({'process_info':{'shell_pid':100,'foreground_processes':[{'pid':pid,'cwd':state['cwd']}]}})
if a[:2] == ['pane','run']:
 # Actually execute setup in a disposable shell and capture its resulting environment.
 command=a[3]+'\npython3 -c \'import os,json; print("SNAPSHOT="+json.dumps({"env":dict(os.environ),"cwd":os.getcwd()}))\''
 r=subprocess.run(['bash','-c',command],cwd=state['cwd'],env=os.environ,text=True,capture_output=True)
 if r.returncode: reply({'error':r.stderr},1)
 lines=r.stdout.splitlines(); snap=json.loads(next(x[9:] for x in lines if x.startswith('SNAPSHOT=')))
 state['cwd']=snap['cwd']; state['env']=snap['env']; state['output']=r.stdout
 p.write_text(json.dumps(state)); sys.exit(0)
if a[:2] == ['pane','wait-output']:
 import re
 match=a[a.index('--match')+1] in state.get('output','') and a[a.index('--source')+1]=='detection'
 reply({},0 if match and not state.get('shell_timeout') else 1)
if a[:2] == ['agent','start']:
 state['launch_env']={k:state.get('env',{}).get(k) for k in ['PGPORT','TIPS_DB_SUFFIX','TIPS_TEST_PORT','MIX_ENV','MIX_TEST_PARTITION','CLAUDE_AUTOCOMPACT_PCT_OVERRIDE','TIPS_CHECK_TIMEOUT_SECONDS','TIPS_TEAM_CONFIG']}
 state['launch_argv']=a
 root=state['cwd']; kind=a[a.index('--kind')+1]
 if state.get('wrong_start_root'): root=state['wrong_start_root']
 agent={'name':a[2],'pane_id':a[a.index('--pane')+1],'agent':kind,'cwd':root,'foreground_cwd':root,'agent_status':'blocked' if state.get('start_fails') else 'idle'}
 state['agents']=[agent]
 reply({'agent':agent},1 if state.get('start_fails') else 0)
reply({'error':'unhandled fake Herdr command: '+repr(a)},2)
'''
FAKE_STOP = r'''import json,os,subprocess,sys
from pathlib import Path
p=Path(os.environ['FAKE_HERDR_STATE']); s=json.loads(p.read_text())
head=subprocess.check_output(['git','-C',sys.argv[2],'rev-parse','HEAD'],text=True).strip()
s['events'].append(['stop_agent',sys.argv[1],sys.argv[2],head])
if not s.get('stop_fails'): s['agents']=[]
if s.get('stop_dirties'): (Path(sys.argv[2])/'tracked.txt').write_text('saved at exit\n')
p.write_text(json.dumps(s))
sys.exit(1 if s.get('stop_fails') else 0)
'''


class WorktreeIntegrationTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='tips helper ')
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name).resolve()
        self.env = dict(os.environ, GIT_CONFIG_GLOBAL=os.devnull, GIT_CONFIG_NOSYSTEM='1', HERDR_ENV='1')
        self.env.pop('TIPS_TEAM_CONFIG', None)
        for k in ('TIPS_DB_SUFFIX','TIPS_TEST_PORT','PGPORT','MIX_ENV','MIX_TEST_PARTITION','CLAUDE_AUTOCOMPACT_PCT_OVERRIDE'):
            self.env.pop(k, None)
        self.git('init','-q','-b','main')
        for d in ('agent/lsp','agent/teams','.agents/skills','.elixir-tools/bin','fakebin'):
            (self.root/d).mkdir(parents=True)
        (self.root/'.gitignore').write_text('.codex/\n.claude/\n.agents/\n.elixir-tools/\n.worktrees/\nfakebin/\nstate.json\nstop.py\n')
        shutil.copy(TEAMS/'task_worktree.py', self.root/'agent/teams/task_worktree.py')
        shutil.copy(LSP_WRAPPER, self.root/'agent/lsp/elixir_lsp.sh')
        (self.root/'agent/teams/team.py').write_text((TEAMS/'team.py').read_text() + '\nimport os, subprocess, sys\ndef stop_agent(pane, root):\n    if subprocess.run([sys.executable, os.environ["FAKE_STOP"], pane, root]).returncode:\n        raise RuntimeError("stop failed")\n')
        (self.root/'agent/teams/config.toml').write_text(CONFIG)
        (self.root/'tracked.txt').write_text('base\n')
        for name in ('expert','mcp-language-server'):
            p=self.root/'.elixir-tools/bin'/name; p.write_text('#!/bin/sh\nexit 0\n'); p.chmod(0o755)
        self.git('add','.'); self.commit('base'); self.base=self.git('rev-parse','HEAD')
        self.git('remote','add','origin',str(self.root))
        self.git('update-ref','refs/remotes/origin/main',self.base)
        fake=self.root/'fakebin/herdr'; fake.write_text(FAKE_HERDR); fake.chmod(0o755)
        (self.root/'stop.py').write_text(FAKE_STOP)
        self.state_path=self.root/'state.json'
        self.save(dict(agents=[],events=[],cwd=str(self.root)))
        self.env.update(PATH=str(self.root/'fakebin')+os.pathsep+self.env['PATH'],FAKE_HERDR_STATE=str(self.state_path),FAKE_STOP=str(self.root/'stop.py'))
        self.script=self.root/'agent/teams/task_worktree.py'
        self.wt=self.root/'.worktrees/28-review-team-3-lead'

    def git(self,*a):
        return subprocess.check_output(['git',*a],cwd=self.root,env=self.env,text=True,stderr=subprocess.DEVNULL).strip()

    def commit(self,msg):
        self.git('-c','user.name=Test','-c','user.email=test@example.invalid','commit','-q','--allow-empty','-m',msg)

    def state(self): return json.loads(self.state_path.read_text())
    def save(self,s): self.state_path.write_text(json.dumps(s))
    def call(self,*extra,ref=None,ok=True,role='lead',team='3',task='28-review-team-3-lead'):
        args=[sys.executable,str(self.script),task,'--team',team,'--pane','wA:pB','--role',role]
        if ref is not False: args+=['--review-ref',ref or self.base]
        p=subprocess.run(args+list(extra),cwd=self.root,env=self.env,text=True,capture_output=True,timeout=20)
        if ok: self.assertEqual(p.returncode,0,p.stdout+p.stderr)
        else: self.assertNotEqual(p.returncode,0,p.stdout+p.stderr)
        return p

    def test_codex_only_canonical_wrapper_and_idempotent_config(self):
        self.call(); path=self.wt/'.codex/config.toml'; cfg=tomllib.loads(path.read_text())['mcp_servers']['elixir-lsp']
        self.assertEqual(cfg['args'],[str(self.root/'agent/lsp/elixir_lsp.sh'),str(self.wt)])
        self.assertEqual(cfg['cwd'],str(self.wt)); self.assertEqual(cfg['tool_timeout_sec'],120)
        self.assertFalse((self.wt/'.claude').exists())
        before=path.stat().st_mtime_ns; self.call(); self.assertEqual(before,path.stat().st_mtime_ns)
        self.assertEqual(self.git('-C',str(self.wt),'status','--porcelain'),'')

    def test_claude_only_and_actual_target_environment(self):
        self.call('--start',role='test',team='6')
        self.assertFalse((self.wt/'.codex').exists())
        mcp=json.loads((self.wt/'.claude/elixir-mcp.json').read_text())['mcpServers']['elixir-lsp']
        self.assertEqual(mcp['args'],[str(self.root/'agent/lsp/elixir_lsp.sh'),str(self.wt)])
        self.assertEqual(mcp['timeout'],120000)
        self.assertFalse(json.loads((self.wt/'.claude/settings.local.json').read_text())['enabledPlugins']['elixir-lsp@elixir-agent-tools'])
        s=self.state(); self.assertEqual(s['launch_env'],dict(PGPORT='5433',TIPS_DB_SUFFIX='_t6r',TIPS_TEST_PORT='4161',MIX_ENV='test',MIX_TEST_PARTITION=None,CLAUDE_AUTOCOMPACT_PCT_OVERRIDE=None,TIPS_CHECK_TIMEOUT_SECONDS='1800',TIPS_TEAM_CONFIG=str(self.root/'agent/teams/config.toml')))
        self.assertEqual(s['cwd'],str(self.wt)); self.assertIn('fixture-test',s['launch_argv']); self.assertIn('--mcp-config',s['launch_argv'])

    def test_codex_models_and_config_parameters(self):
        self.call('--start'); self.assertIn('fixture-lead',self.state()['launch_argv'])
        s=self.state(); s['agents']=[]; self.save(s)
        cfg=self.root/'agent/teams/config.toml'; cfg.write_text(CONFIG.replace('fixture-dev','configured-sol').replace('4100','5100').replace('5433','5434').replace('launch_seconds = 120','launch_seconds = 42'))
        self.call('--start',role='dev',team='6',task='29-dev',ref=False)
        s=self.state(); self.assertIn('configured-sol',s['launch_argv']); self.assertIn('42000',s['launch_argv'])
        self.assertEqual(s['launch_env']['TIPS_TEST_PORT'],'5160'); self.assertEqual(s['launch_env']['PGPORT'],'5434')

    def test_same_live_session_reused_and_new_sha_stops_before_checkout(self):
        self.call('--start'); before=len(self.state()['events']); p=self.call('--start')
        self.assertIn('Already running',p.stdout)
        self.assertFalse(any(e[:2]==['agent','start'] for e in self.state()['events'][before:]))
        self.commit('next'); new=self.git('rev-parse','HEAD'); self.call('--start',ref=new)
        stops=[e for e in self.state()['events'] if e[0]=='stop_agent']
        self.assertEqual(stops,[['stop_agent','wA:pB',str(self.wt),self.base]])
        self.assertEqual(self.git('-C',str(self.wt),'rev-parse','HEAD'),new)
        self.assertEqual(sum(e[:2]==['agent','start'] for e in self.state()['events']),2)

    def test_failed_stop_preserves_review_head(self):
        self.call('--start'); s=self.state(); s['stop_fails']=True; self.save(s)
        self.commit('next'); new=self.git('rev-parse','HEAD'); self.call('--start',ref=new,ok=False)
        self.assertEqual(self.git('-C',str(self.wt),'rev-parse','HEAD'),self.base)

    def test_dirty_review_refused_even_same_sha(self):
        self.call()
        for file in ('tracked.txt','untracked.txt'):
            with self.subTest(file=file):
                p=self.wt/file; p.write_text('keep\n'); self.call('--start',ok=False)
                self.assertEqual(p.read_text(),'keep\n')
                if file=='tracked.txt': self.git('-C',str(self.wt),'restore',file)
                else: p.unlink()
        self.assertFalse(any(e[:2]==['agent','start'] for e in self.state()['events']))

    def test_config_conflict_precedes_stop_and_checkout(self):
        self.call('--start'); config=self.wt/'.codex/config.toml'; config.write_text('custom=true\n')
        self.commit('next'); self.call('--start',ref=self.git('rev-parse','HEAD'),ok=False)
        self.assertEqual(self.git('-C',str(self.wt),'rev-parse','HEAD'),self.base)
        self.assertFalse(any(e[0]=='stop_agent' for e in self.state()['events']))
        self.assertEqual(config.read_text(),'custom=true\n')

    def test_unused_client_conflict_ignored(self):
        self.call(); (self.wt/'.claude').mkdir(); f=self.wt/'.claude/settings.local.json'; f.write_text('{"mine":true}\n')
        self.call('--start'); self.assertEqual(f.read_text(),'{"mine":true}\n')

    def test_wrong_owner_and_busy_pane_refused_before_mutation(self):
        s=self.state(); s['agents']=[dict(name='someone-else',pane_id='wA:pB',agent='codex',foreground_cwd=str(self.root))]; self.save(s)
        self.call('--start',ok=False); self.assertFalse(self.wt.exists())
        s['agents']=[]; s['busy']=True; self.save(s)
        self.call('--start',ok=False); self.assertFalse(self.wt.exists())

    def test_duplicate_root_in_another_pane_refused(self):
        self.call('--start'); s=self.state(); s['agents'][0]['pane_id']='wA:pC'; self.save(s)
        self.call('--start',ok=False)
        self.assertEqual(sum(e[:2]==['agent','start'] for e in self.state()['events']),1)

    def test_start_failure_and_wrong_runtime_root_reported(self):
        s=self.state(); s['start_fails']=True; self.save(s); self.call('--start',ok=False)
        s=self.state(); s['agents']=[]; s['start_fails']=False; s['wrong_start_root']=str(self.root); self.save(s)
        self.call('--start',ok=False)

    def test_missing_tool_and_invalid_team_refused(self):
        self.call('--start',team='7',ok=False); self.assertFalse(self.wt.exists())
        (self.root/'.elixir-tools/bin/expert').unlink(); self.call('--start',ok=False); self.assertFalse(self.wt.exists())

    def test_shell_setup_failure_never_starts_agent(self):
        s=self.state(); s['shell_timeout']=True; self.save(s)
        self.call('--start',ok=False)
        self.assertFalse(any(e[:2]==['agent','start'] for e in self.state()['events']))

    def test_provision_only_cannot_advance_active_reviewer(self):
        self.call('--start'); self.commit('next'); self.call(ref=self.git('rev-parse','HEAD'),ok=False)
        self.assertEqual(self.git('-C',str(self.wt),'rev-parse','HEAD'),self.base)

    def test_canonical_wrapper_not_needed_in_reviewed_commit(self):
        self.git('rm','agent/lsp/elixir_lsp.sh'); self.commit('old revision without wrapper'); old=self.git('rev-parse','HEAD')
        (self.root/'agent/lsp').mkdir(exist_ok=True)
        shutil.copy(LSP_WRAPPER,self.root/'agent/lsp/elixir_lsp.sh')
        self.call('--start',ref=old)
        cfg=tomllib.loads((self.wt/'.codex/config.toml').read_text())['mcp_servers']['elixir-lsp']
        self.assertTrue(Path(cfg['args'][0]).is_file()); self.assertFalse((self.wt/'agent/lsp/elixir_lsp.sh').exists())

    def test_kind_mismatch_and_unsupported_bridge_timeout_refused(self):
        self.call('--kind','claude',ok=False)
        self.assertFalse(self.wt.exists())
        path=self.root/'agent/teams/config.toml'
        path.write_text(CONFIG.replace('mcp_tool_seconds = 120','mcp_tool_seconds = 180'))
        p=self.call(ok=False)
        self.assertIn('compiled 120-second',p.stderr)
        self.assertFalse(self.wt.exists())

    def test_role_inferred_from_agent_name_and_policy_from_config(self):
        path=self.root/'agent/teams/config.toml'
        path.write_text(CONFIG.replace('codex_approval = "never"','codex_approval = "on-request"'))
        args=[sys.executable,str(self.script),'28-review-team-3-lead','--team','3','--pane','wA:pB',
              '--agent','team-3-lead','--review-ref',self.base,'--start']
        p=subprocess.run(args,cwd=self.root,env=self.env,text=True,capture_output=True,timeout=20)
        self.assertEqual(p.returncode,0,p.stderr)
        self.assertIn('fixture-lead',self.state()['launch_argv'])
        self.assertIn('on-request',self.state()['launch_argv'])

    def test_developer_dirty_work_is_preserved_on_resume(self):
        self.call('--start',role='dev',task='29-dev',ref=False)
        wt=self.root/'.worktrees/29-dev'; (wt/'tracked.txt').write_text('unfinished work\n')
        self.call('--start',role='dev',task='29-dev',ref=False)
        self.assertEqual((wt/'tracked.txt').read_text(),'unfinished work\n')
        self.assertEqual(sum(e[:2]==['agent','start'] for e in self.state()['events']),1)

    def test_last_edit_during_shutdown_prevents_advance(self):
        self.call('--start'); s=self.state(); s['stop_dirties']=True; self.save(s)
        self.commit('next'); self.call('--start',ref=self.git('rev-parse','HEAD'),ok=False)
        self.assertEqual(self.git('-C',str(self.wt),'rev-parse','HEAD'),self.base)
        self.assertEqual((self.wt/'tracked.txt').read_text(),'saved at exit\n')

    def test_attached_review_refused_and_partition_preserved(self):
        self.env['MIX_TEST_PARTITION']='2'
        self.call('--start')
        self.assertEqual(self.state()['launch_env']['MIX_TEST_PARTITION'],'2')
        self.git('-C',str(self.wt),'switch','-c','keep-review')
        self.call('--start',ok=False)
        self.assertEqual(self.git('-C',str(self.wt),'branch','--show-current'),'keep-review')

    def test_orphan_foreground_prevents_review_advance(self):
        self.call(); self.commit('next'); new=self.git('rev-parse','HEAD')
        s=self.state(); s['busy']=True; self.save(s)
        for flags in ((), ('--start',)):
            self.call(*flags,ref=new,ok=False)
            self.assertEqual(self.git('-C',str(self.wt),'rev-parse','HEAD'),self.base)

    def test_config_override_reaches_child_and_ack_is_not_echo(self):
        override=self.root/'alternate.toml'; override.write_text(CONFIG.replace('checks_minutes = 30','checks_minutes = 7'))
        self.env['TIPS_TEAM_CONFIG']=str(override)
        self.call('--start')
        s=self.state()
        self.assertEqual(s['launch_env']['TIPS_TEAM_CONFIG'],str(override))
        self.assertEqual(s['launch_env']['TIPS_CHECK_TIMEOUT_SECONDS'],'420')
        wait=next(e for e in s['events'] if e[:2]==['pane','wait-output'])
        marker=wait[wait.index('--match')+1]
        command=next(e[3] for e in s['events'] if e[:2]==['pane','run'])
        self.assertNotIn(marker,command)
        self.assertIn(marker,s['output'])

    def test_requested_tree_conflicts_refused_before_stop_or_checkout(self):
        self.call('--start')
        for relative in ('.codex/config.toml', '.agents/skills/owned.txt'):
            with self.subTest(path=relative):
                path=self.root/relative; path.parent.mkdir(parents=True,exist_ok=True); path.write_text('tracked in review revision\n')
                self.git('add','-f',relative); self.commit('incoming conflict'); sha=self.git('rev-parse','HEAD')
                self.git('reset','--hard',self.base)
                self.call('--start','--force',ref=sha,ok=False)
                self.assertEqual(self.git('-C',str(self.wt),'rev-parse','HEAD'),self.base)
                self.assertFalse(any(e[0]=='stop_agent' for e in self.state()['events']))

    def test_requested_tree_symlink_parent_refused_before_creation(self):
        target=self.root/'symlink-target'; target.mkdir()
        (self.root/'.codex').symlink_to(target)
        self.git('add','-f','.codex'); self.commit('incoming symlink'); sha=self.git('rev-parse','HEAD')
        self.git('reset','--hard',self.base)
        self.call(ref=sha,ok=False)
        self.assertFalse(self.wt.exists())

    def test_one_issue_per_team_across_live_coding_roles(self):
        s=self.state(); s['agents']=[dict(name='team-3-dev',pane_id='wA:pD',agent='codex',foreground_cwd=str(self.root/'.worktrees/27-other-issue'))]; self.save(s)
        self.call('--start',ok=False); self.assertFalse(self.wt.exists())
        s['agents'][0]['foreground_cwd']=str(self.root/'.worktrees/28-same-issue'); self.save(s)
        self.call('--start')

    def test_developer_renamed_issue_reuses_branch_and_worktree(self):
        self.call(role='dev',task='29-original',ref=False)
        wt=self.root/'.worktrees/29-original'; (wt/'tracked.txt').write_text('unfinished\n')
        self.call('--start',role='dev',task='29-renamed',ref=False)
        self.assertEqual(self.state()['cwd'],str(wt))
        self.assertFalse((self.root/'.worktrees/29-renamed').exists())
        self.assertEqual((wt/'tracked.txt').read_text(),'unfinished\n')
        self.assertEqual(self.git('branch','--list','task/29-*').strip(),'+ task/29-original')

    def test_developer_existing_branch_without_worktree_and_ambiguity(self):
        self.git('branch','task/29-original')
        self.call(role='dev',task='29-renamed',ref=False)
        self.assertTrue((self.root/'.worktrees/29-original').is_dir())
        self.git('branch','task/29-duplicate')
        self.call('--start',role='dev',task='29-latest',ref=False,ok=False)
        self.assertFalse((self.root/'.worktrees/29-latest').exists())

    def test_named_agent_must_match_team_and_role(self):
        self.call('--agent','team-2-lead',ok=False)
        self.call('--agent','team-3-dev',ok=False)
        self.assertFalse(self.wt.exists())

    def test_wrapper_explicit_root_is_used_from_main(self):
        self.call(); bridge=self.root/'.elixir-tools/bin/mcp-language-server'
        bridge.write_text('#!/usr/bin/env python3\nimport json,os,sys\nprint(json.dumps({"cwd":os.getcwd(),"argv":sys.argv[1:]}))\n')
        p=subprocess.run(['/bin/sh',str(self.root/'agent/lsp/elixir_lsp.sh'),str(self.wt)],cwd=self.root,env=self.env,text=True,capture_output=True,check=True)
        self.assertEqual(json.loads(p.stdout)['cwd'],str(self.wt))


    def test_codex_lsp_approval_is_scoped_to_four_tools(self):
        self.call('--start')
        cfg=tomllib.loads((self.wt/'.codex/config.toml').read_text())
        server=cfg['mcp_servers']['elixir-lsp']
        self.assertEqual(server['tools'],{name:{'approval_mode':'approve'} for name in ('definition','references','hover','diagnostics')})
        self.assertNotIn('approval_policy',cfg)
        self.assertNotIn('default_tools_approval_mode',server)
        self.assertIn('never',self.state()['launch_argv'])

if __name__=='__main__': unittest.main()
