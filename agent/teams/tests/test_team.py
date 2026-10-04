"""Lifecycle integration tests: real Git/process trees, disposable Herdr CLI fixture."""

import contextlib
import json
import os
import signal
import subprocess
import tempfile
import time
import unittest
from collections.abc import Sequence
from pathlib import Path
from typing import cast

from task_worktree import bound_command
from team import command_args, execute, require_git_admin

# Fixed fixture values, independent of production tuning; one 40-column pane model.
from .test_task_worktree import CONFIG, MIX_PROJECT, PANE_SCREEN

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
    def alive(pid):
        try:
            os.kill(pid, 0)
        except ProcessLookupError:
            return False
        return True

    procs = [
        {"pid": s["pid"], "name": "codex", "argv0": "codex", "cwd": s["root"]},
        {"pid": s["child"], "name": "node", "argv0": "node", "cwd": s["root"]},
    ]
    procs = [x for x in procs if alive(x["pid"])]
    if not procs and s.get("replacement"):
        procs = [{"pid": 424242, "name": "2.1.288", "argv0": "claude", "cwd": s["root"]}]
    if not procs:
        procs = [{"pid": s["shell"], "name": "zsh", "argv0": "zsh", "cwd": s["root"]}]
    r = {
        "process_info": {
            "shell_pid": s["shell"],
            "foreground_process_group_id": procs[0]["pid"],
            "foreground_processes": procs,
        }
    }
elif a[:2] == ["agent", "list"]:
    r = {
        "agents": [
            {
                "pane_id": "wT:p1",
                "name": "fixture-client",
                "agent": s.get("listed_kind", "codex"),
                "foreground_cwd": s["root"],
            }
        ]
    }
    if s.get("omit_kind"):
        del r["agents"][0]["agent"]
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

REAL_DEXTER = "opt-in real Dexter: TIPS_TEST_REAL_DEXTER and DEXTER_ELIXIR_LIB_ROOT"


def real_bound_command(root: Path) -> Path:
    """Write the production bound command for root over the real binary."""
    wrapper = root / ".dexter/dexter.sh"
    wrapper.parent.mkdir()
    wrapper.write_text(
        bound_command(
            Path(os.environ["TIPS_TEST_REAL_DEXTER"]) / "vendor/dexter",
            root,
            os.environ["DEXTER_ELIXIR_LIB_ROOT"],
        )
    )
    return wrapper


def daemon_pid(root: Path) -> int | None:
    """The real daemon serving root, found as Dexter finds it: by its arguments."""
    rows = execute(["ps", "-A", "-ww", "-o", "pid=,args="], check=True).stdout.splitlines()
    pids = [int(row.split()[0]) for row in rows if row.rstrip().endswith(f"dexter daemon {root}")]
    assert len(pids) <= 1, pids
    return pids[0] if pids else None


def wait_until_stopped(root: Path) -> None:
    for _ in range(100):
        if daemon_pid(root) is None:
            return
        time.sleep(0.05)
    raise AssertionError(f"Dexter daemon still serves {root}")


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
        wrapper = self.root / ".dexter/dexter.sh"
        if wrapper.exists():
            # A real daemon outlives its clients; stop it before its root disappears.
            execute(["/bin/sh", wrapper, "stop", "--force"], input_text="")
        self.tmp.cleanup()

    def client(
        self, stubborn: bool = False, child: Sequence[str | Path] | None = None
    ) -> subprocess.Popen[bytes]:
        # The child has its own process group, like Expert's engine nodes.
        child = child or ["python3", "-c", "import sys; sys.stdin.read()"]
        code = """import os, signal, subprocess, sys, time
p=subprocess.Popen(sys.argv[3:],start_new_session=True,stdin=subprocess.PIPE,
                   stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
open(sys.argv[1],'w').write(str(p.pid))
def stop(*_):
 p.stdin.close(); status=p.wait(); sys.exit(0 if status == 0 else 99)
signal.signal(signal.SIGTERM, signal.SIG_IGN if sys.argv[2]=='yes' else stop)
while True: time.sleep(.05)
"""
        for name in ("client", "child"):
            (self.root / name).unlink(missing_ok=True)
        host = (
            "import subprocess,sys; p=subprocess.Popen(sys.argv[2:]); open(sys"
            '.argv[1],"w").write(str(p.pid)); sys.exit(p.wait())'
        )
        # Reviewed S603: fixed synthetic argv for an owned test child, no shell.
        p = subprocess.Popen(  # noqa: S603
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
                    "yes" if stubborn else "no",
                    *child,
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

    def test_released_kind_with_stale_name_succeeds_after_exit(self) -> None:
        for omit_kind in (False, True):
            with self.subTest(omit_kind=omit_kind):
                client = self.client()
                state = json.loads((self.root / "state.json").read_text())
                state.update(listed_kind=None, omit_kind=omit_kind)
                (self.root / "state.json").write_text(json.dumps(state))
                (self.root / "calls").unlink(missing_ok=True)
                result = self.stop()
                assert result.returncode == 0, result.stderr
                assert client.wait(timeout=2) == 0
                calls = [
                    json.loads(line) for line in (self.root / "calls").read_text().splitlines()
                ]
                assert ["agent", "rename", "wT:p1", "--clear"] in calls

    def test_replacement_client_after_exit_preserves_its_name(self) -> None:
        for listed_kind in ("codex", None):
            with self.subTest(listed_kind=listed_kind):
                client = self.client()
                state = json.loads((self.root / "state.json").read_text())
                state.update(replacement=True, listed_kind=listed_kind)
                (self.root / "state.json").write_text(json.dumps(state))
                (self.root / "calls").unlink(missing_ok=True)
                result = self.stop()
                assert result.returncode != 0
                assert "owner changed during shutdown" in result.stderr
                assert "occupied=True" in result.stderr
                assert "leader_pid=424242" in result.stderr
                assert "leader_argv0='claude'" in result.stderr
                assert client.wait(timeout=2) == 0
                calls = [
                    json.loads(line) for line in (self.root / "calls").read_text().splitlines()
                ]
                assert ["agent", "rename", "wT:p1", "--clear"] not in calls

    def test_different_kind_at_shell_preserves_its_name(self) -> None:
        client = self.client()
        state = json.loads((self.root / "state.json").read_text())
        state["listed_kind"] = "claude"
        (self.root / "state.json").write_text(json.dumps(state))
        result = self.stop()
        assert result.returncode != 0
        assert "owner changed during shutdown" in result.stderr
        assert "previous_kind='codex', listed_kind='claude'" in result.stderr
        assert "occupied=False" in result.stderr
        assert client.wait(timeout=2) == 0
        calls = [json.loads(line) for line in (self.root / "calls").read_text().splitlines()]
        assert ["agent", "rename", "wT:p1", "--clear"] not in calls

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

    @unittest.skipUnless(os.environ.get("TIPS_TEST_REAL_DEXTER"), REAL_DEXTER)
    def test_client_stop_leaves_real_daemons_started_by_a_client_query(self) -> None:
        (self.root / "mix.exs").write_text(MIX_PROJECT)
        wrapper = real_bound_command(self.root)
        query = ["/bin/sh", wrapper, "query", "workspace-symbols", "--wait", "20s", "MixProject"]
        # A client's query starts the daemon and ends; the daemon is then nobody's child.
        client = self.client(child=query)
        child = int((self.root / "child").read_text())
        for _ in range(600):
            if daemon_pid(self.root) and execute(["ps", "-p", str(child)]).returncode:
                break
            time.sleep(0.05)
        daemon = daemon_pid(self.root)
        assert daemon, "The query did not start a daemon"
        stopped = self.stop()
        assert stopped.returncode == 0, stopped.stderr
        client.wait(timeout=5)
        # The daemon belongs to the workspace: it outlives its client and still answers.
        assert daemon_pid(self.root) == daemon
        assert "Fixture.MixProject" in execute(query, input_text="", check=True).stdout
        # Retirement stops it with the same bound command.
        execute(["/bin/sh", wrapper, "stop"], input_text="", check=True)
        wait_until_stopped(self.root)


class GitAdminGuardTest(unittest.TestCase):
    def test_writable_probe_preserves_existing_git_files(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            common = Path(tmp)
            (common / "HEAD").write_text("ref: refs/heads/main\n")
            require_git_admin(common)
            assert [path.name for path in common.iterdir()] == ["HEAD"]
            assert (common / "HEAD").read_text() == "ref: refs/heads/main\n"


TEAM_HERDR = (
    r"""#!/usr/bin/env python3
import json, os, subprocess, sys
"""
    + PANE_SCREEN
    + r"""

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
    x = next(x for x in s["panes"] if x["pane_id"] == opt("--pane"))
    leader = 88888888 if x.get("agent") else 99999999
    result = {
        "process_info": {
            "shell_pid": 99999999,
            "foreground_process_group_id": leader,
            "foreground_processes": [
                {"pid": leader, "cwd": x["cwd"]},
                {"pid": 88888889, "cwd": "/opt/homebrew/lsp-child"},
            ][: 2 if x.get("agent") else 1],
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
elif a[:2] == ["pane", "run"]:
    # Execute the setup; a lost setup leaves only the typed command echo on screen.
    output = subprocess.run(["bash", "-c", a[3]], capture_output=True, text=True).stdout
    s["screen"] = a[3] + "\n" + ("" if s.get("setup_lost") else output)
elif a[:2] == ["pane", "wait-output"]:
    if opt("--source") not in ("visible", "recent", "recent-unwrapped"):
        sys.exit("invalid --source " + opt("--source"))
    if opt("--match") not in pane_screen(s.get("screen", ""), opt("--source")):
        sys.exit("timed out waiting for output match")
elif a[:2] != ["agent", "prompt"]:
    sys.exit("Unexpected " + repr(a))
json.dump(s, open(p, "w"))
if a[:2] != ["pane", "run"]:
    print(json.dumps({"result": result}))
"""
)


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
        # A stop-time write lands between the two cleanliness checks (ps runs only in stop()).
        (self.bin / "ps").write_text(
            '#!/bin/sh\n[ -n "$RACE_DIRTY_FILE" ] && echo raced > "$RACE_DIRTY_FILE"\nexit 0\n'
        )
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

    def codex_coordinator_arguments(self) -> list[str]:
        """The client arguments of a lead TPM launched as Codex."""
        path = self.repo / "agent/teams/config.toml"
        path.write_text(
            CONFIG.replace('[roles.lead_tpm]\nkind = "claude"', '[roles.lead_tpm]\nkind = "codex"')
        )
        started = self.run_team("start", "lead")
        assert started.returncode == 0, started.stderr
        start = next(c for c in self.calls() if c[:2] == ["agent", "start"])
        assert start[start.index("--kind") + 1] == "codex"
        return start[start.index("--") + 1 :]

    def test_start_team_six_and_repeat_creates_three_shell_panes_and_no_client(self) -> None:
        assert self.run_team("start", "6").returncode == 0
        r = self.run_team("start", "6")
        assert r.returncode == 0, r.stderr
        state = json.loads(self.state.read_text())
        assert [pane["label"] for pane in state["panes"]] == [
            "team-6-dev",
            "team-6-test",
            "team-6-lead",
        ]
        assert not any(pane.get("agent") for pane in state["panes"])
        launches = (["agent", "start"], ["agent", "prompt"], ["pane", "run"])
        assert not any(c[:2] in launches for c in self.calls())

    def test_start_lead_and_repeat_reuses_the_coordinator(self) -> None:
        assert self.run_team("start", "lead").returncode == 0
        r = self.run_team("start", "lead")
        assert r.returncode == 0, r.stderr
        starts = [c for c in self.calls() if c[:2] == ["agent", "start"]]
        assert len(starts) == 1
        assert starts[0][2] == "lead-tpm"
        setups = [c[3] for c in self.calls() if c[:2] == ["pane", "run"]]
        assert "CLAUDE_AUTOCOMPACT_PCT_OVERRIDE=35" in setups[0]
        assert "--strict-mcp-config" in starts[0]

    def test_narrow_pane_setup_acknowledges_output_but_never_its_echo(self) -> None:
        r = self.run_team("start", "lead")
        assert r.returncode == 0, r.stderr
        command = next(c[3] for c in self.calls() if c[:2] == ["pane", "run"])
        wait = next(c for c in self.calls() if c[:2] == ["pane", "wait-output"])
        token = wait[wait.index("--match") + 1]
        assert wait[wait.index("--source") + 1] == "recent-unwrapped"
        # Unwrapping may drop whitespace at a wrap point; the echo must still not match.
        assert token not in "".join(command.split())

    def test_lost_setup_output_never_starts_coordinator(self) -> None:
        self.state.write_text(json.dumps({"workspaces": [], "panes": [], "setup_lost": True}))
        r = self.run_team("start", "lead")
        assert r.returncode != 0
        assert "timed out waiting for output match" in r.stderr
        assert not any(c[:2] == ["agent", "start"] for c in self.calls())

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
            .replace('effort = "high"', 'effort = "low"')
        )
        assert self.run_team("start", "3").returncode != 0
        assert not (self.root / "calls").exists()
        assert self.run_team("start", "2").returncode == 0
        r = self.run_team("start", "lead")
        assert r.returncode == 0, r.stderr
        start = next(c for c in self.calls() if c[:2] == ["agent", "start"])
        assert "configured-model" in start
        assert "low" in start

    def test_conflicting_pane_prevents_reuse(self) -> None:
        assert self.run_team("start", "lead").returncode == 0
        state = json.loads(self.state.read_text())
        state["panes"][0]["name"] = "someone-else"
        self.state.write_text(json.dumps(state))
        r = self.run_team("start", "lead")
        assert r.returncode != 0
        assert "conflicting" in r.stderr
        assert len([c for c in self.calls() if c[:2] == ["agent", "start"]]) == 1

    def test_stop_empty_coding_panes_closes_only_owned_workspace(self) -> None:
        assert self.run_team("start", "1").returncode == 0
        r = self.run_team("stop", "1")
        assert r.returncode == 0, r.stderr
        assert json.loads(self.state.read_text())["workspaces"] == []
        assert (self.root / "docker-calls").exists()

    def test_stop_preserves_a_workspace_holding_a_pane_outside_the_team_roles(self) -> None:
        assert self.run_team("start", "1").returncode == 0
        state = json.loads(self.state.read_text())
        state["panes"].append({"pane_id": "wT:p4", "label": "team-1-tpm", "cwd": str(self.repo)})
        self.state.write_text(json.dumps(state))
        r = self.run_team("stop", "1")
        assert r.returncode != 0
        assert "Unexpected or duplicate pane wT:p4; preserved" in r.stderr
        assert json.loads(self.state.read_text())["workspaces"]
        assert not (self.root / "docker-calls").exists()

    def test_stop_dirty_worktree_preserves_workspace_and_database(self) -> None:
        assert self.run_team("start", "1").returncode == 0
        work = self.repo / ".worktrees/task"
        execute(
            ["git", "-C", str(self.repo), "worktree", "add", "-q", "--detach", str(work)],
            check=True,
        )
        (work / "uncommitted").write_text("keep")
        state = json.loads(self.state.read_text())
        state["panes"][1]["cwd"] = str(work)
        state["panes"][1]["foreground_cwd"] = "/opt/homebrew/lsp-child"
        self.state.write_text(json.dumps(state))
        self.calls_before_stop = self.calls()
        r = self.run_team("stop", "1")
        assert r.returncode != 0
        assert "Dirty worktree" in r.stderr
        assert not any(
            c[:2] == ["pane", "get"] for c in self.calls()[len(self.calls_before_stop) :]
        )
        assert work.exists()
        assert json.loads(self.state.read_text())["workspaces"]
        assert not (self.root / "docker-calls").exists()

    def test_worktree_dirtied_during_shutdown_is_preserved_after_clients_exit(self) -> None:
        assert self.run_team("start", "1").returncode == 0
        work = self.repo / ".worktrees/task"
        execute(
            ["git", "-C", str(self.repo), "worktree", "add", "-q", "--detach", str(work)],
            check=True,
        )
        state = json.loads(self.state.read_text())
        state["panes"][1]["cwd"] = str(work)
        state["panes"][1]["foreground_cwd"] = "/opt/homebrew/lsp-child"
        self.state.write_text(json.dumps(state))
        self.env["RACE_DIRTY_FILE"] = str(work / "written-during-shutdown")
        r = self.run_team("stop", "1")
        assert r.returncode != 0
        assert "client and owned descendants exited" in r.stdout
        assert "Dirty worktree" in r.stderr
        assert work.exists()
        assert json.loads(self.state.read_text())["workspaces"]
        assert not (self.root / "docker-calls").exists()

    def test_shared_worktree_daemon_stops_once_before_retirement(self) -> None:
        assert self.run_team("start", "1").returncode == 0
        work = self.repo / ".worktrees/task"
        execute(["git", "-C", self.repo, "worktree", "add", "-q", "--detach", work], check=True)
        (self.repo / ".git/info/exclude").write_text(".dexter/\n")
        wrapper = work / ".dexter/dexter.sh"
        wrapper.parent.mkdir(parents=True)
        wrapper.write_text(
            '#!/bin/sh\necho "$1" >> "$DEXTER_STOP_LOG"\nexit "${DEXTER_STOP_FAIL:-0}"\n'
        )
        state = json.loads(self.state.read_text())
        for pane in state["panes"][1:3]:
            pane["cwd"] = str(work)
        self.state.write_text(json.dumps(state))
        log = self.root / "dexter-stop"
        self.env["DEXTER_STOP_LOG"] = str(log)
        self.env["DEXTER_STOP_FAIL"] = "1"
        failed = self.run_team("stop", "1")
        assert failed.returncode != 0
        assert work.exists()
        assert not (self.root / "docker-calls").exists()
        assert log.read_text() == "stop\n"
        self.env["DEXTER_STOP_FAIL"] = "0"
        result = self.run_team("stop", "1")
        assert result.returncode == 0, result.stderr
        assert log.read_text() == "stop\nstop\n"
        assert not work.exists()

    @unittest.skipUnless(os.environ.get("TIPS_TEST_REAL_DEXTER"), REAL_DEXTER)
    def test_retirement_stops_real_daemons_before_removing_the_worktree(self) -> None:
        assert self.run_team("start", "1").returncode == 0
        work = self.repo / ".worktrees/task"
        execute(["git", "-C", self.repo, "worktree", "add", "-q", "--detach", work], check=True)
        (self.repo / ".git/info/exclude").write_text(".dexter/\n")
        wrapper = real_bound_command(work)
        try:
            execute(
                ["/bin/sh", wrapper, "query", "workspace-symbols", "--wait", "20s"],
                input_text="",
                check=True,
            )
            assert daemon_pid(work)
            state = json.loads(self.state.read_text())
            state["panes"][1]["cwd"] = str(work)
            self.state.write_text(json.dumps(state))
            result = self.run_team("stop", "1")
            assert result.returncode == 0, result.stderr
            # Stopping needs the bound command, so it ran before the checkout was removed.
            wait_until_stopped(work)
            assert not work.exists()
        finally:
            if wrapper.exists():
                execute(["/bin/sh", wrapper, "stop", "--force"], input_text="")

    def test_codex_coordinator_overrides_no_mcp_server(self) -> None:
        # A partial mcp_servers override is an invalid transport unless a legacy entry exists.
        assert not any("mcp_servers" in arg for arg in self.codex_coordinator_arguments())

    @unittest.skipUnless(
        os.environ.get("TIPS_TEST_REAL_CODEX"), "opt-in installed Codex config check"
    )
    def test_installed_codex_accepts_coordinator_arguments_without_a_legacy_entry(self) -> None:
        arguments = self.codex_coordinator_arguments()
        assert not (self.repo / ".codex").exists()
        result = execute(["codex", *arguments, "mcp", "list", "--json"], cwd=self.repo, timeout=30)
        assert result.returncode == 0, result.stderr
        assert "elixir-lsp" not in {server["name"] for server in json.loads(result.stdout)}

    def test_retirement_removes_ignored_dexter_state_without_relocating_it(self) -> None:
        assert self.run_team("start", "1").returncode == 0
        work = self.repo / ".worktrees/task"
        execute(["git", "-C", self.repo, "worktree", "add", "-q", "--detach", work], check=True)
        (self.repo / ".git/info/exclude").write_text(".dexter/\n")
        snapshot = work / ".dexter/dx/snapshots/recovery.json"
        snapshot.parent.mkdir(parents=True)
        snapshot.write_text('{"files":{"ignored.ex":"saved contents"}}')
        state = json.loads(self.state.read_text())
        state["panes"][1]["cwd"] = str(work)
        self.state.write_text(json.dumps(state))
        result = self.run_team("stop", "1")
        assert result.returncode == 0, result.stderr
        assert not work.exists()
        assert not (self.repo / "tmp").exists()
        assert "preserved" not in result.stdout

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
        state["panes"][1]["cwd"] = str(work)
        state["panes"][1]["foreground_cwd"] = "/opt/homebrew/lsp-child"
        self.state.write_text(json.dumps(state))
        before = len(self.calls())
        r = self.run_team("stop", "1")
        assert r.returncode != 0
        assert "Unmerged worktree" in r.stderr
        assert not any(c[:2] == ["pane", "get"] for c in self.calls()[before:])
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
        state["panes"][1]["cwd"] = str(work)
        state["panes"][1]["foreground_cwd"] = "/opt/homebrew/lsp-child"
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
        assert not any(c[:2] == ["pane", "get"] for c in self.calls()[before:])
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

    def test_lead_ui_needs_client_settings_only_and_retirement_drops_the_lead_partition(
        self,
    ) -> None:
        (self.repo / "agent/teams/config.toml").write_text(
            CONFIG + '\n[roles.lead_ui]\nkind = "claude"\nmodel = ""\neffort = "high"\n'
        )
        r = self.run_team("start", "1")
        assert r.returncode == 0, r.stderr
        (self.bin / "docker").write_text(
            '#!/bin/sh\nprintf "%s\\n" "$*" >> "$DOCKER_LOG"\ncase "$*" in *SELEC'
            'T*) printf "tips_test_t1l\\ntips_test_t2l\\n";; esac\n'
        )
        r = self.run_team("stop", "1")
        assert r.returncode == 0, r.stderr
        calls = (self.root / "docker-calls").read_text()
        assert 'DROP DATABASE "tips_test_t1l"' in calls
        assert 'DROP DATABASE "tips_test_t2l"' not in calls

    def test_lead_start_applies_config_but_has_no_stop_subcommand(self) -> None:
        r = self.run_team("start", "lead")
        assert r.returncode == 0, r.stderr
        prompt = next(c[3] for c in self.calls() if c[:2] == ["agent", "prompt"])
        assert "Read agent/teams/README.md" in prompt
        assert "agent/teams/roles/lead-tpm.md" in prompt
        assert "Report readiness to the user" in prompt
        assert "task_worktree.py" not in prompt
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
        state["panes"][1]["cwd"] = str(work)
        state["panes"][1]["foreground_cwd"] = "/opt/homebrew/lsp-child"
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
