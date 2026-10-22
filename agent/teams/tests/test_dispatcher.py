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

from commands import execute
from config import repo_key
from tests.harness import CONFIG, TEST_RUNS, fake

TEAMS = Path(__file__).resolve().parents[1]
DOCUMENTS = ("roles/common.md", "roles/dispatcher.md")

# Logs every call with its arguments and the variables the launcher sets. The client stub
# records its process id, which Herdr's fake reports as the pane's foreground client. It
# runs until the starter has prompted it or given up, which the fake Herdr marks with the
# done file, or for CLIENT_SECONDS at most.
STUB = """#!/usr/bin/env python3
import json, os, sys, time
from pathlib import Path
args = sys.argv[1:]
env = {k: os.environ.get(k) for k in ("CLAUDE_AUTOCOMPACT_PCT_OVERRIDE", "TIPS_TEAM_CONFIG")}
with open(os.environ["DISPATCH_LOG"], "a") as output:
    output.write(json.dumps([Path(sys.argv[0]).name, args, env, os.getcwd()]) + "\\n")
client = Path(os.environ["DISPATCH_LOG"] + ".client")
done = Path(os.environ["DISPATCH_LOG"] + ".done")
if Path(sys.argv[0]).name == "claude":
    done.unlink(missing_ok=True)
    deadline = time.monotonic() + float(os.environ.get("CLIENT_SECONDS", "0"))
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
    # The adapter lists its tools to this session after READY_SECONDS, or never. With
    # STALE_NOTE, another session's note is there first.
    ready = os.environ.get("READY_SECONDS", "0")
    session = args[args.index("--session-id") + 1]
    note = Path(os.environ["LOCK_PATH"]).with_name("dispatcher.ready")
    if os.environ.get("STALE_NOTE"):
        note.write_text(json.dumps({"session": "old", "text": "tools listed"}))
    if ready != "never":
        time.sleep(float(ready))
        note.write_text(json.dumps({"session": session, "text": "tools listed"}))
    while time.monotonic() < deadline and not done.exists():
        time.sleep(0.05)
if Path(sys.argv[0]).name == "herdr":
    agents = json.loads(os.environ.get("LIVE_AGENTS", "[]"))
    if args[:2] == ["pane", "layout"]:
        result = {"layout": {"panes": [{"pane_id": "caller", "rect": {"width": 140}}]}}
    elif args[:2] == ["pane", "split"]:
        result = {"pane": {"pane_id": "new-pane"}}
    elif args[:2] == ["agent", "list"]:
        result = {"agents": agents}
    elif args[:2] == ["agent", "get"]:
        status = os.environ.get("AGENT_STATUS", "idle")
        result = {"agent": {"pane_id": args[2], "agent": "claude", "agent_status": status}}
    elif args[:2] == ["agent", "rename"] and os.environ.get("RENAME_FAILS"):
        sys.exit("agent_not_found")
    elif args[:2] == ["agent", "prompt"]:
        # Record whether this session's ready note existed when the prompt was sent.
        state = Path(os.environ["LOCK_PATH"]).parent
        session = json.loads((state / "dispatcher.json").read_text())["session"]
        note = state / "dispatcher.ready"
        seen = note.exists() and json.loads(note.read_text())["session"] == session
        with open(os.environ["DISPATCH_LOG"] + ".prompted", "a") as output:
            output.write(json.dumps(seen) + "\\n")
        done.touch()
        if os.environ.get("PROMPT_FAILS") == "hang":
            time.sleep(5)
        if os.environ.get("PROMPT_FAILS"):
            sys.exit("agent_prompt_stalled")
        result = {}
    elif args[:2] == ["pane", "process-info"]:
        leader = int(client.read_text()) if client.exists() else 1
        leader = 1 if os.environ.get("FOREIGN_CLIENT") else leader
        process = {"pid": leader, "cwd": "/"}
        result = {"process_info": {"shell_pid": 1, "foreground_process_group_id": leader,
                                   "foreground_processes": [process]}}
    elif args[:2] == ["notification", "show"]:
        done.touch()
        result = {}
    else:
        result = {}
    if args[:2] != ["pane", "run"]:
        print(json.dumps({"result": result}))
"""


class DispatchTest(unittest.TestCase):
    def setUp(self) -> None:
        TEST_RUNS.mkdir(parents=True, exist_ok=True)
        self.tmp = tempfile.TemporaryDirectory(prefix="dispatch test ", dir=TEST_RUNS)
        self.addCleanup(self.tmp.cleanup)
        # The checkout sits in the temporary directory; the harness root is its sibling.
        self.root = Path(self.tmp.name).resolve() / "tips"
        self.state = Path(self.tmp.name).resolve() / "agent_teams" / repo_key("o/r") / "state"
        self.scripts = self.root / "agent/teams"
        (self.scripts / "roles").mkdir(parents=True)
        for script in sorted(TEAMS.glob("*.py")):
            shutil.copy2(script, self.scripts / script.name)
        # A link, not a new executable: macOS scans each new one on its first run.
        (self.scripts / "dispatch").symlink_to(TEAMS / "dispatch")
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
            (bin_dir / name).symlink_to(fake("dispatch-stub", STUB))
        self.env = dict(
            os.environ,
            PATH=f"{bin_dir}:{os.environ['PATH']}",
            HERDR_ENV="1",
            HERDR_PANE_ID="caller",
            TIPS_TEAM_CONFIG=str(self.config),
            DISPATCH_LOG=str(self.log),
            LOCK_PATH=str(self.state / "dispatcher.lock"),
        )

    def write_config(self, model: str, launch_seconds: int = 120) -> None:
        dispatcher = f'\n[dispatcher]\nmodel="{model}"\neffort="high"\ncompact_percent=42\n'
        launch = f"launch_seconds = {launch_seconds}"
        self.config.write_text(CONFIG.replace("launch_seconds = 120", launch) + dispatcher)

    def calls(self, name: str) -> list[list[Any]]:
        lines = self.log.read_text().splitlines() if self.log.exists() else []
        return [call for call in map(json.loads, lines) if call[0] == name]

    def dispatch(self, *args: str, ok: bool = True, **env: str) -> str:
        result = execute([self.scripts / "dispatch", *args], env={**self.env, **env})
        assert (result.returncode == 0) == ok, result.stdout + result.stderr
        return result.stdout + result.stderr

    def launch_record(self) -> dict[str, Any]:
        launch: dict[str, Any] = json.loads((self.state / "dispatcher.json").read_text())
        return launch

    def herdr_calls(self, *prefix: str, seconds: float = 10) -> list[list[Any]]:
        """Wait for the detached starter's Herdr calls with this prefix; return them."""
        deadline = time.monotonic() + seconds
        while True:
            calls = [c[1] for c in self.calls("herdr") if c[1][: len(prefix)] == list(prefix)]
            if calls or time.monotonic() >= deadline:
                return calls
            time.sleep(0.05)

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

    def test_dispatcher_starts_with_its_tools_one_server_and_the_role_text(self) -> None:
        self.dispatch()
        _, args, env, cwd = self.calls("claude")[-1]
        assert args[:4] == [
            "--permission-mode",
            "bypassPermissions",
            "--strict-mcp-config",
            "--mcp-config",
        ]
        assert "--restricted" not in args
        assert json.loads(args[args.index("--settings") + 1]) == {"remoteControlAtStartup": False}
        assert args[args.index("--allowedTools") + 1] == "mcp__tips"
        servers = json.loads(args[4])["mcpServers"]
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
        prompt = args[args.index("--append-system-prompt") + 1]
        for name in DOCUMENTS:
            assert f"Trusted {name} text." in prompt, name
        # The role files carry the dispatcher's rules; the README is not in the prompt.
        for name in ("AGENTS.md", "README.md"):
            assert f"Trusted {name} text." not in prompt, name
        # No command-line prompt: the first turn waits for the client to be ready.
        assert args[-2] == "--append-system-prompt"
        assert "Begin." not in args
        assert env["CLAUDE_AUTOCOMPACT_PCT_OVERRIDE"] == "42"
        assert cwd == str(self.root)
        assert args[args.index("--model") + 1] == "test-model"
        assert args[args.index("--effort") + 1] == "high"

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
        assert self.herdr_calls("agent", "prompt") == [["agent", "prompt", "caller", "Begin."]]
        # Named first, then prompted through Herdr, once each.
        started = [c[1] for c in self.calls("herdr") if c[1][0] == "agent" and c[1][1] != "get"]
        assert started == [
            ["agent", "list"],
            ["agent", "rename", "caller", "dispatcher"],
            ["agent", "prompt", "caller", "Begin."],
        ]
        assert not self.herdr_calls("notification", seconds=0)

    def test_the_client_holds_the_start_lock_and_a_second_launch_fails_at_once(self) -> None:
        self.dispatch()
        assert (self.root / "calls.lock").read_text() == "held"
        # Two launchers at once: one client starts, the other is refused while it runs.
        command = [self.scripts / "dispatch"]
        # Ready after a second, the winner's client still holds the lock when the other
        # launcher reaches it.
        env = {**self.env, "CLIENT_SECONDS": "4", "READY_SECONDS": "1"}
        pipe, merged = subprocess.PIPE, subprocess.STDOUT
        first = subprocess.Popen(command, env=env, stdout=pipe, stderr=merged)  # noqa: S603
        second = subprocess.Popen(command, env=env, stdout=pipe, stderr=merged)  # noqa: S603
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

    def test_the_starter_leaves_a_pane_whose_client_is_not_the_launched_process(self) -> None:
        self.write_config("test-model", launch_seconds=1)
        self.dispatch(CLIENT_SECONDS="3", FOREIGN_CLIENT="1")
        # The starter gave up without naming or prompting the pane's client.
        assert len(self.herdr_calls("notification", "show")) == 1
        assert not self.herdr_calls("agent", "rename", seconds=0)
        assert not self.herdr_calls("agent", "prompt", seconds=0)

    def test_begin_waits_for_the_adapters_ready_note_for_this_session(self) -> None:
        # A note left by an earlier session is removed before the client starts; another
        # session's note written after the start is there at once, this session's a second
        # later.
        self.state.mkdir(parents=True)
        (self.state / "dispatcher.ready").write_text('{"session": "old", "text": "tools listed"}')
        self.dispatch(CLIENT_SECONDS="5", READY_SECONDS="1", STALE_NOTE="1")
        assert self.herdr_calls("agent", "prompt") == [["agent", "prompt", "caller", "Begin."]]
        # Herdr showed the client idle from the start; Begin. still waited for the note.
        prompted = (self.root / "calls.prompted").read_text().split()
        assert prompted == ["true"], f"Begin. sent before this session's note: {prompted}"

    def test_a_client_never_ready_or_a_failed_prompt_names_the_operator_command(self) -> None:
        prompt = 'herdr agent prompt caller "Begin."'
        both = f"herdr agent rename caller dispatcher && {prompt}"
        # (case, fake Herdr and client settings, Begin. prompts sent, what the note says)
        cases: list[tuple[str, dict[str, str], int, list[str]]] = [
            ("never idle", {"AGENT_STATUS": "unknown"}, 0, ["not ready within 3 s", both]),
            ("no tools", {"READY_SECONDS": "never"}, 0, ["not ready within 3 s", both]),
            ("rename fails", {"RENAME_FAILS": "1"}, 0, ["naming it failed", both]),
            ("prompt fails", {"PROMPT_FAILS": "1"}, 1, ["may or may not", "only if", prompt]),
            ("prompt hangs", {"PROMPT_FAILS": "hang"}, 1, ["may or may not", "timed out"]),
        ]
        for case, extra, sent, says in cases:
            with self.subTest(case=case):
                # A client that is never ready keeps the starter until its deadline. The
                # deadline also bounds each Herdr call; 3 s survives a loaded parallel run.
                never_ready = case in ("never idle", "no tools")
                self.write_config("test-model", launch_seconds=3 if never_ready else 2)
                self.log.unlink(missing_ok=True)
                (self.state / "dispatcher.recovery").unlink(missing_ok=True)
                env = {"AGENT_STATUS": "idle", "READY_SECONDS": "0", "RENAME_FAILS": ""}
                env = {**env, "PROMPT_FAILS": "", **extra}
                self.dispatch(
                    CLIENT_SECONDS="6",
                    AGENT_STATUS=env["AGENT_STATUS"],
                    READY_SECONDS=env["READY_SECONDS"],
                    RENAME_FAILS=env["RENAME_FAILS"],
                    PROMPT_FAILS=env["PROMPT_FAILS"],
                )
                shown = self.herdr_calls("notification", "show", seconds=8)
                assert len(shown) == 1, shown
                prompts = self.herdr_calls("agent", "prompt", seconds=0)
                assert prompts == [["agent", "prompt", "caller", "Begin."]] * sent, prompts
                # team.py status shows the same text from the recovery note.
                note = json.loads((self.state / "dispatcher.recovery").read_text())
                assert note["session"] == self.launch_record()["session"]
                for text in says:
                    assert text in shown[0][-1], (text, note)
                    assert text in note["text"], (text, note)
                if case in ("prompt fails", "prompt hangs"):
                    assert both not in note["text"]

    def test_an_empty_model_passes_no_model_flag(self) -> None:
        self.write_config("")
        self.dispatch()
        assert "--model" not in self.calls("claude")[-1][1]

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
