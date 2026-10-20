"""Shared test fixtures: the fixture configuration, the fake programs, real-Dexter
helpers and the Harness base class. Test modules import from here."""

import atexit
import functools
import json
import os
import shutil
import subprocess
import tempfile
import time
import unittest
from pathlib import Path
from typing import Any

from bootstrap import wrapper_text
from commands import execute

SCRIPT = Path(__file__).resolve().parents[1] / "team.py"
# Deliberately fixed test data: changing production defaults must not rewrite tests.
# Each parallel test worker gets its own port range; see tests/parallel.py.
PORT_BASE = int(os.environ.get("TIPS_TEST_PORT_BASE", "24100"))
CONFIG = f"""\
# Agent launch settings. Changes apply to newly started sessions.
# An empty model uses the client's configured default.
[github]
repository = "o/r"

[github.projects]
16 = ["Phase", "Feature"]

[team]
clone_url = "/fixture/origin.git"
psql = ["/fixture/psql", "fixture-dsn"]
max_teams = 6
port_base = {PORT_BASE}
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

[agents.lead]
role = "designer"
kind = "codex"
model = "fixture-lead"
effort = "high"
db_suffix = "l"
port_offset = 4

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


@functools.cache
def fakes() -> Path:
    """This test process's directory of fake programs, removed when the process exits."""
    directory = Path(tempfile.mkdtemp(prefix="tips-test-fakes-"))
    atexit.register(shutil.rmtree, directory, ignore_errors=True)
    return directory


def fake(name: str, body: str) -> Path:
    """The fake program `name`, written once per test process. macOS scans each new
    executable on its first run (about 0.5 s), so tests symlink to one copy instead of
    writing their own. Per-test state comes from environment variables such as
    HERDR_FIXTURE. Replace a link before writing: writing through it changes every test."""
    path = fakes() / name
    if not path.exists():
        path.write_text(body)
        path.chmod(0o755)
    return path


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
    live = [x for x in procs if alive(x["pid"])]
    if not live and s.get("stale_reads"):
        # Herdr's snapshot lags the exit: the dead client still leads the pane (#478).
        s["stale_reads"] -= 1
        json.dump(s, open(os.environ["HERDR_FIXTURE"], "w"))
    else:
        procs = live
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
if state.get('mix_partial'):
    Path('deps').mkdir(exist_ok=True)
    sys.exit('fixture mix failed after writing deps')
if state.get('mix_fails'):
    sys.exit('fixture mix failed')
Path('deps').mkdir(exist_ok=True)
"""

# Issues, PRs, comments, reviews, labels and required checks live in the fixture state. Each
# posted comment gets the next id and a time one minute after the previous one. An issue's
# labels are in `labels`; the repository's label names in `label_names`. As gh does, an edit
# that adds a label the repository lacks fails naming it, and `label_add_fails` refuses
# every label addition.
FAKE_GH = r"""#!/usr/bin/env python3
import datetime, json, os, sys
from pathlib import Path
path = Path(os.environ["HERDR_FIXTURE"])
s = json.loads(path.read_text())
a = sys.argv[1:]
if a[0] in ("pr", "issue") and ["--repo", "o/r"] not in [a[i : i + 2] for i in range(len(a))]:
    sys.exit("fixture gh: no --repo o/r in " + repr(a))  # never the working directory's remote
s.setdefault("events", []).append(["gh", *a])
comments = s.setdefault("comments", {})
out, code = "", 0
PASSING = [
    {"name": "checks", "workflow": "CI", "bucket": "pass", "link": "https://ci/1"},
    {"name": "release", "workflow": "CI", "bucket": "pass", "link": "https://ci/1"},
]
if a[:2] == ["issue", "view"] and "closedBy" in a[-1] and s.get("gh_stalls"):
    import time
    time.sleep(30)  # GitHub never answers; the caller's bound must end this
if a[:2] == ["issue", "view"]:
    body = s.get("issues", {}).get(a[2], "")
    view = {
        "body": body,
        "labels": [{"name": n} for n in s.get("labels", {}).get(a[2], [])],
        "url": "https://github.com/o/r/issues/" + a[2],
        "state": "CLOSED" if a[2] in s.get("closed_by", {}) else "OPEN",
        "closedByPullRequestsReferences": [
            {"number": int(n)} for n in s.get("closed_by", {}).get(a[2], [])
        ],
    }
    out = json.dumps({key: view[key] for key in a[a.index("--json") + 1].split(",")})
elif a[:2] == ["issue", "edit"] and ("--add-label" in a or "--remove-label" in a):
    # As in gh, the remove and the add are separate mutations: a failed add still removes.
    labels = s.setdefault("labels", {}).setdefault(a[2], [])
    if "--remove-label" in a:
        remove = a[a.index("--remove-label") + 1].split(",")
        labels[:] = [n for n in labels if n not in remove]
    if "--add-label" in a:
        add = a[a.index("--add-label") + 1].split(",")
        missing = [n for n in add if n not in s.get("label_names", [])]
        if s.get("label_add_fails"):
            out, code = "fixture GitHub refused the label edit", 1
        elif missing:
            url = "https://github.com/o/r/issues/" + a[2]
            out, code = "failed to update %s: '%s' not found" % (url, missing[0]), 1
        else:
            labels += [n for n in add if n not in labels]
elif a[:2] == ["label", "create"]:
    if a[2] in s.get("label_names", []):
        out, code = 'label with name "%s" already exists' % a[2], 1
    else:
        s.setdefault("label_names", []).append(a[2])
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
    # The head or base can move while a reader is between its first and last view.
    if "head_after_checks" in s:
        s["pr_head"] = s.pop("head_after_checks")
    if "base_after_checks" in s:
        s["pr_base"] = s.pop("base_after_checks")
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
elif a[0] == "api" and "/rules/branches/" in a[1]:
    required = [{"context": name} for name in s.get("required", ["checks", "release"])]
    rule = {"type": "required_status_checks", "parameters": {"required_status_checks": required}}
    out = json.dumps([{"type": "deletion"}, *([rule] if required else [])])
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
# timeout, timeout_exited runs the task's side effect and exits before the timeout,
# misreport reports the fields in `report` instead of the started client's, and
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
    # An exited client may still be listed as an agent while its shell leads again.
    live = (x.get("agent") or x.get("busy")) and not x.get("exited")
    leader = 200 if live else 100
    processes = [{"pid": leader, "cwd": x["cwd"]}]
    if live:
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
    if mode == "misreport":
        # Herdr reports another session, name or kind than the launcher asked for.
        x.update(fault["report"])
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


class FakeState:
    """The state file the fake programs share: Herdr's panes and events, gh's PRs and
    comments, and every call they logged."""

    state_path: Path

    def state(self) -> dict[str, Any]:
        state: dict[str, Any] = json.loads(self.state_path.read_text())
        return state

    def save(self, state: dict[str, Any]) -> None:
        self.state_path.write_text(json.dumps(state))

    def update(self, **flags: object) -> None:
        self.save({**self.state(), **flags})

    def events(self, *prefix: str) -> list[list[str]]:
        return [e for e in self.state()["events"] if e[: len(prefix)] == list(prefix)]

    def comments(self, issue: str) -> list[dict[str, Any]]:
        comments: list[dict[str, Any]] = self.state().get("comments", {}).get(issue, [])
        return comments

    def labelled_before(self, mark: int, *prefixes: list[str]) -> None:
        """Of the events after `mark`, the last label edit comes before the first event that
        starts with one of `prefixes`, such as a client start or a prompt."""
        events = self.state()["events"][mark:]
        edits = [i for i, e in enumerate(events) if e[:3] == ["gh", "issue", "edit"]]
        later = [i for i, e in enumerate(events) if any(e[: len(p)] == p for p in prefixes)]
        assert edits, events
        assert later, events
        assert edits[-1] < later[0], events

    def labels(self, issue: str) -> list[str]:
        """The issue's labels as the fake GitHub holds them."""
        labels: list[str] = self.state().get("labels", {}).get(issue, [])
        return labels


class Harness(FakeState, unittest.TestCase):
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
        programs = {
            "herdr": PAIR_HERDR,
            "mix": FAKE_MIX,
            "gh": FAKE_GH,
            "psql": FAKE_PSQL,
            "ps": FAKE_PS,
            "elixir": '#!/bin/sh\nprintf "1.2.3\\n"\n',
        }
        # Per-test links, so a test can replace or remove one without touching the others.
        for name, body in programs.items():
            (self.bin / name).symlink_to(fake(name, body))
        execute(["git", "init", "-q", "-b", "main", str(self.repo)], env=self.env, check=True)
        execute(["git", "init", "-q", "--bare", "-b", "main", str(self.origin)], env=self.env)
        (self.repo / ".gitignore").write_text(
            ".codex/\n.agents/\n.dexter/\n.worktrees/\nagent/lsp/dexter/vendor/\n"
            "agent/teams/allocations/\ndeps/\ntmp/\n"
        )
        for script in [*sorted(SCRIPT.parent.glob("*.py")), SCRIPT.parent / "dispatch"]:
            (self.repo / "agent/teams" / script.name).write_text(script.read_text())
        self.write_config(CONFIG)
        (self.repo / "tracked.txt").write_text("base\n")
        (self.repo / "agent/lsp/dexter/vendor/dexter").symlink_to(fake("dexter", FAKE_DEXTER))
        self.commit("base")
        self.git("remote", "add", "origin", str(self.origin))
        self.git("push", "-q", "origin", "main")
        issues = {
            "29": BRIEF,
            "30": WIDE,
            "31": NARROW,
            "40": "Spec: a design\nLead: critic\n",
            "50": "Spec: a design\nLead: lead\n",
        }
        # The repository already has the labels most tests write.
        names = [f"phase:{p}" for p in ("design", "implement", "review")]
        names += [f"turn:{e}" for e in ("dispatcher", "impl", "tester", "critic", "lead")]
        self.save(
            {"workspaces": [], "panes": [], "events": [], "issues": issues, "label_names": names}
        )

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
        record: dict[str, Any] = json.loads((self.trusted / f"state/{slot}.json").read_text())
        return record

    def recorded_briefs(self) -> set[str]:
        files = (p for p in (self.trusted / "state").glob("*.json") if p.stem.isdecimal())
        return {json.loads(path.read_text())["brief"] for path in files}

    def allocation(self, name: str) -> dict[str, Any]:
        for path in (self.trusted / "state").glob("[0-9]*.json"):
            record: dict[str, Any] = json.loads(path.read_text())
            agents: dict[str, dict[str, Any]] = record["agents"]
            for allocation in agents.values():
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
        env = dict(self.env, HERDR_PANE_ID=pane["pane_id"])
        env.update({k: v for k, v in pane["launch_env"].items() if v is not None})
        env.update(extra)
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

    def launched_session(self, label: str) -> str:
        """The session id the launcher assigned to a Claude client."""
        argv: list[str] = self.pane(label)["launch_argv"]
        return argv[argv.index("--session-id") + 1]

    def launch_env(self, label: str) -> tuple[str, str]:
        env = self.pane(label)["launch_env"]
        return env["TIPS_DB_SUFFIX"], env["TIPS_TEST_PORT"]

    def system_prompt(self, label: str) -> str:
        argv: list[str] = self.pane(label)["launch_argv"]
        return argv[argv.index("--append-system-prompt") + 1]
