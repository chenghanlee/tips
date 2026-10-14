"""The harness root: where it may be, and the stable path workers name. The concurrent
first-claim test is RepositoryConfigTest in test_team.py."""

import os
import tempfile
import unittest
from pathlib import Path
from typing import Any, cast
from unittest import mock

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
                    team.claim_root(root, "o/tips", self.checkout)
                assert not root.exists()

    def test_workers_name_the_stable_harness_path_of_an_installed_harness(self) -> None:
        root = self.base / "agent_teams/tips"
        recorded = {"root": root}
        with (
            mock.patch.object(team, "installed", side_effect=recorded.get),
            mock.patch.object(team, "harness_root", return_value=root),
        ):
            assert team.harness() == root / "harness/agent/teams"
        assert team.harness() == Path(team.__file__).resolve().parent

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
            mock.patch.object(team, "installed", side_effect=recorded.get),
            mock.patch.object(team, "harness_root", return_value=root),
            mock.patch.object(team, "state_dir", return_value=root / "state"),
            mock.patch.object(team, "main", self.checkout, create=True),
            mock.patch.object(team, "cfg", settings, create=True),
        ):
            # The stable link path, not the release it resolves to today.
            config = root / "harness/agent/teams/config.toml"
            assert config.resolve() == (release / "config.toml").resolve()
            assert team.config_location() == (self.checkout, config)
            env = team.agent_env(cast(team.Allocation, allocation))
            assert env["TIPS_TEAM_CONFIG"] == str(config)
            os.environ["TIPS_TEAM_CONFIG"] = str(self.base / "other.toml")
            env = team.agent_env(cast(team.Allocation, allocation))
            assert env["TIPS_TEAM_CONFIG"] == str(self.base / "other.toml")

    def test_a_symlinked_state_directory_refuses_before_the_identity_is_published(self) -> None:
        root = self.base / "agent_teams/tips"
        root.mkdir(parents=True)
        outside = self.base / "outside"
        outside.mkdir()
        (root / "state").symlink_to(outside, target_is_directory=True)
        with self.assertRaises(RuntimeError):
            team.claim_root(root, "o/tips", self.checkout)
        assert sorted(p.name for p in root.iterdir()) == ["state"]
        assert not any(outside.iterdir())
