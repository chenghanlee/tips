"""Brief lifecycle tests: real Git and process trees, fake Herdr; never a live pane or client."""

import contextlib
import json
import os
import re
import signal
import socket
import subprocess
import tempfile
import time
import unittest
from collections.abc import Sequence
from pathlib import Path
from typing import Any

from bootstrap import wrapper_text
from team import command_args, execute

SCRIPT = Path(__file__).resolve().parents[1] / "team.py"
# Deliberately fixed test data: changing production defaults must not rewrite tests.
CONFIG = """\
# Agent launch settings. Changes apply to newly started sessions.
# An empty model uses the client's configured default.
[github]
repository = "o/r"

[team]
clone_url = "/fixture/origin.git"
psql = ["/fixture/psql", "fixture-dsn"]
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
lock_seconds = 1

[launch]
codex_approval = "never"
claude_permission_mode = "bypassPermissions"

[agents.impl]
role = "implementer"
kind = "codex"
model = "fixture-impl"
effort = "xhigh"
db_suffix = "i"
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
        wrapper_text(
            str(Path(os.environ["TIPS_TEST_REAL_DEXTER"]) / "vendor/dexter"),
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
daemons = state.setdefault('daemons', [])
if argv[:1] == ['stop']:
    if state.get('dexter_stop_fails'):
        state_path.write_text(json.dumps(state))
        sys.exit('fixture Dexter stop failed')
    if root in daemons:
        daemons.remove(root)
elif not state.get('dexter_fails') and root not in daemons:
    # A query starts the project's daemon; ps lists it until stop.
    daemons.append(root)
state_path.write_text(json.dumps(state))
if state.get('dexter_fails'):
    sys.exit('fixture Dexter failed')
if argv[:1] == ['query']:
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
    view = {
        "body": body,
        "url": "https://github.com/o/r/issues/" + a[2],
        "state": "CLOSED" if a[2] in s.get("closed_by", {}) else "OPEN",
        "closedByPullRequestsReferences": [
            {"number": int(n)} for n in s.get("closed_by", {}).get(a[2], [])
        ],
    }
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
        "state": "MERGED" if a[2] in s.get("merged", []) else "OPEN",
        "url": "https://github.com/o/r/pull/" + a[2],
        "closingIssuesReferences": briefs,
    }
    out = json.dumps({key: view[key] for key in a[a.index("--json") + 1].split(",")})
elif a[:2] == ["pr", "checks"]:
    # The head can move, or another observer can post, while a reader is between its
    # first and last view.
    if "head_after_checks" in s:
        s["pr_head"] = s.pop("head_after_checks")
    posts = s.pop("post_on_checks", [])
    for body in [posts] if isinstance(posts, str) else posts:
        n = sum(len(c) for c in comments.values()) + 1
        url = "https://github.com/o/r/issues/%s#issuecomment-%d" % (a[2], n)
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
# `faults` injects one failure into the first call whose command and some argument match:
# crash_before and crash_after kill the calling launcher (SIGKILL) before or after the call
# takes effect; for `agent start`, timeout_live starts the client and then reports a
# timeout, timeout_exited runs the task's side effect and exits before the timeout, and
# concurrent runs a second team.py with `argv` while the first holds the store lock.
PAIR_HERDR = (
    r"""#!/usr/bin/env python3
import json, os, signal, subprocess, sys
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
    "TIPS_TEAM_HARNESS", "TIPS_TEAM_ALLOCATION_ID", "TIPS_TEAM_STATE",
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
    if fault and fault["mode"] == "crash_after":
        os.kill(os.getppid(), signal.SIGKILL)
    if error:
        sys.exit(error)
    if a[:2] != ["pane", "run"]:
        print(json.dumps({"result": result}))
    sys.exit(0)


fault = next(
    (
        f
        for f in s.get("faults", [])
        if not f.get("done")
        and a[:2] == f["call"].split()
        and any(f["arg"] in str(arg) for arg in a[2:])
    ),
    None,
)
if fault:
    fault["done"] = True
    if fault["mode"] == "crash_before":
        json.dump(s, open(path, "w"))
        os.kill(os.getppid(), signal.SIGKILL)
        sys.exit(1)

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
    mode = fault["mode"] if fault else None
    if mode == "concurrent":
        json.dump(s, open(path, "w"))
        nested = subprocess.run(
            ["python3", "agent/teams/team.py", *fault["argv"]], text=True, capture_output=True
        )
        s = json.load(open(path))
        s["nested"] = {"code": nested.returncode, "stderr": nested.stderr}
    x = pane(opt("--pane"))
    if mode == "timeout_exited":
        # The client took its task, did it and exited before Herdr saw it ready.
        s["events"].append(["side-effect", a[2]])
        finish("timed out waiting for " + a[2])
    x.update(agent=opt("--kind"), name=a[2], launch_argv=a, launch_env=x.get("env", {}))
    # Claude reports the id the launcher assigned; Herdr learns it through a user hook,
    # which restricted mode ignores (no_sessions).
    sid = opt("--session-id") if "--session-id" in a else "session-" + a[2]
    x["agent_session"] = None if s.get("no_sessions") else {"kind": "id", "value": sid}
    x["agent_status"] = "blocked" if s.get("start_fails") else "idle"
    if s.get("wrong_start_root"):
        x["cwd"] = s["wrong_start_root"]
    if mode == "timeout_live":
        finish("timed out waiting for " + a[2])
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
# Harness fixtures stay outside temporary directories: the harness root refuses them.
TEST_RUNS = SCRIPT.parents[2] / "tmp/team-tests"

# Stands in for psql: lists PSQL_DBS, drops one name per call, refuses names in PSQL_REFUSE.
FAKE_PSQL = r"""#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
with open(os.environ["PSQL_LOG"], "a") as log:
    log.write(json.dumps(sys.argv[1:]) + "\n")
dbs = Path(os.environ["PSQL_DBS"])
names = dbs.read_text().split() if dbs.exists() else []
if "-Atc" in sys.argv:
    print("\n".join(names))
    sys.exit(0)
name = sys.argv[sys.argv.index("-c") + 1].split('"')[1]
if name in os.environ.get("PSQL_REFUSE", "").split(","):
    sys.exit('ERROR:  database "%s" is being accessed by other users' % name)
dbs.write_text("".join(n + "\n" for n in names if n != name))
"""

# Stands in for ps: lists the fixture's Dexter daemons; RACE_DIRTY_FILE is a late writer.
FAKE_PS = r"""#!/usr/bin/env python3
import json, os, sys
if os.environ.get("RACE_DIRTY_FILE"):
    with open(os.environ["RACE_DIRTY_FILE"], "w") as late:
        late.write("written while stopping\n")
state = json.load(open(os.environ["HERDR_FIXTURE"]))
if "args=" in sys.argv:
    for root in state.get("daemons", []):
        print("/fixture/vendor/dexter daemon " + root)
"""

class Harness(unittest.TestCase):
    """A harness checkout and a bare origin, with fake Herdr, gh, Mix, psql, ps, Codex and
    Dexter on PATH. The harness root is the checkout's sibling `agent_teams/r`."""

    def setUp(self) -> None:
        TEST_RUNS.mkdir(parents=True, exist_ok=True)
        self.tmp = tempfile.TemporaryDirectory(prefix="tips pair ", dir=TEST_RUNS)
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name).resolve()
        self.repo, self.bin = self.root / "repo", self.root / "bin"
        self.origin = self.root / "origin.git"
        self.stdlib = self.root / "stdlib/lib"
        self.state_path = self.root / "state.json"
        self.trusted = self.root / "agent_teams/r"
        self.env = dict(
            os.environ,
            GIT_CONFIG_GLOBAL=os.devnull,
            GIT_CONFIG_NOSYSTEM="1",
            HERDR_ENV="1",
            HERDR_FIXTURE=str(self.state_path),
            PSQL_LOG=str(self.root / "psql-calls"),
            PSQL_DBS=str(self.root / "databases"),
            DEXTER_ELIXIR_LIB_ROOT=str(self.stdlib),
            PATH=str(self.bin) + os.pathsep + os.environ["PATH"],
        )
        for key in (
            "TIPS_TEAM_CONFIG",
            "TIPS_DEXTER_HOME",
            "TIPS_DB_SUFFIX",
            "TIPS_TEST_PORT",
            "TIPS_TEAM_STATE",
            "TIPS_TEAM_ALLOCATION_ID",
            "TIPS_TEAM_HARNESS",
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
            "psql": FAKE_PSQL,
            "ps": FAKE_PS,
            "elixir": '#!/bin/sh\nprintf "1.2.3\\n"\n',
        }
        for name, body in fakes.items():
            (self.bin / name).write_text(body)
            (self.bin / name).chmod(0o755)
        execute(["git", "init", "-q", "-b", "main", str(self.repo)], env=self.env, check=True)
        execute(["git", "init", "-q", "--bare", "-b", "main", str(self.origin)], env=self.env)
        (self.repo / ".gitignore").write_text(
            ".codex/\n.agents/\n.dexter/\n.worktrees/\nagent/lsp/dexter/vendor/\n"
            "agent/teams/allocations/\ndeps/\ntmp/\n"
        )
        for script in ("team.py", "board.py", "pr_review.py", "bootstrap.py", "retirement.py"):
            (self.repo / "agent/teams" / script).write_text((SCRIPT.parent / script).read_text())
        self.write_config(CONFIG)
        (self.repo / "tracked.txt").write_text("base\n")
        binary = self.repo / "agent/lsp/dexter/vendor/dexter"
        binary.write_text(FAKE_DEXTER)
        binary.chmod(0o755)
        self.commit("base")
        self.git("remote", "add", "origin", str(self.origin))
        self.git("push", "-q", "origin", "main")
        issues = {"29": BRIEF, "30": WIDE, "31": NARROW, "50": "Spec: a design\n"}
        self.save({"workspaces": [], "panes": [], "events": [], "issues": issues})

    def write_config(self, text: str) -> None:
        text = text.replace("/fixture/origin.git", str(self.origin))
        text = text.replace("/fixture/psql", str(self.bin / "psql"))
        (self.repo / "agent/teams/config.toml").write_text(text)

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
        return json.loads((self.trusted / f"state/{slot}.json").read_text())

    def recorded_briefs(self) -> set[str]:
        files = (p for p in (self.trusted / "state").glob("*.json") if p.stem.isdecimal())
        return {json.loads(path.read_text())["brief"] for path in files}

    def allocation(self, name: str) -> dict[str, Any]:
        for path in (self.trusted / "state").glob("[0-9]*.json"):
            for allocation in json.loads(path.read_text())["agents"].values():
                if allocation["name"] == name:
                    return allocation
        raise AssertionError(f"No allocation named {name}")

    def project(self, name: str) -> Path:
        return Path(self.allocation(name)["root"]) / "project"

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

    def worker(
        self, name: str, script: str, *args: str, ok: bool = True, **extra: str
    ) -> subprocess.CompletedProcess[str]:
        """Run a worker-side helper as the named client: its pane's environment, in its
        allocation directory, under the test's own authority."""
        pane = self.pane(name)
        env = dict(self.env, HERDR_PANE_ID=pane["pane_id"], **extra)
        env.update({k: v for k, v in pane["launch_env"].items() if v is not None})
        harness = self.repo / "agent/teams"
        result = execute(
            ["python3", str(harness / script), *args],
            cwd=self.allocation(name)["root"],
            env=env,
            timeout=60,
        )
        assert (result.returncode == 0) == ok, result.stdout + result.stderr
        return result

    def bootstrap(self, name: str, *args: str, ok: bool = True) -> subprocess.CompletedProcess[str]:
        return self.worker(name, "bootstrap.py", *args, ok=ok)

    def retire(self, *names: str) -> None:
        for name in names:
            self.worker(name, "retirement.py")

    def push(self, name: str, message: str = "work", pr: str = "7", brief: str = "29") -> str:
        """Commit in the client's clone, push it and report it as the PR's pushed head."""
        project = self.project(name)
        (project / "tracked.txt").write_text(message + "\n")
        head = self.commit(message, cwd=project)
        self.git("push", "-q", "origin", f"HEAD:refs/heads/task/{brief}", cwd=project)
        self.update(pr_head=head, pr_briefs={**self.state().get("pr_briefs", {}), pr: [brief]})
        return head

    def merge(self, head: str, pr: str = "7", brief: str = "29") -> None:
        """GitHub merges the PR into main and closes the brief."""
        self.git("--git-dir", self.origin, "update-ref", "refs/heads/main", head)
        state = self.state()
        state["closed_by"] = {**state.get("closed_by", {}), brief: [pr]}
        state["merged"] = [*state.get("merged", []), pr]
        self.save(state)

    def databases(self, *names: str) -> None:
        (self.root / "databases").write_text("".join(n + "\n" for n in names))

    def remaining_databases(self) -> list[str]:
        path = self.root / "databases"
        return path.read_text().split() if path.exists() else []

    def psql_calls(self) -> list[list[str]]:
        path = self.root / "psql-calls"
        return [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []

    def reset(self, brief: str, *entries: str) -> None:
        """The operator, having checked the stopped clients' work, allows replacements."""
        for entry in entries:
            self.team("reset", brief, entry)

    def prompts(self, name: str) -> list[str]:
        """The messages Herdr sent to the named client, oldest first."""
        return [e[3] for e in self.events("agent", "prompt") if e[2] == name]

    def latest_prompts(self) -> dict[str, str]:
        """The latest prompt each recipient received."""
        return {e[2]: e[3] for e in self.events("agent", "prompt")}

    def launched_session(self, label: str) -> str:
        """The session id the launcher assigned to a Claude client."""
        argv = self.pane(label)["launch_argv"]
        return argv[argv.index("--session-id") + 1]

    def launch_env(self, label: str) -> tuple[str, str]:
        env = self.pane(label)["launch_env"]
        return env["TIPS_DB_SUFFIX"], env["TIPS_TEST_PORT"]

    def system_prompt(self, label: str) -> str:
        argv = self.pane(label)["launch_argv"]
        return argv[argv.index("--append-system-prompt") + 1]

    def comments(self, issue: str) -> list[dict[str, Any]]:
        return self.state().get("comments", {}).get(issue, [])


class PairLifecycleTest(Harness):
    def test_start_launches_the_pair_in_empty_allocations_that_bootstrap_themselves(
        self,
    ) -> None:
        # origin/main moves on and the launcher's checkout is dirty: neither leaks in.
        (self.repo / "AGENTS.md").write_text("Committed instructions.\n")
        release = self.commit("instructions")
        self.git("push", "-q", "origin", "main")
        (self.repo / "AGENTS.md").write_text("Uncommitted launcher-only instructions.\n")
        self.team("start", "29")
        assert self.workspaces() == ["team-1-29"]
        assert self.tabs("w1") == {
            "implementers": ["team-1-impl"],
            "reviewers": ["team-1-tester"],
        }
        record = self.record(1)
        assert record["tabs"] == {"implementers": "w1:t1", "reviewers": "w1:t2"}
        assert (record["version"], len(record["id"]), record["generation"]) == (3, 32, 1)
        assert (record["kind"], record["brief"], record["implementer"], record["tester"]) == (
            "brief",
            "29",
            "impl",
            "tester",
        )
        # Each client has its own allocation under the harness root: an empty project and
        # logs in its working directory, launcher configuration outside it.
        impl_root = self.trusted / "allocations/g1-impl"
        tester_root = self.trusted / "allocations/g1-tester"
        assert self.allocation("team-1-impl")["root"] == str(impl_root)
        for root in (impl_root, tester_root):
            assert sorted(p.name for p in root.iterdir()) == ["logs", "project"]
            assert not any((root / "project").iterdir())
        settings = json.loads((self.trusted / "state/g1-impl/bootstrap.json").read_text())
        assert (settings["branch"], settings["commit"]) == ("task/29", "")
        assert "probe" not in settings
        assert settings["clone_url"] == str(self.origin)
        assert settings["writable"] == [str(impl_root)]
        tester_settings = json.loads((self.trusted / "state/g1-tester/bootstrap.json").read_text())
        assert tester_settings["branch"] == ""
        # The launcher ran no Git, Mix or Dexter step for them.
        assert not self.events("mix")
        assert not self.events("dexter")
        impl, tester = self.pane("team-1-impl"), self.pane("team-1-tester")
        assert (impl["agent"], tester["agent"]) == ("codex", "claude")
        assert (impl["cwd"], tester["cwd"]) == (str(impl_root), str(tester_root))
        shared = {
            "PGPORT": "5433",
            "MIX_ENV": "test",
            "TIPS_CHECK_TIMEOUT_SECONDS": "1800",
            "TIPS_TEAM_CONFIG": str(self.repo / "agent/teams/config.toml"),
            "TIPS_PROVIDER_ENV_FILE": str(self.repo / ".env"),
            "TIPS_TEAM_HARNESS": str(self.trusted / "harness"),
            "TIPS_TEAM_STATE": str(self.trusted / "state"),
        }
        assert impl["launch_env"] == {
            **shared,
            "TIPS_DB_SUFFIX": "_t1g1i",
            "TIPS_TEST_PORT": "4110",
            "TIPS_DEXTER": str(impl_root / "project/.dexter/dexter.sh"),
            "TIPS_TEAM_ALLOCATION_ID": "g1-impl",
            # Codex's sandbox cannot write the shared Hex cache; Claude keeps the default.
            "HEX_HOME": str(impl_root / "project/tmp/hex"),
        }
        assert tester["launch_env"] == {
            **shared,
            "TIPS_DB_SUFFIX": "_t1g1r",
            "TIPS_TEST_PORT": "4111",
            "TIPS_DEXTER": str(tester_root / "project/.dexter/dexter.sh"),
            "TIPS_TEAM_ALLOCATION_ID": "g1-tester",
            "HEX_HOME": None,
        }
        # Codex works in the allocation directory, outside the clone.
        argv = impl["launch_argv"]
        assert argv[argv.index("-C") + 1] == str(impl_root)
        assert argv[-1] == 'model_reasoning_effort="xhigh"'
        assert "--add-dir" not in argv
        assert not (impl_root / ".codex").exists()
        # Codex starts with no task and gets its brief as the first message; Claude holds
        # its brief as a system prompt, so its first message only starts the work.
        assert self.prompts("team-1-tester") == ["Begin."]
        [impl_brief] = self.prompts("team-1-impl")
        tester_brief = self.system_prompt("team-1-tester")
        harness = self.repo / "agent/teams"
        assert impl_brief.startswith("You are impl, the implementer for brief #29;")
        assert f"First run python3 {harness / 'bootstrap.py'}:" in impl_brief
        assert f"your project is {impl_root / 'project'}" in impl_brief
        assert f"python3 {harness / 'team.py'} turn <pr> tester" in impl_brief
        assert tester_brief.startswith("You are tester, the merge-confirming tester for brief #29;")
        assert f"python3 {harness / 'team.py'} turn <pr> impl" in tester_brief
        assert "Put tester, <session> on line 2" in tester_brief
        assert f"python3 {harness / 'retirement.py'}" in tester_brief
        assert "persona" not in tester_brief
        targ = tester["launch_argv"]
        assert targ[targ.index("--advisor") + 1] == "fixture-advisor"
        assert "--advisor" not in argv
        plugins = json.loads(targ[targ.index("--settings") + 1])["enabledPlugins"]
        assert plugins["elixir-lsp@elixir-agent-tools"] is False
        assert plugins["mix-credo@elixir-agent-tools"] is True
        tester_session = self.launched_session("team-1-tester")
        assert re.fullmatch(r"[0-9a-f-]{36}", tester_session)
        assert "--session-id" not in impl["launch_argv"]
        assert record["agents"]["tester"]["session"] == tester_session
        assert {a["submission"] for a in record["agents"].values()} == {"submitted"}
        assert [c["body"] for c in self.comments("29")] == [
            f"EVENT implementer team-1-impl session-team-1-impl\nlaunched codex in {impl_root}; "
            "allocation g1-impl; database suffix _t1g1i; port 4110",
            f"EVENT tester team-1-tester {tester_session}\nlaunched claude in "
            f"{tester_root}; allocation g1-tester; database suffix _t1g1r; port 4111",
        ]
        # Each worker clones for itself: the implementer on its task branch from fetched
        # origin/main, the tester detached at origin/main, in separate clones.
        result = self.bootstrap("team-1-impl")
        project = impl_root / "project"
        assert f"Bootstrap ready: {project} at {release}" in result.stdout
        assert self.git("branch", "--show-current", cwd=project) == "task/29"
        assert (project / "AGENTS.md").read_text() == "Committed instructions.\n"
        assert self.events("mix") == [["mix", str(project), "deps.get", "--check-locked"]]
        assert self.state()["mix_env"] == {
            "HEX_HOME": str(project / "tmp/hex"),
            "MIX_ENV": "test",
        }
        assert [e[1:3] for e in self.events("dexter")] == [
            [str(project), "query"],
            [str(project), "reindex"],
        ]
        assert os.readlink(project / ".agents/skills") == str(self.repo / ".agents/skills")
        assert self.git("status", "--porcelain", "--untracked-files=all", cwd=project) == ""
        # The full log is in the allocation's logs; the console stays bounded.
        [log] = (impl_root / "logs").glob("bootstrap-*.log")
        assert "deps.get --check-locked" in log.read_text()
        assert len(result.stdout.encode()) <= 8192 + 200
        # The wrapper keeps its root and sources from any directory.
        env = dict(self.env)
        env.pop("DEXTER_ELIXIR_LIB_ROOT")
        query = ["query", "hover", "a.ex", "1", "1"]
        wrapper = project / ".dexter/dexter.sh"
        execute(["/bin/sh", wrapper, *query], cwd=self.root, env=env, check=True)
        assert self.state()["events"][-1] == ["dexter", str(project), *query]
        assert self.state()["dexter_stdlib"] == str(self.stdlib)
        self.bootstrap("team-1-tester")
        other = tester_root / "project"
        assert self.git("rev-parse", "HEAD", cwd=other) == release
        assert self.git("branch", "--show-current", cwd=other) == ""
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
        assert not self.state()["workspaces"]
        assert not (self.trusted / "allocations").exists()
        assert not list((self.trusted / "state").glob("*.json"))

    def test_restart_adopts_live_clients_and_replaces_stopped_ones_only_after_reset(self) -> None:
        self.team("start", "29")
        self.bootstrap("team-1-impl")
        project = self.project("team-1-impl")
        (project / "tracked.txt").write_text("unfinished work\n")
        before = len(self.state()["events"])
        # Live clients are left alone.
        self.team("start", "29")
        later = self.state()["events"][before:]
        assert not any(e[:2] in (["agent", "start"], ["pane", "run"]) for e in later)
        assert not any(e[:2] == ["agent", "prompt"] for e in later)
        # Reset refuses a running client.
        refused = self.team("reset", "29", "impl", ok=False)
        assert "team-1-impl is running in" in refused.stderr
        # A stopped client may have done its task: a rerun neither relaunches nor resends.
        self.clients_exit(1)
        refused = self.team("start", "29", ok=False)
        assert "team-1-impl is not running and its task submission is submitted" in refused.stderr
        assert "team.py reset 29 impl" in refused.stderr
        assert len(self.events("agent", "start")) == 2
        # After a reset, the replacement gets the allocation it was launched with, even
        # after config.toml changed its database and port; its clone keeps unfinished work.
        self.write_config(
            CONFIG.replace('db_suffix = "r"', 'db_suffix = "z"').replace(
                "port_offset = 1", "port_offset = 5"
            )
        )
        reset = self.team("reset", "29", "tester").stdout
        session = self.launched_session("team-1-tester")
        assert f"task submission was submitted, session {session}" in reset
        self.reset("29", "impl")
        self.team("start", "29")
        assert len(self.events("agent", "start")) == 4
        assert self.launch_env("team-1-tester") == ("_t1g1r", "4111")
        # The replacement reuses its clone: bootstrap neither reclones nor resets it.
        self.bootstrap("team-1-impl")
        assert (project / "tracked.txt").read_text() == "unfinished work\n"
        assert self.git("branch", "--show-current", cwd=project) == "task/29"
        assert len(self.events("mix")) == 1
        assert self.record(1)["generation"] == 1
        assert self.record(1)["agents"]["tester"]["submission"] == "submitted"
        assert self.prompts("team-1-tester") == ["Begin.", "Begin."]
        # A closed pane is reopened in its role's tab; the allocation keeps its resources.
        # Herdr closes a tab with its last pane, so the role gets a new tab too.
        old = self.record(1)["agents"]["impl"]
        state = self.state()
        state["panes"] = [x for x in state["panes"] if x.get("label") != "team-1-impl"]
        state["tabs"] = [t for t in state["tabs"] if t["tab_id"] != old["tab"]]
        self.save(state)
        self.clients_exit(1)
        self.reset("29", "impl", "tester")
        self.team("start", "29")
        new = self.record(1)["agents"]["impl"]
        assert new["pane"] != old["pane"]
        assert new["workspace"] == old["workspace"]
        assert new["tab"] != old["tab"]
        assert (new["root"], new["db_suffix"], new["port"]) == (
            old["root"],
            old["db_suffix"],
            old["port"],
        )
        assert self.pane("team-1-impl")["cwd"] == old["root"]
        # A vanished workspace is recreated with both clients in their tabs.
        self.update(workspaces=[], tabs=[], panes=[])
        self.reset("29", "impl", "tester")
        self.team("start", "29")
        workspace = self.record(1)["workspace"]
        assert workspace != old["workspace"]
        assert self.tabs(workspace) == {
            "implementers": ["team-1-impl"],
            "reviewers": ["team-1-tester"],
        }
        # A client cannot change kind or disappear from config while it is allocated.
        self.clients_exit(1)
        self.reset("29", "impl", "tester")
        self.write_config(
            CONFIG.replace(
                'kind = "codex"\nmodel = "fixture-impl"', 'model = "fixture-impl"\nkind = "claude"'
            )
        )
        assert "launched as codex; preserved" in self.team("start", "29", ok=False).stderr
        assert self.record(1)["agents"]["impl"]["submission"] == "never_submitted"
        self.write_config(CONFIG.replace("[agents.tester]", "[agents.other]"))
        assert "not a configured entry" in self.team("start", "29", ok=False).stderr
        # The pair cannot change hands while the allocations are theirs.
        self.write_config(CONFIG)
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
        small = CONFIG.replace("max_teams = 6", "max_teams = 2")
        self.write_config(small)
        self.team("start", "29")
        self.team("start", "30")
        assert self.launch_env("team-2-impl") == ("_t2g2i", "4120")
        assert self.pane("team-2-impl")["cwd"] == str(self.trusted / "allocations/g2-impl")
        # A new allocation never takes a recorded port, even after configuration changes.
        self.bootstrap("team-1-impl")
        self.push("team-1-impl")
        # Config moved the critic onto the running tester's port: refused in its slot.
        moved = small.replace("port_offset = 1", "port_offset = 5")
        self.write_config(moved.replace("port_offset = 2", "port_offset = 1"))
        refused = self.team("review", "7", "critic", ok=False)
        assert "port 4111 collides with team-1-tester's" in refused.stderr
        self.write_config(small)
        self.team("review", "7", "critic")
        assert self.launch_env("team-1-critic") == ("_t1g1c", "4112")
        self.update(issues={**self.state()["issues"], "32": BRIEF})
        assert "No free slot" in self.team("start", "32", ok=False).stderr
        # Slots come from the records, so a slot whose workspaces are gone is still taken.
        self.update(workspaces=[], tabs=[], panes=[])
        assert "No free slot" in self.team("start", "32", ok=False).stderr

    def test_foreign_client_in_an_allocation_refuses_and_is_left_untouched(self) -> None:
        stray = {
            "pane_id": "wX:p9",
            "workspace_id": "wX",
            "name": "stray",
            "agent": "claude",
            "cwd": str(self.trusted / "allocations/g1-impl/project"),
        }
        self.update(strays=[stray])
        refused = self.team("start", "29", ok=False)
        assert "Conflicting live agent" in refused.stderr
        assert not self.state()["workspaces"]
        assert not self.events("agent", "start")
        assert not any(e[:2] in (["agent", "prompt"], ["agent", "rename"]) for e in self.events())
        assert self.state()["strays"] == [stray]

    def test_failed_bootstrap_is_recoverable_and_proves_only_the_steps_it_ran(self) -> None:
        self.team("start", "29")
        project = self.project("team-1-impl")
        failures = (
            ({"mix_fails": True}, "fixture mix failed"),
            ({"dexter_fails": True}, "fixture Dexter failed"),
            ({"dexter_empty": True}, "no MixProject"),
        )
        healthy = {"mix_fails": False, "dexter_fails": False, "dexter_empty": False}
        for flags, message in failures:
            with self.subTest(flags=flags):
                self.update(**{**healthy, **flags})
                failed = self.bootstrap("team-1-impl", ok=False)
                assert message in failed.stderr
                assert "Bootstrap ready" not in failed.stdout
        # The clone survives; a fetch that failed is retried because deps/ is missing.
        self.update(**healthy)
        self.bootstrap("team-1-impl")
        mixes = [e for e in self.events("mix") if e[1] == str(project)]
        assert len(mixes) == 2
        assert self.git("branch", "--show-current", cwd=project) == "task/29"
        # Missing tools are refused before a record or allocation exists.
        self.update(issues={**self.state()["issues"], "34": BRIEF})
        self.env["DEXTER_ELIXIR_LIB_ROOT"] = str(self.root / "no-sources")
        assert "sources are missing" in self.team("start", "34", ok=False).stderr
        self.env["DEXTER_ELIXIR_LIB_ROOT"] = str(self.stdlib)
        (self.repo / "agent/lsp/dexter/vendor/dexter").unlink()
        assert "Missing executable" in self.team("start", "34", ok=False).stderr
        assert self.recorded_briefs() == {"29"}

    def test_lost_setup_output_never_starts_a_client(self) -> None:
        self.update(setup_lost=True)
        refused = self.team("start", "29", ok=False)
        assert "timed out waiting for output match" in refused.stderr
        assert not self.events("agent", "start")
        # Nothing could have received the task, so a rerun launches.
        assert self.record(1)["agents"]["impl"]["submission"] == "never_submitted"
        self.update(setup_lost=False)
        self.team("start", "29")
        assert len(self.events("agent", "start")) == 2

    def test_client_started_blocked_or_in_another_root_is_reported(self) -> None:
        # A blocked client has the recorded identity: a rerun adopts it and sends nothing.
        self.update(start_fails=True)
        assert "unexpected state or root" in self.team("start", "29", ok=False).stderr
        assert self.record(1)["agents"]["impl"]["submission"] == "unknown"
        self.update(start_fails=False)
        rerun = self.team("start", "29").stdout
        assert "Already running: team-1-impl (blocked)" in rerun
        assert "team-1-impl: task submission is unknown; nothing was resent" in rerun
        assert len(self.events("agent", "start")) == 2
        assert not self.prompts("team-1-impl")
        # A client in another root is not the recorded client: refused.
        self.update(wrong_start_root="/")
        assert "unexpected state or root" in self.team("start", "30", ok=False).stderr
        refused = self.team("start", "30", ok=False)
        assert "runs in /, not its allocation; preserved" in refused.stderr
        assert len(self.events("agent", "start")) == 3
        # Once the operator has exited it and reset the record, a replacement launches.
        self.update(wrong_start_root="")
        self.clients_exit(2)
        self.reset("30", "impl")
        self.team("start", "30")
        assert self.prompts("team-2-impl")[0].startswith("You are impl, the implementer")
        assert self.record(2)["agents"]["impl"]["submission"] == "submitted"

    def test_invalid_config_refuses_before_herdr(self) -> None:
        cases = (
            ("port_base = 4100", 'port_base = "wrong"', "team.port_base must be int"),
            ('role = "designer"', 'role = "architect"', "agents.critic.role must be one of"),
            ('advisor = "fixture-advisor"', 'adviser = "x"', "unknown keys ['adviser']"),
            ('model = "fixture-impl"', 'model = "x"\nadvisor = "y"', "advisor applies to Claude"),
            ('db_suffix = "r"', 'db_suffix = "9r"', "db_suffix must be nonempty and start"),
            ('repository = "o/r"', 'repository = "o"', "github.repository must be owner/name"),
            ('psql = ["/fixture/psql"', 'psql = ["psql"', "psql must start with an absolute"),
            ('db_suffix = "c"', 'db_suffix = "c"\nprobe = ["make"]', "unknown keys ['probe']"),
            ('psql = ["/fixture/psql", "fixture-dsn"]', "psql = []", "psql must hold 1 to 16"),
            ('db_suffix_prefix = "_t"', 'db_suffix_prefix = "_' + "t" * 50 + '"', "exceed 63"),
        )
        for original, edited, message in cases:
            with self.subTest(edited=edited):
                self.write_config(CONFIG.replace(original, edited))
                assert message in self.team("start", "29", ok=False).stderr
        assert self.state()["events"] == []
        assert not self.trusted.exists()

    def test_a_root_claimed_by_another_repository_is_refused(self) -> None:
        # Another owner's repository with the same name has the same default root.
        self.trusted.mkdir(parents=True)
        (self.trusted / "repository.json").write_text('{"repository": "x/r"}\n')
        refused = self.team("start", "29", ok=False)
        assert f"{self.trusted} belongs to x/r, not o/r" in refused.stderr
        assert not (self.trusted / "state").exists()
        # A dispatcher record beside the slot records is not a slot record.
        (self.trusted / "repository.json").write_text('{"repository": "o/r"}\n')
        (self.trusted / "state").mkdir()
        (self.trusted / "state/dispatcher.json").write_text('{"pid": 1}\n')
        self.team("start", "29")
        assert self.recorded_briefs() == {"29"}
        # The harness override names <root>/harness by an absolute path.
        self.env["TIPS_TEAM_HARNESS"] = "agent_teams/r/harness"
        refused = self.team("stop", "29", ok=False)
        assert "TIPS_TEAM_HARNESS must be an absolute path" in refused.stderr

    def test_records_from_a_shared_worktree_team_py_refuse_every_command(self) -> None:
        legacy = self.repo / "agent/teams/allocations/1.json"
        legacy.parent.mkdir()
        legacy.write_text('{"slot": 1, "brief": "29"}\n')
        for command in (("start", "29"), ("design", "50", "critic"), ("stop", "29")):
            with self.subTest(command=command):
                refused = self.team(*command, ok=False)
                assert "used shared worktrees; refusing every launch and stop" in refused.stderr
        assert [e for e in self.state()["events"] if e[0] != "gh"] == []

    def test_trusted_paths_inside_writable_or_temporary_roots_are_refused(self) -> None:
        self.team("start", "29")
        # A worker whose TMPDIR holds the harness: bootstrap refuses before any clone.
        failed = self.worker("team-1-impl", "bootstrap.py", ok=False, TMPDIR=str(self.root))
        assert f"Trusted {self.repo / 'agent/teams'} is inside {self.root}" in failed.stderr
        assert not any(self.project("team-1-impl").iterdir())
        # A launcher configuration that grants a trusted path is a layout error.
        path = self.trusted / "state/g1-impl/bootstrap.json"
        settings = json.loads(path.read_text())
        path.write_text(json.dumps({**settings, "writable": [str(self.trusted)]}))
        failed = self.bootstrap("team-1-impl", ok=False)
        assert f"is inside {self.trusted}; refused" in failed.stderr
        # A project that is a symlink out of the harness root is refused.
        path.write_text(json.dumps(settings))
        project = self.project("team-1-impl")
        project.rmdir()
        outside = self.root / "outside"
        outside.mkdir()
        project.symlink_to(outside)
        failed = self.bootstrap("team-1-impl", ok=False)
        assert "passes through a symlink; refused" in failed.stderr
        assert not any(outside.iterdir())
        # The launcher refuses an allocation directory that escapes the harness root.
        self.update(issues={**self.state()["issues"], "33": BRIEF})
        (self.trusted / "allocations/g2-impl").symlink_to(outside)
        refused = self.team("start", "33", ok=False)
        assert "escapes" in refused.stderr
        assert not any(outside.iterdir())

    @unittest.skipUnless(
        os.environ.get("TIPS_TEST_REAL_CODEX"), "opt-in installed Codex config check"
    )
    def test_codex_started_in_the_allocation_ignores_the_clone_configuration(self) -> None:
        self.team("start", "29")
        launch = self.pane("team-1-impl")["launch_argv"]
        args = launch[launch.index("--") + 1 :]
        # A project file cannot add a server for a client started in the allocation.
        project = self.project("team-1-impl")
        hostile = project / ".codex/config.toml"
        hostile.parent.mkdir()
        hostile.write_text('[mcp_servers.project-evil]\ncommand = "/usr/bin/false"\n')
        result = execute(
            ["codex", *args, "mcp", "list", "--json"],
            cwd=self.allocation("team-1-impl")["root"],
            env=self.env,
            timeout=30,
        )
        assert result.returncode == 0, result.stderr
        enabled = {s["name"] for s in json.loads(result.stdout) if s.get("enabled")}
        assert "project-evil" not in enabled

    def use_real_dexter(self) -> None:
        """Bootstrap with the real Dexter binary and a real Mix project."""
        self.env["TIPS_DEXTER_HOME"] = os.environ["TIPS_TEST_REAL_DEXTER"]
        self.env["DEXTER_ELIXIR_LIB_ROOT"] = os.environ["DEXTER_ELIXIR_LIB_ROOT"]
        self.env["DEXTER_DAEMON_IDLE_TIMEOUT"] = "5s"
        (self.bin / "elixir").unlink()  # the real toolchain must match the sources
        (self.bin / "ps").unlink()  # stop finds the real daemon
        source = 'defmodule Sample do\n  @doc "Original documentation"\n'
        (self.repo / "sample.ex").write_text(source + "  def greet(name), do: name\nend\n")
        (self.repo / "mix.exs").write_text(MIX_PROJECT)
        self.commit("mix fixture")
        self.git("push", "-q", "origin", "main")

    def stop_real_daemon(self, project: Path) -> None:
        wrapper = project / ".dexter/dexter.sh"
        if wrapper.exists():
            execute(["/bin/sh", wrapper, "stop", "--force"], input_text="")

    @unittest.skipUnless(os.environ.get("TIPS_TEST_REAL_DEXTER"), REAL_DEXTER)
    def test_two_allocations_use_isolated_real_daemons(self) -> None:
        self.use_real_dexter()
        self.team("start", "29")
        projects = [self.project("team-1-impl"), self.project("team-1-tester")]
        for name, project in zip(("team-1-impl", "team-1-tester"), projects, strict=True):
            self.addCleanup(self.stop_real_daemon, project)
            self.bootstrap(name)
        source = (projects[0] / "sample.ex").read_text()
        changed = projects[0] / ".replace"
        changed.write_text(source.replace("Original documentation", "First clone only"))
        changed.replace(projects[0] / "sample.ex")
        hover = ["query", "--raw", "hover", "sample.ex", "3", "8"]
        docs = ("First clone only", "Original documentation")
        for project, doc in zip(projects, docs, strict=True):
            result = execute(
                ["/bin/sh", project / ".dexter/dexter.sh", *hover],
                cwd=self.root,
                env=self.env,
                input_text="",
                check=True,
            )
            assert doc in json.dumps(json.loads(result.stdout))

    @unittest.skipUnless(os.environ.get("TIPS_TEST_REAL_DEXTER"), REAL_DEXTER)
    def test_stop_stops_real_daemons_and_retains_the_projects(self) -> None:
        self.use_real_dexter()
        self.team("start", "29")
        project = self.project("team-1-impl")
        self.addCleanup(self.stop_real_daemon, project)
        self.bootstrap("team-1-impl")
        self.bootstrap("team-1-tester")
        self.addCleanup(self.stop_real_daemon, self.project("team-1-tester"))
        assert daemon_pid(project)
        self.retire("team-1-impl", "team-1-tester")
        self.clients_exit(1)
        self.team("stop", "29")
        wait_until_stopped(project)
        assert (project / "sample.ex").exists()


class HandoffTest(Harness):
    def setUp(self) -> None:
        super().setUp()
        self.team("start", "29")
        self.bootstrap("team-1-impl")
        self.impl = self.pane("team-1-impl")["pane_id"]
        self.tester = self.pane("team-1-tester")["pane_id"]

    def test_turn_to_reviewers_needs_the_pushed_head_and_notifies_every_reviewer(self) -> None:
        project = self.project("team-1-impl")
        pushed = self.push("team-1-impl")
        prompts = len(self.events("agent", "prompt"))
        (project / "scratch.txt").write_text("not committed\n")
        refused = self.team("turn", "7", "tester", pane=self.impl, ok=False)
        assert "has uncommitted or untracked files" in refused.stderr
        (project / "scratch.txt").unlink()
        self.update(pr_head="0" * 40)
        refused = self.team("turn", "7", "tester", pane=self.impl, ok=False)
        assert f"HEAD is {pushed}, not the PR head" in refused.stderr
        assert len(self.events("agent", "prompt")) == prompts
        self.update(pr_head=pushed)
        self.team("turn", "7", "tester", pane=self.impl)
        # The critic is not launched: the handoff asks the dispatcher and records the notice.
        sent = self.events("agent", "prompt")[prompts:]
        assert [e[2] for e in sent] == ["team-1-tester", "dispatcher"]
        ring = sent[0][3]
        harness = self.repo / "agent/teams"
        assert "https://github.com/o/r/pull/7" in ring
        assert f"python3 {harness / 'bootstrap.py'} --commit {pushed}" in ring
        assert "it refuses a dirty clone" in ring
        assert "Put tester, <session> on line 2" in ring
        assert f"python3 {harness / 'team.py'} turn 7 impl; do not wait" in ring
        assert "asked the dispatcher to launch critic" in ring
        assert "pr_review.py observe 7 reports ready to merge" in ring
        assert sent[1][3] == (
            "https://github.com/o/r/pull/7 review: run agent/teams/team.py review 7 critic"
        )
        assert self.comments("7")[-1]["body"] == (
            "EVENT implementer team-1-impl session-team-1-impl\n"
            f"pending review of {pushed} by critic: not launched; "
            "launch requested from the dispatcher"
        )
        # A new head reaches the tester and the launched critic in the same handoff.
        self.team("review", "7", "critic")
        moved = self.push("team-1-impl", "second push")
        prompts = len(self.events("agent", "prompt"))
        self.team("turn", "7", "tester", pane=self.impl)
        sent = self.events("agent", "prompt")[prompts:]
        assert [e[2] for e in sent] == ["team-1-tester", "team-1-critic"]
        assert all(moved in e[3] for e in sent)
        assert f"bootstrap.py --commit {moved}" in sent[1][3]
        assert "never resets one" in sent[1][3]
        assert "herdr agent prompt team-1-tester" in sent[1][3]
        assert "asked the dispatcher" not in sent[0][3]
        # The brief cannot move the merge-confirming tester under a running pair.
        prompts = len(self.events("agent", "prompt"))
        body = "Implementer: impl\nRequired reviews: second, critic\n"
        self.update(issues={**self.state()["issues"], "29": body})
        refused = self.team("turn", "7", "tester", pane=self.impl, ok=False)
        assert "changed its implementer or merge-confirming tester" in refused.stderr
        assert len(self.events("agent", "prompt")) == prompts

    def test_two_clones_at_one_handed_off_head_stay_isolated(self) -> None:
        head = self.push("team-1-impl")
        self.team("turn", "7", "tester", pane=self.impl)
        # The tester moves its own clone to the handed-off head.
        self.bootstrap("team-1-tester", "--commit", head)
        impl, tester = self.project("team-1-impl"), self.project("team-1-tester")
        assert impl != tester
        assert self.git("rev-parse", "HEAD", cwd=tester) == head
        # Tester edits never reach the implementer, and the implementer repairs while the
        # tester stays on the immutable head it reviews.
        (tester / "tracked.txt").write_text("tester experiment\n")
        assert (impl / "tracked.txt").read_text() == "work\n"
        repaired = self.push("team-1-impl", "repair")
        assert self.git("rev-parse", "HEAD", cwd=tester) == head
        # A dirty clone blocks the move and is never reset.
        failed = self.bootstrap("team-1-tester", "--commit", repaired, ok=False)
        assert "uncommitted or untracked files; nothing changed" in failed.stderr
        assert (tester / "tracked.txt").read_text() == "tester experiment\n"
        assert self.git("rev-parse", "HEAD", cwd=tester) == head
        # A head that never reached origin is refused.
        self.git("checkout", "-q", "tracked.txt", cwd=tester)
        failed = self.bootstrap("team-1-tester", "--commit", "0" * 40, ok=False)
        assert "is not on origin; push it first" in failed.stderr
        assert self.git("rev-parse", "HEAD", cwd=tester) == head
        self.bootstrap("team-1-tester", "--commit", repaired)
        assert self.git("rev-parse", "HEAD", cwd=tester) == repaired

    def test_absent_reviewer_and_failed_sends_are_reported_after_every_send(self) -> None:
        self.update(issues={**self.state()["issues"], "29": WIDE})
        self.push("team-1-impl")
        self.team("review", "7", "critic")
        # The critic's client exited and the dispatcher is gone: both sends fail, the
        # tester is still notified and the pending notice for second is recorded.
        state = self.state()
        critic = next(x for x in state["panes"] if x.get("label") == "team-1-critic")
        critic.pop("agent")
        state["dispatcher_down"] = True
        self.save(state)
        prompts = len(self.events("agent", "prompt"))
        refused = self.team("turn", "7", "tester", pane=self.impl, ok=False)
        assert [e[2] for e in self.events("agent", "prompt")[prompts:]] == [
            "team-1-tester",
            "team-1-critic",
            "dispatcher",
        ]
        assert "Notified team-1-tester" in refused.stdout
        assert "Handoff incomplete; failed sends: team-1-critic: agent_not_found" in refused.stderr
        assert "dispatcher: agent_not_found: dispatcher" in refused.stderr
        assert "by second: not launched" in self.comments("7")[-1]["body"]

    def test_known_merge_conflict_blocks_review_handoff_until_resolved(self) -> None:
        head = self.push("team-1-impl")
        self.team("review", "7", "critic")
        prompts = len(self.events("agent", "prompt"))
        # A conflict that cannot be recorded blocks the handoff with the failure and error.
        self.update(pr_mergeable="CONFLICTING", comments_fail=True)
        refused = self.team("turn", "7", "tester", pane=self.impl, ok=False)
        unrecorded = f"Known failure not recorded on PR 7: Merge conflict at head {head}"
        assert unrecorded in refused.stderr
        assert "Error: fixture GitHub refused the comment" in refused.stderr
        self.update(comments_fail=False, history_fails=True)
        refused = self.team("turn", "7", "tester", pane=self.impl, ok=False)
        assert unrecorded in refused.stderr
        assert "Error: fixture comment-history unavailable" in refused.stderr
        # Recorded, it still blocks; later unavailable reads neither record nor clear it.
        self.update(history_fails=False)
        refused = self.team("turn", "7", "tester", pane=self.impl, ok=False)
        finding = self.comments("7")[-1]["html_url"]
        assert f"Known merge conflict {finding}" in refused.stderr
        self.update(pr_mergeable="UNKNOWN", checks_error="fixture checks unavailable")
        refused = self.team("turn", "7", "tester", pane=self.impl, ok=False)
        assert f"Known merge conflict {finding}" in refused.stderr
        assert self.comments("7")[-1]["html_url"] == finding
        head = self.push("team-1-impl", "merged main")
        refused = self.team("turn", "7", "tester", pane=self.impl, ok=False)
        assert f"has not reported mergeability for {head} yet" in refused.stderr
        assert len(self.events("agent", "prompt")) == prompts
        self.update(pr_mergeable="MERGEABLE", checks_error="")
        self.team("turn", "7", "tester", pane=self.impl)
        resolved = self.comments("7")[-1]["body"]
        assert '"state":"resolved"' in resolved
        assert f"Resolves {finding}." in resolved
        assert [e[2] for e in self.events("agent", "prompt")[prompts:]] == [
            "team-1-tester",
            "team-1-critic",
        ]

    def test_turn_to_implementer_rings_with_open_findings_from_any_tester_clone(self) -> None:
        self.push("team-1-impl")
        failed = {"name": "checks", "workflow": "CI", "bucket": "fail", "link": "https://ci/2"}
        self.update(checks=[failed])
        # The tester's clone state never blocks handing findings back.
        self.team("turn", "7", "impl", pane=self.tester)
        finding = self.comments("7")[-1]
        session = self.launched_session("team-1-tester")
        assert finding["body"].startswith(f"FINDING tester team-1-tester {session}\n")
        ring = self.events("agent", "prompt")[-1]
        assert ring[2] == "team-1-impl"
        assert "pr_review.py list 7" in ring[3]
        assert f"Open findings: check:CI/checks {finding['html_url']}" in ring[3]
        assert "agent/skills/implement-software/SKILL.md from your clone" in ring[3]

    def test_turn_refuses_outside_callers_and_wrong_briefs(self) -> None:
        self.team("start", "30")
        self.push("team-1-impl")
        self.team("review", "7", "critic")
        prompts = len(self.events("agent", "prompt"))
        critic = self.pane("team-1-critic")["pane_id"]
        other = self.pane("team-2-impl")["pane_id"]
        cases: list[tuple[tuple[str, str], str | None, str]] = [
            (("7", "impl"), self.impl, "this pane is impl"),
            (("7", "critic"), self.impl, "between impl and tester"),
            (("7", "tester"), critic, "this pane is critic"),
            (("7", "tester"), None, "HERDR_PANE_ID is not set"),
            (("7", "tester"), other, "does not close brief #30"),
            (("7", "Lead"), self.impl, "Usage:"),
        ]
        for args, pane, message in cases:
            with self.subTest(args=args, message=message):
                refused = self.team("turn", *args, ok=False, pane=pane)
                assert message in refused.stderr
        assert len(self.events("agent", "prompt")) == prompts

    def test_review_launches_each_reviewer_in_its_own_allocation_at_the_pr_head(self) -> None:
        head = self.push("team-1-impl")
        self.team("review", "7", "critic")
        root = self.trusted / "allocations/g1-critic"
        critic = self.pane("team-1-critic")
        assert critic["cwd"] == str(root)
        assert self.launch_env("team-1-critic") == ("_t1g1c", "4112")
        brief = self.system_prompt("team-1-critic")
        assert brief.startswith("You are critic, the reviewing designer for brief #29;")
        assert "Your persona: operations: failure and recovery paths." in brief
        assert f"bootstrap.py --commit {head}" in brief
        assert f"Review PR https://github.com/o/r/pull/7 at {head} from your own clone" in brief
        assert "herdr agent prompt team-1-tester" in brief
        allocation = self.record(1)["agents"]["critic"]
        assert (allocation["pr"], allocation["head"]) == ("7", head)
        assert allocation["session"] == self.launched_session("team-1-critic")
        assert self.comments("29")[-1]["body"].startswith(
            f"EVENT designer team-1-critic {allocation['session']}\nlaunched claude in "
        )
        # The reviewer clones and checks out the head under its own authority.
        self.bootstrap("team-1-critic", "--commit", head)
        project = root / "project"
        assert self.git("rev-parse", "HEAD", cwd=project) == head
        assert self.git("branch", "--show-current", cwd=project) == ""
        # The lead adds a tester to the brief: a Codex client with its own allocation.
        self.update(issues={**self.state()["issues"], "29": WIDE})
        self.team("review", "7", "second")
        second = self.pane("team-1-second")
        assert second["agent"] == "codex"
        assert self.launch_env("team-1-second") == ("_t1g1s", "4113")
        assert "the additional tester for brief #29" in self.prompts("team-1-second")[0]
        assert self.tabs("w1") == {
            "implementers": ["team-1-impl"],
            "reviewers": ["team-1-tester", "team-1-second"],
            "designers": ["team-1-critic"],
        }
        assert second["split"] == "right"
        # A running reviewer keeps the head its record names.
        moved = self.push("team-1-impl", "second push")
        starts = len(self.events("agent", "start"))
        rerun = self.team("review", "7", "critic").stdout
        assert f"Already running: team-1-critic at {head}" in rerun
        assert self.record(1)["agents"]["critic"]["head"] == head
        assert len(self.events("agent", "start")) == starts
        # Another client in the reviewer's pane is not the reviewer, however it is named.
        self.clients_exit(1)
        state = self.state()
        pane = next(x for x in state["panes"] if x.get("label") == "team-1-critic")
        pane.update(agent="claude", name="team-1-critic", cwd=str(self.repo))
        self.save(state)
        refused = self.team("review", "7", "critic", ok=False)
        assert "not its allocation; preserved" in refused.stderr
        pane.update(agent="codex", name="visitor", cwd=str(self.repo))
        self.save(state)
        refused = self.team("review", "7", "critic", ok=False)
        assert "conflicting client; preserved" in refused.stderr
        assert len(self.events("agent", "start")) == starts
        # A stopped reviewer is relaunched in the same allocation only after a reset, with
        # bootstrap configured for the new head; the reused clone is not recloned.
        pane.update(cwd=str(root))
        for key in ("agent", "name"):
            pane.pop(key)
        self.save(state)
        assert "task submission is submitted" in self.team("review", "7", "critic", ok=False).stderr
        self.reset("29", "critic")
        self.team("review", "7", "critic")
        assert f"bootstrap.py --commit {moved}" in self.system_prompt("team-1-critic")
        (project / ".dexter/marker").write_text("kept\n")
        self.bootstrap("team-1-critic", "--commit", moved)
        assert self.git("rev-parse", "HEAD", cwd=project) == moved
        assert (project / ".dexter/marker").read_text() == "kept\n"
        assert self.record(1)["agents"]["critic"]["head"] == moved

    def test_review_refuses_pair_entries_unknown_reviewers_and_unlinked_prs(self) -> None:
        self.push("team-1-impl")
        for entry in ("tester", "impl", "second"):
            with self.subTest(entry=entry):
                refused = self.team("review", "7", entry, ok=False)
                assert "not an additional reviewer" in refused.stderr
        self.update(pr_briefs={"7": []})
        assert "exactly one started brief" in self.team("review", "7", "critic", ok=False).stderr
        assert self.workspaces() == ["team-1-29"]
        assert not (self.trusted / "allocations/g1-critic").exists()


class DesignTest(Harness):
    def test_a_designer_uses_the_same_allocation_lifecycle(self) -> None:
        self.team("design", "50", "critic")
        record = self.record(1)
        assert (record["kind"], record["brief"], record["generation"]) == ("design", "50", 1)
        assert (record["implementer"], record["tester"]) == ("", "")
        root = self.trusted / "allocations/g1-critic"
        assert self.pane("team-1-critic")["cwd"] == str(root)
        assert self.tabs("w1") == {"designers": ["team-1-critic"]}
        brief = self.system_prompt("team-1-critic")
        assert brief.startswith("You are critic, the designer for spec #50;")
        assert "Read agent/teams/roles/designer.md" in brief
        assert "bootstrap.py:" in brief
        # The launch EVENT lets board.py usage find the designer's session.
        assert self.comments("50")[-1]["body"] == (
            f"EVENT designer team-1-critic {self.launched_session('team-1-critic')}\n"
            f"launched claude in {root}; "
            "allocation g1-critic; database suffix _t1g1c; port 4112"
        )
        usage = execute(
            ["python3", str(self.repo / "agent/teams/board.py"), "usage", "50"],
            cwd=self.repo,
            env=self.env,
            timeout=60,
        )
        assert "team-1-critic" in usage.stdout + usage.stderr
        # A second designer joins the spec's team; non-designers are refused.
        refused = self.team("design", "50", "tester", ok=False)
        assert "tester is not a configured designer entry" in refused.stderr
        assert "Already running: team-1-critic" in self.team("design", "50", "critic").stdout
        self.bootstrap("team-1-critic")
        project = root / "project"
        assert self.git("rev-parse", "HEAD", cwd=project) == self.git("rev-parse", "HEAD")
        assert self.git("branch", "--show-current", cwd=project) == ""
        # A brief start cannot take the spec's slot, and a design team keeps its databases.
        self.retire("team-1-critic")
        self.clients_exit(1)
        self.databases("tips_test_t1g1c")
        self.team("stop", "50")
        assert self.remaining_databases() == ["tips_test_t1g1c"]
        assert not any(call[-2:-1] == ["-c"] for call in self.psql_calls())
        assert project.is_dir()
        retired = json.loads((self.trusted / "state/g1-critic/retired.json").read_text())
        assert retired["databases_kept_because"] == "a design team has no merged work"
        assert self.recorded_briefs() == set()


class RetirementTest(Harness):
    def setUp(self) -> None:
        super().setUp()
        self.team("start", "29")
        self.bootstrap("team-1-impl")
        self.bootstrap("team-1-tester")

    def merged_pair(self) -> str:
        head = self.push("team-1-impl")
        self.merge(head)
        return head

    def test_stop_waits_for_every_report_then_releases_merged_work(self) -> None:
        self.team("start", "30")
        self.merged_pair()
        self.team("review", "7", "critic")
        self.bootstrap("team-1-critic")
        self.databases(
            "tips_test_t1g1i",
            "tips_test_t1g1r",
            "tips_test_t1g1r2",
            "tips_test_t1g1c",
            "tips_test_t2g2i",
            "tips_dev_t1g1r",
            "tips_test_t1g11i",
        )
        # Without reports nothing is stopped, dropped or released; running clients are
        # asked to report.
        refused = self.team("stop", "29", ok=False)
        assert "No retirement report yet from team-1-critic, team-1-impl, team-1-tester" in (
            refused.stderr
        )
        assert "Every resource stays reserved" in refused.stderr
        ask = self.latest_prompts()["team-1-impl"]
        assert ask == f"Retire: run python3 {self.repo / 'agent/teams/retirement.py'}, then " + (
            "end your turn."
        )
        assert not self.psql_calls()
        assert self.workspaces() == ["team-1-29", "team-2-30"]
        # A stopped client without a report gets an operator command, not a guess.
        self.clients_exit(1)
        refused = self.team("stop", "29", ok=False)
        assert "TIPS_TEAM_ALLOCATION_ID=g1-impl" in refused.stderr
        # Each worker reports its own clone; the report changes nothing.
        before = self.git("rev-parse", "HEAD", cwd=self.project("team-1-impl"))
        self.retire("team-1-impl", "team-1-tester", "team-1-critic")
        assert self.git("rev-parse", "HEAD", cwd=self.project("team-1-impl")) == before
        report = self.comments("29")[-3]["body"].splitlines()
        assert report[0] == "EVENT implementer team-1-impl session-team-1-impl"
        fields = json.loads(report[1].removeprefix("TEAM_RETIREMENT "))
        assert fields == {
            "v": 1,
            "id": "g1-impl",
            "cloned": True,
            "clean": True,
            "unpushed": 0,
            "merged": True,
            "head": before,
        }
        # A visitor pane in the team's workspace keeps everything.
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
        assert not self.psql_calls()
        self.update(strays=[])
        assert "nothing removed" in self.team("stop", "99").stdout
        daemons = sorted(self.state()["daemons"])
        stopped = self.team("stop", "29").stdout
        # Exactly the recorded databases and their partitions are dropped, without FORCE
        # and without project files; the other team and other generations stay.
        assert sorted(self.remaining_databases()) == ["tips_test_t1g11i", "tips_test_t2g2i"]
        assert all(call[:2] == ["fixture-dsn", "-X"] for call in self.psql_calls())
        assert not any("FORCE" in " ".join(call) for call in self.psql_calls())
        assert "databases dropped: tips_test_t1g1i" in stopped
        # Owned daemons were stopped with the trusted binary; the other team's stays.
        stops = sorted(e[1] for e in self.events("dexter") if e[2:] == ["stop"])
        assert stops == [d for d in daemons if "/g1-" in d]
        assert [d for d in self.state()["daemons"] if "/g1-" in d] == []
        # Project files are retained and listed, never deleted.
        for ident in ("g1-impl", "g1-tester", "g1-critic"):
            project = self.trusted / "allocations" / ident / "project"
            assert (project / "tracked.txt").exists()
            retired = json.loads((self.trusted / "state" / ident / "retired.json").read_text())
            assert str(project) in retired["retained"]
            assert retired["databases_kept_because"] == ""
        assert f"Retained {self.trusted / 'allocations/g1-impl/project'}" in stopped
        assert self.workspaces() == ["team-2-30"]
        assert self.recorded_briefs() == {"30"}
        assert self.pane("team-2-impl")["agent"] == "codex"
        assert "nothing removed" in self.team("stop", "29").stdout

    def test_unmerged_or_dirty_work_keeps_its_databases_and_files(self) -> None:
        self.databases("tips_test_t1g1i", "tips_test_t1g1r")
        project = self.project("team-1-impl")
        (project / "uncommitted").write_text("keep")
        self.retire("team-1-impl", "team-1-tester")
        self.clients_exit(1)
        stopped = self.team("stop", "29").stdout
        assert "team-1-impl reported uncommitted or unpushed work" in stopped
        assert self.remaining_databases() == ["tips_test_t1g1i", "tips_test_t1g1r"]
        assert (project / "uncommitted").read_text() == "keep"
        # Committed but unpushed work is also kept. The freed slot takes a new generation.
        self.team("start", "30")
        self.bootstrap("team-1-impl")
        other = self.project("team-1-impl")
        assert other == self.trusted / "allocations/g2-impl/project"
        self.commit("local only", cwd=other)
        self.retire("team-1-impl", "team-1-tester")
        self.clients_exit(1)
        assert "team-1-impl reported uncommitted or unpushed work" in (
            self.team("stop", "30").stdout
        )
        assert self.git("log", "-1", "--format=%s", cwd=other) == "local only"

    def test_a_writer_that_outlives_stop_never_causes_deletion(self) -> None:
        self.merged_pair()
        self.retire("team-1-impl", "team-1-tester")
        self.clients_exit(1)
        project = self.project("team-1-impl")
        late = project / "late.txt"
        self.env["RACE_DIRTY_FILE"] = str(late)
        self.team("stop", "29")
        assert late.read_text() == "written while stopping\n"
        retired = json.loads((self.trusted / "state/g1-impl/retired.json").read_text())
        assert str(project) in retired["retained"]
        # clean lists what stop retained and deletes nothing.
        listed = self.team("clean").stdout
        assert f"g1-impl (#29): {project.parent}; files: project and log files" in listed
        assert "databases _t1g1i: dropped" in listed
        assert late.exists()

    def test_refused_database_drop_keeps_the_rest_and_the_reservation(self) -> None:
        self.merged_pair()
        self.retire("team-1-impl", "team-1-tester")
        self.clients_exit(1)
        self.databases("tips_test_t1g1i", "tips_test_t1g1r", "tips_dev_t1g1r")
        self.env["PSQL_REFUSE"] = "tips_test_t1g1r"
        refused = self.team("stop", "29", ok=False)
        assert 'PostgreSQL refused to drop tips_test_t1g1r: ERROR:  database "tips_test' in (
            refused.stderr
        )
        assert "Dropped: tips_test_t1g1i; the rest and the reservation are kept" in refused.stderr
        assert self.remaining_databases() == ["tips_test_t1g1r", "tips_dev_t1g1r"]
        assert self.recorded_briefs() == {"29"}
        # The slot is not reassigned while it is kept.
        self.write_config(CONFIG.replace("max_teams = 6", "max_teams = 1"))
        assert "No free slot" in self.team("start", "30", ok=False).stderr
        del self.env["PSQL_REFUSE"]
        self.team("stop", "29")
        assert self.remaining_databases() == []
        assert self.recorded_briefs() == set()

    def test_busy_port_or_failed_daemon_stop_keeps_the_reservation(self) -> None:
        self.merged_pair()
        self.retire("team-1-impl", "team-1-tester")
        self.clients_exit(1)
        self.update(dexter_stop_fails=True)
        refused = self.team("stop", "29", ok=False)
        assert "fixture Dexter stop failed; the reservation is kept" in refused.stderr
        assert self.recorded_briefs() == {"29"}
        self.update(dexter_stop_fails=False)
        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as server:
            server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            server.bind(("127.0.0.1", 4111))
            server.listen()
            refused = self.team("stop", "29", ok=False)
            assert "Ports 4111 are in use; the reservation is kept" in refused.stderr
            assert self.recorded_briefs() == {"29"}
        self.team("stop", "29")
        assert self.recorded_briefs() == set()

    def test_generations_never_reuse_allocations_or_database_names(self) -> None:
        self.merged_pair()
        self.retire("team-1-impl", "team-1-tester")
        self.clients_exit(1)
        self.team("stop", "29")
        old = self.trusted / "allocations/g1-impl"
        # The brief starts again in the same slot with a new generation and new names.
        self.update(closed_by={}, merged=[])
        self.team("start", "29")
        assert self.record(1)["generation"] == 2
        assert self.launch_env("team-1-impl") == ("_t1g2i", "4110")
        assert self.pane("team-1-impl")["cwd"] == str(self.trusted / "allocations/g2-impl")
        assert (old / "project/tracked.txt").exists()
        # A forged record pointing at another allocation's directory is refused at stop.
        path = self.trusted / "state/1.json"
        record = json.loads(path.read_text())
        record["agents"]["impl"]["root"] = str(old)
        path.write_text(json.dumps(record))
        self.clients_exit(1)
        refused = self.team("stop", "29", ok=False)
        assert f"recorded allocation {old} is not" in refused.stderr
        assert (old / "project/tracked.txt").exists()

    def test_symlinked_allocation_paths_are_refused_at_retirement(self) -> None:
        self.retire("team-1-impl", "team-1-tester")
        self.clients_exit(1)
        logs = self.trusted / "allocations/g1-impl/logs"
        outside = self.root / "outside-logs"
        logs.rename(outside)
        logs.symlink_to(outside)
        refused = self.team("stop", "29", ok=False)
        assert "passes through a symlink; refused" in refused.stderr
        assert any(outside.iterdir())
        assert self.recorded_briefs() == {"29"}


class LaunchRecoveryTest(Harness):
    """Interrupted launches through `team.py start`, with faults injected into fake Herdr."""

    def fault(self, call: str, arg: str, mode: str, **extra: object) -> None:
        self.update(faults=[{"call": call, "arg": arg, "mode": mode, **extra}])

    def starts(self) -> list[str]:
        return [e[2] for e in self.events("agent", "start")]

    def test_two_concurrent_starts_launch_each_client_once(self) -> None:
        # The second start runs while the first is starting the implementer.
        self.fault("agent start", "team-1-impl", "concurrent", argv=["start", "29"])
        self.team("start", "29")
        nested = self.state()["nested"]
        assert nested["code"] == 1
        assert "Busy: another team.py command held" in nested["stderr"]
        assert self.starts() == ["team-1-impl", "team-1-tester"]
        assert len(self.prompts("team-1-impl")) == 1
        assert self.prompts("team-1-tester") == ["Begin."]

    def test_crash_before_durable_unknown_relaunches_and_after_it_holds_the_task(self) -> None:
        # Before: the launcher dies while preparing the tester's shell. No client could have
        # received the task, and the crash released the lock, so a rerun launches it.
        self.fault("pane run", "_t1g1r", "crash_before")
        self.team("start", "29", ok=False)
        assert self.record(1)["agents"]["tester"]["submission"] == "never_submitted"
        self.team("start", "29")
        assert self.starts() == ["team-1-impl", "team-1-tester"]
        assert self.prompts("team-1-tester") == ["Begin."]
        # After: the launcher dies once UNKNOWN is on disk, before the client starts.
        self.fault("agent start", "team-2-tester", "crash_before")
        self.team("start", "30", ok=False)
        assert self.record(2)["agents"]["tester"]["submission"] == "unknown"
        refused = self.team("start", "30", ok=False)
        assert "team-2-tester is not running and its task submission is unknown" in refused.stderr
        assert self.starts() == ["team-1-impl", "team-1-tester", "team-2-impl", "team-2-tester"]
        assert not self.prompts("team-2-tester")

    def test_client_live_after_launcher_timeout_or_crash_is_adopted_without_resend(self) -> None:
        # Herdr times out after the Claude tester started: Begin. was never sent.
        self.fault("agent start", "team-1-tester", "timeout_live")
        assert "timed out waiting for team-1-tester" in self.team("start", "29", ok=False).stderr
        assert self.record(1)["agents"]["tester"]["submission"] == "unknown"
        rerun = self.team("start", "29").stdout
        assert "team-1-tester: task submission is unknown; nothing was resent" in rerun
        assert self.starts() == ["team-1-impl", "team-1-tester"]
        assert not self.prompts("team-1-tester")
        tester = self.record(1)["agents"]["tester"]
        session = self.launched_session("team-1-tester")
        assert (tester["session"], tester["submission"]) == (session, "unknown")
        # The adoption records the launch EVENT the timeout skipped.
        bodies = [c["body"] for c in self.comments("29")]
        header = f"EVENT tester team-1-tester {session}\n"
        assert any(body.startswith(header) for body in bodies)
        # The launcher is killed after the Codex client started. The crash released the
        # lock, so the rerun is not busy, and it adopts the client.
        self.fault("agent start", "team-2-impl", "crash_after")
        self.team("start", "31", ok=False)
        assert "Already running: team-2-impl" in self.team("start", "31").stdout
        # First discovery: the record had no session and the client reports one.
        assert self.record(2)["agents"]["impl"]["session"] == "session-team-2-impl"
        assert self.starts()[2:] == ["team-2-impl", "team-2-tester"]
        assert not self.prompts("team-2-impl")
        # The launcher dies before Herdr sends Begin.: the task was not submitted.
        self.fault("agent prompt", "team-3-tester", "crash_before")
        self.team("start", "30", ok=False)
        assert self.record(3)["agents"]["tester"]["submission"] == "unknown"
        rerun = self.team("start", "30").stdout
        assert "team-3-tester: task submission is unknown; nothing was resent" in rerun
        assert self.prompts("team-3-tester") == ["Begin."]  # only the call the crash cut short

    def test_task_done_and_client_exited_before_the_record_update_is_never_replayed(self) -> None:
        self.fault("agent start", "team-1-tester", "timeout_exited")
        self.team("start", "29", ok=False)
        assert self.events("side-effect") == [["side-effect", "team-1-tester"]]
        held = "team-1-tester is not running and its task submission is unknown"
        for _ in range(2):
            assert held in self.team("start", "29", ok=False).stderr
        assert self.starts() == ["team-1-impl", "team-1-tester"]
        assert not self.prompts("team-1-tester")

    def test_malformed_record_or_uncertain_client_identity_blocks(self) -> None:
        self.team("start", "29")
        path = self.trusted / "state/1.json"
        good = json.loads(path.read_text())
        unknown_state = json.loads(path.read_text())
        unknown_state["agents"]["tester"]["submission"] = "done"
        cases = {
            "without record versions": {k: v for k, v in good.items() if k != "version"},
            "record version 2 is not 3": {**good, "version": 2},
            "allocation id must be 32 hex digits": {**good, "id": "slot-1"},
            "agents.tester.submission is not a known state": unknown_state,
        }
        for message, value in cases.items():
            with self.subTest(message=message):
                path.write_text(json.dumps(value))
                for command in (("start", "29"), ("reset", "29", "impl"), ("stop", "29")):
                    assert message in self.team(*command, ok=False).stderr
        # A live client with the recorded name that this record never started.
        never = json.loads(json.dumps(good))
        never["agents"]["tester"]["submission"] = "never_submitted"
        path.write_text(json.dumps(never))
        refused = self.team("start", "29", ok=False)
        assert "team-1-tester is live in w1:p2, but this record never started it" in refused.stderr
        # A client with the recorded name, kind and root but another session replaced it.
        path.write_text(json.dumps(good))
        state = self.state()
        tester = next(x for x in state["panes"] if x.get("label") == "team-1-tester")
        tester["agent_session"] = {"kind": "id", "value": "session-replacement"}
        self.save(state)
        refused = self.team("start", "29", ok=False).stderr
        session = self.launched_session("team-1-tester")
        assert f"runs session session-replacement, not {session}; preserved" in refused
        assert self.record(1)["agents"]["tester"]["session"] == session
        tester["agent_session"] = {"kind": "id", "value": session}
        self.save(state)
        # Another client in a recorded pane.
        state = self.state()
        visitor = next(x for x in state["panes"] if x.get("label") == "team-1-tester")
        visitor.update(name="visitor", cwd=str(self.repo))
        self.save(state)
        assert "conflicting client; preserved" in self.team("start", "29", ok=False).stderr
        assert self.starts() == ["team-1-impl", "team-1-tester"]
        assert len(self.events("agent", "prompt")) == 2
        assert self.state()["workspaces"]
        # Herdr reports no session (restricted mode): the record keeps the Claude session
        # the launcher assigned, but nothing shows which client is live, so a rerun refuses
        # to adopt either client; so does a replacement reported later.
        self.update(no_sessions=True)
        self.team("start", "30")
        session = self.launched_session("team-2-tester")
        assert self.record(2)["agents"]["tester"]["session"] == session
        assert self.record(2)["agents"]["impl"]["session"] == "unknown"
        refused = self.team("start", "30", ok=False).stderr
        assert "team-2-impl reports no session; cannot confirm the recorded client" in refused
        assert "only the operator decides" in refused
        state = self.state()
        for pane in state["panes"]:
            if pane.get("label") == "team-2-impl":
                pane["agent_session"] = {"kind": "id", "value": "session-team-2-impl"}
        self.save(state)
        refused = self.team("start", "30", ok=False).stderr
        assert "team-2-tester reports no session; cannot confirm the recorded client" in refused
        state = self.state()
        tester = next(x for x in state["panes"] if x.get("label") == "team-2-tester")
        tester["agent_session"] = {"kind": "id", "value": "session-replacement"}
        self.save(state)
        assert "preserved" in self.team("start", "30", ok=False).stderr
        assert self.starts().count("team-2-tester") == 1

    def test_missing_record_with_an_earlier_allocation_never_means_never_submitted(
        self,
    ) -> None:
        # The clients exit and the record is gone, but the earlier allocations remain.
        self.team("start", "29")
        self.clients_exit(1)
        (self.trusted / "state/1.json").unlink()
        held = "team-1-impl is not running and its task submission is unknown"
        for attempt in range(2):
            refused = self.team("start", "29", ok=False)
            assert held in refused.stderr, refused.stderr
            assert "team.py reset 29 impl" in refused.stderr
            if not attempt:
                assert "these remain: allocation g1-impl" in refused.stdout, refused.stdout
        assert self.starts() == ["team-1-impl", "team-1-tester"]
        assert len(self.events("agent", "prompt")) == 2
        # The operator checks the work, closes the earlier workspace and resets each client;
        # then both relaunch.
        self.update(workspaces=[], tabs=[], panes=[])
        self.reset("29", "impl", "tester")
        self.team("start", "29")
        assert self.starts()[2:] == ["team-1-impl", "team-1-tester"]
        # A reviewer whose allocation entry is gone while its allocation remains is held too.
        self.bootstrap("team-1-impl")
        self.push("team-1-impl")
        self.team("review", "7", "critic")
        self.clients_exit(1)
        path = self.trusted / "state/1.json"
        record = json.loads(path.read_text())
        del record["agents"]["critic"]
        path.write_text(json.dumps(record))
        refused = self.team("review", "7", "critic", ok=False).stderr
        assert "team-1-critic is not running and its task submission is unknown" in refused
        assert self.starts().count("team-1-critic") == 1


class RepositoryConfigTest(unittest.TestCase):
    def test_shipped_configuration_validates(self) -> None:
        env = dict(os.environ, TIPS_TEAM_CONFIG=str(SCRIPT.parent / "config.toml"))
        code = "import sys; sys.path.insert(0,sys.argv[1]); from team import load_config; "
        result = execute(["python3", "-c", code + "load_config()", str(SCRIPT.parent)], env=env)
        assert result.returncode == 0, result.stderr


if __name__ == "__main__":
    unittest.main()
