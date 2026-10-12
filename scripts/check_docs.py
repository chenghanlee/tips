#!/usr/bin/env python3
"""Check local links in the instructions, README and repository documentation."""
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


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


def check_design_index():
    """Every section of a design doc has a link in docs/design/README.md."""
    folder = ROOT / "docs/design"
    index = (folder / "README.md").read_text()
    for path in sorted(folder.glob("*.md")):
        if path.name == "README.md":
            continue
        for heading in re.findall(r"^#{2,3} (.+)$", path.read_text(), re.M):
            slug = re.sub(r"[^a-z0-9 -]", "", heading.lower()).replace(" ", "-")
            link = f"({path.name}#{slug})"
            assert link in index, f"docs/design/README.md: add a row linking {path.name}#{slug}"


if __name__ == "__main__":
    check_local_links()
    check_fragments()
    check_design_index()
    print("PASS: local documentation links valid")
