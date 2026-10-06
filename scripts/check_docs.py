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


if __name__ == "__main__":
    check_local_links()
    check_fragments()
    print("PASS: local documentation links valid")
