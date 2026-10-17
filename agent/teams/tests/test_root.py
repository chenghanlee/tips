"""The harness root: where it may be, and the stable path workers name. The concurrent
first-claim test is RepositoryConfigTest in test_team.py."""

import json
import os
import tempfile
import unittest
from pathlib import Path
from typing import Any, cast
from unittest import mock

import config as conf
import team
from tests.test_team import TEST_RUNS


class ClaimRootTest(unittest.TestCase):
    def setUp(self) -> None:
        TEST_RUNS.mkdir(parents=True, exist_ok=True)
        self.tmp = tempfile.TemporaryDirectory(prefix="root test ", dir=TEST_RUNS)
        self.addCleanup(self.tmp.cleanup)
        self.base = Path(self.tmp.name).resolve()
        self.checkout = self.base / "tips"
        self.checkout.mkdir()

    def test_a_root_inside_the_checkout_a_temporary_directory_or_a_symlink_is_refused(
        self,
    ) -> None:
        link = self.base / "link"
        link.symlink_to(self.base / "agent_teams")
        with tempfile.TemporaryDirectory() as temporary:
            for root in (
                self.checkout / "agent_teams/tips",
                Path(temporary).resolve() / "tips",
                link / "tips",
            ):
                with self.subTest(root=root), self.assertRaises(RuntimeError):
                    conf.claim_root(root, "o/tips", self.checkout)
                assert not root.exists()

    def test_workers_name_the_stable_harness_path_of_an_installed_harness(self) -> None:
        root = self.base / "agent_teams/tips"
        recorded = {"root": root}
        with (
            mock.patch.object(conf, "installed", side_effect=recorded.get),
            mock.patch.object(conf, "harness_root", return_value=root),
        ):
            assert conf.harness() == root / "harness/agent/teams"
        assert conf.harness() == Path(team.__file__).resolve().parent

    def test_workers_get_the_config_the_installed_harness_reads(self) -> None:
        root = self.base / "agent_teams/tips"
        recorded = {"root": root, "source": self.checkout}
        allocation: dict[str, Any] = {
            "id": "g1-impl",
            "launch": "launch",
            "kind": "claude",
            "root": str(root / "allocations/g1-impl"),
            "db_suffix": "a",
            "port": 4100,
        }
        # The installed layout: <root>/harness links to the release.
        release = root / "releases/r1/agent/teams"
        release.mkdir(parents=True)
        (release / "config.toml").write_text("")
        (root / "harness").symlink_to("releases/r1", target_is_directory=True)
        settings = {"team": {"postgres_port": 5432}, "timeouts": {"checks_minutes": 30}}
        environ = {k: v for k, v in os.environ.items() if k != "TIPS_TEAM_CONFIG"}
        with (
            mock.patch.dict(os.environ, environ, clear=True),
            mock.patch.object(conf, "installed", side_effect=recorded.get),
            mock.patch.object(conf, "harness_root", return_value=root),
            mock.patch.object(conf, "state_dir", return_value=root / "state"),
            mock.patch.object(conf, "main", self.checkout),
            mock.patch.object(conf, "cfg", settings),
        ):
            # The stable link path, not the release it resolves to today.
            config = root / "harness/agent/teams/config.toml"
            assert config.resolve() == (release / "config.toml").resolve()
            assert conf.config_location() == (self.checkout, config)
            env = team.agent_env(cast(conf.Allocation, allocation))
            assert env["TIPS_TEAM_CONFIG"] == str(config)
            os.environ["TIPS_TEAM_CONFIG"] = str(self.base / "other.toml")
            env = team.agent_env(cast(conf.Allocation, allocation))
            assert env["TIPS_TEAM_CONFIG"] == str(self.base / "other.toml")

    def test_status_shows_the_starters_note_for_the_running_launch_only(self) -> None:
        state = self.base / "state"
        state.mkdir()
        launch = {"pid": 1, "started": "x", "pane": "w1:p1", "session": "s1"}
        note = {"session": "s1", "text": "Dispatcher in w1:p1: run this"}
        (state / "dispatcher.recovery").write_text(json.dumps(note))
        with (
            mock.patch.object(team, "dispatcher_launch", return_value=launch),
            mock.patch.object(team, "dispatcher_running", return_value=True),
            mock.patch.object(team, "dispatcher_path", return_value=state / "dispatcher.json"),
        ):
            assert team.dispatcher_status(None).endswith("; starter note: " + note["text"])
            launch["session"] = "s2"
            assert "starter note" not in team.dispatcher_status(None)

    def test_a_symlinked_state_directory_refuses_before_the_identity_is_published(self) -> None:
        root = self.base / "agent_teams/tips"
        root.mkdir(parents=True)
        outside = self.base / "outside"
        outside.mkdir()
        (root / "state").symlink_to(outside, target_is_directory=True)
        with self.assertRaises(RuntimeError):
            conf.claim_root(root, "o/tips", self.checkout)
        assert sorted(p.name for p in root.iterdir()) == ["state"]
        assert not any(outside.iterdir())

    def test_a_client_names_its_launch_only_with_a_canonical_state_path(self) -> None:
        state = self.base / "agent_teams/tips/state"
        state.mkdir(parents=True)
        link = self.base / "state-link"
        link.symlink_to(state, target_is_directory=True)
        cases = {
            "are not set": {"TIPS_TEAM_ALLOCATION_ID": "g1-impl"},
            "not set": {"TIPS_TEAM_ALLOCATION_ID": "impl", "TIPS_TEAM_STATE": str(state)},
            "is not a canonical absolute path": {
                "TIPS_TEAM_ALLOCATION_ID": "g1-impl",
                "TIPS_TEAM_STATE": str(link),
            },
        }
        for message, env in cases.items():
            with (
                self.subTest(message=message),
                mock.patch.dict(os.environ, env, clear=True),
                self.assertRaisesRegex(ValueError, message),
            ):
                conf.launch_identity()
        env = {"TIPS_TEAM_ALLOCATION_ID": "g12-impl", "TIPS_TEAM_STATE": str(state)}
        with mock.patch.dict(os.environ, env, clear=True):
            assert conf.launch_identity() == ("g12-impl", state)
