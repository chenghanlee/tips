#!/usr/bin/env python3
"""Check local links in the instructions, README and repository documentation."""
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
AGENTS_MAX_LINES = 100


def doc_paths():
    """Every checked Markdown file; the vendored Elixir sources are not ours."""
    paths = [ROOT / "AGENTS.md", ROOT / "README.md"]
    for folder in (".github", "docs", "agent"):
        paths += (ROOT / folder).rglob("*.md")
    return [path for path in paths if not path.is_relative_to(ROOT / "agent/lsp/vendor")]


def check_local_links():
    for path in doc_paths():
        for target in re.findall(r"\]\(([^)]+)\)", path.read_text()):
            target = target.strip("<>").split("#", 1)[0]
            if not target or "://" in target or target.startswith("mailto:"):
                continue
            assert (path.parent / target).is_file(), f"{path.relative_to(ROOT)}: broken local link {target}"


ROLES = {
    "Lead TPM": "lead-tpm",
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
    for path in doc_paths():
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


def check_agents_length():
    """AGENTS.md is the map: detail belongs in the guide it links."""
    lines = len((ROOT / "AGENTS.md").read_text().splitlines())
    assert lines <= AGENTS_MAX_LINES, (
        f"AGENTS.md has {lines} lines (maximum {AGENTS_MAX_LINES}). Move detailed guidance to "
        "its existing guide and keep a clear link; do not compress prose to hide the length."
    )


if __name__ == "__main__":
    check_local_links()
    check_agents_length()
    check_fragments()
    check_role_cards()
    print("PASS: local documentation links valid; role cards complete")
