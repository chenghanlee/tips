"""The harness root's repository identity under concurrent first use."""

import json
import os
import tempfile
import threading
import unittest
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from unittest import mock

import team


class ClaimRootTest(unittest.TestCase):
    def test_concurrent_first_claims_for_two_repositories_admit_one(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory) / "agent_teams/tips"
            barrier = threading.Barrier(2)
            link = os.link

            def together(source: str | os.PathLike[str], target: str | os.PathLike[str]) -> None:
                # Both callers have written their identity before either publishes it.
                barrier.wait(timeout=5)
                link(source, target)

            def claim(repository: str) -> str:
                try:
                    team.claim_root(root, repository)
                except RuntimeError as error:
                    return str(error)
                return "claimed"

            with mock.patch.object(team.os, "link", together), ThreadPoolExecutor(2) as pool:
                results = list(pool.map(claim, ["owner1/tips", "owner2/tips"]))
            winner = json.loads((root / "repository.json").read_text())["repository"]
            assert sorted(r == "claimed" for r in results) == [False, True], results
            assert f"belongs to {winner}" in next(r for r in results if r != "claimed")
            assert [p.name for p in root.iterdir() if p.name.startswith(".")] == []
