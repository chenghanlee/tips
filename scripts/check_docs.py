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


ROLES = {
    "Lead TPM": "lead-tpm",
    "Team TPM": "team-tpm",
    "Tech lead": "tech-lead",
    "Developer": "developer",
    "Tester": "tester",
}


def check_role_cards():
    """Every role card carries every event once, in order, with a filled cell."""
    readme = ROOT / "agent/teams/README.md"
    events = re.findall(r"^\d+\. \*\*([^*]+)\*\*:", readme.read_text(), re.M)
    assert events, "agent/teams/README.md: no numbered event list found"
    assert not re.search(r"^### ", readme.read_text(), re.M), "agent/teams/README.md: stray ###"
    for role, slug in ROLES.items():
        path = ROOT / f"agent/teams/roles/{slug}.md"
        text = path.read_text()
        assert text.startswith(f"# {role}\n"), f"{path.relative_to(ROOT)}: title must be '# {role}'"
        cells = re.findall(r"^## (.+)$", text, re.M)
        assert cells == events, f"{path.relative_to(ROOT)}: cells {cells} != {events}"
        for cell, body in zip(cells, re.split(r"^## .+$", text, flags=re.M)[1:]):
            assert body.strip(), f"{path.relative_to(ROOT)}: {cell} is empty"


def check_fragments():
    """Local links with #fragments point at an existing heading."""
    paths = [ROOT / "README.md", *(ROOT / "docs").rglob("*.md"), *(ROOT / "agent").rglob("*.md")]
    for path in paths:
        if path.is_relative_to(ROOT / "agent/lsp/vendor") or path.is_relative_to(
            ROOT / "agent/elixir-agent-tools"
        ):
            continue
        for target in re.findall(r"\]\(([^)]+)\)", path.read_text()):
            target = target.strip("<>")
            if "://" in target or "#" not in target:
                continue
            file, fragment = target.split("#", 1)
            dest = path if not file else path.parent / file
            slugs = {
                re.sub(r"[^a-z0-9 -]", "", h.lower()).replace(" ", "-")
                for h in re.findall(r"^#+ (.+)$", dest.read_text(), re.M)
            }
            assert fragment in slugs, f"{path.relative_to(ROOT)}: broken fragment #{fragment}"


if __name__ == "__main__":
    check_local_links()
    check_fragments()
    check_role_cards()
    print("PASS: local documentation links valid; role cards complete")
