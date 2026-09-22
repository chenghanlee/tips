"""Lifecycle integration tests: real Git/process trees, disposable Herdr CLI fixture."""
import json
import os
from pathlib import Path
import signal
import subprocess
import tempfile
import time
import unittest

SCRIPT = Path(__file__).with_name('team.py').resolve()
from test_task_worktree import CONFIG  # Fixed fixture values, independent of production tuning.

HERDR = '''#!/usr/bin/env python3
import json, os, sys
s=json.load(open(os.environ['HERDR_FIXTURE']))
a=sys.argv[1:]
with open(os.environ['HERDR_LOG'],'a') as f: f.write(json.dumps(a)+'\\n')
if a[:2]==['pane','get']:
 r={'pane':{'pane_id':'wT:p1','agent':'codex','foreground_cwd':s['root']}}
elif a[:2]==['pane','process-info']:
 r={'process_info':{'shell_pid':s['shell'], 'foreground_processes':[{'pid':s['pid'],'name':'codex','cwd':s['root']},{'pid':s['child'],'name':'node','cwd':s['root']}]}}
elif a[:2]==['agent','list']:
 r={'agents':[{'pane_id':'wT:p1','name':'fixture-client','agent':'codex','foreground_cwd':s['root']}]}
elif a[:2]==['agent','rename']:
 if s.get('clear_error'):
  print(json.dumps({'error':{'code':s['clear_error']}}),file=sys.stderr); sys.exit(1)
 try: os.kill(s['child'],0)
 except ProcessLookupError: pass
 else: sys.exit('Name cleared before descendant exit')
 r={}
else:
 sys.exit('Unexpected Herdr call: '+repr(a))
print(json.dumps({'result':r}))
'''

class StopAgentTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name).resolve()
        self.bin = self.root / 'bin'
        self.bin.mkdir()
        (self.bin / 'herdr').write_text(HERDR)
        (self.bin / 'herdr').chmod(0o755)
        self.config = self.root / 'agent-team.toml'
        self.config.write_text(CONFIG.replace('shutdown_seconds = 15', 'shutdown_seconds = 1'))
        self.env = dict(os.environ, PATH=str(self.bin)+':'+os.environ['PATH'], HERDR_ENV='1',
                        HERDR_FIXTURE=str(self.root/'state.json'), HERDR_LOG=str(self.root/'calls'),
                        TIPS_TEAM_CONFIG=str(self.config))
        self.processes = []

    def tearDown(self):
        for p in self.processes:
            if p.poll() is None:
                p.kill()
            p.wait()
        for name in ('client', 'child'):
            child_file = self.root/name
            if child_file.exists():
                try: os.kill(int(child_file.read_text()), signal.SIGKILL)
                except ProcessLookupError: pass
        self.tmp.cleanup()

    def client(self, stubborn=False):
        # The child has its own process group, like Expert's engine nodes.
        child = 'import sys; sys.stdin.read()'
        code = '''import os, signal, subprocess, sys, time
p=subprocess.Popen([sys.executable,'-c',sys.argv[2]],start_new_session=True,stdin=subprocess.PIPE)
open(sys.argv[1],'w').write(str(p.pid))
def stop(*_):
 p.stdin.close(); status=p.wait(); sys.exit(0 if status == 0 else 99)
signal.signal(signal.SIGTERM, signal.SIG_IGN if sys.argv[3]=='yes' else stop)
while True: time.sleep(.05)
'''
        host = 'import subprocess,sys; p=subprocess.Popen(sys.argv[2:]); open(sys.argv[1],"w").write(str(p.pid)); sys.exit(p.wait())'
        p = subprocess.Popen(['python3','-c',host,str(self.root/'client'),'python3','-c',code,str(self.root/'child'),child,'yes' if stubborn else 'no'], cwd=self.root)
        self.processes.append(p)
        for _ in range(100):
            if (self.root/'child').exists(): break
            time.sleep(.02)
        (self.root/'state.json').write_text(json.dumps({'pid':int((self.root/'client').read_text()),'shell':p.pid,'root':str(self.root),'child':int((self.root/'child').read_text())}))
        return p

    def stop(self, root=None):
        return subprocess.run(['python3','-c','import sys; sys.path.insert(0,sys.argv[1]); from team import stop_agent; stop_agent("wT:p1",sys.argv[2])',str(SCRIPT.parent),str(root or self.root)],
                              env=self.env,text=True,capture_output=True,timeout=8)

    def test_source_has_no_side_effects(self):
        r=subprocess.run(['python3','-c','import sys; sys.path.insert(0,sys.argv[1]); import team',str(SCRIPT.parent)],env=self.env,text=True,capture_output=True)
        self.assertEqual(r.returncode,0,r.stderr)
        self.assertFalse((self.root/'calls').exists())

    def test_only_client_signaled_and_separate_group_child_exits_on_eof(self):
        p=self.client()
        r=self.stop()
        self.assertEqual(r.returncode,0,r.stderr)
        self.assertEqual(p.wait(timeout=2),0)
        with self.assertRaises(ProcessLookupError): os.kill(int((self.root/'child').read_text()),0)
        calls=[json.loads(line) for line in (self.root/'calls').read_text().splitlines()]
        self.assertIn(['agent','rename','wT:p1','--clear'],calls)

    def test_name_already_released_is_success_after_exit(self):
        p=self.client()
        state=json.loads((self.root/'state.json').read_text()); state['clear_error']='agent_not_found'
        (self.root/'state.json').write_text(json.dumps(state))
        r=self.stop(); self.assertEqual(r.returncode,0,r.stderr)
        self.assertEqual(p.wait(timeout=2),0)

    def test_other_name_clear_errors_still_fail(self):
        self.client()
        state=json.loads((self.root/'state.json').read_text()); state['clear_error']='permission_denied'
        (self.root/'state.json').write_text(json.dumps(state))
        r=self.stop(); self.assertNotEqual(r.returncode,0)
        self.assertIn('permission_denied',r.stderr)

    def test_wrong_root_refuses_to_signal(self):
        p=self.client()
        r=self.stop(self.root/'wrong')
        self.assertNotEqual(r.returncode,0)
        self.assertIsNone(p.poll())
        self.assertIn('root',r.stderr.lower())

    def test_timeout_preserves_client_and_reports_failure(self):
        p=self.client(stubborn=True)
        r=self.stop()
        self.assertNotEqual(r.returncode,0)
        self.assertIsNone(p.poll())
        self.assertIn('surviv',r.stderr.lower())

TEAM_HERDR = r'''#!/usr/bin/env python3
import json, os, sys
p=os.environ['HERDR_FIXTURE']
s=json.load(open(p)); a=sys.argv[1:]; result={}
with open(os.environ['HERDR_LOG'],'a') as f: f.write(json.dumps(a)+'\n')
def opt(key): return a[a.index(key)+1]
def pane(): return next(x for x in s['panes'] if x['pane_id']==a[2])
if a[:2]==['agent','list']: result={'agents':[x for x in s['panes'] if x.get('agent')]}
elif a[:2]==['workspace','list']: result={'workspaces':s['workspaces']}
elif a[:2]==['workspace','create']:
 w={'workspace_id':'wT','label':opt('--label')}; s['workspaces'].append(w)
 x={'pane_id':'wT:p1','cwd':opt('--cwd'),'foreground_cwd':opt('--cwd')}; s['panes'].append(x)
 result={'workspace':w,'root_pane':x}
elif a[:2]==['pane','list']: result={'panes':s['panes']}
elif a[:2]==['pane','rename']: pane()['label']=a[3]
elif a[:2]==['pane','split']:
 x={'pane_id':'wT:p'+str(len(s['panes'])+1),'cwd':opt('--cwd'),'foreground_cwd':opt('--cwd')}; s['panes'].append(x); result={'pane':x}
elif a[:2]==['pane','process-info']:
 result={'process_info':{'shell_pid':99999999,'foreground_processes':[{'pid':99999999,'cwd':next(x for x in s['panes'] if x['pane_id']==opt('--pane'))['foreground_cwd']}]}}
elif a[:2]==['pane','get']: result={'pane':pane()}
elif a[:2]==['agent','get']:
 result={'agent':next(x for x in s['panes'] if a[2] in (x['pane_id'],x.get('name')))}
elif a[:2]==['agent','start']:
 x=next(x for x in s['panes'] if x['pane_id']==opt('--pane')); x.update(agent=opt('--kind'),name=a[2])
elif a[:2]==['workspace','close']: s['workspaces']=[]; s['panes']=[]
elif a[:2] not in (['pane','run'],['pane','wait-output'],['agent','prompt']): sys.exit('Unexpected '+repr(a))
json.dump(s,open(p,'w'))
if a[:2] != ['pane','run']: print(json.dumps({'result':result}))
'''

class TeamLifecycleTest(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory()
        self.root=Path(self.tmp.name).resolve()
        self.repo=self.root/'repo'; self.repo.mkdir()
        self.bin=self.root/'bin'; self.bin.mkdir()
        subprocess.run(['git','init','-q','-b','main',str(self.repo)],check=True)
        for key,value in [('user.email','fixture@example.com'),('user.name','Fixture')]:
            subprocess.run(['git','-C',str(self.repo),'config',key,value],check=True)
        (self.repo/'README').write_text('fixture')
        subprocess.run(['git','-C',str(self.repo),'add','.'],check=True)
        subprocess.run(['git','-C',str(self.repo),'commit','-qm','initial'],check=True)
        subprocess.run(['git','-C',str(self.repo),'remote','add','origin',str(self.repo)],check=True)
        (self.repo/'agent/teams').mkdir(parents=True)
        (self.repo/'agent/teams/team.py').write_text(SCRIPT.read_text())
        (self.repo/'agent/teams/config.toml').write_text(CONFIG)
        (self.bin/'herdr').write_text(TEAM_HERDR); (self.bin/'herdr').chmod(0o755)
        (self.bin/'ps').write_text('#!/bin/sh\nexit 0\n'); (self.bin/'ps').chmod(0o755)
        (self.bin/'docker').write_text('#!/bin/sh\nprintf "%s\\n" "$*" >> "$DOCKER_LOG"\n'); (self.bin/'docker').chmod(0o755)
        self.state=self.root/'state.json'; self.state.write_text(json.dumps({'workspaces':[],'panes':[]}))
        self.env=dict(os.environ,PATH=str(self.bin)+':'+os.environ['PATH'],HERDR_ENV='1',HERDR_FIXTURE=str(self.state),HERDR_LOG=str(self.root/'calls'),DOCKER_LOG=str(self.root/'docker-calls'))
        self.env.pop('TIPS_TEAM_CONFIG',None)

    def tearDown(self): self.tmp.cleanup()

    def run_team(self,*args):
        return subprocess.run(['python3',str(self.repo/'agent/teams/team.py'),*args],cwd=self.repo,env=self.env,text=True,capture_output=True,timeout=10)

    def calls(self): return [json.loads(line) for line in (self.root/'calls').read_text().splitlines()]

    def test_start_team_six_and_repeat_reuses_tpm_without_coding_clients(self):
        self.assertEqual(self.run_team('start','6').returncode,0)
        r=self.run_team('start','6'); self.assertEqual(r.returncode,0,r.stderr)
        state=json.loads(self.state.read_text()); self.assertEqual(len(state['panes']),4)
        starts=[c for c in self.calls() if c[:2]==['agent','start']]
        self.assertEqual(len(starts),1); self.assertEqual(starts[0][2],'team-6-tpm')
        setups=[c[3] for c in self.calls() if c[:2]==['pane','run']]
        self.assertIn('CLAUDE_AUTOCOMPACT_PCT_OVERRIDE=35',setups[0])
        self.assertIn('--strict-mcp-config',starts[0])

    def test_repository_configuration_validates_without_herdr_mutation(self):
        env=dict(self.env,TIPS_TEAM_CONFIG=str(SCRIPT.parent/'config.toml'))
        r=subprocess.run(['python3','-c','import sys; sys.path.insert(0,sys.argv[1]); from team import load_config; load_config()',str(SCRIPT.parent)],env=env,text=True,capture_output=True)
        self.assertEqual(r.returncode,0,r.stderr)
        self.assertFalse((self.root/'calls').exists())

    def test_config_drives_model_effort_and_team_limit(self):
        path=self.repo/'agent/teams/config.toml'
        path.write_text(path.read_text().replace('max_teams = 6','max_teams = 2').replace('model = ""','model = "configured-model"').replace('effort = "medium"','effort = "low"'))
        self.assertNotEqual(self.run_team('start','3').returncode,0)
        self.assertFalse((self.root/'calls').exists())
        r=self.run_team('start','2'); self.assertEqual(r.returncode,0,r.stderr)
        start=next(c for c in self.calls() if c[:2]==['agent','start'])
        self.assertIn('configured-model',start); self.assertIn('low',start)

    def test_conflicting_pane_prevents_reuse(self):
        self.assertEqual(self.run_team('start','1').returncode,0)
        state=json.loads(self.state.read_text()); state['panes'][0]['name']='someone-else'; self.state.write_text(json.dumps(state))
        r=self.run_team('start','1'); self.assertNotEqual(r.returncode,0); self.assertIn('conflicting',r.stderr)
        self.assertEqual(len([c for c in self.calls() if c[:2]==['agent','start']]),1)

    def test_stop_empty_coding_panes_closes_only_owned_workspace(self):
        self.assertEqual(self.run_team('start','1').returncode,0)
        state=json.loads(self.state.read_text()); state['panes'][0].pop('agent'); self.state.write_text(json.dumps(state))
        r=self.run_team('stop','1'); self.assertEqual(r.returncode,0,r.stderr)
        self.assertEqual(json.loads(self.state.read_text())['workspaces'],[])
        self.assertTrue((self.root/'docker-calls').exists())

    def test_stop_dirty_worktree_preserves_workspace_and_database(self):
        self.assertEqual(self.run_team('start','1').returncode,0)
        work=self.repo/'.worktrees/task'
        subprocess.run(['git','-C',str(self.repo),'worktree','add','-q','--detach',str(work)],check=True)
        (work/'uncommitted').write_text('keep')
        state=json.loads(self.state.read_text()); state['panes'][0].pop('agent'); state['panes'][1]['foreground_cwd']=str(work); self.state.write_text(json.dumps(state))
        self.calls_before_stop=self.calls()
        r=self.run_team('stop','1'); self.assertNotEqual(r.returncode,0)
        self.assertIn('Dirty worktree',r.stderr)
        self.assertFalse(any(c[:2]==['pane','process-info'] for c in self.calls()[len(self.calls_before_stop):]))
        self.assertTrue(work.exists()); self.assertTrue(json.loads(self.state.read_text())['workspaces'])
        self.assertFalse((self.root/'docker-calls').exists())

    def test_clean_unmerged_worktree_refuses_before_any_stop(self):
        self.assertEqual(self.run_team('start','1').returncode,0)
        work=self.repo/'.worktrees/task'
        subprocess.run(['git','-C',str(self.repo),'worktree','add','-q','--detach',str(work)],check=True)
        (work/'new').write_text('unmerged')
        subprocess.run(['git','-C',str(work),'add','new'],check=True)
        subprocess.run(['git','-C',str(work),'commit','-qm','unmerged'],check=True)
        state=json.loads(self.state.read_text()); state['panes'][0].pop('agent'); state['panes'][1]['foreground_cwd']=str(work); self.state.write_text(json.dumps(state))
        before=len(self.calls()); r=self.run_team('stop','1')
        self.assertNotEqual(r.returncode,0); self.assertIn('Unmerged worktree',r.stderr)
        self.assertFalse(any(c[:2]==['pane','process-info'] for c in self.calls()[before:]))
        self.assertFalse((self.root/'docker-calls').exists()); self.assertTrue(work.exists())

    def test_ambiguous_team_partition_names_refuse_before_database_access(self):
        self.assertEqual(self.run_team('start','1').returncode,0)
        path=self.repo/'agent/teams/config.toml'
        path.write_text(path.read_text().replace('max_teams = 6','max_teams = 10'))
        (self.bin/'docker').write_text('#!/bin/sh\nprintf "tips_test_t1\\ntips_test_t10\\n"\nprintf "%s\\n" "$*" >> "$DOCKER_LOG"\n')
        r=self.run_team('stop','1'); self.assertNotEqual(r.returncode,0)
        self.assertIn('overlapping database',r.stderr)
        self.assertFalse((self.root/'docker-calls').exists())

    def test_tpm_brief_routes_readiness_to_lead_tpm(self):
        self.assertEqual(self.run_team('start','1').returncode,0)
        prompt=next(c[3] for c in self.calls() if c[:2]==['agent','prompt'])
        self.assertIn('Report readiness to lead-tpm',prompt)

    def test_lead_start_applies_config_but_has_no_stop_subcommand(self):
        r=self.run_team('start','lead'); self.assertEqual(r.returncode,0,r.stderr)
        self.assertEqual(len(json.loads(self.state.read_text())['panes']),1)
        r=self.run_team('stop','lead'); self.assertNotEqual(r.returncode,0)

    def test_stop_merged_worktree_drops_only_team_databases_then_removes_checkout(self):
        self.assertEqual(self.run_team('start','1').returncode,0)
        work=self.repo/'.worktrees/task'
        subprocess.run(['git','-C',str(self.repo),'worktree','add','-q','--detach',str(work)],check=True)
        state=json.loads(self.state.read_text()); state['panes'][0].pop('agent'); state['panes'][1]['foreground_cwd']=str(work); self.state.write_text(json.dumps(state))
        (self.bin/'docker').write_text('#!/bin/sh\nprintf "%s\\n" "$*" >> "$DOCKER_LOG"\ncase "$*" in *SELECT*) printf "tips_test_t1\\ntips_test_t1r2\\ntips_test_t2\\n";; esac\n')
        r=self.run_team('stop','1'); self.assertEqual(r.returncode,0,r.stderr)
        self.assertFalse(work.exists()); self.assertEqual(json.loads(self.state.read_text())['workspaces'],[])
        calls=(self.root/'docker-calls').read_text()
        self.assertIn('DROP DATABASE "tips_test_t1"',calls)
        self.assertIn('DROP DATABASE "tips_test_t1r2"',calls)
        self.assertNotIn('DROP DATABASE "tips_test_t2"',calls)

if __name__ == '__main__': unittest.main()
