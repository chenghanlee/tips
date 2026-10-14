"""Dispatcher launch tests using fake clients and Herdr; never create live panes."""

import fcntl
import json
import os
import shutil
import subprocess
import tempfile
import time
import unittest
from pathlib import Path
from typing import Any

from team import execute, repo_key
from tests.test_team import CONFIG

TEAMS = Path(__file__).resolve().parents[1]
DOCUMENTS = ("AGENTS.md", "README.md", "roles/common.md", "roles/dispatcher.md")
GITHUB = '\n[github]\nrepository = "o/r"\n\n[github.projects]\n16 = ["Phase"]\n'

# Logs every call with its arguments and the variables the launcher sets. The client stub
# records its process id, which Herdr's fake reports as the pane's foreground client.
STUB = """#!/usr/bin/env python3
import json, os, sys, time
from pathlib import Path
args = sys.argv[1:]
env = {k: os.environ.get(k) for k in ("CLAUDE_AUTOCOMPACT_PCT_OVERRIDE", "TIPS_TEAM_CONFIG")}
with open(os.environ["DISPATCH_LOG"], "a") as output:
    output.write(json.dumps([Path(sys.argv[0]).name, args, env, os.getcwd()]) + "\\n")
client = Path(os.environ["DISPATCH_LOG"] + ".client")
if Path(sys.argv[0]).name == "claude":
    client.write_text(str(os.getpid()))
    # A fresh descriptor cannot lock the file while the inherited one holds it.
    import fcntl
    with open(os.environ["LOCK_PATH"], "a") as probe:
        try:
            fcntl.flock(probe, fcntl.LOCK_EX | fcntl.LOCK_NB)
            held = "free"
        except BlockingIOError:
            held = "held"
    Path(os.environ["DISPATCH_LOG"] + ".lock").write_text(held)
    time.sleep(float(os.environ.get("CLIENT_SECONDS", "0")))
if Path(sys.argv[0]).name == "herdr":
    agents = json.loads(os.environ.get("LIVE_AGENTS", "[]"))
    if args[:2] == ["pane", "layout"]:
        result = {"layout": {"panes": [{"pane_id": "caller", "rect": {"width": 140}}]}}
    elif args[:2] == ["pane", "split"]:
        result = {"pane": {"pane_id": "new-pane"}}
    elif args[:2] == ["agent", "list"]:
        result = {"agents": agents}
    elif args[:2] == ["agent", "get"]:
        result = {"agent": {"pane_id": args[2], "agent": "claude"}}
    elif args[:2] == ["pane", "process-info"]:
        leader = int(client.read_text()) if client.exists() else 1
        leader = 1 if os.environ.get("FOREIGN_CLIENT") else leader
        process = {"pid": leader, "cwd": "/"}
        result = {"process_info": {"shell_pid": 1, "foreground_process_group_id": leader,
                                   "foreground_processes": [process]}}
    else:
        result = {}
    if args[:2] != ["pane", "run"]:
        print(json.dumps({"result": result}))
"""


class DispatchTest(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory(prefix="dispatch test ")
        self.addCleanup(self.tmp.cleanup)
        # The checkout sits in the temporary directory; the harness root is its sibling.
        self.root = Path(self.tmp.name).resolve() / "tips"
        self.state = Path(self.tmp.name).resolve() / "agent_teams" / repo_key("o/r") / "state"
        self.scripts = self.root / "agent/teams"
        (self.scripts / "roles").mkdir(parents=True)
        for name in ("dispatch", "dispatcher.py", "team.py"):
            shutil.copy2(TEAMS / name, self.scripts / name)
        for name in ("README.md", "roles/common.md", "roles/dispatcher.md"):
            (self.scripts / name).write_text(f"Trusted {name} text.\n")
        (self.root / "AGENTS.md").write_text("Trusted AGENTS.md text.\n")
        python = self.scripts / ".venv/bin/python"
        python.parent.mkdir(parents=True)
        python.write_text("#!/bin/sh\n")
        python.chmod(0o755)
        execute(["git", "init", "-q", str(self.root)], check=True)
        self.config = self.root / "custom config.toml"
        self.write_config("test-model")
        bin_dir = self.root / "bin"
        bin_dir.mkdir()
        self.log = self.root / "calls"
        for name in ("herdr", "claude"):
            (bin_dir / name).write_text(STUB)
            (bin_dir / name).chmod(0o755)
        self.env = dict(
            os.environ,
            PATH=f"{bin_dir}:{os.environ['PATH']}",
            HERDR_ENV="1",
            HERDR_PANE_ID="caller",
            TIPS_TEAM_CONFIG=str(self.config),
            DISPATCH_LOG=str(self.log),
            LOCK_PATH=str(self.state / "dispatcher.lock"),
        )

    def write_config(self, model: str) -> None:
        dispatcher = f'\n[dispatcher]\nmodel="{model}"\neffort="high"\ncompact_percent=42\n'
        self.config.write_text(CONFIG + GITHUB + dispatcher)

    def calls(self, name: str) -> list[list[Any]]:
        lines = self.log.read_text().splitlines() if self.log.exists() else []
        return [call for call in map(json.loads, lines) if call[0] == name]

    def dispatch(self, *args: str, ok: bool = True, **env: str) -> str:
        result = execute([self.scripts / "dispatch", *args], env={**self.env, **env})
        assert (result.returncode == 0) == ok, result.stdout + result.stderr
        return result.stdout + result.stderr

    def launch_record(self) -> dict[str, Any]:
        return json.loads((self.state / "dispatcher.json").read_text())

    def renamed(self, seconds: float = 10) -> list[list[Any]]:
        """Wait for the detached namer's rename; return the rename calls."""
        deadline = time.monotonic() + seconds
        while time.monotonic() < deadline:
            renames = [c for c in self.calls("herdr") if c[1][:2] == ["agent", "rename"]]
            if renames:
                return renames
            time.sleep(0.05)
        return []

    def test_new_pane_runs_the_launcher_there_with_the_callers_config(self) -> None:
        self.dispatch("--new-pane")
        herdr = [call[1] for call in self.calls("herdr")]
        split = next(args for args in herdr if args[:2] == ["pane", "split"])
        assert "--current" in split
        assert "--no-focus" in split
        assert split[split.index("--cwd") + 1] == str(self.root)
        run = next(args for args in herdr if args[:2] == ["pane", "run"])
        assert run[2] == "new-pane"
        assert not self.calls("claude")
        execute(["bash", "-c", run[3]], env=self.env, check=True)
        _, _, env, cwd = self.calls("claude")[-1]
        assert env["TIPS_TEAM_CONFIG"] == str(self.config)
        assert cwd == str(self.root)

    def test_dispatcher_starts_restricted_with_one_server_and_trusted_text(self) -> None:
        self.dispatch()
        _, args, env, cwd = self.calls("claude")[-1]
        assert args[:5] == ["--restricted", "--tools", "", "--strict-mcp-config", "--mcp-config"]
        assert "--permission-mode" not in args
        assert json.loads(args[args.index("--settings") + 1]) == {"remoteControlAtStartup": False}
        assert args[args.index("--allowedTools") + 1] == "mcp__tips"
        servers = json.loads(args[5])["mcpServers"]
        assert list(servers) == ["tips"]
        tips = servers["tips"]
        assert tips["command"] == str(self.scripts / ".venv/bin/python")
        assert tips["args"] == ["-E", "-s", str(self.scripts / "adapter.py")]
        # The adapter posts as the session the launcher assigned to the client.
        session = args[args.index("--session-id") + 1]
        assert tips["env"] == {
            "TIPS_DISPATCHER_SESSION": session,
            "TIPS_TEAM_CONFIG": str(self.config),
        }
        prompt = args[args.index("--system-prompt") + 1]
        for name in DOCUMENTS:
            assert f"Trusted {name} text." in prompt, name
        # No instruction asks a tool-less model to rename itself or read files.
        assert args[-1] == "Begin."
        assert "herdr" not in args[-1]
        assert env["CLAUDE_AUTOCOMPACT_PCT_OVERRIDE"] == "42"
        assert cwd == str(self.root)
        assert args[args.index("--model") + 1] == "test-model"
        assert args[args.index("--effort") + 1] == "high"
        assert args[args.index("--advisor") + 1] == "fable"

    def test_the_launch_records_the_client_process_and_names_only_that_client(self) -> None:
        # The client keeps the launcher's process id: the record names the exact process.
        self.dispatch(CLIENT_SECONDS="4")
        record = self.launch_record()
        client = int((self.root / "calls.client").read_text())
        assert record["pid"] == client
        assert record["pane"] == "caller"
        assert record["started"]
        session = self.calls("claude")[-1][1]
        assert record["session"] == session[session.index("--session-id") + 1]
        assert [call[1] for call in self.renamed()] == [["agent", "rename", "caller", "dispatcher"]]

    def test_the_root_is_created_on_first_use_and_must_name_the_repository(self) -> None:
        root = self.state.parent
        self.dispatch()
        assert json.loads((root / "repository.json").read_text()) == {"repository": "o/r"}
        assert root.parent.name == "agent_teams"
        # TIPS_TEAM_HARNESS names <root>/harness and moves the root.
        other = self.root.parent / "elsewhere"
        self.dispatch(TIPS_TEAM_HARNESS=str(other / "harness"))
        assert (other / "state/dispatcher.json").exists()
        # Another repository with the same name is refused.
        (other / "repository.json").write_text(json.dumps({"repository": "x/r"}))
        output = self.dispatch(ok=False, TIPS_TEAM_HARNESS=str(other / "harness"))
        assert "belongs to x/r, not o/r" in output

    def test_the_client_holds_the_start_lock_and_a_second_launch_fails_at_once(self) -> None:
        self.dispatch()
        assert (self.root / "calls.lock").read_text() == "held"
        # Two launchers at once: one client starts, the other is refused while it runs.
        command = [self.scripts / "dispatch"]
        env = {**self.env, "CLIENT_SECONDS": "4"}
        pipe, merged = subprocess.PIPE, subprocess.STDOUT
        first = subprocess.Popen(command, env=env, stdout=pipe, stderr=merged)
        second = subprocess.Popen(command, env=env, stdout=pipe, stderr=merged)
        outputs = [p.communicate(timeout=30)[0].decode() for p in (first, second)]
        codes = sorted(p.returncode for p in (first, second))
        assert codes == [0, 1], outputs
        assert any("Busy" in output for output in outputs), outputs
        assert len(self.calls("claude")) == 2

    def test_a_held_start_lock_refuses_before_any_check(self) -> None:
        self.state.mkdir(parents=True)
        with open(self.state / "dispatcher.lock", "a") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            output = self.dispatch(ok=False)
        assert "Busy" in output
        assert not self.calls("claude")
        assert not self.calls("herdr")

    def test_the_namer_leaves_a_pane_whose_client_is_not_the_launched_process(self) -> None:
        self.dispatch(CLIENT_SECONDS="3", FOREIGN_CLIENT="1")
        assert not self.renamed(seconds=4)

    def test_model_setting_controls_model_and_advisor(self) -> None:
        for model in ("claude-fable-5-1", ""):
            with self.subTest(model=model):
                self.write_config(model)
                self.dispatch()
                args = self.calls("claude")[-1][1]
                assert "--advisor" not in args
                assert ("--model" in args) == bool(model)

    def write_launch(self, pid: int, started: str) -> None:
        path = self.state / "dispatcher.json"
        path.parent.mkdir(parents=True, exist_ok=True)
        record = {"pid": pid, "started": started, "pane": "w9:p9", "session": "s"}
        path.write_text(json.dumps(record))

    def test_rerun_refuses_the_recorded_live_dispatcher_and_an_unconfirmed_one(self) -> None:
        # A recorded process that still runs, with its start time, is the dispatcher, even
        # after its Herdr name is gone.
        own = execute(["ps", "-o", "lstart=", "-p", str(os.getpid())], check=True).stdout.strip()
        self.write_launch(os.getpid(), own)
        output = self.dispatch(ok=False)
        assert f"pid {os.getpid()}" in output
        assert "already running" in output
        # The same id with another start time is a reused id: not the dispatcher.
        self.write_launch(os.getpid(), "Thu Jan  1 00:00:00 1970")
        self.dispatch()
        assert len(self.calls("claude")) == 1
        # A live agent named dispatcher that is not the recorded process is uncertain.
        live = json.dumps([{"pane_id": "other", "name": "dispatcher", "agent": "claude"}])
        self.write_launch(999_999, own)
        output = self.dispatch(ok=False, LIVE_AGENTS=live)
        assert "cannot confirm" in output
        assert len(self.calls("claude")) == 1

    def test_refuses_a_missing_environment(self) -> None:
        (self.scripts / ".venv/bin/python").unlink()
        output = self.dispatch(ok=False)
        assert "Missing" in output
        assert "development.md" in output
        assert not self.calls("claude")
