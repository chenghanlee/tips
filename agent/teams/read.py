#!/usr/bin/env python3
"""Print a role's launch reading, or one Markdown section, in one call.

Usage:
  agent/teams/read.py launch <role>
  agent/teams/read.py section <file> <heading>

launch prints, in order and each under a `--- <path> ---` line: AGENTS.md, the common
rules, the role file, then every workflow section that item 1 of the role file's `## Read`
list links. It stops at the brief; the brief and the skills are read at their step. It
prints the files themselves, never a copy, so the role file stays the only list.

section prints the heading named by its text or its link slug, at any depth, with its
subsections, up to the next heading of equal or shallower depth. Headings inside fenced
code blocks do not start or end a section. An unknown heading exits 1 with an error; an
empty result is never a success.

Run it from anywhere inside the clone; it finds the repository root from the current
directory.
"""

import re
import sys
from dataclasses import dataclass
from pathlib import Path

FENCE = re.compile(r"^\s{0,3}(```|~~~)")
HEADING = re.compile(r"^(#{1,6})\s+(.*?)\s*#*\s*$")
LINK = re.compile(r"\]\(([^)\s]+)\)")


@dataclass(frozen=True)
class Heading:
    """One Markdown heading outside fenced code."""

    level: int
    title: str
    line: int

    @property
    def slug(self) -> str:
        return slugify(self.title)


def slugify(title: str) -> str:
    """The link fragment GitHub derives from a heading; the same rule as check_docs.py."""
    plain = re.sub(r"`|\*|_", "", title)
    return re.sub(r"[^a-z0-9 -]", "", plain.lower()).replace(" ", "-")


def headings(lines: list[str]) -> list[Heading]:
    """Every heading outside fenced code blocks, with its zero-based line."""
    found: list[Heading] = []
    fence = ""
    for number, line in enumerate(lines):
        opened = FENCE.match(line)
        if fence:
            if opened and opened.group(1) == fence:
                fence = ""
            continue
        if opened:
            fence = opened.group(1)
            continue
        match = HEADING.match(line)
        if match:
            found.append(Heading(len(match.group(1)), match.group(2), number))
    return found


def section(text: str, name: str) -> str:
    """The section whose heading text or slug is `name`, with its subsections."""
    lines = text.splitlines()
    all_headings = headings(lines)
    wanted = name.lstrip("#").strip()
    target = next(
        (
            h
            for h in all_headings
            if h.slug == slugify(wanted) or h.title.casefold() == wanted.casefold()
        ),
        None,
    )
    if target is None:
        raise LookupError(
            f"no heading {name!r}; headings: {', '.join(h.slug for h in all_headings)}"
        )
    end = next(
        (h.line for h in all_headings if h.line > target.line and h.level <= target.level),
        len(lines),
    )
    return "\n".join(lines[target.line : end]).rstrip("\n") + "\n"


def repository_root(start: Path) -> Path:
    """The nearest ancestor of `start` that holds agent/teams/roles."""
    for candidate in (start, *start.parents):
        if (candidate / "agent" / "teams" / "roles").is_dir():
            return candidate
    raise LookupError(f"{start} is not inside a clone: no agent/teams/roles above it")


def launch_targets(role_text: str) -> list[str]:
    """The workflow links of item 1 in the role's `## Read` list: `../README.md#slug`."""
    try:
        read = section(role_text, "Read")
    except LookupError:
        return []
    item_one = re.split(r"^\s*2\.\s", read, maxsplit=1, flags=re.M)[0]
    return [link for link in LINK.findall(item_one) if link.startswith("../README.md#")]


def launch(role: str, root: Path) -> str:
    """The role's launch reading, each part under a `--- <path> ---` line."""
    roles = root / "agent" / "teams" / "roles"
    role_file = roles / f"{role}.md"
    if not role_file.is_file():
        raise LookupError(
            f"no role {role!r}; roles: {', '.join(sorted(p.stem for p in roles.glob('*.md')))}"
        )
    role_text = role_file.read_text()
    parts = [
        ("AGENTS.md", (root / "AGENTS.md").read_text()),
        ("agent/teams/roles/common.md", (roles / "common.md").read_text()),
        (f"agent/teams/roles/{role}.md", role_text),
    ]
    workflow = (root / "agent" / "teams" / "README.md").read_text()
    for link in launch_targets(role_text):
        slug = link.split("#", 1)[1]
        parts.append((f"agent/teams/README.md#{slug}", section(workflow, slug)))
    return "".join(f"--- {label} ---\n{body.rstrip()}\n\n" for label, body in parts)


def main(argv: list[str]) -> int:
    """Run `launch <role>` or `section <file> <heading>`; print the text; 1 on any error."""
    try:
        match argv:
            case ["launch", role]:
                sys.stdout.write(launch(role, repository_root(Path.cwd().resolve())))
            case ["section", file, heading]:
                sys.stdout.write(section(Path(file).read_text(), heading))
            case _:
                sys.stderr.write(__doc__ or "")
                return 2
    except (LookupError, OSError) as error:
        sys.stderr.write(f"read.py: {error}\n")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
