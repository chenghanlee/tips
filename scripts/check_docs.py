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


if __name__ == "__main__":
    check_local_links()
    print("PASS: local documentation links valid")
