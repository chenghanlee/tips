"""Routing between role files: a step one role delegates names a task the other role has."""

import re
import unittest
from pathlib import Path

ROLES = Path(__file__).resolve().parents[1] / "roles"


def section(name: str, heading: str) -> str:
    """The text under a level-2 heading of a role file, up to the next level-2 heading."""
    text = (ROLES / name).read_text()
    match = re.search(rf"^## {re.escape(heading)}\n(.*?)(?=^## |\Z)", text, re.M | re.S)
    assert match, f"{name} has no section {heading!r}"
    return match.group(1)


class RevertRoutingTest(unittest.TestCase):
    def test_the_dispatcher_routes_a_broken_main_to_the_testers_revert_task(self) -> None:
        dispatcher = section("dispatcher.md", "Revert a broken main")
        assert "(tester.md#revert-a-broken-main)" in dispatcher
        assert "`prompt_agent`" in dispatcher
        assert "report it to the user" in dispatcher
        tester = section("tester.md", "Revert a broken main")
        for step in ("gh pr revert <pr>", "--required", "--match-head-commit", "`done`"):
            assert step in tester, step
        # Diagnosis outside the tester's allocation goes back as a blocker, not a retry.
        assert "outside your allocation" in tester
        assert "`blocked`" in tester
