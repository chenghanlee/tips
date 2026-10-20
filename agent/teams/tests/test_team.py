"""Brief lifecycle tests: real Git and process trees, fake Herdr; never a live pane or client."""

import contextlib
import json
import os
import re
import shutil
import signal
import socket
import subprocess
import tempfile
import time
import tomllib
import unittest
from collections.abc import Sequence
from pathlib import Path
from typing import Any, cast
from unittest import mock

import config as conf
import herdr as herdr_module
import team
from commands import command_args, execute
from tests.harness import (
    BRIEF,
    CONFIG,
    HERDR,
    MIX_PROJECT,
    PORT_BASE,
    REAL_DEXTER,
    SCRIPT,
    TEST_RUNS,
    WIDE,
    Harness,
    daemon_pid,
    fake,
    real_bound_command,
    wait_until_stopped,
)

# The shell and client process ids InProcessTeamTest's Herdr reports for a pane.
SHELL, CLIENT = 100, 200


class StopAgentTest(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name).resolve()
        self.bin = self.root / "bin"
        self.bin.mkdir()
        (self.bin / "herdr").symlink_to(fake("stop-herdr", HERDR))
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
                'import config, herdr; config.configure(); herdr.stop("wT:p1",sys.argv[2])',
                str(SCRIPT.parent),
                str(root or self.root),
            ],
            env=self.env,
            timeout=8,
        )

    def test_graceful_stop_exits_owned_children_and_releases_the_name(self) -> None:
        """The client is signalled, its separate-group child exits on EOF, the name is cleared.

        Herdr may list the kind as released or the name as already gone before the clear,
        or still show the exited client as the pane's leader for a read or two (#478).
        """
        cases: list[dict[str, Any]] = [
            {},
            {"listed_kind": None, "omit_kind": False},
            {"listed_kind": None, "omit_kind": True},
            {"clear_error": "agent_not_found"},
            {"stale_reads": 2},
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
        query: list[str | Path] = [
            "/bin/sh",
            wrapper,
            "query",
            "workspace-symbols",
            "--wait",
            "20s",
            "MixProject",
        ]
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


class InProcessTeamTest(unittest.TestCase):
    """stop and prompt in this process: brief 29's record in slot 1 under a harness root,
    with Herdr, GitHub, Dexter, psql and the port probe replaced. `self.calls` logs every
    Herdr call and every client stop in order."""

    def setUp(self) -> None:
        TEST_RUNS.mkdir(parents=True, exist_ok=True)
        directory = tempfile.TemporaryDirectory(prefix="stop test ", dir=TEST_RUNS)
        self.addCleanup(directory.cleanup)
        self.root = Path(directory.name).resolve() / "agent_teams/r"
        self.calls: list[tuple[str, ...]] = []
        # Panes that hold a client, and agents listed in a pane outside the team.
        self.live = {"w1:p1", "w1:p2"}
        self.strays: list[dict[str, Any]] = []
        self.agents = {
            "impl": self.allocation("impl", "implementer", "codex", "w1:p1"),
            "tester": self.allocation("tester", "tester", "claude", "w1:p2"),
        }
        record = {
            "version": conf.RECORD_VERSION,
            "slot": 1,
            "generation": 1,
            "kind": "brief",
            "brief": "29",
            "implementer": "impl",
            "tester": "tester",
            "workspace": "w1",
            "tabs": {},
            "agents": self.agents,
        }
        (self.root / "state/1.json").write_text(json.dumps(record))
        self.clean_up = mock.Mock()
        patch = mock.patch.object
        self.enterContext(patch(conf, "cfg", cast(conf.Config, tomllib.loads(CONFIG))))
        self.enterContext(patch(conf, "harness_root", return_value=self.root))
        self.enterContext(patch(team, "herdr", self.herdr))
        self.enterContext(patch(herdr_module, "herdr", self.herdr))
        self.enterContext(patch(team, "stop", self.stop))
        self.enterContext(patch(team, "merged_brief", return_value=True))
        self.enterContext(patch(team, "stop_daemon"))
        self.enterContext(patch(team, "port_in_use", return_value=False))
        self.enterContext(patch(team, "clean_up", self.clean_up))

    def stop(self, pane: str, root: str | Path) -> None:
        self.calls.append(("stop", pane, str(root)))

    def allocation(self, entry: str, role: str, kind: str, pane: str) -> dict[str, Any]:
        ident = f"g1-{entry}"
        root = self.root / "allocations" / ident
        for directory in (root / "project", root / "logs", self.root / "state" / ident):
            directory.mkdir(parents=True)
        return {
            "id": ident,
            "entry": entry,
            "role": role,
            "name": f"team-1-{entry}",
            "kind": kind,
            "root": str(root),
            "db_suffix": f"_t1g1{entry[0]}",
            "port": 24110,
            "workspace": "w1",
            "tab": "w1:t1",
            "pane": pane,
            "session": f"session-{entry}",
            "launch": f"launch-{entry}",
            "submission": "submitted",
        }

    def by_pane(self, pane: str) -> dict[str, Any]:
        return next(a for a in self.agents.values() if a["pane"] == pane)

    def herdr(self, *args: str) -> dict[str, Any]:
        self.calls.append(args)
        if args[:2] == ("workspace", "list"):
            return {"workspaces": [{"workspace_id": "w1"}]}
        if args[:2] == ("pane", "list"):
            return {"panes": [{"pane_id": a["pane"]} for a in self.agents.values()]}
        if args[:2] == ("pane", "process-info"):
            pane = args[3]
            stray = next((s for s in self.strays if s["pane_id"] == pane), None)
            cwd = stray["cwd"] if stray else self.by_pane(pane)["root"]
            leader = CLIENT if stray or pane in self.live else SHELL
            info = {"pid": leader, "cwd": cwd}
            return {
                "process_info": {
                    "shell_pid": SHELL,
                    "foreground_process_group_id": leader,
                    "foreground_processes": [info],
                }
            }
        if args[:2] == ("agent", "get"):
            allocation = self.by_pane(args[2])
            session = {"kind": "id", "value": allocation["session"]}
            return {
                "agent": {"name": allocation["name"], "agent": allocation["kind"]}
                | {"pane_id": args[2], "agent_session": session}
            }
        if args[:2] == ("agent", "list"):
            listed = [
                {"pane_id": a["pane"], "name": a["name"], "agent": a["kind"]}
                for a in self.agents.values()
                if a["pane"] in self.live
            ]
            return {"agents": listed + self.strays}
        if args[:2] in (("workspace", "close"), ("agent", "prompt")):
            return {}
        raise AssertionError(f"Unexpected Herdr call {args}")

    def effects(self) -> list[tuple[str, ...]]:
        """The stops, workspace closes and prompts, in order."""
        kept = ("stop", "close", "prompt")
        return [c for c in self.calls if c[0] in kept or (len(c) > 1 and c[1] in kept)]

    def test_an_agent_that_enters_an_allocation_during_the_stops_keeps_everything(self) -> None:
        stopped: list[str] = []

        def stop(pane: str, root: str | Path) -> None:
            # A client starts in the implementer's allocation while stop shuts the team down.
            stopped.append(pane)
            self.calls.append(("stop", pane, str(root)))
            cwd = self.agents["impl"]["root"]
            self.strays[:] = [{"pane_id": "w9:p1", "name": "visitor", "agent": "codex", "cwd": cwd}]

        self.enterContext(mock.patch.object(team, "stop", stop))
        with self.assertRaises(RuntimeError) as refused:
            team.stop_brief("29")
        root = self.agents["impl"]["root"]
        assert f"Conflicting live agent in {root}: visitor; preserved" in str(refused.exception), (
            refused.exception
        )
        assert stopped == ["w1:p1", "w1:p2"], stopped
        assert ("workspace", "close", "w1") not in self.calls, "the workspace stays open"
        self.clean_up.assert_not_called()
        assert (self.root / "state/1.json").exists(), "the record is kept"

    def test_an_exited_client_is_refused_and_nothing_is_sent(self) -> None:
        self.live.discard("w1:p2")
        with self.assertRaises(RuntimeError) as refused:
            team.prompt_agent("29", "tester", "late")
        assert "team-1-tester is not running in w1:p2" in str(refused.exception), refused.exception
        assert self.effects() == [], f"no prompt is sent to an exited client: {self.effects()}"


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
        assert (record["version"], record["generation"]) == (3, 1)
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
            "TIPS_TEST_PORT": str(PORT_BASE + 10),
            "TIPS_DEXTER": str(impl_root / "project/.dexter/dexter.sh"),
            "TIPS_TEAM_ALLOCATION_ID": "g1-impl",
            # Codex's sandbox cannot write the shared Hex cache; Claude keeps the default.
            "HEX_HOME": str(impl_root / "project/tmp/hex"),
        }
        assert tester["launch_env"] == {
            **shared,
            "TIPS_DB_SUFFIX": "_t1g1r",
            "TIPS_TEST_PORT": str(PORT_BASE + 11),
            "TIPS_DEXTER": str(tester_root / "project/.dexter/dexter.sh"),
            "TIPS_TEAM_ALLOCATION_ID": "g1-tester",
            "HEX_HOME": None,
        }
        assert re.fullmatch(r"[0-9a-f]{32}", self.allocation("team-1-tester")["launch"])
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
        # Each worker reads the common rules and its own role file, not the whole README.
        assert "agent/teams/roles/common.md and agent/teams/roles/implementer.md;" in impl_brief
        assert "agent/teams/roles/common.md and agent/teams/roles/tester.md;" in tester_brief
        assert "the restart rule in the README Turns section" in impl_brief
        assert tester_brief.startswith("You are tester, the merge-confirming tester for brief #29;")
        assert f"python3 {harness / 'team.py'} turn <pr> impl" in tester_brief
        assert "Put tester, <session> on line 2" in tester_brief
        assert "retirement.py" not in tester_brief
        assert "persona" not in tester_brief
        targ = tester["launch_argv"]
        assert "--advisor" not in targ + argv
        settings = json.loads(targ[targ.index("--settings") + 1])
        assert settings["promptSuggestionEnabled"] is False
        # The brief body is the implementer's to maintain; auto mode must not deny it.
        allowed = settings["permissions"]["allow"]
        assert "Bash(gh issue edit:*)" in allowed
        assert f"Bash(python3 {harness / 'pr_review.py'}:*)" in allowed
        assert not [rule for rule in allowed if "merge" in rule or "team.py" in rule]
        plugins = settings["enabledPlugins"]
        assert plugins["elixir-lsp@elixir-agent-tools"] is False
        assert plugins["mix-credo@elixir-agent-tools"] is True
        tester_session = self.launched_session("team-1-tester")
        assert re.fullmatch(r"[0-9a-f-]{36}", tester_session)
        assert "--session-id" not in impl["launch_argv"]
        assert record["agents"]["tester"]["session"] == tester_session
        assert {a["submission"] for a in record["agents"].values()} == {"submitted"}
        launches = [record["agents"][e]["launch"] for e in ("impl", "tester")]
        assert all(re.fullmatch(r"[0-9a-f]{32}", launch) for launch in launches)
        assert [c["body"] for c in self.comments("29")] == [
            f"EVENT implementer team-1-impl session-team-1-impl\nlaunched codex in {impl_root}; "
            f"allocation g1-impl; launch {launches[0]}; database suffix _t1g1i; "
            f"port {PORT_BASE + 10}",
            f"EVENT tester team-1-tester {tester_session}\nlaunched claude in {tester_root}; "
            f"allocation g1-tester; launch {launches[1]}; database suffix _t1g1r; "
            f"port {PORT_BASE + 11}",
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
        # A refused post is an error after the launch itself: the record stands and a rerun
        # posts the EVENT.
        self.update(comments_fail=True)
        refused = self.team("start", "31", ok=False)
        assert "EVENT not recorded on #31" in refused.stderr
        assert "Rerun this command once GitHub answers" in refused.stderr
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
        assert "team.py' reset 29 impl" in refused.stderr
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
        assert self.launch_env("team-1-tester") == ("_t1g1r", str(PORT_BASE + 11))
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
        assert self.launch_env("team-2-impl") == ("_t2g2i", str(PORT_BASE + 20))
        assert self.pane("team-2-impl")["cwd"] == str(self.trusted / "allocations/g2-impl")
        # A new allocation never takes a recorded port, even after configuration changes.
        self.bootstrap("team-1-impl")
        self.push("team-1-impl")
        # Config moved the critic onto the running tester's port: refused in its slot.
        moved = small.replace("port_offset = 1", "port_offset = 5")
        self.write_config(moved.replace("port_offset = 2", "port_offset = 1"))
        refused = self.team("review", "7", "critic", ok=False)
        assert f"port {PORT_BASE + 11} collides with team-1-tester's" in refused.stderr
        # Config moved the critic onto the running tester's database stem: refused too.
        renamed = small.replace('db_suffix = "r"', 'db_suffix = "x"')
        self.write_config(renamed.replace('db_suffix = "c"', 'db_suffix = "r"'))
        refused = self.team("review", "7", "critic", ok=False)
        stem = f"critic: database _t1g1r or port {PORT_BASE + 12} collides with team-1-tester's"
        assert stem in refused.stderr, refused.stderr
        self.write_config(small)
        self.team("review", "7", "critic")
        assert self.launch_env("team-1-critic") == ("_t1g1c", str(PORT_BASE + 12))
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
        # A run killed after the clone and before its checkout left both clones on local
        # main. A rerun finishes the checkout of a clean clone and refuses local work.
        tester = self.project("team-1-tester")
        for clone in (project, tester):
            self.git("clone", "-q", self.origin, clone, cwd=clone.parent)
        self.commit("local only", cwd=tester)
        failed = self.bootstrap("team-1-tester", ok=False)
        assert "is on main, not a detached HEAD, and has commits or files not on origin" in (
            failed.stderr
        )
        assert self.git("branch", "--show-current", cwd=tester) == "main"
        self.git("reset", "-q", "--hard", "origin/main", cwd=tester)
        self.bootstrap("team-1-tester")
        assert self.git("branch", "--show-current", cwd=tester) == ""
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
        assert self.git("rev-parse", "HEAD", cwd=project) == self.git(
            "rev-parse", "origin/main", cwd=project
        )
        # Missing tools are refused before a record or allocation exists.
        self.update(issues={**self.state()["issues"], "34": BRIEF})
        self.env["DEXTER_ELIXIR_LIB_ROOT"] = str(self.root / "no-sources")
        assert "sources are missing" in self.team("start", "34", ok=False).stderr
        self.env["DEXTER_ELIXIR_LIB_ROOT"] = str(self.stdlib)
        (self.repo / "agent/lsp/dexter/vendor/dexter").unlink()
        assert "Missing executable" in self.team("start", "34", ok=False).stderr
        assert self.recorded_briefs() == {"29"}

    def test_bootstrap_fetches_dependencies_until_a_fetch_for_the_current_lock_succeeds(
        self,
    ) -> None:
        self.team("start", "29")
        self.bootstrap("team-1-impl")
        self.bootstrap("team-1-tester")
        tester = self.project("team-1-tester")

        def fetches() -> int:
            return len([e for e in self.events("mix") if e[1] == str(tester)])

        assert fetches() == 1
        self.bootstrap("team-1-tester")
        assert fetches() == 1  # same lock, fetched: nothing to do
        # A new head changes mix.lock: the fetch runs again although deps/ exists.
        (self.project("team-1-impl") / "mix.lock").write_text("new lock\n")
        head = self.push("team-1-impl", "new dependency")
        self.update(mix_partial=True)
        failed = self.bootstrap("team-1-tester", "--commit", head, ok=False)
        assert "fixture mix failed after writing deps" in failed.stderr
        assert fetches() == 2
        # The failed fetch left deps/ behind; the retry still fetches before ready.
        self.update(mix_partial=False)
        assert "Bootstrap ready" in self.bootstrap("team-1-tester", "--commit", head).stdout
        assert fetches() == 3

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

    def test_a_team_whose_clients_never_launched_retires(self) -> None:
        self.update(setup_lost=True)
        self.team("start", "29", ok=False)
        assert [a["launch"] for a in self.record(1)["agents"].values()] == ["", ""]
        self.update(setup_lost=False)
        self.merge(self.git("--git-dir", self.origin, "rev-parse", "main"))
        self.databases("tips_test_t1g1i")
        stopped = self.team("stop", "29").stdout
        assert "slot 1 released" in stopped
        assert self.recorded_briefs() == set()
        assert self.remaining_databases() == []

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
            (f"port_base = {PORT_BASE}", 'port_base = "wrong"', "team.port_base must be int"),
            ('role = "designer"', 'role = "architect"', "agents.critic.role must be one of"),
            ('model = "fixture-test"', 'model = "x"\nadviser = "y"', "unknown keys ['adviser']"),
            ('db_suffix = "r"', 'db_suffix = "9r"', "db_suffix must be nonempty and start"),
            ('repository = "o/r"', 'repository = "o"', "github.repository must be owner/name"),
            ('psql = ["/fixture/psql"', 'psql = ["psql"', "psql must start with an absolute"),
            ('db_suffix = "c"', 'db_suffix = "c"\nprobe = ["make"]', "unknown keys ['probe']"),
            ('psql = ["/fixture/psql", "fixture-dsn"]', "psql = []", "psql must hold 1 to 16"),
            ('db_suffix_prefix = "_t"', 'db_suffix_prefix = "_' + "t" * 50 + '"', "exceed 63"),
            ('[github.projects]\n16 = ["Phase", "Feature"]\n', "", "github.projects must be"),
            ('16 = ["Phase", "Feature"]', '16 = ["Phase", 7]', "github.projects.16 must be str"),
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

    def test_a_root_in_the_checkout_or_a_temporary_directory_is_refused(self) -> None:
        scratch, tmp = self.root / "scratch", Path("/tmp").resolve()  # noqa: S108 - must be refused
        roots: dict[str, tuple[Path, Path, dict[str, str]]] = {
            "checkout": (self.repo / "x", self.repo, {}),
            "tmp": (tmp / f"tips-root-{os.getpid()}", tmp, {}),
            "TMPDIR": (scratch / "x", scratch, {"TMPDIR": str(scratch)}),
        }
        env = self.env
        for case, (root, parent, extra) in roots.items():
            self.addCleanup(shutil.rmtree, root, ignore_errors=True)
            with self.subTest(case=case):
                self.env = {**env, **extra, "TIPS_TEAM_HARNESS": str(root / "harness")}
                refused = self.team("start", "29", ok=False)
                assert f"Harness root {root} is inside {parent}; refused" in refused.stderr
                assert not root.exists()
        self.env = env
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

    def test_a_symlinked_root_directory_refuses_before_creating_anything(self) -> None:
        self.team("retained")  # creates the root
        for name in ("allocations", "state"):
            with self.subTest(directory=name):
                outside = self.root / f"outside-{name}"
                outside.mkdir()
                directory = self.trusted / name
                directory.rename(self.root / f"kept-{name}")
                directory.symlink_to(outside, target_is_directory=True)
                refused = self.team("start", "29", ok=False)
                assert f"{directory} escapes {self.trusted} or passes through a symlink" in (
                    refused.stderr
                )
                assert not any(outside.iterdir())
                directory.unlink()
                (self.root / f"kept-{name}").rename(directory)
        assert [e for e in self.state()["events"] if e[0] != "gh"] == []

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
    def test_stop_stops_real_daemons_before_cleanup_deletes_the_projects(self) -> None:
        self.use_real_dexter()
        self.team("start", "29")
        project = self.project("team-1-impl")
        self.addCleanup(self.stop_real_daemon, project)
        self.bootstrap("team-1-impl")
        self.bootstrap("team-1-tester")
        self.addCleanup(self.stop_real_daemon, self.project("team-1-tester"))
        assert daemon_pid(project)
        self.merge(self.push("team-1-impl"))
        self.clients_exit(1)
        assert "g1-impl: files deleted" in self.team("stop", "29").stdout
        wait_until_stopped(project)
        assert not project.exists()


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
        # A head that never reached origin is refused, even when the clone has it locally.
        self.git("checkout", "-q", "tracked.txt", cwd=tester)
        local = self.commit("local only", cwd=tester)
        self.git("checkout", "-q", "--detach", head, cwd=tester)
        for missing in (local, "0" * 40):
            failed = self.bootstrap("team-1-tester", "--commit", missing, ok=False)
            assert f"Commit {missing} is not on origin; push it first" in failed.stderr
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

    def test_review_handoff_is_refused_until_github_reports_the_head_mergeable(self) -> None:
        head = self.push("team-1-impl")
        self.team("review", "7", "critic")
        prompts = len(self.events("agent", "prompt"))
        comments = len(self.comments("7"))
        self.update(pr_mergeable="CONFLICTING")
        refused = self.team("turn", "7", "tester", pane=self.impl, ok=False)
        assert f"Merge conflict at {head}: merge origin/main and push" in refused.stderr
        # GitHub has not computed mergeability for the new head: unknown is refused too.
        head = self.push("team-1-impl", "merged main")
        self.update(pr_mergeable="UNKNOWN")
        refused = self.team("turn", "7", "tester", pane=self.impl, ok=False)
        assert f"has not reported mergeability for {head} yet" in refused.stderr
        assert len(self.events("agent", "prompt")) == prompts
        assert len(self.comments("7")) == comments
        # A failed required check does not block the review handoff; the tester is told.
        failed = {"name": "checks", "workflow": "CI", "bucket": "fail", "link": "https://ci/3"}
        self.update(pr_mergeable="MERGEABLE", checks=[failed])
        self.team("turn", "7", "tester", pane=self.impl)
        sent = self.events("agent", "prompt")[prompts:]
        assert [e[2] for e in sent] == ["team-1-tester", "team-1-critic"]
        assert "Current failures: check:CI/checks is fail: https://ci/3." in sent[0][3]

    def test_turn_to_implementer_names_the_live_failures_from_any_tester_clone(self) -> None:
        self.push("team-1-impl")
        failed = {"name": "checks", "workflow": "CI", "bucket": "fail", "link": "https://ci/2"}
        self.update(checks=[failed], pr_mergeable="CONFLICTING")
        comments = len(self.comments("7"))
        # The tester's clone state never blocks handing findings back, nor does a conflict.
        self.team("turn", "7", "impl", pane=self.tester)
        ring = self.events("agent", "prompt")[-1]
        assert ring[2] == "team-1-impl"
        assert "pr_review.py list 7" in ring[3]
        head = self.state()["pr_head"]
        failures = f"merge conflict at {head}; check:CI/checks is fail: https://ci/2"
        assert f"Current failures: {failures}." in ring[3]
        assert "agent/skills/implement-software/SKILL.md from your clone" in ring[3]
        assert len(self.comments("7")) == comments

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
        assert self.launch_env("team-1-critic") == ("_t1g1c", str(PORT_BASE + 12))
        brief = self.system_prompt("team-1-critic")
        assert brief.startswith("You are critic, the reviewing designer for brief #29;")
        assert "Your persona: operations: failure and recovery paths." in brief
        assert f"bootstrap.py --commit {head}" in brief
        assert f"Review PR https://github.com/o/r/pull/7 at {head} from your own clone" in brief
        assert "herdr agent prompt team-1-tester" in brief
        assert 'Follow "Steps: reviewing designer" in agent/teams/roles/designer.md' in brief
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
        assert self.launch_env("team-1-second") == ("_t1g1s", str(PORT_BASE + 13))
        assert "the additional tester for brief #29" in self.prompts("team-1-second")[0]
        assert "review steps in agent/teams/roles/tester.md" in self.prompts("team-1-second")[0]
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
    def test_a_designer_joins_a_full_brief_then_reviews_and_retires_with_it(self) -> None:
        self.write_config(CONFIG.replace("max_teams = 6", "max_teams = 1"))
        ordinary = "Implementer: impl\nRequired reviews: tester\n"
        self.update(issues={**self.state()["issues"], "29": ordinary})
        self.team("start", "29")
        self.team("design", "29", "critic")
        record = self.record(1)
        assert (record["kind"], record["generation"]) == ("brief", 1)
        assert (record["implementer"], record["tester"]) == ("impl", "tester")
        assert self.recorded_briefs() == {"29"}
        assert self.launch_env("team-1-critic") == ("_t1g1c", str(PORT_BASE + 12))
        assert "No free slot" in self.team("start", "30", ok=False).stderr
        assert "not a configured designer" in self.team("design", "29", "tester", ok=False).stderr
        starts = len(self.events("agent", "start"))
        prompts = len(self.prompts("team-1-critic"))
        assert "Already running" in self.team("design", "29", "critic").stdout
        assert len(self.events("agent", "start")) == starts
        assert len(self.prompts("team-1-critic")) == prompts

        self.bootstrap("team-1-impl")
        self.bootstrap("team-1-tester")
        question_head = self.push("team-1-impl", "question evidence")
        self.bootstrap("team-1-critic", "--commit", question_head)
        assert self.git("rev-parse", "HEAD", cwd=self.project("team-1-critic")) == question_head
        # Advice does not add a required reviewer or submit a review. The body writer
        # adds the reviewer, then the ordinary turn sends the current head once.
        self.update(issues={**self.state()["issues"], "29": BRIEF})
        before = len(self.events("agent", "prompt"))
        self.team("turn", "7", "tester", pane=self.pane("team-1-impl")["pane_id"])
        notices = self.events("agent", "prompt")[before:]
        assert [e[2] for e in notices] == ["team-1-tester", "team-1-critic"]
        assert all(question_head in e[3] for e in notices)
        assert len(self.events("agent", "start")) == starts

        # The attached designer retires with the pair once the brief is merged.
        self.merge(question_head)
        self.clients_exit(1)
        assert "slot 1 released" in self.team("stop", "29").stdout
        assert self.recorded_briefs() == set()

    def test_attaching_a_designer_checks_the_existing_pair_ownership(self) -> None:
        self.team("start", "29")
        self.update(
            issues={
                **self.state()["issues"],
                "29": WIDE.replace("tester, second", "second, tester"),
            }
        )
        refused = self.team("design", "29", "critic", ok=False)
        assert "changed its implementer or merge-confirming tester" in refused.stderr
        assert "critic" not in self.record(1)["agents"]

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
        assert "agent/teams/roles/common.md and agent/teams/roles/designer.md;" in brief
        assert "bootstrap.py:" in brief
        # The launch EVENT lets board.py usage find the designer's session.
        assert self.comments("50")[-1]["body"] == (
            f"EVENT designer team-1-critic {self.launched_session('team-1-critic')}\n"
            f"launched claude in {root}; allocation g1-critic; launch "
            f"{self.record(1)['agents']['critic']['launch']}; database suffix _t1g1c; "
            f"port {PORT_BASE + 12}"
        )
        usage = execute(
            ["python3", str(self.repo / "agent/teams/board.py"), "usage", "50"],
            cwd=self.repo,
            env=self.env,
            timeout=60,
        )
        assert "team-1-critic" in usage.stdout + usage.stderr
        # A second designer joins the spec's team in its own allocation; non-designers
        # are refused.
        refused = self.team("design", "50", "tester", ok=False)
        assert "tester is not a configured designer entry" in refused.stderr
        assert "Already running: team-1-critic" in self.team("design", "50", "critic").stdout
        self.team("design", "50", "lead")
        assert self.record(1)["agents"]["lead"]["root"] == str(self.trusted / "allocations/g1-lead")
        assert self.tabs("w1") == {"designers": ["team-1-critic", "team-1-lead"]}
        assert self.prompts("team-1-lead")[0].startswith("You are lead, the designer for spec #50;")
        assert self.comments("50")[-1]["body"].startswith("EVENT designer team-1-lead ")
        self.bootstrap("team-1-critic")
        project = root / "project"
        assert self.git("rev-parse", "HEAD", cwd=project) == self.git("rev-parse", "HEAD")
        assert self.git("branch", "--show-current", cwd=project) == ""
        # A brief start cannot take the spec's slot.
        spec = self.state()["issues"]["50"]
        self.update(issues={**self.state()["issues"], "50": BRIEF})
        refused = self.team("start", "50", ok=False)
        assert "#50 already holds a design team in slot 1" in refused.stderr, refused.stderr
        self.update(issues={**self.state()["issues"], "50": spec})
        # A design team has no PR; its clean clones and its databases go at stop.
        self.clients_exit(1)
        self.databases("tips_test_t1g1c", "tips_test_t1g1l")
        stopped = self.team("stop", "50").stdout
        assert self.remaining_databases() == []
        assert not root.exists()
        assert not (self.trusted / "allocations/g1-lead").exists()
        retired = json.loads((self.trusted / "state/g1-critic/retired.json").read_text())
        assert (retired["files"], retired["databases"]) == ("deleted", "dropped")
        assert "g1-critic: files deleted; databases dropped" in stopped
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

    def test_stop_releases_merged_work_of_exited_clients(self) -> None:
        # A stop that runs while a start holds the store lock waits, then gives up.
        fault = {"call": "agent start", "arg": "team-2-impl", "mode": "concurrent"}
        self.update(faults=[{**fault, "argv": ["stop", "29"]}])
        self.team("start", "30")
        nested = self.state()["nested"]
        assert "Busy: another team.py command held" in nested["stderr"], nested
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
        self.clients_exit(1)
        daemons = sorted(self.state()["daemons"])
        # An unrecorded name in generation 1, and names no record or retirement owns.
        self.databases(*self.remaining_databases(), "tips_test_t1g1i_rb", "tips_test_t3g77_x")
        orphan = self.trusted / "allocations/g99-x"
        orphan.mkdir()
        stopped = self.team("stop", "29").stdout
        # Every database of slot 1's generation 1 is dropped, recorded or not, without
        # FORCE; generation 11, the live team and the orphan stay.
        assert sorted(self.remaining_databases()) == [
            "tips_test_t1g11i",
            "tips_test_t2g2i",
            "tips_test_t3g77_x",
        ]
        assert all(call[:2] == ["fixture-dsn", "-X"] for call in self.psql_calls())
        assert not any("FORCE" in " ".join(call) for call in self.psql_calls())
        assert "Databases _t1g1: dropped tips_test_t1g1i, " in stopped
        # Owned daemons were stopped with the trusted binary; the other team's stays.
        stops = sorted(e[1] for e in self.events("dexter") if e[2:] == ["stop"])
        assert stops == [d for d in daemons if "/g1-" in d]
        assert [d for d in self.state()["daemons"] if "/g1-" in d] == []
        # Clean clones go with their whole allocation; only retired.json remains.
        for ident in ("g1-impl", "g1-tester", "g1-critic"):
            assert not (self.trusted / "allocations" / ident).exists()
            state = self.trusted / "state" / ident
            assert [path.name for path in state.iterdir()] == ["retired.json"]
            retired = json.loads((state / "retired.json").read_text())
            assert (retired["files"], retired["databases"]) == ("deleted", "dropped")
            assert f"{ident}: files deleted; databases dropped" in stopped
        # Orphans are listed and never deleted; the live team's database is no orphan.
        for run in (stopped, self.team("cleanup", "29").stdout):
            assert f"Orphan, not deleted: {orphan}\n" in run
            assert "Orphan, not deleted: database tips_test_t3g77_x\n" in run
            assert "Orphan, not deleted: database tips_test_t1g11i\n" in run
            assert "tips_test_t2g2i" not in run
        assert orphan.is_dir()
        assert "tips_test_t3g77_x" in self.remaining_databases()
        assert self.workspaces() == ["team-2-30"]
        assert self.recorded_briefs() == {"30"}
        assert self.pane("team-2-impl")["agent"] == "codex"
        assert "nothing removed" in self.team("stop", "29").stdout

    def stop_with_double(self, refuse: str, ok: bool) -> subprocess.CompletedProcess[str]:
        """Run `team.py stop 29` with herdr.stop replaced by a double. Each call logs the pane,
        the root and what stop had already released; the double then clears the pane's
        client, as a completed stop does, or raises for the pane named in `refuse`."""
        code = """import json, os, sys
sys.path.insert(0, sys.argv[1])
import team
log, refuse = sys.argv[2], sys.argv[3]
def double(pane, root):
    fixture = os.environ["HERDR_FIXTURE"]
    state = json.load(open(fixture))
    calls = open(os.environ["PSQL_LOG"]).read() if os.path.exists(os.environ["PSQL_LOG"]) else ""
    seen = {"pane": pane, "root": str(root), "record": team.record_path(1).exists(),
            "workspaces": [w["label"] for w in state["workspaces"]], "drops": "DROP" in calls}
    open(log, "a").write(json.dumps(seen) + "\\n")
    if pane == refuse:
        raise RuntimeError(f"{pane}: double refused the stop; preserved")
    for x in state["panes"]:
        if x["pane_id"] == pane:
            for key in ("agent", "name", "agent_status", "agent_session"):
                x.pop(key, None)
    json.dump(state, open(fixture, "w"))
team.stop = double
sys.argv = ["team.py", "stop", "29"]
try:
    team.cli()
except RuntimeError as error:
    print(f"team: {error}", file=sys.stderr)
    sys.exit(1)
"""
        log = self.root / "stops.jsonl"
        argv = ["python3", "-c", code, str(self.repo / "agent/teams"), str(log), refuse]
        result = execute(argv, cwd=self.repo, env=self.env, timeout=60)
        assert (result.returncode == 0) == ok, result.stdout + result.stderr
        return result

    def stops(self) -> list[dict[str, Any]]:
        log = self.root / "stops.jsonl"
        return [json.loads(line) for line in log.read_text().splitlines()] if log.exists() else []

    def test_stop_stops_each_live_client_before_releasing_anything(self) -> None:
        self.merged_pair()
        self.databases("tips_test_t1g1i")
        impl, tester = self.allocation("team-1-impl"), self.allocation("team-1-tester")
        # A refused stop of a live client keeps the record, databases and workspace.
        refused = self.stop_with_double(tester["pane"], ok=False)
        assert f"{tester['pane']}: double refused the stop; preserved" in refused.stderr
        assert self.recorded_briefs() == {"29"}
        assert self.remaining_databases() == ["tips_test_t1g1i"]
        assert self.workspaces() == ["team-1-29"]
        # The rerun stops the client still running before closing, dropping or releasing.
        self.stop_with_double("", ok=True)
        unreleased = {"record": True, "workspaces": ["team-1-29"], "drops": False}
        assert self.stops() == [
            {"pane": impl["pane"], "root": impl["root"], **unreleased},
            {"pane": tester["pane"], "root": tester["root"], **unreleased},
            {"pane": tester["pane"], "root": tester["root"], **unreleased},
        ]
        assert self.recorded_briefs() == set()
        assert self.remaining_databases() == []
        assert self.workspaces() == []

    def test_stop_skips_a_stale_listing_of_its_exited_client_but_not_a_new_occupant(self) -> None:
        self.merged_pair()
        self.clients_exit(1)
        state = self.state()
        impl = next(x for x in state["panes"] if x.get("label") == "team-1-impl")

        def occupy(**agent: object) -> None:
            state = self.state()
            pane = next(x for x in state["panes"] if x["pane_id"] == impl["pane_id"])
            for key in ("agent", "name", "exited"):
                pane.pop(key, None)
            pane.update(agent)
            self.save(state)

        # A live unnamed client, or a client with another name, in the recorded pane.
        occupy(agent="claude")
        refused = self.team("stop", "29", ok=False)
        assert f"Conflicting live agent in {self.project('team-1-impl').parent}" in refused.stderr
        occupy(agent="claude", name="visitor", exited=True)
        refused = self.team("stop", "29", ok=False)
        assert "Conflicting live agent" in refused.stderr
        assert ": visitor; preserved" in refused.stderr
        assert self.recorded_briefs() == {"29"}
        occupy()
        # The same listing in a pane the record does not hold is refused.
        stray = {
            "pane_id": "wX:p9",
            "workspace_id": "wX",
            "agent": "claude",
            "exited": True,
            "cwd": str(self.project("team-1-impl")),
        }
        self.update(strays=[stray])
        refused = self.team("stop", "29", ok=False)
        assert "Conflicting live agent" in refused.stderr
        assert ": wX:p9; preserved" in refused.stderr
        self.update(strays=[])
        # Herdr still lists the exited client, unnamed, while its shell leads the pane.
        occupy(agent="claude", exited=True)
        assert "slot 1 released" in self.team("stop", "29").stdout
        assert self.recorded_briefs() == set()

    def test_an_open_brief_is_refused_and_abandon_keeps_its_databases(self) -> None:
        self.databases("tips_test_t1g1i")
        project = self.project("team-1-impl")
        (project / "unfinished.txt").write_text("in progress\n")
        unmerged = "#29 is not closed by a PR merged into main. Nothing was stopped"
        refused = self.team("stop", "29", ok=False).stderr
        assert unmerged in refused
        abandon = f"python3 '{self.repo / 'agent/teams/team.py'}' stop 29 --abandon"
        assert f"closed without a merged PR, the operator runs {abandon};" in refused
        assert "agent/teams/README.md#retire-a-brief-closed-without-a-merged-pr" in refused
        # A brief closed by a PR that was never merged, or merged into another branch, is
        # refused the same way.
        self.update(closed_by={"29": ["7"]})
        assert unmerged in self.team("stop", "29", ok=False).stderr
        self.update(merged=["7"], pr_base_ref="release")
        assert unmerged in self.team("stop", "29", ok=False).stderr
        self.update(closed_by={}, merged=[], pr_base_ref="main")
        assert self.workspaces() == ["team-1-29"]
        assert self.remaining_databases() == ["tips_test_t1g1i"]
        assert self.recorded_briefs() == {"29"}
        # The operator abandons the brief: the slot is freed, and the databases and files,
        # unfinished work included, are kept and listed.
        self.push("team-1-impl", "pushed, never merged")
        self.clients_exit(1)
        stopped = self.team("stop", "29", "--abandon").stdout
        assert "#29: slot 1 released\n" in stopped
        assert self.remaining_databases() == ["tips_test_t1g1i"]
        retired = json.loads((self.trusted / "state/g1-impl/retired.json").read_text())
        kept = "kept: brief closed without a merged PR (stop --abandon)"
        assert (retired["files"], retired["databases"]) == (kept, kept)
        listed = self.team("retained").stdout
        assert f"g1-impl (#29): {self.trusted / 'allocations/g1-impl'}" in listed
        self.team("start", "30")
        assert self.record(1)["brief"] == "30"
        assert (project / "tracked.txt").exists()
        assert (project / "unfinished.txt").exists()

    def test_unpublished_or_unreadable_work_is_kept_and_the_databases_still_drop(self) -> None:
        self.merged_pair()
        self.team("review", "7", "critic")
        self.bootstrap("team-1-critic")
        self.clients_exit(1)
        self.databases("tips_test_t1g1i", "tips_test_t1g1c")
        impl, tester, critic = (self.project(f"team-1-{e}") for e in ("impl", "tester", "critic"))
        # A writer still running during stop leaves an uncommitted file; the tester's clone
        # has a commit only it holds, the critic's a stash.
        self.env["RACE_DIRTY_FILE"] = str(impl / "late.txt")
        self.commit("local only", cwd=tester)
        (critic / "tracked.txt").write_text("stashed\n")
        self.git("stash", "-q", cwd=critic)
        stopped = self.team("stop", "29").stdout
        del self.env["RACE_DIRTY_FILE"]
        assert "g1-impl: files kept: uncommitted or untracked files: ?? late.txt;" in stopped
        assert "g1-tester: files kept: commits not on origin: " in stopped
        assert "g1-critic: files kept: stashed changes: stash@{0}" in stopped
        assert all((p / "tracked.txt").exists() for p in (impl, tester, critic))
        assert self.remaining_databases() == []
        # A clone whose Git cannot be read, or whose fetch fails, is kept too; retained lists
        # every kept allocation.
        shutil.rmtree(impl / ".git")
        self.git("remote", "set-url", "origin", self.root / "missing.git", cwd=critic)
        rerun = self.team("cleanup", "29").stdout
        assert "g1-impl: files kept: project has no Git repository;" in rerun
        assert "g1-critic: files kept: git fetch failed: " in rerun
        assert (impl / "late.txt").exists()
        listed = self.team("retained").stdout
        for ident, project in (("g1-impl", impl), ("g1-tester", tester), ("g1-critic", critic)):
            assert f"{ident} (#29): {project.parent}; files: kept: " in listed
        assert "databases _t1g1i: dropped" in listed

    def test_a_stalled_github_read_keeps_the_record_and_releases_the_lock(self) -> None:
        self.merged_pair()
        self.clients_exit(1)
        self.databases("tips_test_t1g1i")
        self.write_config(CONFIG.replace("shell_seconds = 15", "shell_seconds = 1"))
        self.update(gh_stalls=True)
        started = time.monotonic()
        refused = self.team("stop", "29", ok=False)
        assert time.monotonic() - started < 15
        assert "GitHub did not answer within 1 s whether #29" in refused.stderr
        assert self.remaining_databases() == ["tips_test_t1g1i"]
        assert self.recorded_briefs() == {"29"}
        self.update(gh_stalls=False)
        # The retry gets the usual deadline: 1 s for its GitHub reads fails under load.
        self.write_config(CONFIG)
        self.team("stop", "29")
        assert self.recorded_briefs() == set()

    def test_a_refused_drop_is_recorded_and_the_rest_of_cleanup_continues(self) -> None:
        self.merged_pair()
        self.clients_exit(1)
        self.databases("tips_test_t1g1i", "tips_test_t1g1r", "tips_dev_t1g1r")
        self.env["PSQL_REFUSE"] = "tips_test_t1g1r"
        stopped = self.team("stop", "29").stdout
        refusal = 'refused: tips_test_t1g1r: ERROR:  database "tips_test_t1g1r" is being accessed'
        dropped = "Databases _t1g1: dropped tips_test_t1g1i, tips_dev_t1g1r"
        assert f"{dropped}; {refusal}" in stopped
        assert self.remaining_databases() == ["tips_test_t1g1r"]
        assert self.recorded_briefs() == set()
        assert not (self.trusted / "allocations/g1-impl").exists()
        retired = json.loads((self.trusted / "state/g1-impl/retired.json").read_text())
        assert retired["databases"].startswith(refusal), retired
        # Once the connection closes, a rerun drops the rest.
        del self.env["PSQL_REFUSE"]
        self.team("cleanup", "29")
        assert self.remaining_databases() == []
        retired = json.loads((self.trusted / "state/g1-impl/retired.json").read_text())
        assert retired["databases"] == "dropped"

    def test_busy_port_or_failed_daemon_stop_keeps_the_reservation(self) -> None:
        self.merged_pair()
        self.clients_exit(1)
        self.update(dexter_stop_fails=True)
        refused = self.team("stop", "29", ok=False)
        assert "fixture Dexter stop failed; the reservation is kept" in refused.stderr
        assert self.recorded_briefs() == {"29"}
        self.update(dexter_stop_fails=False)
        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as server:
            # A free port, so two suites on one machine never collide.
            server.bind(("127.0.0.1", 0))
            server.listen()
            port = server.getsockname()[1]
            path = self.trusted / "state/1.json"
            record = json.loads(path.read_text())
            record["agents"]["tester"]["port"] = port
            path.write_text(json.dumps(record))
            refused = self.team("stop", "29", ok=False)
            assert f"Ports {port} are in use; the reservation is kept" in refused.stderr
            assert self.recorded_briefs() == {"29"}
        self.team("stop", "29")
        assert self.recorded_briefs() == set()

    def test_generations_never_reuse_allocations_or_database_names(self) -> None:
        self.merged_pair()
        self.clients_exit(1)
        old = self.trusted / "allocations/g1-impl"
        (old / "project/unfinished.txt").write_text("not committed\n")
        self.team("stop", "29")
        # Another brief takes the slot with a new generation and new names.
        self.team("start", "30")
        assert self.record(1)["generation"] == 2
        assert self.launch_env("team-1-impl") == ("_t1g2i", str(PORT_BASE + 10))
        new = self.trusted / "allocations/g2-impl"
        assert self.pane("team-1-impl")["cwd"] == str(new)
        self.bootstrap("team-1-impl")
        # Cleanup of the old brief removes only its own allocation and generation.
        self.databases("tips_test_t1g1i", "tips_test_t1g2i")
        (old / "project/unfinished.txt").unlink()
        assert "g1-impl: files deleted" in self.team("cleanup", "29").stdout
        assert not old.exists()
        assert self.remaining_databases() == ["tips_test_t1g2i"]
        assert (new / "project/tracked.txt").exists()
        # A stop killed after writing retirements but before deleting the record leaves the
        # live team's allocations retired; cleanup keeps what the live record names.
        self.update(closed_by={"30": ["8"]}, merged=["8"])
        note = {"id": "g2-impl", "issue": "30", "abandoned": False, "db_suffix": "_t1g2i"}
        note |= {"files": "pending", "databases": "pending", "orphans": []}
        (self.trusted / "state/g2-impl/retired.json").write_text(json.dumps(note))
        kept = self.team("cleanup", "30").stdout
        assert "g2-impl: files kept: a live record names this allocation;" in kept
        assert (new / "project/tracked.txt").exists()
        assert self.remaining_databases() == ["tips_test_t1g2i"]
        # A forged record pointing at another allocation's directory is refused at stop.
        path = self.trusted / "state/1.json"
        record = json.loads(path.read_text())
        record["agents"]["impl"]["root"] = str(old)
        path.write_text(json.dumps(record))
        self.clients_exit(1)
        refused = self.team("stop", "30", ok=False)
        assert f"recorded allocation {old} is not" in refused.stderr
        assert (new / "project/tracked.txt").exists()

    def test_symlinked_allocation_paths_are_refused_at_retirement(self) -> None:
        self.merged_pair()
        self.clients_exit(1)
        logs = self.trusted / "allocations/g1-impl/logs"
        outside = self.root / "outside-logs"
        logs.rename(outside)
        logs.symlink_to(outside)
        refused = self.team("stop", "29", ok=False)
        assert "passes through a symlink; refused" in refused.stderr
        assert any(outside.iterdir())
        assert self.recorded_briefs() == {"29"}

    def test_stop_gives_its_own_next_step_for_a_client_it_cannot_confirm(self) -> None:
        self.merged_pair()
        state = self.state()
        tester = next(x for x in state["panes"] if x.get("label") == "team-1-tester")
        tester["agent_session"] = None
        self.save(state)
        refused = self.team("stop", "29", ok=False).stderr
        assert (
            "team-1-tester reports no session; cannot confirm the recorded client; preserved. "
            "Nothing was stopped. The operator inspects the pane" in refused
        )
        assert "resent" not in refused
        assert self.recorded_briefs() == {"29"}


class LaunchRecoveryTest(Harness):
    """Interrupted launches through `team.py start`, with faults injected into fake Herdr."""

    def fault(self, call: str, arg: str, mode: str, **extra: object) -> None:
        self.update(faults=[{"call": call, "arg": arg, "mode": mode, **extra}])

    def starts(self) -> list[str]:
        return [e[2] for e in self.events("agent", "start")]

    def test_attached_designer_after_launch_timeout_is_adopted_without_resend(self) -> None:
        self.team("start", "29")
        self.fault("agent start", "team-1-critic", "timeout_live")
        assert "timed out" in self.team("design", "29", "critic", ok=False).stderr
        allocation = self.record(1)["agents"]["critic"]
        assert allocation["submission"] == "unknown"
        starts = self.starts()
        assert "nothing was resent" in self.team("design", "29", "critic").stdout
        assert self.starts() == starts
        assert not self.prompts("team-1-critic")
        assert self.record(1)["agents"]["critic"]["id"] == allocation["id"]

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
        status = self.team("status").stdout
        assert "team-1-tester: startup incomplete in" in status
        assert "team-1-impl: running in" in status
        rerun = self.team("start", "29").stdout
        assert "team-1-tester: task submission is unknown; nothing was resent" in rerun
        assert f"python3 '{self.repo / 'agent/teams/team.py'}' reset 29 tester and" in rerun
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

    def test_a_client_reported_with_another_session_name_or_kind_gets_no_task(self) -> None:
        reports = {
            "29": {"agent_session": {"kind": "id", "value": "session-other"}},
            "30": {"name": "other"},
            "31": {"agent": "codex"},
        }
        for slot, (brief, report) in enumerate(reports.items(), start=1):
            with self.subTest(report=report):
                tester = f"team-{slot}-tester"
                self.fault("agent start", tester, "misreport", report=report)
                refused = self.team("start", brief, ok=False).stderr
                assert f"{tester} started in an unexpected state or root" in refused, refused
                submission = self.record(slot)["agents"]["tester"]["submission"]
                assert submission == "unknown", f"{tester} recorded as {submission}"
                assert not self.prompts(tester), f"{tester} was sent its task"

    def test_stop_retires_a_client_whose_session_was_never_recorded(self) -> None:
        # The launcher dies after the Codex client started: the record has no session.
        self.fault("agent start", "team-1-impl", "crash_after")
        self.team("start", "29", ok=False)
        assert self.record(1)["agents"]["impl"]["session"] == ""
        self.bootstrap("team-1-impl")
        self.merge(self.push("team-1-impl"))
        self.clients_exit(1)
        assert "slot 1 released" in self.team("stop", "29").stdout

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
        no_launch = json.loads(path.read_text())
        del no_launch["agents"]["tester"]["launch"]
        cases = {
            "record version 2 is not 3": {**good, "version": 2},
            "agents.tester.submission is not a known state": unknown_state,
            "agents.tester.launch must be str": no_launch,
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
        stderr = self.team("start", "29", ok=False).stderr
        session = self.launched_session("team-1-tester")
        assert f"runs session session-replacement, not {session}; preserved" in stderr
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
        assert self.record(2)["agents"]["impl"]["session"] == ""
        stderr = self.team("start", "30", ok=False).stderr
        assert "team-2-impl reports no session; cannot confirm the recorded client" in stderr
        assert "only the operator decides" in stderr
        state = self.state()
        for pane in state["panes"]:
            if pane.get("label") == "team-2-impl":
                pane["agent_session"] = {"kind": "id", "value": "session-team-2-impl"}
        self.save(state)
        stderr = self.team("start", "30", ok=False).stderr
        assert "team-2-tester reports no session; cannot confirm the recorded client" in stderr
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
            assert "team.py' reset 29 impl" in refused.stderr
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
        stderr = self.team("review", "7", "critic", ok=False).stderr
        assert "team-1-critic is not running and its task submission is unknown" in stderr
        assert self.starts().count("team-1-critic") == 1

    def test_an_allocation_with_no_launch_id_retires(self) -> None:
        # The record is lost while the earlier allocations remain: the new ones are recorded
        # as unknown and refused before any client is entered in them.
        self.team("start", "29")
        self.clients_exit(1)
        (self.trusted / "state/1.json").unlink()
        self.team("start", "29", ok=False)
        agents = self.record(1)["agents"].values()
        assert [(a["submission"], a["launch"]) for a in agents] == [("unknown", "")] * 2
        self.merge(self.git("--git-dir", self.origin, "rev-parse", "main"))
        assert "slot 1 released" in self.team("stop", "29").stdout

    def test_a_launch_event_that_failed_to_post_is_posted_once_by_the_rerun(self) -> None:
        def events(name: str) -> list[str]:
            bodies = [c["body"] for c in self.comments("29")]
            return [b for b in bodies if b.startswith("EVENT ") and f" {name} " in b]

        # GitHub refuses the implementer's EVENT after its task was submitted.
        self.update(comments_fail=True)
        refused = self.team("start", "29", ok=False).stderr
        assert "EVENT not recorded on #29" in refused
        assert "Rerun this command once GitHub answers" in refused
        assert self.record(1)["agents"]["impl"]["submission"] == "submitted"
        self.update(comments_fail=False)
        self.team("start", "29")
        self.team("start", "29")
        assert len(events("team-1-impl")) == len(events("team-1-tester")) == 1
        # A Codex session that Herdr reports only after the EVENT was posted adds no second
        # EVENT: the record had no session, and the rerun records the one the client reports.
        self.update(no_sessions=True)
        self.team("start", "30")
        assert self.record(2)["agents"]["impl"]["session"] == ""
        sessions = {"team-2-impl": "late", "team-2-tester": self.launched_session("team-2-tester")}
        state = self.state()
        for pane in state["panes"]:
            if pane.get("label") in sessions:
                pane["agent_session"] = {"kind": "id", "value": sessions[pane["label"]]}
        self.save(state)
        self.team("start", "30")
        assert self.record(2)["agents"]["impl"]["session"] == "late"
        bodies = [c["body"] for c in self.comments("30")]
        assert [b.split("\n")[0] for b in bodies if " team-2-impl " in b] == [
            "EVENT implementer team-2-impl unknown"
        ]

    def test_a_failed_tab_rename_leaves_no_unrecorded_pane(self) -> None:
        self.fault("tab rename", "implementers", "crash_before")
        self.team("start", "29", ok=False)
        assert self.record(1)["agents"]["impl"]["pane"] == "w1:p1"
        self.team("start", "29")
        assert not self.events("pane", "split")
        recorded = {a["pane"] for a in self.record(1)["agents"].values()}
        assert {p["pane_id"] for p in self.state()["panes"]} == recorded
        # Both clients exit, the implementer's in the pane the failed rename left unlabelled.
        state = self.state()
        for pane in state["panes"]:
            for key in ("agent", "name", "agent_status", "agent_session"):
                pane.pop(key, None)
        self.save(state)
        self.merge(self.git("--git-dir", self.origin, "rev-parse", "main"))
        assert "slot 1 released" in self.team("stop", "29").stdout


if __name__ == "__main__":
    unittest.main()
