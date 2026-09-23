#!/usr/bin/env python3
"""Check local links in the README and repository documentation."""
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def check_local_links():
    paths = [ROOT / "README.md", *(ROOT / "docs").rglob("*.md"), *(ROOT / "agent").rglob("*.md")]
    for path in paths:
        if (
            path.is_relative_to(ROOT / "agent/lsp/vendor")
            or path.is_relative_to(ROOT / "agent/elixir-agent-tools")
        ):
            continue
        for target in re.findall(r"\]\(([^)]+)\)", path.read_text()):
            target = target.strip("<>").split("#", 1)[0]
            if not target or "://" in target or target.startswith("mailto:"):
                continue
            assert (path.parent / target).is_file(), f"{path.relative_to(ROOT)}: broken local link {target}"


def check_role_cards():
    """Every role card in the agent teams README carries every event once, in order."""
    text = (ROOT / "agent/teams/README.md").read_text()
    events = re.findall(r"^\d+\. \*\*([^*]+)\*\*:", text, re.M)
    assert events, "agent/teams/README.md: no numbered event list found"
    cards = re.split(r"^## ", text, flags=re.M)[1:]
    roles = [c.split("\n", 1)[0] for c in cards if re.search(r"^### ", c, re.M)]
    assert roles, "agent/teams/README.md: no role cards with ### cells found"
    for card in cards:
        role = card.split("\n", 1)[0]
        cells = re.findall(r"^### (.+)$", card, re.M)
        if role in roles:
            assert cells == events, f"agent/teams/README.md: {role} cells {cells} != {events}"
        else:
            assert not cells, f"agent/teams/README.md: {role} has ### headings outside a role card"


if __name__ == "__main__":
    check_local_links()
    check_role_cards()
    print("PASS: local documentation links valid; role cards complete")
