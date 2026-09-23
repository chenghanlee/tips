"""Lifecycle integration tests: real Git/process trees, disposable Herdr CLI fixture."""

import contextlib
import json
import os
import signal
import subprocess
import tempfile
import time
import unittest
from pathlib import Path
from typing import cast

from team import command_args, execute, require_git_admin

from .test_task_worktree import CONFIG  # Fixed fixture values, independent of production tuning.

SCRIPT = Path(__file__).resolve().parents[1] / "team.py"

HERDR = r"""#!/usr/bin/env python3
import json, os, sys

s = json.load(open(os.environ["HERDR_FIXTURE"]))
a = sys.argv[1:]
with open(os.environ["HERDR_LOG"], "a") as f:
    f.write(json.dumps(a) + "\n")
if a[:2] == ["pane", "get"]:
    r = {"pane": {"pane_id": "wT:p1", "agent": "codex", "foreground_cwd": s["root"]}}
elif a[:2] == ["pane", "process-info"]:
    r = {
        "process_info": {
            "shell_pid": s["shell"],
            "foreground_processes": [
                {"pid": s["pid"], "name": "codex", "cwd": s["root"]},
                {"pid": s["child"], "name": "node", "cwd": s["root"]},
            ],
        }
    }
elif a[:2] == ["agent", "list"]:
    r = {
        "agents": [
            {
                "pane_id": "wT:p1",
                "name": "fixture-client",
                "agent": "codex",
                "foreground_cwd": s["root"],
            }
        ]
    }
elif a[:2] == ["agent", "rename"]:
    if s.get("clear_error"):
        print(json.dumps({"error": {"code": s["clear_error"]}}), file=sys.stderr)
        sys.exit(1)
    try:
        os.kill(s["child"], 0)
    except ProcessLookupError:
        pass
    else:
        sys.exit("Name cleared before descendant exit")
    r = {}
else:
    sys.exit("Unexpected Herdr call: " + repr(a))
print(json.dumps({"result": r}))
"""


class StopAgentTest(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name).resolve()
        self.bin = self.root / "bin"
        self.bin.mkdir()
        (self.bin / "herdr").write_text(HERDR)
        (self.bin / "herdr").chmod(0o755)
        self.config = self.root / "agent-team.toml"
        self.config.write_text(CONFIG.replace("shutdown_seconds = 15", "shutdown_seconds = 1"))
        self.env = dict(
            os.environ,
            PATH=str(self.bin) + ":" + os.environ["PATH"],
            HERDR_ENV="1",
            HERDR_FIXTURE=str(self.root / "state.json"),
            HERDR_LOG=str(self.root / "calls"),
            TIPS_TEAM_CONFIG=str(self.config),
        )
        self.processes: list[subprocess.Popen[bytes]] = []

    def tearDown(self) -> None:
        for p in self.processes:
            if p.poll() is None:
                p.kill()
            p.wait()
        for name in ("client", "child"):
            child_file = self.root / name
            if child_file.exists():
                with contextlib.suppress(ProcessLookupError):
                    os.kill(int(child_file.read_text()), signal.SIGKILL)
        self.tmp.cleanup()

    def client(self, stubborn: bool = False) -> subprocess.Popen[bytes]:
        # The child has its own process group, like Expert's engine nodes.
        child = "import sys; sys.stdin.read()"
        code = """import os, signal, subprocess, sys, time
p=subprocess.Popen([sys.executable,'-c',sys.argv[2]],start_new_session=True,stdin=subprocess.PIPE)
open(sys.argv[1],'w').write(str(p.pid))
def stop(*_):
 p.stdin.close(); status=p.wait(); sys.exit(0 if status == 0 else 99)
signal.signal(signal.SIGTERM, signal.SIG_IGN if sys.argv[3]=='yes' else stop)
while True: time.sleep(.05)
"""
        host = (
            "import subprocess,sys; p=subprocess.Popen(sys.argv[2:]); open(sys"
            '.argv[1],"w").write(str(p.pid)); sys.exit(p.wait())'
        )
        p = subprocess.Popen(
            command_args(
                [
                    "python3",
                    "-c",
                    host,
                    str(self.root / "client"),
                    "python3",
                    "-c",
                    code,
                    str(self.root / "child"),
                    child,
                    "yes" if stubborn else "no",
                ]
            ),
            cwd=self.root,
        )
        self.processes.append(p)
        for _ in range(100):
            if (self.root / "child").exists():
                break
            time.sleep(0.02)
        (self.root / "state.json").write_text(
            json.dumps(
                {
                    "pid": int((self.root / "client").read_text()),
                    "shell": p.pid,
                    "root": str(self.root),
                    "child": int((self.root / "child").read_text()),
                }
            )
        )
        return p

    def stop(self, root: Path | None = None) -> subprocess.CompletedProcess[str]:
        return execute(
            [
                "python3",
                "-c",
                "import sys; sys.path.insert(0,sys.argv[1]); "
                'from team import stop_agent; stop_agent("wT:p1",sys.argv[2])',
                str(SCRIPT.parent),
                str(root or self.root),
            ],
            env=self.env,
            timeout=8,
        )

    def test_source_has_no_side_effects(self) -> None:
        r = execute(
            [
                "python3",
                "-c",
                "import sys; sys.path.insert(0,sys.argv[1]); import team",
                str(SCRIPT.parent),
            ],
            env=self.env,
        )
        assert r.returncode == 0, r.stderr
        assert not (self.root / "calls").exists()

    def test_only_client_signaled_and_separate_group_child_exits_on_eof(self) -> None:
        p = self.client()
        r = self.stop()
        assert r.returncode == 0, r.stderr
        assert p.wait(timeout=2) == 0
        try:
            os.kill(int((self.root / "child").read_text()), 0)
        except ProcessLookupError:
            pass  # Expected: this owned child must have exited.
        else:
            raise AssertionError("Owned child survived graceful shutdown")
        calls = [json.loads(line) for line in (self.root / "calls").read_text().splitlines()]
        assert ["agent", "rename", "wT:p1", "--clear"] in calls

    def test_name_already_released_is_success_after_exit(self) -> None:
        p = self.client()
        state = json.loads((self.root / "state.json").read_text())
        state["clear_error"] = "agent_not_found"
        (self.root / "state.json").write_text(json.dumps(state))
        r = self.stop()
        assert r.returncode == 0, r.stderr
        assert p.wait(timeout=2) == 0

    def test_other_name_clear_errors_still_fail(self) -> None:
        self.client()
        state = json.loads((self.root / "state.json").read_text())
        state["clear_error"] = "permission_denied"
        (self.root / "state.json").write_text(json.dumps(state))
        r = self.stop()
        assert r.returncode != 0
        assert "permission_denied" in r.stderr

    def test_wrong_root_refuses_to_signal(self) -> None:
        p = self.client()
        r = self.stop(self.root / "wrong")
        assert r.returncode != 0
        assert p.poll() is None
        assert "root" in r.stderr.lower()

    def test_timeout_preserves_client_and_reports_failure(self) -> None:
        p = self.client(stubborn=True)
        r = self.stop()
        assert r.returncode != 0
        assert p.poll() is None
        assert "surviv" in r.stderr.lower()


class GitAdminGuardTest(unittest.TestCase):
    def test_writable_probe_preserves_existing_git_files(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            common = Path(tmp)
            (common / "HEAD").write_text("ref: refs/heads/main\n")
            require_git_admin(common, "team-1-tpm")
            assert [path.name for path in common.iterdir()] == ["HEAD"]
            assert (common / "HEAD").read_text() == "ref: refs/heads/main\n"


TEAM_HERDR = r"""#!/usr/bin/env python3
import json, os, sys

p = os.environ["HERDR_FIXTURE"]
s = json.load(open(p))
a = sys.argv[1:]
result = {}
with open(os.environ["HERDR_LOG"], "a") as f:
    f.write(json.dumps(a) + "\n")


def opt(key):
    return a[a.index(key) + 1]


def pane():
    return next(x for x in s["panes"] if x["pane_id"] == a[2])


if a[:2] == ["agent", "list"]:
    result = {"agents": [x for x in s["panes"] if x.get("agent")]}
elif a[:2] == ["workspace", "list"]:
    result = {"workspaces": s["workspaces"]}
elif a[:2] == ["workspace", "create"]:
    w = {"workspace_id": "wT", "label": opt("--label")}
    s["workspaces"].append(w)
    x = {"pane_id": "wT:p1", "cwd": opt("--cwd"), "foreground_cwd": opt("--cwd")}
    s["panes"].append(x)
    result = {"workspace": w, "root_pane": x}
elif a[:2] == ["pane", "list"]:
    result = {"panes": s["panes"]}
elif a[:2] == ["pane", "rename"]:
    pane()["label"] = a[3]
elif a[:2] == ["pane", "split"]:
    x = {
        "pane_id": "wT:p" + str(len(s["panes"]) + 1),
        "cwd": opt("--cwd"),
        "foreground_cwd": opt("--cwd"),
    }
    s["panes"].append(x)
    result = {"pane": x}
elif a[:2] == ["pane", "process-info"]:
    result = {
        "process_info": {
            "shell_pid": 99999999,
            "foreground_processes": [
                {
                    "pid": 99999999,
                    "cwd": next(x for x in s["panes"] if x["pane_id"] == opt("--pane"))[
                        "foreground_cwd"
                    ],
                }
            ],
        }
    }
elif a[:2] == ["pane", "get"]:
    result = {"pane": pane()}
elif a[:2] == ["agent", "get"]:
    result = {
        "agent": next(x for x in s["panes"] if a[2] in (x["pane_id"], x.get("name")))
    }
elif a[:2] == ["agent", "start"]:
    x = next(x for x in s["panes"] if x["pane_id"] == opt("--pane"))
    x.update(agent=opt("--kind"), name=a[2])
elif a[:2] == ["workspace", "close"]:
    s["workspaces"] = []
    s["panes"] = []
elif a[:2] not in (["pane", "run"], ["pane", "wait-output"], ["agent", "prompt"]):
    sys.exit("Unexpected " + repr(a))
json.dump(s, open(p, "w"))
if a[:2] != ["pane", "run"]:
    print(json.dumps({"result": result}))
"""


class TeamLifecycleTest(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name).resolve()
        self.repo = self.root / "repo"
        self.repo.mkdir()
        self.bin = self.root / "bin"
        self.bin.mkdir()
        execute(["git", "init", "-q", "-b", "main", str(self.repo)], check=True)
        for key, value in [("user.email", "fixture@example.com"), ("user.name", "Fixture")]:
            execute(["git", "-C", str(self.repo), "config", key, value], check=True)
        (self.repo / "README").write_text("fixture")
        execute(["git", "-C", str(self.repo), "add", "."], check=True)
        execute(["git", "-C", str(self.repo), "commit", "-qm", "initial"], check=True)
        execute(
            ["git", "-C", str(self.repo), "remote", "add", "origin", str(self.repo)], check=True
        )
        (self.repo / "agent/teams").mkdir(parents=True)
        (self.repo / "agent/teams/team.py").write_text(SCRIPT.read_text())
        (self.repo / "agent/teams/config.toml").write_text(CONFIG)
        (self.bin / "herdr").write_text(TEAM_HERDR)
        (self.bin / "herdr").chmod(0o755)
        (self.bin / "ps").write_text("#!/bin/sh\nexit 0\n")
        (self.bin / "ps").chmod(0o755)
        (self.bin / "docker").write_text('#!/bin/sh\nprintf "%s\\n" "$*" >> "$DOCKER_LOG"\n')
        (self.bin / "docker").chmod(0o755)
        self.state = self.root / "state.json"
        self.state.write_text(json.dumps({"workspaces": [], "panes": []}))
        self.env = dict(
            os.environ,
            PATH=str(self.bin) + ":" + os.environ["PATH"],
            HERDR_ENV="1",
            HERDR_FIXTURE=str(self.state),
            HERDR_LOG=str(self.root / "calls"),
            DOCKER_LOG=str(self.root / "docker-calls"),
        )
        self.env.pop("TIPS_TEAM_CONFIG", None)

    def tearDown(self) -> None:
        self.tmp.cleanup()

    def run_team(self, *args: str) -> subprocess.CompletedProcess[str]:
        return execute(
            ["python3", str(self.repo / "agent/teams/team.py"), *args],
            cwd=self.repo,
            env=self.env,
            timeout=10,
        )

    def calls(self) -> list[list[str]]:
        return [
            cast(list[str], json.loads(line))
            for line in (self.root / "calls").read_text().splitlines()
        ]

    def test_start_team_six_and_repeat_reuses_tpm_without_coding_clients(self) -> None:
        assert self.run_team("start", "6").returncode == 0
        r = self.run_team("start", "6")
        assert r.returncode == 0, r.stderr
        state = json.loads(self.state.read_text())
        assert len(state["panes"]) == 4
        starts = [c for c in self.calls() if c[:2] == ["agent", "start"]]
        assert len(starts) == 1
        assert starts[0][2] == "team-6-tpm"
        setups = [c[3] for c in self.calls() if c[:2] == ["pane", "run"]]
        assert "CLAUDE_AUTOCOMPACT_PCT_OVERRIDE=35" in setups[0]
        assert "--strict-mcp-config" in starts[0]

    def test_repository_configuration_validates_without_herdr_mutation(self) -> None:
        env = dict(self.env, TIPS_TEAM_CONFIG=str(SCRIPT.parent / "config.toml"))
        r = execute(
            [
                "python3",
                "-c",
                "import sys; sys.path.insert(0,sys.argv[1]); "
                "from team import load_config; load_config()",
                str(SCRIPT.parent),
            ],
            env=env,
        )
        assert r.returncode == 0, r.stderr
        assert not (self.root / "calls").exists()

    def test_invalid_config_type_refuses_before_herdr(self) -> None:
        path = self.repo / "agent/teams/config.toml"
        path.write_text(CONFIG.replace("port_base = 4100", 'port_base = "wrong"'))
        result = self.run_team("start", "1")
        assert result.returncode != 0
        assert "team.port_base must be int; received 'wrong'" in result.stderr
        assert not (self.root / "calls").exists()

    def test_config_drives_model_effort_and_team_limit(self) -> None:
        path = self.repo / "agent/teams/config.toml"
        path.write_text(
            path.read_text()
            .replace("max_teams = 6", "max_teams = 2")
            .replace('model = ""', 'model = "configured-model"')
            .replace('effort = "medium"', 'effort = "low"')
        )
        assert self.run_team("start", "3").returncode != 0
        assert not (self.root / "calls").exists()
        r = self.run_team("start", "2")
        assert r.returncode == 0, r.stderr
        start = next(c for c in self.calls() if c[:2] == ["agent", "start"])
        assert "configured-model" in start
        assert "low" in start

    def test_conflicting_pane_prevents_reuse(self) -> None:
        assert self.run_team("start", "1").returncode == 0
        state = json.loads(self.state.read_text())
        state["panes"][0]["name"] = "someone-else"
        self.state.write_text(json.dumps(state))
        r = self.run_team("start", "1")
        assert r.returncode != 0
        assert "conflicting" in r.stderr
        assert len([c for c in self.calls() if c[:2] == ["agent", "start"]]) == 1

    def test_stop_empty_coding_panes_closes_only_owned_workspace(self) -> None:
        assert self.run_team("start", "1").returncode == 0
        state = json.loads(self.state.read_text())
        state["panes"][0].pop("agent")
        self.state.write_text(json.dumps(state))
        r = self.run_team("stop", "1")
        assert r.returncode == 0, r.stderr
        assert json.loads(self.state.read_text())["workspaces"] == []
        assert (self.root / "docker-calls").exists()

    def test_stop_dirty_worktree_preserves_workspace_and_database(self) -> None:
        assert self.run_team("start", "1").returncode == 0
        work = self.repo / ".worktrees/task"
        execute(
            ["git", "-C", str(self.repo), "worktree", "add", "-q", "--detach", str(work)],
            check=True,
        )
        (work / "uncommitted").write_text("keep")
        state = json.loads(self.state.read_text())
        state["panes"][0].pop("agent")
        state["panes"][1]["foreground_cwd"] = str(work)
        self.state.write_text(json.dumps(state))
        self.calls_before_stop = self.calls()
        r = self.run_team("stop", "1")
        assert r.returncode != 0
        assert "Dirty worktree" in r.stderr
        assert not any(
            c[:2] == ["pane", "process-info"] for c in self.calls()[len(self.calls_before_stop) :]
        )
        assert work.exists()
        assert json.loads(self.state.read_text())["workspaces"]
        assert not (self.root / "docker-calls").exists()

    def test_clean_unmerged_worktree_refuses_before_any_stop(self) -> None:
        assert self.run_team("start", "1").returncode == 0
        work = self.repo / ".worktrees/task"
        execute(
            ["git", "-C", str(self.repo), "worktree", "add", "-q", "--detach", str(work)],
            check=True,
        )
        (work / "new").write_text("unmerged")
        execute(["git", "-C", str(work), "add", "new"], check=True)
        execute(["git", "-C", str(work), "commit", "-qm", "unmerged"], check=True)
        state = json.loads(self.state.read_text())
        state["panes"][0].pop("agent")
        state["panes"][1]["foreground_cwd"] = str(work)
        self.state.write_text(json.dumps(state))
        before = len(self.calls())
        r = self.run_team("stop", "1")
        assert r.returncode != 0
        assert "Unmerged worktree" in r.stderr
        assert not any(c[:2] == ["pane", "process-info"] for c in self.calls()[before:])
        assert not (self.root / "docker-calls").exists()
        assert work.exists()

    @unittest.skipIf(os.geteuid() == 0, "root bypasses directory permissions")
    def test_stop_with_unwritable_main_git_refers_to_lead_tpm_before_fetch(self) -> None:
        assert self.run_team("start", "1").returncode == 0
        work = self.repo / ".worktrees/task"
        execute(
            ["git", "-C", str(self.repo), "worktree", "add", "-q", "--detach", str(work)],
            check=True,
        )
        state = json.loads(self.state.read_text())
        state["panes"][0].pop("agent")
        state["panes"][1]["foreground_cwd"] = str(work)
        self.state.write_text(json.dumps(state))
        git_dir = self.repo / ".git"
        before = len(self.calls())
        git_dir.chmod(0o555)
        try:
            r = self.run_team("stop", "1")
        finally:
            git_dir.chmod(0o755)
        assert r.returncode != 0
        assert "ask lead-tpm to run it from the main checkout" in r.stderr
        assert "fetch" not in r.stderr
        assert not (git_dir / "FETCH_HEAD").exists()
        assert not any(c[:2] == ["pane", "process-info"] for c in self.calls()[before:])
        assert not (self.root / "docker-calls").exists()
        assert work.exists()
        assert json.loads(self.state.read_text())["workspaces"]

    def test_ambiguous_team_partition_names_refuse_before_database_access(self) -> None:
        assert self.run_team("start", "1").returncode == 0
        path = self.repo / "agent/teams/config.toml"
        path.write_text(path.read_text().replace("max_teams = 6", "max_teams = 10"))
        (self.bin / "docker").write_text(
            '#!/bin/sh\nprintf "tips_test_t1\\ntips_test_t10\\n"\nprintf "%s\\n" "$'
            '*" >> "$DOCKER_LOG"\n'
        )
        r = self.run_team("stop", "1")
        assert r.returncode != 0
        assert "overlapping database" in r.stderr
        assert not (self.root / "docker-calls").exists()

    def test_tpm_brief_routes_readiness_to_lead_tpm(self) -> None:
        assert self.run_team("start", "1").returncode == 0
        prompt = next(c[3] for c in self.calls() if c[:2] == ["agent", "prompt"])
        assert "Report readiness to lead-tpm" in prompt
        assert "talk only to the team tech lead" in prompt
        assert "every task_worktree.py run the lead requests" in prompt
        assert "let the reply wake you" in prompt

    def test_lead_ui_must_share_lead_partition(self) -> None:
        (self.repo / "agent/teams/config.toml").write_text(
            CONFIG + '\n[roles.lead_ui]\nkind = "claude"\nmodel = ""\neffort = "high"\n'
            'db_suffix = "l"\nport_offset = 1\n'
        )
        r = self.run_team("start", "1")
        assert r.returncode != 0
        assert "roles.lead_ui must share" in r.stderr

    def test_lead_start_applies_config_but_has_no_stop_subcommand(self) -> None:
        r = self.run_team("start", "lead")
        assert r.returncode == 0, r.stderr
        assert len(json.loads(self.state.read_text())["panes"]) == 1
        r = self.run_team("stop", "lead")
        assert r.returncode != 0

    def test_stop_merged_worktree_drops_only_team_databases_then_removes_checkout(self) -> None:
        assert self.run_team("start", "1").returncode == 0
        work = self.repo / ".worktrees/task"
        execute(
            ["git", "-C", str(self.repo), "worktree", "add", "-q", "--detach", str(work)],
            check=True,
        )
        state = json.loads(self.state.read_text())
        state["panes"][0].pop("agent")
        state["panes"][1]["foreground_cwd"] = str(work)
        self.state.write_text(json.dumps(state))
        (self.bin / "docker").write_text(
            '#!/bin/sh\nprintf "%s\\n" "$*" >> "$DOCKER_LOG"\ncase "$*" in *SELEC'
            'T*) printf "tips_test_t1\\ntips_test_t1r2\\ntips_test_t2\\n";; esac\n'
        )
        r = self.run_team("stop", "1")
        assert r.returncode == 0, r.stderr
        assert not work.exists()
        assert json.loads(self.state.read_text())["workspaces"] == []
        calls = (self.root / "docker-calls").read_text()
        assert 'DROP DATABASE "tips_test_t1"' in calls
        assert 'DROP DATABASE "tips_test_t1r2"' in calls
        assert 'DROP DATABASE "tips_test_t2"' not in calls


if __name__ == "__main__":
    unittest.main()
