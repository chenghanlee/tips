"""Brief lifecycle tests: real Git and process trees, fake Herdr; never a live pane or client."""

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

from team import bound_command, command_args, execute

SCRIPT = Path(__file__).resolve().parents[1] / "team.py"
# Deliberately fixed test data: changing production defaults must not rewrite tests.
CONFIG = """\
# Agent launch settings. Changes apply to newly started sessions.
# An empty model uses the client's configured default.
[team]
max_teams = 6
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

[agents.impl]
role = "implementer"
kind = "codex"
model = "fixture-impl"
effort = "xhigh"
db_suffix = ""
port_offset = 0

[agents.tester]
role = "tester"
kind = "claude"
model = "fixture-test"
effort = "xhigh"
advisor = "fixture-advisor"
db_suffix = "r"
port_offset = 1

[agents.critic]
role = "designer"
kind = "claude"
model = "fixture-critic"
effort = "high"
persona = "operations: failure and recovery paths"
db_suffix = "c"
port_offset = 2

[agents.second]
role = "tester"
kind = "codex"
model = "fixture-second"
effort = "high"
db_suffix = "s"
port_offset = 3

"""
BRIEF = "Implementer: impl\nRequired reviews: tester, critic\n"
WIDE = "Implementer: impl\nRequired reviews: tester, second, critic\n"
NARROW = "Implementer: impl\nRequired reviews: tester\n"
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
    """Write the production bound command for root using the real Dexter binary."""
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
    """Find the real Dexter daemon for root by matching its arguments."""
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
        # The host writes "client" after its Popen returns, so "child" can appear first
        # and either file can exist before its pid is written.
        pid_files = [self.root / "client", self.root / "child"]
        for _ in range(100):
            if all(f.exists() and f.read_text() for f in pid_files):
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

    def test_graceful_stop_exits_owned_children_and_releases_the_name(self) -> None:
        """The client is signalled, its separate-group child exits on EOF, the name is cleared.

        Herdr may list the kind as released or the name as already gone before the clear.
        """
        cases: list[dict[str, Any]] = [
            {},
            {"listed_kind": None, "omit_kind": False},
            {"listed_kind": None, "omit_kind": True},
            {"clear_error": "agent_not_found"},
        ]
        for flags in cases:
            with self.subTest(flags=flags):
                p = self.client()
                self.save({**json.loads((self.root / "state.json").read_text()), **flags})
                (self.root / "calls").unlink(missing_ok=True)
                r = self.stop()
                assert r.returncode == 0, r.stderr
                assert p.wait(timeout=2) == 0
                try:
                    os.kill(int((self.root / "child").read_text()), 0)
                except ProcessLookupError:
                    pass  # Expected: this owned child must have exited.
                else:
                    raise AssertionError("Owned child survived graceful shutdown")
                calls = [
                    json.loads(line) for line in (self.root / "calls").read_text().splitlines()
                ]
                assert ["agent", "rename", "wT:p1", "--clear"] in calls

    def save(self, state: dict[str, Any]) -> None:
        (self.root / "state.json").write_text(json.dumps(state))

    def test_changed_owner_or_failed_clear_preserves_the_name(self) -> None:
        """Keep the name if the client changes or clearing its name fails."""
        cases = (
            ({"replacement": True, "listed_kind": "codex"}, "occupied=True", False),
            ({"replacement": True, "listed_kind": None}, "leader_argv0='claude'", False),
            ({"listed_kind": "claude"}, "previous_kind='codex', listed_kind='claude'", False),
            ({"clear_error": "permission_denied"}, "permission_denied", True),
        )
        for flags, message, attempted in cases:
            with self.subTest(flags=flags):
                client = self.client()
                self.save({**json.loads((self.root / "state.json").read_text()), **flags})
                (self.root / "calls").unlink(missing_ok=True)
                result = self.stop()
                assert result.returncode != 0
                assert message in result.stderr
                assert client.wait(timeout=2) == 0
                calls = [
                    json.loads(line) for line in (self.root / "calls").read_text().splitlines()
                ]
                # An owner change is detected before any clear; a failed clear is attempted.
                if not attempted:
                    assert "owner changed during shutdown" in result.stderr
                assert (["agent", "rename", "wT:p1", "--clear"] in calls) == attempted

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

# Issues, PRs, comments, reviews and required checks live in the fixture state. Each posted
# comment gets the next id and a time one minute after the previous one.
FAKE_GH = r"""#!/usr/bin/env python3
import datetime, json, os, sys
from pathlib import Path
path = Path(os.environ["HERDR_FIXTURE"])
s = json.loads(path.read_text())
a = sys.argv[1:]
s.setdefault("events", []).append(["gh", *a])
comments = s.setdefault("comments", {})
out, code = "", 0
PASSING = [
    {"name": "checks", "workflow": "CI", "bucket": "pass", "link": "https://ci/1"},
    {"name": "release", "workflow": "CI", "bucket": "pass", "link": "https://ci/1"},
]
if a[:2] == ["issue", "view"]:
    body = s.get("issues", {}).get(a[2], "")
    view = {"body": body, "url": "https://github.com/o/r/issues/" + a[2]}
    out = json.dumps({key: view[key] for key in a[a.index("--json") + 1].split(",")})
elif a[:2] == ["issue", "comment"]:
    if s.get("comments_fail"):
        out, code = "fixture GitHub refused the comment", 1
    else:
        n = sum(len(c) for c in comments.values()) + 1
        at = datetime.datetime(2026, 10, 12, 10, n % 60, tzinfo=datetime.UTC)
        url = "https://github.com/o/r/issues/%s#issuecomment-%d" % (a[2], n)
        comments.setdefault(a[2], []).append(
            {
                "id": n,
                "html_url": url,
                "body": sys.stdin.read(),
                "created_at": at.strftime("%Y-%m-%dT%H:%M:%SZ"),
            }
        )
        out = url
elif a[:2] == ["pr", "view"]:
    briefs = [{"number": int(n)} for n in s.get("pr_briefs", {}).get(a[2], [])]
    view = {
        "headRefOid": s.get("pr_head", ""),
        "baseRefOid": s.get("pr_base", "b" * 40),
        "baseRefName": "main",
        "mergeable": s.get("pr_mergeable", "MERGEABLE"),
        "url": "https://github.com/o/r/pull/" + a[2],
        "closingIssuesReferences": briefs,
    }
    out = json.dumps({key: view[key] for key in a[a.index("--json") + 1].split(",")})
elif a[:2] == ["pr", "checks"]:
    # The head can move, or another observer can post, while a reader is between its
    # first and last view.
    if "head_after_checks" in s:
        s["pr_head"] = s.pop("head_after_checks")
    if "post_on_checks" in s:
        n = sum(len(c) for c in comments.values()) + 1
        url = "https://github.com/o/r/issues/%s#issuecomment-%d" % (a[2], n)
        body = s.pop("post_on_checks")
        comments.setdefault(a[2], []).append({"id": n, "html_url": url, "body": body})
    rows = s.get("checks", PASSING)
    buckets = {row["bucket"] for row in rows}
    if s.get("checks_error"):
        out, code = s["checks_error"], 1
    elif not rows:
        out, code = "no checks reported on the 'task/29' branch", 1
    else:
        out = json.dumps(rows)
        code = 1 if buckets & {"fail", "cancel"} else 8 if "pending" in buckets else 0
elif a[:2] == ["api", "graphql"]:
    query = next(x for x in a if x.startswith("query="))
    name = "reviewThreads" if "reviewThreads" in query else "reviews"
    page = {"pageInfo": {"hasNextPage": False, "endCursor": None}, "nodes": s.get(name, [])}
    out = json.dumps({"data": {"repository": {"pullRequest": {name: page}}}})
elif a[:2] == ["repo", "view"]:
    out = json.dumps({"nameWithOwner": "o/r"})
elif a[0] == "api" and "/rules/branches/" in a[1]:
    required = [{"context": name} for name in s.get("required", ["checks", "release"])]
    rule = {"type": "required_status_checks", "parameters": {"required_status_checks": required}}
    out = json.dumps([{"type": "deletion"}, *([rule] if required else [])])
elif a[0] == "api" and "/comments?" in a[1] and s.get("history_fails"):
    out, code = "fixture comment-history unavailable", 1
elif a[0] == "api" and "/comments?" in a[1]:
    issue = a[1].split("/issues/")[1].split("/")[0]
    page = int(a[1].rsplit("page=", 1)[1])
    out = json.dumps(comments.get(issue, [])[(page - 1) * 100 : page * 100])
else:
    out, code = "Unexpected gh call: " + repr(a), 1
path.write_text(json.dumps(s))
print(out, file=sys.stderr if code == 1 and not out.startswith("[") else sys.stdout)
sys.exit(code)
"""

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
    t = {"tab_id": w["workspace_id"] + ":t1", "workspace_id": w["workspace_id"], "label": "1"}
    x = {"pane_id": w["workspace_id"] + ":p1", "tab_id": t["tab_id"]}
    x["workspace_id"] = w["workspace_id"]
    x["cwd"] = opt("--cwd")
    s["workspaces"].append(w)
    s.setdefault("tabs", []).append(t)
    s["panes"].append(x)
    result = {"workspace": w, "tab": t, "root_pane": x}
elif a[:2] == ["workspace", "close"]:
    s["workspaces"] = [w for w in s["workspaces"] if w["workspace_id"] != a[2]]
    s["tabs"] = [t for t in s.get("tabs", []) if t["workspace_id"] != a[2]]
    s["panes"] = [x for x in s["panes"] if x["workspace_id"] != a[2]]
elif a[:2] == ["tab", "create"]:
    w = opt("--workspace")
    s["count"] = s.get("count", 0) + 1
    t = {"tab_id": "%s:t%d" % (w, s["count"]), "workspace_id": w, "label": opt("--label")}
    x = {"pane_id": "%s:p%d" % (w, s["count"]), "tab_id": t["tab_id"], "workspace_id": w}
    x["cwd"] = opt("--cwd")
    s.setdefault("tabs", []).append(t)
    s["panes"].append(x)
    result = {"tab": t, "root_pane": x}
elif a[:2] == ["tab", "rename"]:
    next(t for t in s["tabs"] if t["tab_id"] == a[2])["label"] = a[3]
elif a[:2] == ["pane", "split"]:
    y = pane(a[2])
    s["count"] = s.get("count", 0) + 1
    x = {
        "pane_id": "%s:p%d" % (y["workspace_id"], s["count"]),
        "tab_id": y["tab_id"],
        "workspace_id": y["workspace_id"],
        "cwd": opt("--cwd"),
        "split": opt("--direction"),
    }
    s["panes"].append(x)
    result = {"pane": x}
elif a[:2] == ["pane", "list"]:
    every = s["panes"] + s.get("strays", [])
    result = {"panes": [x for x in every if x.get("workspace_id") == opt("--workspace")]}
elif a[:2] == ["pane", "rename"]:
    pane(a[2])["label"] = a[3]
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
    x["agent_session"] = {"kind": "id", "value": "session-" + a[2]}
    x["agent_status"] = "blocked" if s.get("start_fails") else "idle"
    if s.get("wrong_start_root"):
        x["cwd"] = s["wrong_start_root"]
    result = {"agent": x}
elif a[:2] == ["agent", "prompt"]:
    # Only a running client accepts a prompt; the dispatcher runs outside the fixture.
    if a[2] == "dispatcher":
        if s.get("dispatcher_down"):
            finish("agent_not_found: dispatcher")
    elif not pane(a[2]).get("agent"):
        finish("agent_not_found: " + a[2])
elif a[:2] == ["agent", "rename"]:
    pane(a[2]).pop("name", None)
else:
    finish("Unexpected " + repr(a))
finish()
"""
)

IDENTITY = ["-c", "user.name=Test", "-c", "user.email=test@example.invalid"]


class Harness(unittest.TestCase):
    """A disposable repository with fake Herdr, gh, Mix, Docker and Dexter on PATH."""

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
            # Stop-time events land after the first checks: ps runs only in stop(). A write
            # dirties the worktree; a visitor pane joins a recorded workspace.
            "ps": (
                '#!/bin/sh\n[ -n "$RACE_DIRTY_FILE" ] && echo raced > "$RACE_DIRTY_FILE"\n'
                "[ -n \"$RACE_VISITOR_WORKSPACE\" ] && python3 - <<'PY'\n"
                "import json, os\n"
                "path = os.environ['HERDR_FIXTURE']\n"
                "workspace = os.environ['RACE_VISITOR_WORKSPACE']\n"
                "state = json.load(open(path))\n"
                "visitor = {'pane_id': workspace + ':p8', 'workspace_id': workspace, 'cwd': '/'}\n"
                "if visitor not in state.get('strays', []):\n"
                "    state['strays'] = state.get('strays', []) + [visitor]\n"
                "json.dump(state, open(path, 'w'))\n"
                "PY\nexit 0\n"
            ),
        }
        for name, body in fakes.items():
            (self.bin / name).write_text(body)
            (self.bin / name).chmod(0o755)
        execute(["git", "init", "-q", "-b", "main", str(self.repo)], env=self.env, check=True)
        (self.repo / ".gitignore").write_text(
            ".codex/\n.agents/\n.dexter/\n.worktrees/\nagent/lsp/dexter/vendor/\n"
            "agent/teams/allocations/\ndeps/\ntmp/\n"
        )
        for script in ("team.py", "board.py", "pr_review.py"):
            (self.repo / "agent/teams" / script).write_text((SCRIPT.parent / script).read_text())
        (self.repo / "agent/teams/config.toml").write_text(CONFIG)
        (self.repo / "tracked.txt").write_text("base\n")
        binary = self.repo / "agent/lsp/dexter/vendor/dexter"
        binary.write_text(FAKE_DEXTER)
        binary.chmod(0o755)
        self.commit("base")
        self.git("remote", "add", "origin", str(self.repo))
        self.git("update-ref", "refs/remotes/origin/main", "HEAD")
        issues = {"29": BRIEF, "30": WIDE, "31": NARROW}
        self.save({"workspaces": [], "panes": [], "events": [], "issues": issues})

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

    def workspaces(self) -> list[str]:
        return [w["label"] for w in self.state()["workspaces"]]

    def tabs(self, workspace: str) -> dict[str, list[str]]:
        """Each tab label of the workspace with the labels of its panes."""
        state = self.state()
        panes = state["panes"]
        return {
            tab["label"]: [str(p.get("label", "")) for p in panes if p["tab_id"] == tab["tab_id"]]
            for tab in state.get("tabs", [])
            if tab["workspace_id"] == workspace
        }

    def record(self, slot: int) -> dict[str, Any]:
        return json.loads((self.repo / f"agent/teams/allocations/{slot}.json").read_text())

    def recorded_briefs(self) -> set[str]:
        files = (self.repo / "agent/teams/allocations").glob("*.json")
        return {json.loads(path.read_text())["brief"] for path in files}

    def clients_exit(self, slot: int) -> None:
        """The slot's clients have exited: their panes are back at the shell."""
        state = self.state()
        for pane in state["panes"]:
            if str(pane.get("label", "")).startswith(f"team-{slot}-"):
                for key in ("agent", "name", "agent_status", "agent_session"):
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

    def worktree(self, name: str) -> Path:
        return self.repo / ".worktrees" / name

    def push(self, wt: Path, message: str = "work", pr: str = "7", brief: str = "29") -> str:
        """Commit in the worktree and report that head as the PR's pushed head."""
        (wt / "tracked.txt").write_text(message + "\n")
        head = self.commit(message, cwd=wt)
        self.update(pr_head=head, pr_briefs={**self.state().get("pr_briefs", {}), pr: [brief]})
        return head

    def launch_env(self, label: str) -> tuple[str, str]:
        env = self.pane(label)["launch_env"]
        return env["TIPS_DB_SUFFIX"], env["TIPS_TEST_PORT"]

    def system_prompt(self, label: str) -> str:
        argv = self.pane(label)["launch_argv"]
        return argv[argv.index("--append-system-prompt") + 1]

    def comments(self, issue: str) -> list[dict[str, Any]]:
        return self.state().get("comments", {}).get(issue, [])


class PairLifecycleTest(Harness):
    def test_start_launches_the_pair_in_one_prepared_worktree(self) -> None:
        # origin/main moves on and the launcher's checkout is dirty: neither leaks in.
        (self.repo / "AGENTS.md").write_text("Committed instructions.\n")
        release = self.commit("instructions")
        (self.repo / "AGENTS.md").write_text("Uncommitted launcher-only instructions.\n")
        self.team("start", "29")
        wt = self.worktree("29")
        assert self.git("branch", "--show-current", cwd=wt) == "task/29"
        assert self.git("rev-parse", "HEAD", cwd=wt) == release
        assert (wt / "AGENTS.md").read_text() == "Committed instructions.\n"
        assert self.workspaces() == ["team-1-29"]
        assert self.tabs("w1") == {
            "implementers": ["team-1-impl"],
            "reviewers": ["team-1-tester"],
        }
        assert self.record(1)["tabs"] == {"implementers": "w1:t1", "reviewers": "w1:t2"}
        impl, tester = self.pane("team-1-impl"), self.pane("team-1-tester")
        assert (impl["agent"], tester["agent"]) == ("codex", "claude")
        assert (impl["tab_id"], tester["tab_id"]) == ("w1:t1", "w1:t2")
        assert impl["cwd"] == tester["cwd"] == str(wt)
        # Each client has its own database and port; both use the worktree's one Dexter.
        shared = {
            "PGPORT": "5433",
            "MIX_ENV": "test",
            "TIPS_CHECK_TIMEOUT_SECONDS": "1800",
            "TIPS_TEAM_CONFIG": str(self.repo / "agent/teams/config.toml"),
            "TIPS_PROVIDER_ENV_FILE": str(self.repo / ".env"),
            "TIPS_DEXTER": str(wt / ".dexter/dexter.sh"),
        }
        assert impl["launch_env"] == {
            **shared,
            "TIPS_DB_SUFFIX": "_t1",
            "TIPS_TEST_PORT": "4110",
            # Codex's sandbox cannot write the shared Hex cache; Claude keeps the default.
            "HEX_HOME": str(wt / "tmp/hex"),
        }
        assert tester["launch_env"] == {
            **shared,
            "TIPS_DB_SUFFIX": "_t1r",
            "TIPS_TEST_PORT": "4111",
            "HEX_HOME": None,
        }
        impl_brief, tester_brief = impl["launch_argv"][-1], self.system_prompt("team-1-tester")
        assert impl_brief.startswith("You are impl, the implementer for brief #29;")
        assert "team-1-impl" in impl_brief
        assert "team.py turn <pr> tester" in impl_brief
        assert tester_brief.startswith("You are tester, the merge-confirming tester for brief #29;")
        assert "team.py turn <pr> impl" in tester_brief
        assert "Put tester, <session> on line 2" in tester_brief
        assert "persona" not in tester_brief
        for text in (impl_brief, tester_brief):
            assert f"TIPS_DEXTER={wt / '.dexter/dexter.sh'}" in text
        # Claude holds its brief as a system prompt, so it alone needs a first message.
        assert self.events("agent", "prompt") == [["agent", "prompt", "team-1-tester", "Begin."]]
        argv = tester["launch_argv"]
        assert {"fixture-impl", "never"} <= set(impl["launch_argv"])
        assert "fixture-test" in argv
        # The advisor is the entry's own setting; the implementer has none.
        assert argv[argv.index("--advisor") + 1] == "fixture-advisor"
        assert "--advisor" not in impl["launch_argv"]
        plugins = json.loads(argv[argv.index("--settings") + 1])["enabledPlugins"]
        assert plugins["elixir-lsp@elixir-agent-tools"] is False
        assert plugins["mix-credo@elixir-agent-tools"] is True
        codex = tomllib.loads((wt / ".codex/config.toml").read_text())
        assert codex["plugins"]["mix-credo@elixir-agent-tools"]["enabled"] is True
        assert "mcp_servers" not in codex
        # The shared worktree is prepared once, before either client starts.
        assert self.events("mix") == [["mix", str(wt), "deps.get", "--check-locked"]]
        assert self.state()["mix_env"] == {"HEX_HOME": str(wt / "tmp/hex"), "MIX_ENV": "test"}
        assert [e[2] for e in self.events("dexter")] == ["query", "reindex"]
        first_launch = self.state()["events"].index(self.events("agent", "start")[0])
        assert self.state()["events"].index(self.events("dexter")[-1]) < first_launch
        assert self.git("status", "--porcelain", cwd=wt) == ""
        # The bound command keeps its root and sources from any directory.
        env = dict(self.env)
        env.pop("DEXTER_ELIXIR_LIB_ROOT")
        query = ["query", "hover", "a.ex", "1", "1"]
        execute(["/bin/sh", wt / ".dexter/dexter.sh", *query], cwd=self.root, env=env, check=True)
        assert self.state()["events"][-1] == ["dexter", str(wt), *query]
        assert self.state()["dexter_stdlib"] == str(self.stdlib)
        # The record names the pair and each client's session; restart, handoff and
        # teardown prove its use.
        record = self.record(1)
        assert (record["brief"], record["implementer"], record["tester"]) == (
            "29",
            "impl",
            "tester",
        )
        assert record["agents"]["tester"]["session"] == "session-team-1-tester"
        # Each launch is recorded on the brief as the launched client, with its allocation.
        assert [c["body"] for c in self.comments("29")] == [
            f"EVENT implementer team-1-impl session-team-1-impl\nlaunched codex in {wt}; "
            "database suffix _t1; port 4110",
            f"EVENT tester team-1-tester session-team-1-tester\nlaunched claude in {wt}; "
            "database suffix _t1r; port 4111",
        ]
        # A refused post is an error after the launch itself: the record stands and the
        # message says how to post the EVENT by hand.
        self.update(comments_fail=True)
        refused = self.team("start", "31", ok=False)
        assert "EVENT not recorded on #31" in refused.stderr
        assert (
            "board.py post 31 EVENT --as implementer team-2-impl session-team-2-impl"
            in refused.stderr
        )
        assert self.record(2)["agents"]["impl"]["session"] == "session-team-2-impl"

    def test_brief_roster_is_validated_before_any_change(self) -> None:
        cases = {
            "40": ("Required reviews: tester\n", "needs an Implementer: and a Required reviews"),
            "41": ("Implementer: impl\n", "needs an Implementer: and a Required reviews"),
            "42": ("Implementer: impl\nRequired reviews: tester, ghost\n", "not a configured"),
            "43": ("Implementer: tester\nRequired reviews: critic\n", "not an implementer"),
            "44": ("Implementer: impl\nRequired reviews: critic\n", "names no tester"),
            "45": ("Implementer: impl\nRequired reviews: tester, impl\n", "cannot review"),
            "46": ("Implementer: impl\nRequired reviews: tester, tester\n", "repeated name"),
            "47": ("Implementer: impl\nRequired reviews: tester,\n", "empty or repeated"),
        }
        self.update(issues={**self.state()["issues"], **{k: v[0] for k, v in cases.items()}})
        for brief, (_, message) in cases.items():
            with self.subTest(brief=brief):
                assert message in self.team("start", brief, ok=False).stderr
                assert not self.worktree(brief).exists()
        assert not self.state()["workspaces"]
        assert not (self.repo / "agent/teams/allocations").exists()

    def test_restart_keeps_live_clients_and_relaunches_missing_ones_from_the_record(self) -> None:
        self.team("start", "29")
        wt = self.worktree("29")
        (wt / "tracked.txt").write_text("unfinished work\n")
        before = len(self.state()["events"])
        # Live clients are left alone.
        self.team("start", "29")
        later = self.state()["events"][before:]
        assert not any(e[:2] in (["agent", "start"], ["pane", "run"]) for e in later)
        assert not any(e[0] == "mix" for e in later)
        # A missing client is relaunched with the database and port it was launched with,
        # even after config.toml changed them; the worktree keeps its unfinished work.
        config = self.repo / "agent/teams/config.toml"
        config.write_text(
            CONFIG.replace('db_suffix = "r"', 'db_suffix = "z"').replace(
                "port_offset = 1", "port_offset = 5"
            )
        )
        self.clients_exit(1)
        self.team("start", "29")
        assert len(self.events("agent", "start")) == 4
        assert self.launch_env("team-1-tester") == ("_t1r", "4111")
        assert (wt / "tracked.txt").read_text() == "unfinished work\n"
        assert len(self.events("mix")) == 1
        assert self.workspaces() == ["team-1-29"]
        # A closed pane is reopened in its role's tab; the allocation keeps its resources.
        # Herdr closes a tab with its last pane, so the role gets a new tab too.
        old = self.record(1)["agents"]["impl"]
        state = self.state()
        state["panes"] = [x for x in state["panes"] if x.get("label") != "team-1-impl"]
        state["tabs"] = [t for t in state["tabs"] if t["tab_id"] != old["tab"]]
        self.save(state)
        self.clients_exit(1)
        self.team("start", "29")
        new = self.record(1)["agents"]["impl"]
        assert new["pane"] != old["pane"]
        assert new["workspace"] == old["workspace"]
        assert new["tab"] != old["tab"]
        assert self.record(1)["tabs"]["implementers"] == new["tab"]
        assert (new["db_suffix"], new["port"]) == (old["db_suffix"], old["port"])
        assert self.pane("team-1-impl")["pane_id"] == new["pane"]
        assert self.launch_env("team-1-impl") == ("_t1", "4110")
        assert self.tabs("w1") == {
            "reviewers": ["team-1-tester"],
            "implementers": ["team-1-impl"],
        }
        # A vanished workspace is recreated with both clients in their tabs.
        self.update(workspaces=[], tabs=[], panes=[])
        self.team("start", "29")
        assert self.workspaces() == ["team-1-29"]
        workspace = self.record(1)["workspace"]
        assert workspace != old["workspace"]
        assert self.tabs(workspace) == {
            "implementers": ["team-1-impl"],
            "reviewers": ["team-1-tester"],
        }
        assert self.launch_env("team-1-impl") == ("_t1", "4110")
        # A client cannot change kind or disappear from config while it is allocated.
        self.clients_exit(1)
        config.write_text(
            CONFIG.replace(
                'kind = "codex"\nmodel = "fixture-impl"', 'model = "fixture-impl"\nkind = "claude"'
            )
        )
        assert "launched as codex; preserved" in self.team("start", "29", ok=False).stderr
        config.write_text(CONFIG.replace("[agents.tester]", "[agents.other]"))
        assert "not a configured entry" in self.team("start", "29", ok=False).stderr
        # The pair cannot change hands while the checkout is theirs.
        config.write_text(CONFIG)
        starts = len(self.events("agent", "start"))
        for body in (
            "Implementer: impl\nRequired reviews: second, tester, critic\n",
            "Implementer: impl\nRequired reviews: second\n",
        ):
            with self.subTest(body=body):
                self.update(issues={**self.state()["issues"], "29": body})
                refused = self.team("start", "29", ok=False)
                assert "changed its implementer or merge-confirming tester" in refused.stderr
        assert len(self.events("agent", "start")) == starts
        assert self.record(1)["tester"] == "tester"

    def test_each_brief_takes_its_own_slot_from_the_records_until_none_is_free(self) -> None:
        path = self.repo / "agent/teams/config.toml"
        path.write_text(CONFIG.replace("max_teams = 6", "max_teams = 2"))
        self.team("start", "29")
        # A new allocation never takes a recorded database, port or partition of one,
        # even after configuration changes: slot 2's implementer would use a partition of _t1r.
        path.write_text(
            CONFIG.replace("max_teams = 6", "max_teams = 2")
            .replace('db_suffix_prefix = "_t"', 'db_suffix_prefix = "_t1r"')
            .replace("port_base = 4100", "port_base = 5100")
        )
        refused = self.team("start", "30", ok=False)
        assert "database _t1r2 or port 5120 collides with team-1-tester's" in refused.stderr
        assert not self.worktree("30").exists()
        path.write_text(CONFIG.replace("max_teams = 6", "max_teams = 2"))
        self.team("start", "30")
        second = self.pane("team-2-impl")
        assert second["cwd"] == str(self.worktree("30"))
        assert self.launch_env("team-2-impl") == ("_t2", "4120")
        assert self.pane("team-1-impl")["cwd"] == str(self.worktree("29"))
        # The same reviewer entry serves both briefs from separate resources.
        self.push(self.worktree("30"), pr="8", brief="30")
        self.team("review", "8", "critic")
        self.push(self.worktree("29"), pr="7", brief="29")
        # Config moved the critic onto the running tester's resources: refused in its slot.
        path.write_text(
            CONFIG.replace("max_teams = 6", "max_teams = 2")
            .replace('db_suffix = "r"', 'db_suffix = "z"')
            .replace("port_offset = 1", "port_offset = 5")
            .replace('db_suffix = "c"', 'db_suffix = "r"')
            .replace("port_offset = 2", "port_offset = 1")
        )
        refused = self.team("review", "7", "critic", ok=False)
        assert "database _t1r or port 4111 collides with team-1-tester's" in refused.stderr, (
            refused.stderr
        )
        path.write_text(CONFIG.replace("max_teams = 6", "max_teams = 2"))
        self.team("review", "7", "critic")
        assert self.launch_env("team-1-critic") == ("_t1c", "4112")
        assert self.launch_env("team-2-critic") == ("_t2c", "4122")
        self.update(issues={**self.state()["issues"], "32": BRIEF})
        refused = self.team("start", "32", ok=False)
        assert "No free slot" in refused.stderr
        assert not self.worktree("32").exists()
        # Slots come from the records, so a slot whose workspaces are gone is still taken.
        self.update(workspaces=[], tabs=[], panes=[])
        assert "No free slot" in self.team("start", "32", ok=False).stderr

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

    def test_failed_preparation_keeps_a_recoverable_reservation_and_never_launches(self) -> None:
        failures = (
            ("31", {"mix_fails": True}, "fixture mix failed"),
            ("30", {"dexter_fails": True}, "fixture Dexter failed"),
            ("29", {"dexter_empty": True}, "no MixProject"),
        )
        healthy = {"mix_fails": False, "dexter_fails": False, "dexter_empty": False}
        for brief, flags, message in failures:
            with self.subTest(flags=flags):
                self.update(**{**healthy, **flags})
                assert message in self.team("start", brief, ok=False).stderr
                assert not self.events("agent", "start")
                # The slot stays reserved, so stop can clean up what was created.
                assert self.worktree(brief).is_dir()
                assert brief in self.recorded_briefs()
        self.update(**healthy)
        # A fetch that failed is retried, then the pair launches as usual.
        self.team("start", "31")
        assert len([e for e in self.events("mix") if e[1] == str(self.worktree("31"))]) == 2
        assert len(self.events("agent", "start")) == 2
        # The other reservations retire through the normal path.
        self.team("stop", "30")
        assert not self.worktree("30").exists()
        assert "30" not in self.recorded_briefs()
        # Missing tools are refused before a worktree or record exists.
        self.update(issues={**self.state()["issues"], "34": BRIEF})
        self.env["DEXTER_ELIXIR_LIB_ROOT"] = str(self.root / "no-sources")
        assert "sources are missing" in self.team("start", "34", ok=False).stderr
        self.env["DEXTER_ELIXIR_LIB_ROOT"] = str(self.stdlib)
        (self.repo / "agent/lsp/dexter/vendor/dexter").unlink()
        assert "Missing executable" in self.team("start", "34", ok=False).stderr
        assert not self.worktree("34").exists()
        assert self.recorded_briefs() == {"29", "31"}

    def test_lost_setup_output_never_starts_a_client(self) -> None:
        self.update(setup_lost=True)
        refused = self.team("start", "29", ok=False)
        assert "timed out waiting for output match" in refused.stderr
        assert not self.events("agent", "start")

    def test_client_started_blocked_or_in_another_root_is_reported(self) -> None:
        cases = (
            ("29", {"start_fails": True}, "startup did not complete; inspect"),
            ("30", {"wrong_start_root": "/"}, "runs in /, not its worktree; preserved"),
        )
        for brief, flags, rerun in cases:
            with self.subTest(flags=flags):
                self.update(**{"start_fails": False, "wrong_start_root": "", **flags})
                refused = self.team("start", brief, ok=False)
                assert "unexpected state or root" in refused.stderr
                assert len(self.events("agent", "start")) == 1
                assert not self.events("agent", "prompt")
                # The client is still there but its startup never completed: a rerun must
                # not call it ready or start another; the operator exits it, then reruns.
                refused = self.team("start", brief, ok=False)
                assert rerun in refused.stderr, refused.stderr
                assert len(self.events("agent", "start")) == 1
                assert not self.events("agent", "prompt")
                self.update(events=[], start_fails=False, wrong_start_root="")
                self.clients_exit(int(brief) - 28)
                self.team("start", brief)
                assert len(self.events("agent", "start")) == 2
                # A replacement for a client that once ran gets the same treatment: the
                # old session does not vouch for it.
                self.clients_exit(int(brief) - 28)
                self.update(events=[], **flags)
                assert "unexpected state or root" in self.team("start", brief, ok=False).stderr
                assert rerun in self.team("start", brief, ok=False).stderr
                assert len(self.events("agent", "start")) == 1
                self.update(events=[], start_fails=False, wrong_start_root="")

    def test_invalid_config_refuses_before_herdr(self) -> None:
        path = self.repo / "agent/teams/config.toml"
        cases = (
            ('port_base = "wrong"', "team.port_base must be int"),
            ('role = "architect"', "agents.critic.role must be one of"),
            ('adviser = "x"', "unknown keys ['adviser']"),
            ('model = "x"\nadvisor = "y"', "advisor applies to Claude"),
            # Slot 10's databases would match slot 1's stem.
            ("max_teams = 10", "overlapping database"),
        )
        originals = (
            "port_base = 4100",
            'role = "designer"',
            'advisor = "fixture-advisor"',
            'model = "fixture-impl"',
            "max_teams = 6",
        )
        for (edited, message), original in zip(cases, originals, strict=True):
            with self.subTest(edited=edited):
                path.write_text(CONFIG.replace(original, edited))
                assert message in self.team("start", "29", ok=False).stderr
        assert self.state()["events"] == []
        assert not (self.root / "docker-calls").exists()

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

    @unittest.skipUnless(
        os.environ.get("TIPS_TEST_REAL_CODEX"), "opt-in installed Codex config check"
    )
    def test_installed_codex_accepts_generated_configuration(self) -> None:
        legacy = self.repo / ".codex/config.toml"
        legacy.parent.mkdir()
        legacy.write_text('[mcp_servers.elixir-lsp]\ncommand = "/usr/bin/false"\n')
        self.team("start", "29")
        wt = self.worktree("29")
        launch = self.pane("team-1-impl")["launch_argv"]
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

    def use_real_dexter(self) -> None:
        """Test new worktree setup with the real Dexter binary and a real Mix project."""
        self.env["TIPS_DEXTER_HOME"] = os.environ["TIPS_TEST_REAL_DEXTER"]
        self.env["DEXTER_ELIXIR_LIB_ROOT"] = os.environ["DEXTER_ELIXIR_LIB_ROOT"]
        self.env["DEXTER_DAEMON_IDLE_TIMEOUT"] = "5s"
        (self.bin / "elixir").unlink()  # the real toolchain must match the sources
        source = 'defmodule Sample do\n  @doc "Original documentation"\n'
        (self.repo / "sample.ex").write_text(source + "  def greet(name), do: name\nend\n")
        (self.repo / "mix.exs").write_text(MIX_PROJECT)
        self.commit("mix fixture")

    @unittest.skipUnless(os.environ.get("TIPS_TEST_REAL_DEXTER"), REAL_DEXTER)
    def test_two_briefs_use_isolated_real_daemons(self) -> None:
        self.use_real_dexter()
        roots = [self.worktree("29"), self.worktree("30")]
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

    def prompts(self) -> dict[str, str]:
        """The latest prompt each recipient received."""
        return {e[2]: e[3] for e in self.events("agent", "prompt")}

    def test_turn_to_reviewers_needs_the_pushed_head_and_notifies_every_reviewer(self) -> None:
        self.team("start", "29")
        wt, impl = self.worktree("29"), self.pane("team-1-impl")["pane_id"]
        pushed = self.push(wt)
        prompts = len(self.events("agent", "prompt"))
        (wt / "scratch.txt").write_text("not committed\n")
        refused = self.team("turn", "7", "tester", cwd=wt, pane=impl, ok=False)
        assert "uncommitted or untracked files" in refused.stderr
        (wt / "scratch.txt").unlink()
        self.update(pr_head="0" * 40)
        refused = self.team("turn", "7", "tester", cwd=wt, pane=impl, ok=False)
        assert f"HEAD is {pushed}, not the PR head" in refused.stderr
        assert len(self.events("agent", "prompt")) == prompts
        self.update(pr_head=pushed)
        self.team("turn", "7", "tester", cwd=wt, pane=impl)
        # The critic is not launched: the handoff asks the dispatcher and records the notice.
        sent = self.events("agent", "prompt")[prompts:]
        assert [e[2] for e in sent] == ["team-1-tester", "dispatcher"]
        ring = sent[0][3]
        assert "https://github.com/o/r/pull/7" in ring
        assert pushed in ring
        assert "agent/skills/review-software-correctness/SKILL.md from this worktree" in ring
        assert "Put tester, <session> on line 2" in ring
        assert "team.py turn 7 impl; do not wait for the other reviews" in ring
        assert "asked the dispatcher to launch critic" in ring
        assert "pr_review.py observe 7 reports ready to merge" in ring
        assert "After your LGTM" not in ring
        assert sent[1][3] == (
            "https://github.com/o/r/pull/7 review: run agent/teams/team.py review 7 critic"
        )
        assert self.comments("7")[-1]["body"] == (
            "EVENT implementer team-1-impl session-team-1-impl\n"
            f"pending review of {pushed} by critic: not launched; "
            "launch requested from the dispatcher"
        )
        # A new head reaches the tester and the launched critic in the same handoff,
        # before either has reviewed.
        self.team("review", "7", "critic")
        moved = self.push(wt, "second push")
        prompts = len(self.events("agent", "prompt"))
        self.team("turn", "7", "tester", cwd=wt, pane=impl)
        sent = self.events("agent", "prompt")[prompts:]
        assert [e[2] for e in sent] == ["team-1-tester", "team-1-critic"]
        assert all(moved in e[3] for e in sent)
        assert f"git checkout --detach {moved}" in sent[1][3]
        assert "herdr agent prompt team-1-tester" in sent[1][3]
        assert "asked the dispatcher" not in sent[0][3]
        # The brief cannot move the merge-confirming tester under a running pair.
        prompts = len(self.events("agent", "prompt"))
        body = "Implementer: impl\nRequired reviews: second, critic\n"
        self.update(issues={**self.state()["issues"], "29": body})
        refused = self.team("turn", "7", "tester", cwd=wt, pane=impl, ok=False)
        assert "changed its implementer or merge-confirming tester" in refused.stderr
        assert len(self.events("agent", "prompt")) == prompts

    def test_absent_reviewer_and_failed_sends_are_reported_after_every_send(self) -> None:
        self.team("start", "30")
        wt, impl = self.worktree("30"), self.pane("team-1-impl")["pane_id"]
        self.push(wt, pr="8", brief="30")
        self.team("review", "8", "critic")
        # The critic's client exited and the dispatcher is gone: both sends fail, the
        # tester is still notified and the pending notice for second is recorded.
        state = self.state()
        critic = next(x for x in state["panes"] if x.get("label") == "team-1-critic")
        critic.pop("agent")
        state["dispatcher_down"] = True
        self.save(state)
        prompts = len(self.events("agent", "prompt"))
        refused = self.team("turn", "8", "tester", cwd=wt, pane=impl, ok=False)
        assert [e[2] for e in self.events("agent", "prompt")[prompts:]] == [
            "team-1-tester",
            "team-1-critic",
            "dispatcher",
        ]
        assert "Notified team-1-tester" in refused.stdout
        assert "Handoff incomplete; failed sends: team-1-critic: agent_not_found" in refused.stderr
        assert "dispatcher: agent_not_found: dispatcher" in refused.stderr
        assert "pending review of" in self.comments("8")[-1]["body"]
        assert "by second: not launched" in self.comments("8")[-1]["body"]

    def test_known_merge_conflict_blocks_review_handoff_until_resolved(self) -> None:
        self.team("start", "29")
        wt, impl = self.worktree("29"), self.pane("team-1-impl")["pane_id"]
        head = self.push(wt)
        self.team("review", "7", "critic")
        prompts = len(self.events("agent", "prompt"))
        # A conflict that cannot be recorded blocks the handoff with the failure and error.
        self.update(pr_mergeable="CONFLICTING", comments_fail=True)
        refused = self.team("turn", "7", "tester", cwd=wt, pane=impl, ok=False)
        unrecorded = f"Known failure not recorded on PR 7: Merge conflict at head {head}"
        assert unrecorded in refused.stderr
        assert "Error: fixture GitHub refused the comment" in refused.stderr
        # An unreadable comment history loses neither the failure nor the error.
        self.update(comments_fail=False, history_fails=True)
        refused = self.team("turn", "7", "tester", cwd=wt, pane=impl, ok=False)
        assert unrecorded in refused.stderr
        assert "Error: fixture comment-history unavailable" in refused.stderr
        # Recorded, it still blocks; later unavailable reads neither record nor clear it.
        self.update(history_fails=False)
        refused = self.team("turn", "7", "tester", cwd=wt, pane=impl, ok=False)
        finding = self.comments("7")[-1]["html_url"]
        assert f"Known merge conflict {finding}" in refused.stderr
        assert "merge origin/main and push" in refused.stderr
        self.update(pr_mergeable="UNKNOWN", checks_error="fixture checks unavailable")
        refused = self.team("turn", "7", "tester", cwd=wt, pane=impl, ok=False)
        assert f"Known merge conflict {finding}" in refused.stderr
        assert self.comments("7")[-1]["html_url"] == finding
        # After the repair push GitHub has not computed mergeability yet: rerun, not remerge.
        head = self.push(wt, "merged main")
        refused = self.team("turn", "7", "tester", cwd=wt, pane=impl, ok=False)
        assert f"has not reported mergeability for {head} yet" in refused.stderr
        assert "rerun turn" in refused.stderr
        assert len(self.events("agent", "prompt")) == prompts
        # A mergeable read resolves it with a new event, and the handoff goes out.
        self.update(pr_mergeable="MERGEABLE")
        self.team("turn", "7", "tester", cwd=wt, pane=impl)
        resolved = self.comments("7")[-1]["body"]
        assert '"state":"resolved"' in resolved
        assert f"Resolves {finding}." in resolved
        assert [e[2] for e in self.events("agent", "prompt")[prompts:]] == [
            "team-1-tester",
            "team-1-critic",
        ]

    def test_turn_to_implementer_always_rings_and_reports_a_checkout_problem(self) -> None:
        self.team("start", "29")
        wt, tester = self.worktree("29"), self.pane("team-1-tester")["pane_id"]
        pushed = self.push(wt)
        # A failed check is recorded as the tester and named in the handoff.
        failed = {"name": "checks", "workflow": "CI", "bucket": "fail", "link": "https://ci/2"}
        self.update(checks=[failed])
        self.team("turn", "7", "impl", cwd=wt, pane=tester)
        finding = self.comments("7")[-1]
        assert finding["body"].startswith("FINDING tester team-1-tester session-team-1-tester\n")
        ring = self.events("agent", "prompt")[-1]
        assert ring[2] == "team-1-impl"
        assert "pr_review.py list 7" in ring[3]
        assert "pr_review.py observe 7" in ring[3]
        assert f"Open findings: check:CI/checks {finding['html_url']}" in ring[3]
        assert "agent/skills/implement-software/SKILL.md from this worktree" in ring[3]
        assert "Fix the checkout first" not in ring[3]
        # Only the implementer can repair the tree, so a problem is reported, not refused.
        (wt / "scratch.txt").write_text("left behind\n")
        self.team("turn", "7", "impl", cwd=wt, pane=tester)
        assert "Fix the checkout first" in self.events("agent", "prompt")[-1][3]
        (wt / "scratch.txt").unlink()
        self.update(pr_head="0" * 40)
        self.team("turn", "7", "impl", cwd=wt, pane=tester)
        assert f"HEAD is {pushed}, not the PR head" in self.events("agent", "prompt")[-1][3]

    def test_turn_refuses_outside_callers_wrong_briefs_and_wrong_checkouts(self) -> None:
        self.team("start", "29")
        self.team("start", "30")
        wt, impl = self.worktree("29"), self.pane("team-1-impl")["pane_id"]
        self.push(wt)
        self.team("review", "7", "critic")
        prompts = len(self.events("agent", "prompt"))
        critic = self.pane("team-1-critic")["pane_id"]
        other = self.pane("team-2-impl")["pane_id"]
        cases: list[tuple[tuple[str, str], Path, str | None, str]] = [
            (("7", "impl"), wt, impl, "this pane is impl"),
            (("7", "critic"), wt, impl, "between impl and tester"),
            # A reviewer never holds the pair checkout.
            (("7", "tester"), wt, critic, "this pane is critic"),
            (("7", "tester"), wt, None, "HERDR_PANE_ID is not set"),
            (("7", "tester"), self.repo, impl, "Run turn from the pair checkout"),
            # The other brief's pair cannot hand off a PR that closes this brief.
            (("7", "tester"), self.worktree("30"), other, "does not close brief #30"),
            (("7", "Lead"), wt, impl, "Usage:"),
        ]
        for args, cwd, pane, message in cases:
            with self.subTest(args=args, message=message):
                refused = self.team("turn", *args, ok=False, cwd=cwd, pane=pane)
                assert message in refused.stderr
        assert len(self.events("agent", "prompt")) == prompts

    def test_review_pins_the_reviewer_in_its_own_worktree_at_the_pr_head(self) -> None:
        self.team("start", "29")
        head = self.push(self.worktree("29"))
        self.team("review", "7", "critic")
        wt = self.worktree("review-7-critic")
        assert self.git("rev-parse", "HEAD", cwd=wt) == head
        assert self.git("branch", "--show-current", cwd=wt) == ""
        critic = self.pane("team-1-critic")
        assert critic["cwd"] == str(wt)
        assert self.launch_env("team-1-critic") == ("_t1c", "4112")
        assert critic["launch_env"]["TIPS_DEXTER"] == str(wt / ".dexter/dexter.sh")
        brief = self.system_prompt("team-1-critic")
        assert brief.startswith("You are critic, the reviewing designer for brief #29;")
        assert "Your persona: operations: failure and recovery paths." in brief
        assert (
            f"Review PR https://github.com/o/r/pull/7 from this worktree, pinned at {head}" in brief
        )
        assert "critic, <session> on line 2" in brief
        assert "herdr agent prompt team-1-tester" in brief
        assert "Never run agent/teams/team.py turn" in brief
        assert "--advisor" not in critic["launch_argv"]
        # The reviewer's worktree is prepared like the pair's, for one client.
        assert ["mix", str(wt), "deps.get", "--check-locked"] in self.events("mix")
        assert ["dexter", str(wt), "reindex"] in self.events("dexter")
        allocation = self.record(1)["agents"]["critic"]
        assert (allocation["pr"], allocation["head"]) == ("7", head)
        assert allocation["session"] == "session-team-1-critic"
        # The lead adds a tester to the brief: it is a Codex client with its own resources.
        self.update(issues={**self.state()["issues"], "29": WIDE})
        self.team("review", "7", "second")
        second = self.pane("team-1-second")
        assert second["agent"] == "codex"
        assert self.launch_env("team-1-second") == ("_t1s", "4113")
        assert "the additional tester for brief #29" in second["launch_argv"][-1]
        # Every reviewer is a pane in the team's workspace: designers in their own tab,
        # the second tester split off the merge-confirming tester's pane.
        assert self.workspaces() == ["team-1-29"]
        assert self.tabs("w1") == {
            "implementers": ["team-1-impl"],
            "reviewers": ["team-1-tester", "team-1-second"],
            "designers": ["team-1-critic"],
        }
        assert second["split"] == "right"
        # A new head: a running reviewer keeps its head and its record says so.
        moved = self.push(self.worktree("29"), "second push")
        starts = len(self.events("agent", "start"))
        assert (
            f"Already running: team-1-critic at {head}" in self.team("review", "7", "critic").stdout
        )
        assert self.git("rev-parse", "HEAD", cwd=wt) == head
        assert self.record(1)["agents"]["critic"]["head"] == head
        assert len(self.events("agent", "start")) == starts
        # Another client in the reviewer's pane is not the reviewer, however it is named.
        self.clients_exit(1)
        state = self.state()
        pane = next(x for x in state["panes"] if x.get("label") == "team-1-critic")
        pane.update(agent="claude", name="team-1-critic", cwd=str(self.repo))
        self.save(state)
        refused = self.team("review", "7", "critic", ok=False)
        assert "not its worktree; preserved" in refused.stderr, refused.stderr
        pane.update(agent="codex", name="visitor", cwd=str(self.repo))
        self.save(state)
        assert (
            "conflicting client; preserved" in self.team("review", "7", "critic", ok=False).stderr
        )
        assert len(self.events("agent", "start")) == starts
        # A dropped reviewer is refused, running or not; so is a brief that moved the pair.
        self.update(
            issues={
                **self.state()["issues"],
                "29": "Implementer: impl\nRequired reviews: tester, second\n",
            }
        )
        assert "not an additional reviewer" in self.team("review", "7", "critic", ok=False).stderr
        self.update(
            issues={**self.state()["issues"], "29": "Implementer: impl\nRequired reviews: second\n"}
        )
        refused = self.team("review", "7", "second", ok=False)
        assert "changed its implementer or merge-confirming tester" in refused.stderr
        assert len(self.events("agent", "start")) == starts
        self.update(issues={**self.state()["issues"], "29": WIDE})
        # A stopped reviewer moves to the new head when its worktree is clean, never when dirty.
        self.clients_exit(1)
        (wt / "notes.txt").write_text("in progress\n")
        refused = self.team("review", "7", "critic", ok=False)
        assert f"is dirty and not at {moved}" in refused.stderr
        assert self.git("rev-parse", "HEAD", cwd=wt) == head
        (wt / "notes.txt").unlink()
        self.team("review", "7", "critic")
        assert self.git("rev-parse", "HEAD", cwd=wt) == moved
        assert self.record(1)["agents"]["critic"]["head"] == moved
        assert f"pinned at {moved}" in self.system_prompt("team-1-critic")

    def test_review_refuses_pair_entries_unknown_reviewers_and_unlinked_prs(self) -> None:
        self.team("start", "29")
        self.push(self.worktree("29"))
        for entry in ("tester", "impl", "second"):
            with self.subTest(entry=entry):
                refused = self.team("review", "7", entry, ok=False)
                assert "not an additional reviewer" in refused.stderr
        self.update(pr_briefs={"7": []})
        assert "exactly one started brief" in self.team("review", "7", "critic", ok=False).stderr
        self.update(pr_briefs={"7": ["29"]}, pr_head="0" * 40)
        assert "not on origin" in self.team("review", "7", "critic", ok=False).stderr
        assert not self.worktree("review-7-critic").exists()
        assert self.workspaces() == ["team-1-29"]

    def test_stop_retires_a_merged_brief_with_its_reviewer_and_leaves_the_other(self) -> None:
        self.team("start", "29")
        self.team("start", "30")
        wt = self.worktree("29")
        self.push(wt)
        self.team("review", "7", "critic")
        review = self.worktree("review-7-critic")
        self.git("merge", "-q", "--ff-only", "task/29")
        (self.root / "databases").write_text(
            "tips_test_t1\ntips_test_t1r\ntips_test_t1r2\ntips_test_t1c\ntips_test_t2\n"
            "tips_test_t2r\ntips_dev_t1r\ntips_dev_t2r\n"
        )
        self.clients_exit(1)
        # An unrecorded pane in a recorded workspace is preserved: nothing is closed.
        visitor = {
            "pane_id": "w1:p9",
            "workspace_id": self.record(1)["workspace"],
            "tab_id": "w1:t9",
            "name": "visitor",
            "agent": "codex",
            "cwd": str(self.repo),
        }
        self.update(strays=[visitor])
        refused = self.team("stop", "29", ok=False)
        assert "holds other panes ['w1:p9']" in refused.stderr
        assert wt.exists()
        assert not (self.root / "docker-calls").exists()
        self.update(strays=[])
        assert "nothing removed" in self.team("stop", "99").stdout
        # A pane arriving while clients are stopped is found at the close itself: its
        # workspace stays open, nothing is removed, and the brief retires once it has gone.
        self.env["RACE_VISITOR_WORKSPACE"] = self.record(1)["workspace"]
        refused = self.team("stop", "29", ok=False)
        assert "holds other panes ['w1:p8']" in refused.stderr, refused.stderr
        assert "team-1-29" in self.workspaces()
        assert wt.exists()
        assert not (self.root / "docker-calls").exists()
        del self.env["RACE_VISITOR_WORKSPACE"]
        self.update(strays=[])
        self.team("stop", "29")
        assert not wt.exists()
        assert not review.exists()
        assert self.git("branch", "--list", "task/29") == ""
        assert self.workspaces() == ["team-2-30"]
        assert not (self.repo / "agent/teams/allocations/1.json").exists()
        assert self.record(2)["brief"] == "30"
        calls = (self.root / "docker-calls").read_text()
        for database in ("tips_test_t1", "tips_test_t1r", "tips_test_t1r2", "tips_test_t1c"):
            assert f'DROP DATABASE "{database}"' in calls
        assert 'DROP DATABASE "tips_dev_t1r"' in calls
        assert "_t2" not in calls.replace("tips_test_t1r2", "")
        # Each worktree's daemon is stopped once, before the checkout is removed.
        stops = sorted(e[1] for e in self.events("dexter") if e[-1] == "stop")
        assert stops == sorted([str(wt), str(review)])
        assert self.worktree("30").is_dir()
        assert self.pane("team-2-impl")["agent"] == "codex"
        # Stopping again removes nothing; a brief whose workspaces Herdr lost still retires.
        assert "nothing removed" in self.team("stop", "29").stdout
        self.push(self.worktree("30"), pr="8", brief="30")
        self.git("merge", "-q", "--no-ff", "-m", "merge 30", "task/30")
        self.update(workspaces=[], tabs=[], panes=[])
        self.team("stop", "30")
        assert not self.worktree("30").exists()
        assert not list((self.repo / "agent/teams/allocations").glob("*.json"))

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
        assert self.record(1)["brief"] == "29"

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

    def test_failed_daemon_stop_preserves_the_brief_until_it_succeeds(self) -> None:
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
        assert self.record(1)["brief"] == "29"
        self.env["DEXTER_STOP_FAIL"] = "0"
        self.team("stop", "29")
        assert log.read_text() == "stop\nstop\n"
        assert not wt.exists()


class RepositoryConfigTest(unittest.TestCase):
    def test_shipped_configuration_validates(self) -> None:
        env = dict(os.environ, TIPS_TEAM_CONFIG=str(SCRIPT.parent / "config.toml"))
        code = "import sys; sys.path.insert(0,sys.argv[1]); from team import load_config; "
        result = execute(["python3", "-c", code + "load_config()", str(SCRIPT.parent)], env=env)
        assert result.returncode == 0, result.stderr


if __name__ == "__main__":
    unittest.main()
