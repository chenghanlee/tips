"""Role-file safety instructions that no link check covers."""

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


class RevertStepTest(unittest.TestCase):
    def test_the_testers_revert_waits_for_required_checks_and_merges_only_the_checked_head(
        self,
    ) -> None:
        tester = section("tester.md", "Revert a broken main")
        lost = [flag for flag in ("--required", "--match-head-commit") if flag not in tester]
        assert not lost, f"tester.md's revert step lost its safety flags {lost}"
