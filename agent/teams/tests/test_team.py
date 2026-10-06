"""Pair lifecycle tests: real Git and process trees, fake Herdr; never a live pane or client."""

import contextlib
import json
import os
import signal
import subprocess
import tempfile
import time
import tomllib
import unittest
from collections.abc import Sequence
from pathlib import Path
from typing import Any

from team import bound_command, command_args, execute, require_git_admin

SCRIPT = Path(__file__).resolve().parents[1] / "team.py"
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
dexter_startup_seconds = 60
checks_minutes = 30

[launch]
codex_approval = "never"
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

"""
# A 40-column pane: "recent" keeps soft wraps; "recent-unwrapped" rejoins each wrapped
# line, dropping whitespace at wrap points as the worst case for echo protection.
PANE_SCREEN = r"""
def pane_screen(text, source, width=40):
    lines = [
        [line[i : i + width] for i in range(0, max(len(line), 1), width)]
        for line in text.splitlines()
    ]
    if source == "recent-unwrapped":
        return "\n".join("".join(row.rstrip() for row in rows) for rows in lines)
    return "\n".join(row for rows in lines for row in rows)
"""
MIX_PROJECT = (
    "defmodule Fixture.MixProject do\n  use Mix.Project\n"
    '  def project, do: [app: :fixture, version: "0.1.0"]\nend\n'
)


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


# Stands in for the built binary: the last --root wins, as in Dexter's CLI.
FAKE_DEXTER = r"""#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
argv, root = sys.argv[1:], os.getcwd()
while '--root' in argv:
    i = argv.index('--root')
    root = argv[i + 1]
    del argv[i : i + 2]
state_path = Path(os.environ['HERDR_FIXTURE'])
state = json.loads(state_path.read_text())
state['events'].append(['dexter', root, *argv])
state['dexter_stdlib'] = os.environ.get('DEXTER_ELIXIR_LIB_ROOT')
state_path.write_text(json.dumps(state))
if state.get('dexter_fails'):
    sys.exit('fixture Dexter failed')
print('[]' if state.get('dexter_empty') else json.dumps([{'name': 'Fixture.MixProject'}]))
"""

# Stands in for Mix: records where and how dependencies were fetched.
FAKE_MIX = r"""#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
state_path = Path(os.environ['HERDR_FIXTURE'])
state = json.loads(state_path.read_text())
state['events'].append(['mix', os.getcwd(), *sys.argv[1:]])
state['mix_env'] = {k: os.environ.get(k) for k in ('HEX_HOME', 'MIX_ENV')}
state_path.write_text(json.dumps(state))
if state.get('mix_fails'):
    sys.exit('fixture mix failed')
Path('deps').mkdir(exist_ok=True)
"""

FAKE_GH = (
    "#!/bin/sh\n"
    'printf \'{"headRefOid":"%s","url":"https://github.com/o/r/pull/%s"}\\n\''
    ' "$(cat "$GH_HEAD")" "$3"\n'
)

# One pane model for every pair: a pane with an agent has a client leading its foreground
# group; a bare pane is its shell. `pane run` really executes the setup and keeps the result.
PAIR_HERDR = (
    r"""#!/usr/bin/env python3
import json, os, subprocess, sys
"""
    + PANE_SCREEN
    + r"""
path = os.environ["HERDR_FIXTURE"]
s = json.load(open(path))
a = sys.argv[1:]
s["events"].append(a)
result = {}
ENV = [
    "PGPORT", "TIPS_DB_SUFFIX", "TIPS_TEST_PORT", "MIX_ENV", "TIPS_CHECK_TIMEOUT_SECONDS",
    "TIPS_TEAM_CONFIG", "TIPS_PROVIDER_ENV_FILE", "TIPS_DEXTER", "HEX_HOME",
]
SNAPSHOT = (
    "\npython3 -c 'import os,json; "
    'print("SNAPSHOT="+json.dumps({"env":dict(os.environ),"cwd":os.getcwd()}))\''
)


def opt(key):
    return a[a.index(key) + 1]


def pane(key):
    every = s["panes"] + s.get("strays", [])
    return next(x for x in every if key in (x["pane_id"], x.get("name")))


def finish(error=None):
    json.dump(s, open(path, "w"))
    if error:
        sys.exit(error)
    if a[:2] != ["pane", "run"]:
        print(json.dumps({"result": result}))
    sys.exit(0)


if a[:2] == ["workspace", "list"]:
    result = {"workspaces": s["workspaces"]}
elif a[:2] == ["workspace", "create"]:
    s["count"] = s.get("count", 0) + 1
    w = {"workspace_id": "w%d" % s["count"], "label": opt("--label")}
    x = {"pane_id": w["workspace_id"] + ":p1", "workspace_id": w["workspace_id"]}
    x["cwd"] = opt("--cwd")
    s["workspaces"].append(w)
    s["panes"].append(x)
    result = {"workspace": w, "root_pane": x}
elif a[:2] == ["workspace", "close"]:
    s["workspaces"] = [w for w in s["workspaces"] if w["workspace_id"] != a[2]]
    s["panes"] = [x for x in s["panes"] if x["workspace_id"] != a[2]]
elif a[:2] == ["pane", "list"]:
    result = {"panes": [x for x in s["panes"] if x["workspace_id"] == opt("--workspace")]}
elif a[:2] == ["pane", "rename"]:
    pane(a[2])["label"] = a[3]
elif a[:2] == ["pane", "split"]:
    w = pane(a[2])["workspace_id"]
    n = len([x for x in s["panes"] if x["workspace_id"] == w]) + 1
    x = {"pane_id": "%s:p%d" % (w, n), "workspace_id": w, "cwd": opt("--cwd")}
    s["panes"].append(x)
    result = {"pane": x}
elif a[:2] == ["pane", "process-info"]:
    x = pane(opt("--pane"))
    leader = 200 if x.get("agent") or x.get("busy") else 100
    processes = [{"pid": leader, "cwd": x["cwd"]}]
    if x.get("agent"):
        # An LSP child shares the foreground group but runs elsewhere.
        processes.append({"pid": 201, "cwd": "/opt/homebrew/lsp-child"})
    result = {
        "process_info": {
            "shell_pid": 100,
            "foreground_process_group_id": leader,
            "foreground_processes": processes,
        }
    }
elif a[:2] == ["pane", "get"]:
    result = {"pane": pane(a[2])}
elif a[:2] == ["pane", "run"]:
    x = pane(a[2])
    r = subprocess.run(
        ["bash", "-c", a[3] + SNAPSHOT], cwd=x["cwd"], text=True, capture_output=True
    )
    if r.returncode:
        finish("setup failed: " + r.stderr)
    line = next(row for row in r.stdout.splitlines() if row.startswith("SNAPSHOT="))
    snapshot = json.loads(line[9:])
    x["cwd"] = snapshot["cwd"]
    x["env"] = {key: snapshot["env"].get(key) for key in ENV}
    x["echo"] = a[3]
    # A lost setup leaves only the typed command echo on screen.
    x["output"] = "" if s.get("setup_lost") else r.stdout.replace(line, "")
elif a[:2] == ["pane", "wait-output"]:
    x = pane(a[2])
    if opt("--source") not in ("visible", "recent", "recent-unwrapped"):
        finish("invalid --source " + opt("--source"))
    screen = pane_screen(x.get("echo", "") + "\n" + x.get("output", ""), opt("--source"))
    if opt("--match") not in screen:
        finish("timed out waiting for output match")
elif a[:2] == ["agent", "list"]:
    result = {"agents": [x for x in s["panes"] + s.get("strays", []) if x.get("agent")]}
elif a[:2] == ["agent", "get"]:
    x = pane(a[2])
    if not x.get("agent"):
        finish("agent_not_found")
    result = {"agent": x}
elif a[:2] == ["agent", "start"]:
    x = pane(opt("--pane"))
    x.update(agent=opt("--kind"), name=a[2], launch_argv=a, launch_env=x.get("env", {}))
    x["agent_status"] = "blocked" if s.get("start_fails") else "idle"
    if s.get("wrong_start_root"):
        x["cwd"] = s["wrong_start_root"]
    result = {"agent": x}
elif a[:2] == ["agent", "prompt"]:
    pane(a[2])
elif a[:2] == ["agent", "rename"]:
    pane(a[2]).pop("name", None)
else:
    finish("Unexpected " + repr(a))
finish()
"""
)

IDENTITY = ["-c", "user.name=Test", "-c", "user.email=test@example.invalid"]


class PairLifecycleTest(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory(prefix="tips pair ")
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name).resolve()
        self.repo, self.bin = self.root / "repo", self.root / "bin"
        self.stdlib = self.root / "stdlib/lib"
        self.state_path = self.root / "state.json"
        self.env = dict(
            os.environ,
            GIT_CONFIG_GLOBAL=os.devnull,
            GIT_CONFIG_NOSYSTEM="1",
            HERDR_ENV="1",
            HERDR_FIXTURE=str(self.state_path),
            DOCKER_LOG=str(self.root / "docker-calls"),
            DOCKER_DBS=str(self.root / "databases"),
            GH_HEAD=str(self.root / "pr-head"),
            DEXTER_ELIXIR_LIB_ROOT=str(self.stdlib),
            PATH=str(self.bin) + os.pathsep + os.environ["PATH"],
        )
        for key in (
            "TIPS_TEAM_CONFIG",
            "TIPS_DEXTER_HOME",
            "TIPS_DB_SUFFIX",
            "TIPS_TEST_PORT",
            "PGPORT",
            "MIX_ENV",
            "HEX_HOME",
            "HERDR_PANE_ID",
        ):
            self.env.pop(key, None)
        for directory in (
            self.bin,
            self.stdlib / "elixir/lib",
            self.repo / "agent/teams",
            self.repo / "agent/lsp/dexter/vendor",
            self.repo / ".agents/skills",
        ):
            directory.mkdir(parents=True)
        (self.stdlib / "elixir/lib/enum.ex").write_text("defmodule Enum do\nend\n")
        (self.stdlib.parent / "VERSION").write_text("1.2.3\n")
        fakes = {
            "herdr": PAIR_HERDR,
            "mix": FAKE_MIX,
            "gh": FAKE_GH,
            "elixir": '#!/bin/sh\nprintf "1.2.3\\n"\n',
            "docker": (
                '#!/bin/sh\nprintf "%s\\n" "$*" >> "$DOCKER_LOG"\n'
                'case "$*" in *SELECT*) cat "$DOCKER_DBS" 2>/dev/null;; esac\nexit 0\n'
            ),
            # A stop-time write lands between the two cleanliness checks: ps runs only in stop().
            "ps": (
                '#!/bin/sh\n[ -n "$RACE_DIRTY_FILE" ] && echo raced > "$RACE_DIRTY_FILE"\nexit 0\n'
            ),
        }
        for name, body in fakes.items():
            (self.bin / name).write_text(body)
            (self.bin / name).chmod(0o755)
        execute(["git", "init", "-q", "-b", "main", str(self.repo)], env=self.env, check=True)
        (self.repo / ".gitignore").write_text(
            ".codex/\n.agents/\n.dexter/\n.worktrees/\nagent/lsp/dexter/vendor/\ndeps/\ntmp/\n"
        )
        (self.repo / "agent/teams/team.py").write_text(SCRIPT.read_text())
        (self.repo / "agent/teams/config.toml").write_text(CONFIG)
        (self.repo / "tracked.txt").write_text("base\n")
        binary = self.repo / "agent/lsp/dexter/vendor/dexter"
        binary.write_text(FAKE_DEXTER)
        binary.chmod(0o755)
        self.commit("base")
        self.git("remote", "add", "origin", str(self.repo))
        self.git("update-ref", "refs/remotes/origin/main", "HEAD")
        self.save({"workspaces": [], "panes": [], "events": []})

    def git(self, *args: str | Path, cwd: Path | None = None) -> str:
        return execute(
            ["git", *IDENTITY, *args], cwd=cwd or self.repo, env=self.env, check=True
        ).stdout.strip()

    def commit(self, message: str, cwd: Path | None = None) -> str:
        self.git("add", "-A", cwd=cwd)
        self.git("commit", "-q", "--allow-empty", "-m", message, cwd=cwd)
        return self.git("rev-parse", "HEAD", cwd=cwd)

    def state(self) -> dict[str, Any]:
        return json.loads(self.state_path.read_text())

    def save(self, state: dict[str, Any]) -> None:
        self.state_path.write_text(json.dumps(state))

    def update(self, **flags: object) -> None:
        self.save({**self.state(), **flags})

    def events(self, *prefix: str) -> list[list[str]]:
        return [e for e in self.state()["events"] if e[: len(prefix)] == list(prefix)]

    def pane(self, label: str) -> dict[str, Any]:
        return next(pane for pane in self.state()["panes"] if pane.get("label") == label)

    def clients_exit(self, slot: int) -> None:
        """The pair's clients have exited: their panes are back at the shell."""
        state = self.state()
        for pane in state["panes"]:
            if str(pane.get("label", "")).startswith(f"team-{slot}-"):
                for key in ("agent", "name", "agent_status"):
                    pane.pop(key, None)
        self.save(state)

    def team(
        self, *args: str, ok: bool = True, cwd: Path | None = None, pane: str | None = None
    ) -> subprocess.CompletedProcess[str]:
        env = dict(self.env, HERDR_PANE_ID=pane) if pane else self.env
        result = execute(
            ["python3", str(self.repo / "agent/teams/team.py"), *args],
            cwd=cwd or self.repo,
            env=env,
            timeout=60,
        )
        assert (result.returncode == 0) == ok, result.stdout + result.stderr
        return result

    def worktree(self, issue: str) -> Path:
        return self.repo / ".worktrees" / issue

    def test_start_launches_developer_and_tester_in_one_prepared_worktree(self) -> None:
        self.team("start", "29")
        wt = self.worktree("29")
        assert self.git("branch", "--show-current", cwd=wt) == "task/29"
        assert [w["label"] for w in self.state()["workspaces"]] == ["tips-team-1-29"]
        dev, test = self.pane("team-1-dev"), self.pane("team-1-test")
        assert (dev["agent"], test["agent"]) == ("codex", "claude")
        assert dev["cwd"] == test["cwd"] == str(wt)
        # Each client has its own database and port; both use the worktree's one Dexter.
        shared = {
            "PGPORT": "5433",
            "MIX_ENV": "test",
            "TIPS_CHECK_TIMEOUT_SECONDS": "1800",
            "TIPS_TEAM_CONFIG": str(self.repo / "agent/teams/config.toml"),
            "TIPS_PROVIDER_ENV_FILE": str(self.repo / ".env"),
            "TIPS_DEXTER": str(wt / ".dexter/dexter.sh"),
        }
        assert dev["launch_env"] == {
            **shared,
            "TIPS_DB_SUFFIX": "_t1",
            "TIPS_TEST_PORT": "4110",
            # Codex's sandbox cannot write the shared Hex cache; Claude keeps the default.
            "HEX_HOME": str(wt / "tmp/hex"),
        }
        assert test["launch_env"] == {
            **shared,
            "TIPS_DB_SUFFIX": "_t1r",
            "TIPS_TEST_PORT": "4111",
            "HEX_HOME": None,
        }
        dev_brief = dev["launch_argv"][-1]
        argv = test["launch_argv"]
        test_brief = argv[argv.index("--append-system-prompt") + 1]
        assert dev_brief.startswith(
            "You are team-1-dev, the developer for issue #29. Read agent/teams/README.md,"
        )
        assert test_brief.startswith("You are team-1-test, the tester for issue #29.")
        for text in (dev_brief, test_brief):
            assert f"TIPS_DEXTER={wt / '.dexter/dexter.sh'}" in text
            assert "README restart rule" in text
            assert "roles/" not in text
        # Claude holds its brief as a system prompt, so it alone needs a first message.
        assert self.events("agent", "prompt") == [["agent", "prompt", "team-1-test", "Begin."]]
        assert {"fixture-dev", "never"} <= set(dev["launch_argv"])
        assert "fixture-test" in argv
        assert argv[argv.index("--advisor") + 1] == "fable"
        assert "--advisor" not in dev["launch_argv"]
        plugins = json.loads(argv[argv.index("--settings") + 1])["enabledPlugins"]
        assert plugins == {
            "mix-credo@elixir-agent-tools": True,
            "elixir-lsp@elixir-agent-tools": False,
        }
        # The shared worktree is prepared once, before either client starts.
        assert self.events("mix") == [["mix", str(wt), "deps.get", "--check-locked"]]
        assert self.state()["mix_env"] == {"HEX_HOME": str(wt / "tmp/hex"), "MIX_ENV": "test"}
        assert [e[2] for e in self.events("dexter")] == ["query", "reindex"]
        first_launch = self.state()["events"].index(self.events("agent", "start")[0])
        assert self.state()["events"].index(self.events("dexter")[-1]) < first_launch
        assert self.git("status", "--porcelain", cwd=wt) == ""

    def test_repeated_start_keeps_the_running_pair(self) -> None:
        self.team("start", "29")
        before = len(self.state()["events"])
        result = self.team("start", "29")
        assert result.stdout.count("Already running") == 2
        later = self.state()["events"][before:]
        assert not any(e[:2] in (["agent", "start"], ["pane", "run"]) for e in later)
        assert not any(e[0] == "mix" for e in later)
        assert len(self.state()["workspaces"]) == 1

    def test_missing_client_is_relaunched_with_unfinished_work_untouched(self) -> None:
        self.team("start", "29")
        wt = self.worktree("29")
        (wt / "tracked.txt").write_text("unfinished work\n")
        for model in ("claude-fable-5-1", ""):
            with self.subTest(model=model):
                config = self.repo / "agent/teams/config.toml"
                config.write_text(CONFIG.replace('model = "fixture-test"', f'model = "{model}"'))
                state = self.state()
                tester = next(pane for pane in state["panes"] if pane["label"] == "team-1-test")
                for key in ("agent", "name", "agent_status"):
                    del tester[key]
                self.save(state)
                before = len(self.events("agent", "start"))
                self.team("start", "29")
                assert self.events("agent", "start")[before:][0][2] == "team-1-test"
                assert len(self.events("agent", "start")) == before + 1
                assert "--advisor" not in self.pane("team-1-test")["launch_argv"]
                assert (wt / "tracked.txt").read_text() == "unfinished work\n"
                # A reused worktree keeps its own dependency state.
                assert len(self.events("mix")) == 1

    def test_each_issue_takes_its_own_slot_until_none_is_free(self) -> None:
        path = self.repo / "agent/teams/config.toml"
        path.write_text(CONFIG.replace("max_teams = 6", "max_teams = 2"))
        self.team("start", "29")
        self.team("start", "30")
        second = self.pane("team-2-dev")
        assert second["cwd"] == str(self.worktree("30"))
        assert second["launch_env"]["TIPS_DB_SUFFIX"] == "_t2"
        assert second["launch_env"]["TIPS_TEST_PORT"] == "4120"
        assert self.pane("team-1-dev")["cwd"] == str(self.worktree("29"))
        refused = self.team("start", "31", ok=False)
        assert "No free slot" in refused.stderr
        assert not self.worktree("31").exists()
        assert len(self.state()["workspaces"]) == 2

    def test_foreign_client_in_the_task_worktree_refuses_before_any_change(self) -> None:
        stray = {
            "pane_id": "wX:p9",
            "name": "stray",
            "agent": "claude",
            "cwd": str(self.worktree("29")),
        }
        self.update(strays=[stray])
        refused = self.team("start", "29", ok=False)
        assert "Conflicting live agent" in refused.stderr
        assert not self.worktree("29").exists()
        assert not self.state()["workspaces"]

    def test_new_worktree_starts_from_fetched_origin_main(self) -> None:
        (self.repo / "AGENTS.md").write_text("Committed instructions.\n")
        release = self.commit("instructions")
        assert self.git("rev-parse", "origin/main") != release
        (self.repo / "AGENTS.md").write_text("Uncommitted launcher-only instructions.\n")
        self.team("start", "29")
        wt = self.worktree("29")
        assert self.git("rev-parse", "HEAD", cwd=wt) == release
        assert (wt / "AGENTS.md").read_text() == "Committed instructions.\n"

    def test_failed_preparation_never_launches_a_client(self) -> None:
        failures = (
            ("31", {"mix_fails": True}, "fixture mix failed"),
            ("32", {"dexter_fails": True}, "fixture Dexter failed"),
            ("33", {"dexter_empty": True}, "no MixProject"),
        )
        healthy = {"mix_fails": False, "dexter_fails": False, "dexter_empty": False}
        for issue, flags, message in failures:
            with self.subTest(flags=flags):
                self.update(**{**healthy, **flags})
                assert message in self.team("start", issue, ok=False).stderr
        self.update(**healthy)
        # Missing tools are refused before a worktree exists.
        self.env["DEXTER_ELIXIR_LIB_ROOT"] = str(self.root / "no-sources")
        assert "sources are missing" in self.team("start", "34", ok=False).stderr
        self.env["DEXTER_ELIXIR_LIB_ROOT"] = str(self.stdlib)
        (self.repo / "agent/lsp/dexter/vendor/dexter").unlink()
        assert "Missing executable" in self.team("start", "34", ok=False).stderr
        assert not self.worktree("34").exists()
        assert not self.events("agent", "start")
        assert not self.state()["workspaces"]

    def test_failed_dependency_fetch_is_retried_on_the_next_start(self) -> None:
        self.update(mix_fails=True)
        self.team("start", "29", ok=False)
        self.update(mix_fails=False)
        self.team("start", "29")
        assert len(self.events("mix")) == 2
        assert len(self.events("agent", "start")) == 2

    def test_setup_is_acknowledged_by_its_output_never_by_its_echo(self) -> None:
        self.team("start", "29")
        command = self.events("pane", "run")[0][3]
        wait = self.events("pane", "wait-output")[0]
        marker = wait[wait.index("--match") + 1]
        assert wait[wait.index("--source") + 1] == "recent-unwrapped"
        # Unwrapping may drop whitespace at a wrap point; the echo must still not match.
        assert marker not in "".join(command.split())

    def test_lost_setup_output_never_starts_a_client(self) -> None:
        self.update(setup_lost=True)
        refused = self.team("start", "29", ok=False)
        assert "timed out waiting for output match" in refused.stderr
        assert not self.events("agent", "start")

    def test_client_started_blocked_or_in_another_root_is_reported(self) -> None:
        for issue, flags in (("29", {"start_fails": True}), ("30", {"wrong_start_root": "/"})):
            with self.subTest(flags=flags):
                self.update(**{"start_fails": False, "wrong_start_root": "", **flags})
                refused = self.team("start", issue, ok=False)
                assert "unexpected state or root" in refused.stderr
                assert len(self.events("agent", "start")) == 1
                self.update(events=[])

    def test_invalid_config_refuses_before_herdr(self) -> None:
        path = self.repo / "agent/teams/config.toml"
        path.write_text(CONFIG.replace("port_base = 4100", 'port_base = "wrong"'))
        refused = self.team("start", "29", ok=False)
        assert "team.port_base must be int; received 'wrong'" in refused.stderr
        # Slot 10's databases would match slot 1's stem: refuse before any database access.
        path.write_text(CONFIG.replace("max_teams = 6", "max_teams = 10"))
        assert "overlapping database" in self.team("stop", "29", ok=False).stderr
        assert self.state()["events"] == []
        assert not (self.root / "docker-calls").exists()

    def test_repository_configuration_validates(self) -> None:
        env = dict(self.env, TIPS_TEAM_CONFIG=str(SCRIPT.parent / "config.toml"))
        code = "import sys; sys.path.insert(0,sys.argv[1]); from team import load_config; "
        result = execute(["python3", "-c", code + "load_config()", str(SCRIPT.parent)], env=env)
        assert result.returncode == 0, result.stderr

    @unittest.skipIf(os.geteuid() == 0, "root bypasses directory permissions")
    def test_unwritable_main_git_refers_caller_to_the_dispatcher_before_fetch(self) -> None:
        git_dir = self.repo / ".git"
        git_dir.chmod(0o555)
        self.addCleanup(git_dir.chmod, 0o755)
        refused = self.team("start", "29", ok=False)
        assert "ask the dispatcher to run it from the main checkout" in refused.stderr
        assert self.state()["events"] == []
        assert not (git_dir / "FETCH_HEAD").exists()
        assert not self.worktree("29").exists()

    def test_codex_config_names_no_language_server(self) -> None:
        self.team("start", "29")
        config = tomllib.loads((self.worktree("29") / ".codex/config.toml").read_text())
        assert set(config) == {"plugins"}
        assert config["plugins"]["mix-credo@elixir-agent-tools"]["enabled"] is True
        assert not any("mcp_servers" in arg for arg in self.pane("team-1-dev")["launch_argv"])

    @unittest.skipUnless(
        os.environ.get("TIPS_TEST_REAL_CODEX"), "opt-in installed Codex config check"
    )
    def test_installed_codex_accepts_generated_configuration(self) -> None:
        legacy = self.repo / ".codex/config.toml"
        legacy.parent.mkdir()
        legacy.write_text('[mcp_servers.elixir-lsp]\ncommand = "/usr/bin/false"\n')
        self.team("start", "29")
        wt = self.worktree("29")
        launch = self.pane("team-1-dev")["launch_argv"]
        args = launch[launch.index("--") + 1 : -1]
        config = tomllib.loads((wt / ".codex/config.toml").read_text())
        # A CLI trust override does not prove project-file loading. Parse the
        # generated values explicitly, without changing the user's trust store.
        for name, plugin in config["plugins"].items():
            args += ["-c", f"plugins.{json.dumps(name)}.enabled={json.dumps(plugin['enabled'])}"]
        result = execute(
            ["codex", *args, "mcp", "list", "--json"], cwd=wt, env=self.env, timeout=30
        )
        assert result.returncode == 0, result.stderr
        assert "elixir-lsp" not in {server["name"] for server in json.loads(result.stdout)}

    def test_bound_command_keeps_its_root_and_sources_from_anywhere(self) -> None:
        self.team("start", "29")
        wt = self.worktree("29")
        env = dict(self.env)
        env.pop("DEXTER_ELIXIR_LIB_ROOT")
        query = ["query", "hover", "a.ex", "1", "1"]
        execute(
            ["/bin/sh", wt / ".dexter/dexter.sh", *query],
            cwd=self.root,
            env=env,
            input_text="",
            check=True,
        )
        assert self.state()["events"][-1] == ["dexter", str(wt), *query]
        assert self.state()["dexter_stdlib"] == str(self.stdlib)

    def use_real_dexter(self) -> None:
        """Bind new worktrees to the real binary over a real Mix project."""
        self.env["TIPS_DEXTER_HOME"] = os.environ["TIPS_TEST_REAL_DEXTER"]
        self.env["DEXTER_ELIXIR_LIB_ROOT"] = os.environ["DEXTER_ELIXIR_LIB_ROOT"]
        self.env["DEXTER_DAEMON_IDLE_TIMEOUT"] = "5s"
        (self.bin / "elixir").unlink()  # the real toolchain must match the sources
        source = 'defmodule Sample do\n  @doc "Original documentation"\n'
        (self.repo / "sample.ex").write_text(source + "  def greet(name), do: name\nend\n")
        (self.repo / "mix.exs").write_text(MIX_PROJECT)
        self.commit("mix fixture")

    @unittest.skipUnless(os.environ.get("TIPS_TEST_REAL_DEXTER"), REAL_DEXTER)
    def test_two_pairs_use_isolated_real_daemons(self) -> None:
        self.use_real_dexter()
        roots = [self.worktree("31"), self.worktree("32")]
        for root in roots:
            self.addCleanup(execute, ["/bin/sh", root / ".dexter/dexter.sh", "stop", "--force"])
            self.team("start", root.name)
        assert len(self.events("agent", "start")) == 4
        source = (roots[0] / "sample.ex").read_text()
        changed = roots[0] / ".replace"
        changed.write_text(source.replace("Original documentation", "First tree only"))
        changed.replace(roots[0] / "sample.ex")
        hover = ["query", "--raw", "hover", "sample.ex", "3", "8"]
        for root, doc in zip(roots, ("First tree only", "Original documentation"), strict=True):
            result = execute(
                ["/bin/sh", root / ".dexter/dexter.sh", *hover],
                cwd=self.root,
                env=self.env,
                input_text="",
                check=True,
            )
            assert doc in json.dumps(json.loads(result.stdout))

    @unittest.skipUnless(os.environ.get("TIPS_TEST_REAL_DEXTER"), REAL_DEXTER)
    def test_retirement_stops_real_daemons_before_removing_the_worktree(self) -> None:
        self.use_real_dexter()
        wt = self.worktree("29")
        self.addCleanup(execute, ["/bin/sh", wt / ".dexter/dexter.sh", "stop", "--force"])
        self.team("start", "29")
        assert daemon_pid(wt)
        self.clients_exit(1)
        self.team("stop", "29")
        # Stopping needs the bound command, so it ran before the checkout was removed.
        wait_until_stopped(wt)
        assert not wt.exists()

    def push(self, wt: Path, message: str = "work") -> str:
        """Commit in the worktree and report that head as the PR's pushed head."""
        (wt / "tracked.txt").write_text(message + "\n")
        head = self.commit(message, cwd=wt)
        (self.root / "pr-head").write_text(head)
        return head

    def test_turn_to_tester_needs_the_clean_pushed_head_then_rings_with_it(self) -> None:
        self.team("start", "29")
        wt, dev = self.worktree("29"), self.pane("team-1-dev")["pane_id"]
        pushed = self.push(wt)
        (wt / "scratch.txt").write_text("not committed\n")
        refused = self.team("turn", "7", "test", cwd=wt, pane=dev, ok=False)
        assert "uncommitted or untracked files" in refused.stderr
        (wt / "scratch.txt").unlink()
        (self.root / "pr-head").write_text("0" * 40)
        refused = self.team("turn", "7", "test", cwd=wt, pane=dev, ok=False)
        assert f"HEAD is {pushed}, not the PR head" in refused.stderr
        assert not self.events("agent", "prompt", "team-1-test", "Your turn")
        (self.root / "pr-head").write_text(pushed)
        self.team("turn", "7", "test", cwd=wt, pane=dev)
        ring = self.events("agent", "prompt")[-1]
        assert ring[2] == "team-1-test"
        assert "https://github.com/o/r/pull/7" in ring[3]
        assert pushed in ring[3]

    def test_turn_to_developer_always_rings_and_reports_a_checkout_problem(self) -> None:
        self.team("start", "29")
        wt, tester = self.worktree("29"), self.pane("team-1-test")["pane_id"]
        self.push(wt)
        self.team("turn", "7", "dev", cwd=wt, pane=tester)
        ring = self.events("agent", "prompt")[-1]
        assert ring[2] == "team-1-dev"
        assert "pr_review.py list 7" in ring[3]
        assert "Fix the checkout first" not in ring[3]
        # Only the developer can repair the tree, so a problem is reported, not refused.
        (wt / "scratch.txt").write_text("left behind\n")
        self.team("turn", "7", "dev", cwd=wt, pane=tester)
        assert "Fix the checkout first" in self.events("agent", "prompt")[-1][3]

    def test_turn_refuses_its_own_role_and_a_pane_outside_the_pair(self) -> None:
        self.team("start", "29")
        wt, dev = self.worktree("29"), self.pane("team-1-dev")["pane_id"]
        self.push(wt)
        before = len(self.events("agent", "prompt"))
        own = self.team("turn", "7", "dev", cwd=wt, pane=dev, ok=False)
        assert "this pane is team-1-dev" in own.stderr
        unnamed = self.team("turn", "7", "test", cwd=wt, ok=False)
        assert "HERDR_PANE_ID is not set" in unnamed.stderr
        assert "Usage:" in self.team("turn", "7", "lead", cwd=wt, pane=dev, ok=False).stderr
        assert len(self.events("agent", "prompt")) == before

    def test_stop_retires_a_clean_merged_pair_and_leaves_the_other_pair_alone(self) -> None:
        self.team("start", "29")
        self.team("start", "30")
        wt = self.worktree("29")
        self.push(wt)
        self.git("merge", "-q", "--ff-only", "task/29")
        (self.root / "databases").write_text(
            "tips_test_t1\ntips_test_t1r\ntips_test_t1r2\ntips_test_t2\ntips_test_t2r\n"
            "tips_dev_t1r\ntips_dev_t2r\n"
        )
        self.clients_exit(1)
        self.team("stop", "29")
        assert not wt.exists()
        assert self.git("branch", "--list", "task/29") == ""
        assert [w["label"] for w in self.state()["workspaces"]] == ["tips-team-2-30"]
        calls = (self.root / "docker-calls").read_text()
        for database in ("tips_test_t1", "tips_test_t1r", "tips_test_t1r2", "tips_dev_t1r"):
            assert f'DROP DATABASE "{database}"' in calls
        assert "_t2" not in calls.replace("tips_test_t1r2", "")
        # The shared worktree's daemon is stopped once, before the checkout is removed.
        assert [e[1:] for e in self.events("dexter") if e[-1] == "stop"] == [[str(wt), "stop"]]
        assert self.worktree("30").is_dir()
        assert self.git("branch", "--list", "task/30") != ""
        assert self.pane("team-2-dev")["agent"] == "codex"

    def test_stop_preserves_dirty_and_unmerged_work(self) -> None:
        self.team("start", "29")
        wt = self.worktree("29")
        self.clients_exit(1)
        (wt / "uncommitted").write_text("keep")
        before = len(self.state()["events"])
        assert "Dirty worktree" in self.team("stop", "29", ok=False).stderr
        self.commit("unmerged", cwd=wt)
        assert "Unmerged worktree" in self.team("stop", "29", ok=False).stderr
        # Refused before any client is stopped or any database is touched.
        assert not any(e[:2] == ["pane", "get"] for e in self.state()["events"][before:])
        assert not (self.root / "docker-calls").exists()
        assert (wt / "uncommitted").read_text() == "keep"
        assert self.git("branch", "--list", "task/29") != ""
        assert self.state()["workspaces"]

    def test_worktree_dirtied_during_shutdown_is_preserved_after_clients_exit(self) -> None:
        self.team("start", "29")
        wt = self.worktree("29")
        self.clients_exit(1)
        self.env["RACE_DIRTY_FILE"] = str(wt / "written-during-shutdown")
        refused = self.team("stop", "29", ok=False)
        assert "client and owned descendants exited" in refused.stdout
        assert "Dirty worktree" in refused.stderr
        assert wt.exists()
        assert self.state()["workspaces"]
        assert not (self.root / "docker-calls").exists()

    def test_failed_daemon_stop_preserves_the_pair_until_it_succeeds(self) -> None:
        self.team("start", "29")
        wt = self.worktree("29")
        self.clients_exit(1)
        (wt / ".dexter/dexter.sh").write_text(
            '#!/bin/sh\necho "$1" >> "$DEXTER_STOP_LOG"\nexit "${DEXTER_STOP_FAIL:-0}"\n'
        )
        log = self.root / "dexter-stop"
        self.env.update(DEXTER_STOP_LOG=str(log), DEXTER_STOP_FAIL="1")
        self.team("stop", "29", ok=False)
        assert wt.exists()
        assert not (self.root / "docker-calls").exists()
        self.env["DEXTER_STOP_FAIL"] = "0"
        self.team("stop", "29")
        assert log.read_text() == "stop\nstop\n"
        assert not wt.exists()

    def test_stop_of_an_unknown_issue_removes_nothing(self) -> None:
        self.team("start", "29")
        result = self.team("stop", "99")
        assert "nothing removed" in result.stdout
        assert self.worktree("29").is_dir()
        assert self.state()["workspaces"]
        assert not (self.root / "docker-calls").exists()


if __name__ == "__main__":
    unittest.main()
