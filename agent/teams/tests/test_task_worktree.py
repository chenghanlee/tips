#!/usr/bin/env python3
"""Real Git + fake Herdr integration; never controls a live pane or model client."""

import json
import os
import shutil
import subprocess
import sys
import tempfile
import tomllib
import unittest
from pathlib import Path
from typing import Literal, TypedDict, cast

from team import execute


class FixtureState(TypedDict):
    agents: list[dict[str, str]]
    events: list[list[str]]
    cwd: str
    output: str
    env: dict[str, str]
    launch_env: dict[str, str | None]
    launch_argv: list[str]
    stop_fails: bool
    stop_dirties: bool
    busy: bool
    start_fails: bool
    wrong_start_root: str
    shell_timeout: bool


TEAMS = Path(__file__).resolve().parents[1]
DEXTER_REV = TEAMS.parents[1] / "agent/lsp/dexter.rev"
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
FAKE_HERDR = (
    r"""#!/usr/bin/env python3
import json, os, subprocess, sys
from pathlib import Path
"""
    + PANE_SCREEN
    + r"""

p = Path(os.environ["FAKE_HERDR_STATE"])
state = json.loads(p.read_text())
a = sys.argv[1:]
state["events"].append(a)


def reply(result, code=0):
    p.write_text(json.dumps(state))
    print(json.dumps({"result": result}))
    sys.exit(code)


if a == ["agent", "list"]:
    reply({"agents": state["agents"]})
if a[:2] == ["agent", "get"]:
    matches = [
        x for x in state["agents"] if x["pane_id"] == a[2] or x.get("name") == a[2]
    ]
    reply({"agent": matches[0]} if matches else {}, 0 if matches else 1)
if a[:2] == ["agent", "rename"]:
    for x in state["agents"]:
        if x["pane_id"] == a[2]:
            x["name"] = a[3]
    reply({})
if a[:2] == ["pane", "get"]:
    reply(
        {
            "pane": {
                "pane_id": a[2],
                "cwd": state["cwd"],
                "foreground_cwd": state["cwd"],
                "agent": None,
            }
        }
    )
if a[:2] == ["pane", "process-info"]:
    pane = a[a.index("--pane") + 1]
    agent = next((x for x in state["agents"] if x["pane_id"] == pane), None)
    if agent is not None and not agent.get("bare"):
        # The client leads the foreground group; an LSP child runs elsewhere.
        client = agent.get("cwd") or agent.get("foreground_cwd")
        reply(
            {
                "process_info": {
                    "shell_pid": 100,
                    "foreground_process_group_id": 200,
                    "foreground_processes": [
                        {"pid": 200, "cwd": client},
                        {"pid": 201, "cwd": "/opt/homebrew/lsp-child"},
                    ],
                }
            }
        )
    pid = 999 if state.get("busy") else 100
    reply(
        {
            "process_info": {
                "shell_pid": 100,
                "foreground_process_group_id": pid,
                "foreground_processes": [{"pid": pid, "cwd": state["cwd"]}],
            }
        }
    )
if a[:2] == ["pane", "run"]:
    # Actually execute setup in a disposable shell and capture its resulting environment.
    command = (
        a[3]
        + '\npython3 -c \'import os,json; '
        'print("SNAPSHOT="+json.dumps({"env":dict(os.environ),"cwd":os.getcwd()}))\''
    )
    r = subprocess.run(
        ["bash", "-c", command],
        cwd=state["cwd"],
        env=os.environ,
        text=True,
        capture_output=True,
    )
    if r.returncode:
        reply({"error": r.stderr}, 1)
    lines = r.stdout.splitlines()
    snap = json.loads(next(x[9:] for x in lines if x.startswith("SNAPSHOT=")))
    state["cwd"] = snap["cwd"]
    state["env"] = snap["env"]
    state["echo"] = a[3]
    state["output"] = r.stdout
    p.write_text(json.dumps(state))
    sys.exit(0)
if a[:2] == ["pane", "wait-output"]:
    source = a[a.index("--source") + 1]
    if source not in ("visible", "recent", "recent-unwrapped"):
        reply({"error": "invalid --source " + source}, 2)
    # shell_timeout: setup produced no output, so only the typed command echo is on screen.
    output = "" if state.get("shell_timeout") else state.get("output", "")
    screen = pane_screen(state.get("echo", "") + "\n" + output, source)
    reply({}, 0 if a[a.index("--match") + 1] in screen else 1)
if a[:2] == ["agent", "start"]:
    state["launch_env"] = {
        k: state.get("env", {}).get(k)
        for k in [
            "PGPORT",
            "TIPS_DB_SUFFIX",
            "TIPS_TEST_PORT",
            "MIX_ENV",
            "MIX_TEST_PARTITION",
            "CLAUDE_AUTOCOMPACT_PCT_OVERRIDE",
            "TIPS_CHECK_TIMEOUT_SECONDS",
            "TIPS_TEAM_CONFIG",
            "TIPS_PROVIDER_ENV_FILE",
            "TIPS_ELIXIR_TOOLS",
        ]
    }
    state["launch_argv"] = a
    root = state["cwd"]
    kind = a[a.index("--kind") + 1]
    if state.get("wrong_start_root"):
        root = state["wrong_start_root"]
    agent = {
        "name": a[2],
        "pane_id": a[a.index("--pane") + 1],
        "agent": kind,
        "cwd": root,
        "foreground_cwd": root,
        "agent_status": "blocked" if state.get("start_fails") else "idle",
    }
    state["agents"] = [agent]
    reply({"agent": agent}, 1 if state.get("start_fails") else 0)
reply({"error": "unhandled fake Herdr command: " + repr(a)}, 2)
"""
)
FAKE_STOP = r"""import json,os,subprocess,sys
from pathlib import Path
p=Path(os.environ['FAKE_HERDR_STATE']); s=json.loads(p.read_text())
head=subprocess.check_output(['git','-C',sys.argv[2],'rev-parse','HEAD'],text=True).strip()
s['events'].append(['stop_agent',sys.argv[1],sys.argv[2],head])
if not s.get('stop_fails'): s['agents']=[]
if s.get('stop_dirties'): (Path(sys.argv[2])/'tracked.txt').write_text('saved at exit\n')
p.write_text(json.dumps(s))
sys.exit(1 if s.get('stop_fails') else 0)
"""


def snapshot(directory: Path) -> dict[str, bytes]:
    return {
        path.relative_to(directory).as_posix(): path.read_bytes()
        for path in sorted(directory.rglob("*"))
        if path.is_file()
    }


class WorktreeIntegrationTest(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory(prefix="tips helper ")
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name).resolve()
        self.env = dict(
            os.environ, GIT_CONFIG_GLOBAL=os.devnull, GIT_CONFIG_NOSYSTEM="1", HERDR_ENV="1"
        )
        self.env.pop("TIPS_TEAM_CONFIG", None)
        for k in (
            "TIPS_DB_SUFFIX",
            "TIPS_TEST_PORT",
            "PGPORT",
            "MIX_ENV",
            "MIX_TEST_PARTITION",
            "CLAUDE_AUTOCOMPACT_PCT_OVERRIDE",
        ):
            self.env.pop(k, None)
        self.git("init", "-q", "-b", "main")
        for d in ("agent/lsp", "agent/teams", ".agents/skills", "agent/lsp/vendor/bin", "fakebin"):
            (self.root / d).mkdir(parents=True)
        (self.root / ".gitignore").write_text(
            ".codex/\n.claude/\n.agents/\n.dexter/\nagent/lsp/vendor/\n.worktrees/\nfakebin/\nsta"
            "te.json\nstop.py\n"
        )
        shutil.copy(TEAMS / "task_worktree.py", self.root / "agent/teams/task_worktree.py")
        shutil.copy(DEXTER_REV, self.root / "agent/lsp/dexter.rev")
        (self.root / "agent/teams/team.py").write_text(
            (TEAMS / "team.py").read_text()
            + (
                "\nimport os, subprocess, sys\ndef stop_agent(pane, root):\n    if su"
                'bprocess.run([sys.executable, os.environ["FAKE_STOP"], pane, root'
                ']).returncode:\n        raise RuntimeError("stop failed")\n'
            )
        )
        (self.root / "agent/teams/config.toml").write_text(CONFIG)
        (self.root / "tracked.txt").write_text("base\n")
        for name in ("dexter",):
            p = self.root / "agent/lsp/vendor/bin" / name
            p.write_text("#!/bin/sh\nexit 0\n")
            p.chmod(0o755)
        self.git("add", ".")
        self.commit("base")
        self.base = self.git("rev-parse", "HEAD")
        self.git("remote", "add", "origin", str(self.root))
        self.git("update-ref", "refs/remotes/origin/main", self.base)
        fake = self.root / "fakebin/herdr"
        fake.write_text(FAKE_HERDR)
        fake.chmod(0o755)
        (self.root / "stop.py").write_text(FAKE_STOP)
        self.state_path = self.root / "state.json"
        self.save({"agents": [], "events": [], "cwd": str(self.root)})
        self.env.update(
            PATH=str(self.root / "fakebin") + os.pathsep + self.env["PATH"],
            FAKE_HERDR_STATE=str(self.state_path),
            FAKE_STOP=str(self.root / "stop.py"),
        )
        self.script = self.root / "agent/teams/task_worktree.py"
        self.wt = self.root / ".worktrees/28-review-team-3-lead"

    def git(self, *a: str) -> str:
        return execute(["git", *a], cwd=self.root, env=self.env, check=True).stdout.strip()

    def commit(self, msg: str) -> None:
        self.git(
            "-c",
            "user.name=Test",
            "-c",
            "user.email=test@example.invalid",
            "commit",
            "-q",
            "--allow-empty",
            "-m",
            msg,
        )

    def state(self) -> FixtureState:
        return cast(FixtureState, json.loads(self.state_path.read_text()))

    def save(self, s: object) -> None:
        self.state_path.write_text(json.dumps(s))

    def call(
        self,
        *extra: str,
        ref: str | Literal[False] | None = None,
        ok: bool = True,
        role: str = "lead",
        team: str = "3",
        task: str = "28-review-team-3-lead",
    ) -> subprocess.CompletedProcess[str]:
        args = [
            sys.executable,
            str(self.script),
            task,
            "--team",
            team,
            "--pane",
            "wA:pB",
            "--role",
            role,
        ]
        if ref is not False:
            args += ["--review-ref", ref or self.base]
        p = execute(args + list(extra), cwd=self.root, env=self.env, timeout=20)
        if ok:
            assert p.returncode == 0, p.stdout + p.stderr
        else:
            assert p.returncode != 0, p.stdout + p.stderr
        return p

    def test_command_resolves_executable_from_target_environment(self) -> None:
        executable = self.root / "fakebin/fixture-command"
        executable.write_text("#!/bin/sh\nprintf 'fixture only\\n'\n")
        executable.chmod(0o755)
        result = execute(["fixture-command"], env=self.env, check=True)
        assert result.stdout == "fixture only\n"

    def test_command_resolves_relative_paths_from_child_directory(self) -> None:
        child = self.root / "child"
        binary = child / "bin"
        binary.mkdir(parents=True)
        executable = binary / "fixture-command"
        executable.write_text("#!/bin/sh\nprintf 'child directory\\n'\n")
        executable.chmod(0o755)
        env = {**self.env, "PATH": "bin"}
        for command in ("fixture-command", "./bin/fixture-command"):
            with self.subTest(command=command):
                result = execute([command], cwd=child, env=env, check=True)
                assert result.stdout == "child directory\n"

    def test_invalid_herdr_response_preserves_checkout(self) -> None:
        (self.root / "fakebin/herdr").write_text(
            '#!/bin/sh\nprintf \'%s\\n\' \'{"result":{"agents":"wrong"}}\'\n'
        )
        result = self.call("--start", ok=False)
        assert "Herdr agents must be a list" in result.stderr
        assert not self.wt.exists()

    @unittest.skipIf(os.geteuid() == 0, "root bypasses directory permissions")
    def test_unwritable_main_git_refers_caller_to_team_tpm_before_fetch(self) -> None:
        git_dir = self.root / ".git"
        before = snapshot(git_dir)
        git_dir.chmod(0o555)
        self.addCleanup(git_dir.chmod, 0o755)
        result = self.call("--start", role="dev", task="29-dev", ref=False, ok=False)
        assert "ask team-3-tpm to run it from the main checkout" in result.stderr
        assert "fetch" not in result.stderr
        assert self.state()["events"] == []
        assert not (self.root / ".worktrees").exists()
        assert snapshot(git_dir) == before

    def test_codex_only_and_idempotent_config(self) -> None:
        self.call()
        path = self.wt / ".codex/config.toml"
        assert not (self.wt / ".claude").exists()
        before = path.stat().st_mtime_ns
        self.call()
        assert before == path.stat().st_mtime_ns
        assert self.git("-C", str(self.wt), "status", "--porcelain") == ""

    def test_dexter_codex_uses_stock_cli_and_declared_shell_environment(self) -> None:
        self.call()
        cfg = tomllib.loads((self.wt / ".codex/config.toml").read_text())
        assert "mcp_servers" not in cfg
        policy = cfg["shell_environment_policy"]["set"]
        assert policy["MIX_ENV"] == "test"
        assert policy["TIPS_DB_SUFFIX"] == "_t3l"
        assert "PATH" not in policy
        assert policy["TIPS_ELIXIR_TOOLS"] == str(self.root / "agent/lsp/vendor")

    def test_codex_reuse_does_not_depend_on_the_launchers_path(self) -> None:
        self.call()
        path = self.wt / ".codex/config.toml"
        before = path.read_bytes(), path.stat().st_mtime_ns
        self.env["PATH"] = str(self.root / "another-bin") + os.pathsep + self.env["PATH"]
        self.call("--start")
        assert (path.read_bytes(), path.stat().st_mtime_ns) == before
        assert self.state()["launch_env"]["TIPS_ELIXIR_TOOLS"] == str(
            self.root / "agent/lsp/vendor"
        )
        assert self.state()["env"]["PATH"] == self.env["PATH"]

    def test_dexter_claude_uses_stock_cli_with_native_plugin_disabled(self) -> None:
        # The session reads the generated file by path; linked-worktree discovery can miss it.
        self.call("--start", role="test", team="6")
        settings = self.wt / ".claude/settings.local.json"
        assert json.loads(settings.read_text()) == {
            "enabledPlugins": {
                "mix-compile@elixir-agent-tools": False,
                "mix-credo@elixir-agent-tools": False,
                "elixir-lsp@elixir-agent-tools": False,
                "dexter-lsp@dexter": False,
            }
        }
        assert [p.name for p in settings.parent.iterdir()] == ["settings.local.json"]
        s = self.state()
        argv = s["launch_argv"]
        assert argv[argv.index("--") + 1 :] == [
            "--permission-mode",
            "bypassPermissions",
            "--effort",
            "xhigh",
            "--settings",
            str(settings),
            "--model",
            "fixture-test",
        ]
        assert s["launch_env"]["TIPS_ELIXIR_TOOLS"] == str(self.root / "agent/lsp/vendor")
        # Agents call the explicit binary; the pane keeps the caller's PATH unchanged.
        setup = next(e[3] for e in s["events"] if e[:2] == ["pane", "run"])
        assert "PATH=" not in setup
        assert s["env"]["PATH"] == self.env["PATH"]

    def test_dexter_initializes_exact_worktree_before_launch(self) -> None:
        dexter = self.root / "agent/lsp/vendor/bin/dexter"
        dexter.write_text(
            '#!/bin/sh\n[ "$1" = init ] || exit 0\n'
            'mkdir -p "$2/.dexter"\ntouch "$2/.dexter/dexter.db"\n'
        )
        self.call("--start")
        assert (self.wt / ".dexter/dexter.db").is_file()
        assert not (self.root / ".dexter").exists()

    def test_dexter_init_failure_prevents_client_launch(self) -> None:
        dexter = self.root / "agent/lsp/vendor/bin/dexter"
        dexter.write_text('#!/bin/sh\necho "index unavailable" >&2\nexit 1\n')
        result = self.call("--start", ok=False)
        assert "index unavailable" in result.stderr
        assert "launch_argv" not in self.state()

    def test_reuse_releases_index_and_does_not_reinitialize_it(self) -> None:
        self.call()
        database = self.wt / ".dexter/dexter.db"
        database.parent.mkdir()
        database.write_text("existing index")
        dexter = self.root / "agent/lsp/vendor/bin/dexter"
        dexter.write_text(
            '#!/bin/sh\n[ "$1" = stop ] || exit 19\nprintf "%s\\n" "$@" > "$3/.dexter/stop-args"\n'
        )
        self.call("--start")
        assert database.read_text() == "existing index"
        assert (database.parent / "stop-args").read_text().splitlines() == [
            "stop",
            "--root",
            str(self.wt),
        ]
        assert self.state()["launch_argv"]

    def test_attached_index_prevents_checkout_and_launch_on_reuse(self) -> None:
        self.call()
        (self.wt / ".dexter").mkdir()
        (self.wt / ".dexter/dexter.db").touch()
        self.commit("new review head")
        newer = self.git("rev-parse", "HEAD")
        dexter = self.root / "agent/lsp/vendor/bin/dexter"
        dexter.write_text("#!/bin/sh\nexit 1\n")
        result = self.call("--start", ref=newer, ok=False)
        assert "release" in result.stderr
        assert "preserved" in result.stderr
        assert self.git("-C", str(self.wt), "rev-parse", "HEAD") == self.base
        assert "launch_argv" not in self.state()

    def test_incomplete_index_never_targets_ancestor_or_changes_checkout(self) -> None:
        self.call()
        (self.root / ".dexter").mkdir()
        (self.root / ".dexter/dexter.db").touch()
        (self.wt / ".dexter").mkdir()
        self.commit("new review head")
        newer = self.git("rev-parse", "HEAD")
        dexter = self.root / "agent/lsp/vendor/bin/dexter"
        dexter.write_text(
            "#!/usr/bin/env python3\nfrom pathlib import Path\n"
            f"Path({str(self.root / '.dexter/called')!r}).touch()\n"
        )
        result = self.call("--start", ref=newer, ok=False)
        assert "release" in result.stderr
        assert "preserved" in result.stderr
        assert not (self.root / ".dexter/called").exists()
        assert self.git("-C", str(self.wt), "rev-parse", "HEAD") == self.base
        assert "launch_argv" not in self.state()

    def test_claude_only_and_actual_target_environment(self) -> None:
        self.call("--start", role="test", team="6")
        assert not (self.wt / ".codex").exists()
        assert not (self.wt / ".claude/elixir-mcp.json").exists()
        assert not json.loads((self.wt / ".claude/settings.local.json").read_text())[
            "enabledPlugins"
        ]["elixir-lsp@elixir-agent-tools"]
        s = self.state()
        assert s["launch_env"] == {
            "PGPORT": "5433",
            "TIPS_DB_SUFFIX": "_t6r",
            "TIPS_TEST_PORT": "4161",
            "MIX_ENV": "test",
            "MIX_TEST_PARTITION": None,
            "CLAUDE_AUTOCOMPACT_PCT_OVERRIDE": None,
            "TIPS_CHECK_TIMEOUT_SECONDS": "1800",
            "TIPS_TEAM_CONFIG": str(self.root / "agent/teams/config.toml"),
            "TIPS_PROVIDER_ENV_FILE": str(self.root / ".env"),
            "TIPS_ELIXIR_TOOLS": str(self.root / "agent/lsp/vendor"),
        }
        assert s["cwd"] == str(self.wt)
        assert "fixture-test" in s["launch_argv"]
        assert "--plugin-dir" not in s["launch_argv"]

    def test_codex_models_and_config_parameters(self) -> None:
        self.call("--start")
        assert "fixture-lead" in self.state()["launch_argv"]
        s = self.state()
        s["agents"] = []
        self.save(s)
        cfg = self.root / "agent/teams/config.toml"
        cfg.write_text(
            CONFIG.replace("fixture-dev", "configured-sol")
            .replace("4100", "5100")
            .replace("5433", "5434")
            .replace("launch_seconds = 120", "launch_seconds = 42")
        )
        self.call("--start", role="dev", team="6", task="29-dev", ref=False)
        s = self.state()
        assert "configured-sol" in s["launch_argv"]
        assert "42000" in s["launch_argv"]
        assert s["launch_env"]["TIPS_TEST_PORT"] == "5160"
        assert s["launch_env"]["PGPORT"] == "5434"

    def test_same_live_session_reused_and_new_sha_stops_tester_before_checkout(self) -> None:
        task, wt = "28-review-team-3-test", self.root / ".worktrees/28-review-team-3-test"
        self.call("--start", role="test", task=task)
        before = len(self.state()["events"])
        p = self.call("--start", role="test", task=task)
        assert "Already running" in p.stdout
        assert not any(e[:2] == ["agent", "start"] for e in self.state()["events"][before:])
        self.commit("next")
        new = self.git("rev-parse", "HEAD")
        self.call("--start", role="test", task=task, ref=new)
        stops = [e for e in self.state()["events"] if e[0] == "stop_agent"]
        assert stops == [["stop_agent", "wA:pB", str(wt), self.base]]
        assert self.git("-C", str(wt), "rev-parse", "HEAD") == new
        assert sum(e[:2] == ["agent", "start"] for e in self.state()["events"]) == 2

    def test_running_lead_advances_in_place_without_stop_or_restart(self) -> None:
        self.call("--start")
        self.commit("next")
        new = self.git("rev-parse", "HEAD")
        p = self.call(ref=new)
        assert "Advanced team-3-lead in place" in p.stdout
        assert not any(e[0] == "stop_agent" for e in self.state()["events"])
        assert sum(e[:2] == ["agent", "start"] for e in self.state()["events"]) == 1
        assert self.git("-C", str(self.wt), "rev-parse", "HEAD") == new
        assert self.git("-C", str(self.wt), "branch", "--show-current") == ""

    def test_review_ref_pushed_only_to_origin_is_fetched_before_resolution(self) -> None:
        # A freshly pushed head is absent from main until fetched (#229).
        remotes = tempfile.TemporaryDirectory(prefix="tips remote ")
        self.addCleanup(remotes.cleanup)
        origin, work = Path(remotes.name) / "origin.git", Path(remotes.name) / "work"
        execute(["git", "clone", "-q", "--bare", self.root, origin], env=self.env, check=True)
        self.git("remote", "set-url", "origin", str(origin))
        execute(["git", "clone", "-q", origin, work], env=self.env, check=True)

        def push_commit(message: str) -> str:
            identity = ["-c", "user.name=Test", "-c", "user.email=test@example.invalid"]
            git = ["git", "-C", str(work)]
            execute([*git, *identity, "commit", "-q", "--allow-empty", "-m", message], check=True)
            execute([*git, "push", "-q", "origin", "HEAD:task/28-fix"], env=self.env, check=True)
            sha = execute([*git, "rev-parse", "HEAD"], check=True).stdout.strip()
            unknown = execute(["git", "cat-file", "-e", sha], cwd=self.root, env=self.env)
            assert unknown.returncode != 0, "commit must exist only on origin"
            return sha

        first = push_commit("first pushed head")
        self.call("--start", ref=first)
        assert self.git("-C", str(self.wt), "rev-parse", "HEAD") == first
        second = push_commit("repair")
        p = self.call(ref=second)
        assert "Advanced team-3-lead in place" in p.stdout
        assert self.git("-C", str(self.wt), "rev-parse", "HEAD") == second

        p = self.call(ref="0" * 40, ok=False)
        assert "rev-parse" in p.stderr
        assert self.git("-C", str(self.wt), "rev-parse", "HEAD") == second
        assert not any(e[0] == "stop_agent" for e in self.state()["events"])
        assert [a["name"] for a in self.state()["agents"]] == ["team-3-lead"]
        assert sum(e[:2] == ["agent", "start"] for e in self.state()["events"]) == 1

    def test_ui_flag_selects_lead_ui_role_and_is_lead_only(self) -> None:
        self.call("--ui", ok=False)
        (self.root / "agent/teams/config.toml").write_text(
            CONFIG + '\n[roles.lead_ui]\nkind = "claude"\nmodel = "fixture-ui"\neffort = "high"\n'
            'db_suffix = "l"\nport_offset = 2\n'
        )
        self.call("--ui", "--start")
        assert "fixture-ui" in self.state()["launch_argv"]
        assert self.state()["launch_env"]["TIPS_TEST_PORT"] == "4132"
        p = self.call("--ui", role="dev", task="29-dev", ref=False, ok=False)
        assert "--ui applies only to the lead role" in p.stderr
        self.commit("next")
        new = self.git("rev-parse", "HEAD")
        p = self.call(ref=new, ok=False)
        assert "Conflicting live agent" in p.stderr
        p = self.call("--ui", ref=new)
        assert "Advanced team-3-lead in place" in p.stdout
        assert self.git("-C", str(self.wt), "rev-parse", "HEAD") == new

    def test_failed_stop_preserves_review_head(self) -> None:
        task, wt = "28-review-team-3-test", self.root / ".worktrees/28-review-team-3-test"
        self.call("--start", role="test", task=task)
        s = self.state()
        s["stop_fails"] = True
        self.save(s)
        self.commit("next")
        new = self.git("rev-parse", "HEAD")
        self.call("--start", role="test", task=task, ref=new, ok=False)
        assert self.git("-C", str(wt), "rev-parse", "HEAD") == self.base

    def test_dirty_review_refused_even_same_sha(self) -> None:
        self.call()
        for file in ("tracked.txt", "untracked.txt"):
            with self.subTest(file=file):
                p = self.wt / file
                p.write_text("keep\n")
                self.call("--start", ok=False)
                assert p.read_text() == "keep\n"
                if file == "tracked.txt":
                    self.git("-C", str(self.wt), "restore", file)
                else:
                    p.unlink()
        assert not any(e[:2] == ["agent", "start"] for e in self.state()["events"])

    def test_config_conflict_precedes_stop_and_checkout(self) -> None:
        self.call("--start")
        config = self.wt / ".codex/config.toml"
        config.write_text("custom=true\n")
        self.commit("next")
        self.call("--start", ref=self.git("rev-parse", "HEAD"), ok=False)
        assert self.git("-C", str(self.wt), "rev-parse", "HEAD") == self.base
        assert not any(e[0] == "stop_agent" for e in self.state()["events"])
        assert config.read_text() == "custom=true\n"

    def test_unused_client_conflict_ignored(self) -> None:
        self.call()
        (self.wt / ".claude").mkdir()
        f = self.wt / ".claude/settings.local.json"
        f.write_text('{"mine":true}\n')
        self.call("--start")
        assert f.read_text() == '{"mine":true}\n'

    def test_claude_launch_refuses_conflicting_local_settings_without_overwriting(self) -> None:
        self.call(role="test")
        f = self.wt / ".claude/settings.local.json"
        f.write_text('{"mine":true}\n')
        result = self.call("--start", role="test", ok=False)
        assert "Refusing to overwrite" in result.stderr
        assert f.read_text() == '{"mine":true}\n'
        assert not any(e[:2] == ["agent", "start"] for e in self.state()["events"])

    def test_wrong_owner_and_busy_pane_refused_before_mutation(self) -> None:
        s = self.state()
        s["agents"] = [
            {
                "name": "someone-else",
                "pane_id": "wA:pB",
                "agent": "codex",
                "foreground_cwd": str(self.root),
            }
        ]
        self.save(s)
        self.call("--start", ok=False)
        assert not self.wt.exists()
        s["agents"] = []
        s["busy"] = True
        self.save(s)
        self.call("--start", ok=False)
        assert not self.wt.exists()

    def test_duplicate_root_in_another_pane_refused(self) -> None:
        self.call("--start")
        s = self.state()
        s["agents"][0]["pane_id"] = "wA:pC"
        self.save(s)
        self.call("--start", ok=False)
        assert sum(e[:2] == ["agent", "start"] for e in self.state()["events"]) == 1

    def test_start_failure_and_wrong_runtime_root_reported(self) -> None:
        s = self.state()
        s["start_fails"] = True
        self.save(s)
        self.call("--start", ok=False)
        s = self.state()
        s["agents"] = []
        s["start_fails"] = False
        s["wrong_start_root"] = str(self.root)
        self.save(s)
        self.call("--start", ok=False)

    def test_missing_tool_and_invalid_team_refused(self) -> None:
        self.call("--start", team="7", ok=False)
        assert not self.wt.exists()
        (self.root / "agent/lsp/vendor/bin/dexter").unlink()
        self.call("--start", ok=False)
        assert not self.wt.exists()

    def test_shell_setup_failure_never_starts_agent(self) -> None:
        s = self.state()
        s["shell_timeout"] = True
        self.save(s)
        self.call("--start", ok=False)
        assert not any(e[:2] == ["agent", "start"] for e in self.state()["events"])

    def test_running_tester_advances_in_place_without_start(self) -> None:
        task, wt = "28-review-team-3-test", self.root / ".worktrees/28-review-team-3-test"
        self.call("--start", role="test", task=task)
        self.commit("next")
        new = self.git("rev-parse", "HEAD")
        p = self.call(role="test", task=task, ref=new)
        assert "Advanced team-3-test in place" in p.stdout
        assert self.git("-C", str(wt), "rev-parse", "HEAD") == new
        assert not any(e[0] == "stop_agent" for e in self.state()["events"])
        assert sum(e[:2] == ["agent", "start"] for e in self.state()["events"]) == 1

    def test_dexter_install_not_needed_in_reviewed_commit(self) -> None:
        self.git("rm", "agent/lsp/dexter.rev")
        self.commit("old revision without Dexter")
        old = self.git("rev-parse", "HEAD")
        shutil.copy(DEXTER_REV, self.root / "agent/lsp/dexter.rev")
        self.call("--start", ref=old, role="test")
        assert "launch_argv" in self.state()
        assert not (self.wt / "agent/lsp/dexter.rev").exists()

    def test_kind_mismatch_refused(self) -> None:
        self.call("--kind", "claude", ok=False)
        assert not self.wt.exists()

    def test_role_inferred_from_agent_name_and_policy_from_config(self) -> None:
        path = self.root / "agent/teams/config.toml"
        path.write_text(CONFIG.replace('codex_approval = "never"', 'codex_approval = "on-request"'))
        args = [
            sys.executable,
            str(self.script),
            "28-review-team-3-lead",
            "--team",
            "3",
            "--pane",
            "wA:pB",
            "--agent",
            "team-3-lead",
            "--review-ref",
            self.base,
            "--start",
        ]
        p = execute(args, cwd=self.root, env=self.env, timeout=20)
        assert p.returncode == 0, p.stderr
        assert "fixture-lead" in self.state()["launch_argv"]
        assert "on-request" in self.state()["launch_argv"]

    def test_developer_dirty_work_is_preserved_on_resume(self) -> None:
        self.call("--start", role="dev", task="29-dev", ref=False)
        wt = self.root / ".worktrees/29-dev"
        (wt / "tracked.txt").write_text("unfinished work\n")
        self.call("--start", role="dev", task="29-dev", ref=False)
        assert (wt / "tracked.txt").read_text() == "unfinished work\n"
        assert sum(e[:2] == ["agent", "start"] for e in self.state()["events"]) == 1

    def test_new_developer_inherits_committed_instructions_from_fetched_main(self) -> None:
        instructions = {
            "AGENTS.md": "Use stock Dexter CLI for Elixir navigation.\n",
            "CLAUDE.md": "@AGENTS.md\n",
        }
        for name, content in instructions.items():
            (self.root / name).write_text(content)
        self.git("add", *instructions)
        self.commit("shared Dexter instructions")
        release = self.git("rev-parse", "HEAD")
        assert self.git("rev-parse", "origin/main") == self.base
        (self.root / "AGENTS.md").write_text("Uncommitted launcher-only instructions.\n")

        self.call(role="dev", task="29-dev", ref=False)

        worktree = self.root / ".worktrees/29-dev"
        assert self.git("-C", str(worktree), "rev-parse", "HEAD") == release
        for name, content in instructions.items():
            assert (worktree / name).read_text() == content

    def test_last_edit_during_shutdown_prevents_advance(self) -> None:
        task, wt = "28-review-team-3-test", self.root / ".worktrees/28-review-team-3-test"
        self.call("--start", role="test", task=task)
        s = self.state()
        s["stop_dirties"] = True
        self.save(s)
        self.commit("next")
        self.call("--start", role="test", task=task, ref=self.git("rev-parse", "HEAD"), ok=False)
        assert self.git("-C", str(wt), "rev-parse", "HEAD") == self.base
        assert (wt / "tracked.txt").read_text() == "saved at exit\n"

    def test_attached_review_refused_and_partition_preserved(self) -> None:
        self.env["MIX_TEST_PARTITION"] = "2"
        self.call("--start")
        assert self.state()["launch_env"]["MIX_TEST_PARTITION"] == "2"
        self.git("-C", str(self.wt), "switch", "-c", "keep-review")
        self.call("--start", ok=False)
        assert self.git("-C", str(self.wt), "branch", "--show-current") == "keep-review"

    def test_orphan_foreground_prevents_review_advance(self) -> None:
        self.call()
        self.commit("next")
        new = self.git("rev-parse", "HEAD")
        s = self.state()
        s["busy"] = True
        self.save(s)
        for flags in ((), ("--start",)):
            self.call(*flags, ref=new, ok=False)
            assert self.git("-C", str(self.wt), "rev-parse", "HEAD") == self.base

    def test_config_override_reaches_child_and_ack_is_not_echo(self) -> None:
        override = self.root / "alternate.toml"
        override.write_text(CONFIG.replace("checks_minutes = 30", "checks_minutes = 7"))
        self.env["TIPS_TEAM_CONFIG"] = str(override)
        self.call("--start")
        s = self.state()
        assert s["launch_env"]["TIPS_TEAM_CONFIG"] == str(override)
        assert s["launch_env"]["TIPS_CHECK_TIMEOUT_SECONDS"] == "420"
        wait = next(e for e in s["events"] if e[:2] == ["pane", "wait-output"])
        marker = wait[wait.index("--match") + 1]
        command = next(e[3] for e in s["events"] if e[:2] == ["pane", "run"])
        # Unwrapping may drop whitespace at a wrap point; the echo must still not match.
        assert marker not in "".join(command.split())
        assert marker in s["output"]
        assert wait[wait.index("--source") + 1] == "recent-unwrapped"

    def test_requested_tree_conflicts_refused_before_stop_or_checkout(self) -> None:
        self.call("--start")
        for relative in (".codex/config.toml", ".agents/skills/owned.txt"):
            with self.subTest(path=relative):
                path = self.root / relative
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text("tracked in review revision\n")
                self.git("add", "-f", relative)
                self.commit("incoming conflict")
                sha = self.git("rev-parse", "HEAD")
                self.git("reset", "--hard", self.base)
                self.call("--start", "--force", ref=sha, ok=False)
                assert self.git("-C", str(self.wt), "rev-parse", "HEAD") == self.base
                assert not any(e[0] == "stop_agent" for e in self.state()["events"])

    def test_requested_tree_symlink_parent_refused_before_creation(self) -> None:
        target = self.root / "symlink-target"
        target.mkdir()
        (self.root / ".codex").symlink_to(target)
        self.git("add", "-f", ".codex")
        self.commit("incoming symlink")
        sha = self.git("rev-parse", "HEAD")
        self.git("reset", "--hard", self.base)
        self.call(ref=sha, ok=False)
        assert not self.wt.exists()

    def test_one_issue_per_team_across_live_coding_roles(self) -> None:
        s = self.state()
        s["agents"] = [
            {
                "name": "team-3-dev",
                "pane_id": "wA:pD",
                "agent": "codex",
                "cwd": str(self.root / ".worktrees/27-other-issue"),
                "foreground_cwd": str(self.root / ".worktrees/27-other-issue"),
            }
        ]
        self.save(s)
        self.call("--start", ok=False)
        assert not self.wt.exists()
        s["agents"][0]["cwd"] = str(self.root / ".worktrees/28-same-issue")
        # A foreground LSP child elsewhere must not change the teammate's root (#227).
        s["agents"][0]["foreground_cwd"] = "/opt/homebrew/lsp-child"
        self.save(s)
        self.call("--start")

    def test_ownership_follows_the_client_process_not_pane_metadata(self) -> None:
        # A client whose process runs in the target worktree owns it even when Herdr's
        # pane cwd says otherwise (#232); a reported agent without a client refuses.
        s = self.state()
        stray: dict[str, str] = {
            "name": "stray",
            "pane_id": "wA:pZ",
            "agent": "claude",
            "cwd": str(self.wt),
            "foreground_cwd": str(self.root),
        }
        s["agents"] = [stray]
        self.save(s)
        self.call("--start", ok=False)
        assert not self.wt.exists()
        s["agents"] = [{**stray, "name": "team-3-dev", "cwd": str(self.root), "bare": "yes"}]
        self.save(s)
        r = self.call("--start", ok=False)
        assert "without a running client" in r.stderr
        assert not self.wt.exists()

    def test_developer_renamed_issue_reuses_branch_and_worktree(self) -> None:
        self.call(role="dev", task="29-original", ref=False)
        wt = self.root / ".worktrees/29-original"
        (wt / "tracked.txt").write_text("unfinished\n")
        self.call("--start", role="dev", task="29-renamed", ref=False)
        assert self.state()["cwd"] == str(wt)
        assert not (self.root / ".worktrees/29-renamed").exists()
        assert (wt / "tracked.txt").read_text() == "unfinished\n"
        assert self.git("branch", "--list", "task/29-*").strip() == "+ task/29-original"

    def test_developer_existing_branch_without_worktree_and_ambiguity(self) -> None:
        self.git("branch", "task/29-original")
        self.call(role="dev", task="29-renamed", ref=False)
        assert (self.root / ".worktrees/29-original").is_dir()
        self.git("branch", "task/29-duplicate")
        self.call("--start", role="dev", task="29-latest", ref=False, ok=False)
        assert not (self.root / ".worktrees/29-latest").exists()

    def test_named_agent_must_match_team_and_role(self) -> None:
        self.call("--agent", "team-2-lead", ok=False)
        self.call("--agent", "team-3-dev", ok=False)
        assert not self.wt.exists()

    def test_codex_permissions_unchanged_without_bridge(self) -> None:
        self.call("--start")
        cfg = tomllib.loads((self.wt / ".codex/config.toml").read_text())
        assert "mcp_servers" not in cfg
        assert "approval_policy" not in cfg
        assert "never" in self.state()["launch_argv"]


if __name__ == "__main__":
    unittest.main()
