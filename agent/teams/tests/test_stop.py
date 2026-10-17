"""stop and prompt in this process against a fake Herdr: which recorded client is stopped
or prompted, and in what order. Real signals are StopAgentTest's job in test_team."""

import contextlib
import io
import json
import tempfile
import tomllib
import unittest
from pathlib import Path
from typing import Any, cast
from unittest import mock

import config as conf
import herdr as herdr_module
import team
from tests.harness import CONFIG, TEST_RUNS

SHELL, CLIENT = 100, 200


class InProcessTeam(unittest.TestCase):
    """Brief 29's record in slot 1 under a harness root in this process, with Herdr,
    GitHub, Dexter, psql and the port probe replaced. `self.calls` logs every Herdr call
    and every `team.stop` in order."""

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
        reports = {
            a["id"]: ({"clean": True, "unpushed": 0, "merged": True}, f"https://r/{a['id']}")
            for a in self.agents.values()
        }
        self.drop = mock.Mock(return_value=["tips_test_t1g1i"])
        patch = mock.patch.object
        self.enterContext(patch(conf, "cfg", cast(conf.Config, tomllib.loads(CONFIG))))
        self.enterContext(patch(conf, "harness_root", return_value=self.root))
        self.enterContext(patch(team, "herdr", self.herdr))
        self.enterContext(patch(herdr_module, "herdr", self.herdr))
        self.enterContext(patch(team, "stop", self.stop))
        self.enterContext(patch(team, "merged_brief", return_value=True))
        self.enterContext(patch(team, "retirement_reports", return_value=reports))
        self.enterContext(patch(team, "stop_daemon"))
        self.enterContext(patch(team, "port_in_use", return_value=False))
        self.enterContext(patch(team, "drop_databases", self.drop))

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

    def session(self, pane: str) -> str:
        """The session Herdr reports for the client in the pane."""
        return str(self.by_pane(pane)["session"])

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
            session = {"kind": "id", "value": self.session(args[2])}
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

    def stop_brief(self) -> str:
        printed = io.StringIO()
        with contextlib.redirect_stdout(printed):
            team.stop_brief("29")
        return printed.getvalue()


class StopTest(InProcessTeam):
    def test_stop_ends_each_recorded_client_in_its_root_before_closing_the_workspace(
        self,
    ) -> None:
        printed = self.stop_brief()
        impl, tester = self.agents["impl"], self.agents["tester"]
        assert self.effects() == [
            ("stop", "w1:p1", impl["root"]),
            ("stop", "w1:p2", tester["root"]),
            ("workspace", "close", "w1"),
        ], f"each client is stopped once, in its own root, before the close: {self.effects()}"
        assert "slot 1 released; databases dropped: tips_test_t1g1i" in printed, printed
        assert not (self.root / "state/1.json").exists(), "a completed stop deletes the record"

    def test_a_client_replaced_after_the_reports_are_read_is_not_stopped(self) -> None:
        # The tester's pane reports another session on the recheck right before the stops.
        reads = 0

        def session(pane: str) -> str:
            nonlocal reads
            if pane == "w1:p2":
                reads += 1
                if reads > 1:
                    return "session-replacement"
            return str(self.by_pane(pane)["session"])

        self.enterContext(mock.patch.object(self, "session", session))
        with self.assertRaises(RuntimeError) as refused:
            self.stop_brief()
        assert "runs session session-replacement, not session-tester; preserved" in str(
            refused.exception
        ), refused.exception
        assert self.effects() == [], f"no client is stopped and nothing closed: {self.effects()}"
        self.drop.assert_not_called()
        assert (self.root / "state/1.json").exists(), "the record is kept"

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
            self.stop_brief()
        root = self.agents["impl"]["root"]
        assert f"Conflicting live agent in {root}: visitor; preserved" in str(refused.exception), (
            refused.exception
        )
        assert stopped == ["w1:p1", "w1:p2"], stopped
        assert ("workspace", "close", "w1") not in self.calls, "the workspace stays open"
        self.drop.assert_not_called()
        assert (self.root / "state/1.json").exists(), "the record is kept"


class PromptAgentTest(InProcessTeam):
    def test_an_exited_client_is_refused_and_nothing_is_sent(self) -> None:
        self.live.discard("w1:p2")
        with self.assertRaises(RuntimeError) as refused:
            team.prompt_agent("29", "tester", "late")
        assert "team-1-tester is not running in w1:p2" in str(refused.exception), refused.exception
        assert self.effects() == [], f"no prompt is sent to an exited client: {self.effects()}"


if __name__ == "__main__":
    unittest.main()
