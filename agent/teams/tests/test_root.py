"""The harness root: where it may be, and the stable path workers name. The concurrent
first-claim test is RepositoryConfigTest in test_team.py."""

import tempfile
import unittest
from pathlib import Path
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
