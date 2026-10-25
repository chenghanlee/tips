"""read.py: section extraction and a role's launch reading, in process."""

import unittest
from pathlib import Path

import read

TEAMS = Path(__file__).resolve().parents[1]
ROOT = TEAMS.parents[1]

DOC = """# Title

intro

## Turns

turn text

### Nested

nested text

```md
## Outcome

fenced heading, not a boundary
```

more turn text

## Severity

severity text
"""


class SectionTest(unittest.TestCase):
    def test_a_section_runs_to_the_next_heading_of_equal_or_shallower_depth(self):
        text = read.section(DOC, "Turns")
        assert text.startswith("## Turns\n")
        assert "### Nested" in text
        assert "more turn text" in text
        assert "## Severity" not in text

    def test_a_heading_inside_a_fence_neither_starts_nor_ends_a_section(self):
        assert "fenced heading, not a boundary" in read.section(DOC, "Turns")
        with self.assertRaises(LookupError):
            read.section(DOC, "Outcome")

    def test_an_inner_shorter_fence_does_not_close_an_outer_one(self):
        doc = (
            "## Target\n\n````markdown\n```python\n## Example heading\n```\n````\n\nAfter.\n\n"
            "## Next\n\nnext text\n"
        )
        text = read.section(doc, "Target")
        assert text.endswith("````\n\nAfter.\n")
        with self.assertRaises(LookupError):
            read.section(doc, "Example heading")
        assert read.section(doc, "Next") == "## Next\n\nnext text\n"

    def test_a_slug_a_title_and_a_fragment_all_resolve_at_any_depth(self):
        for name in ("nested", "Nested", "#nested"):
            text = read.section(DOC, name)
            assert text.startswith("### Nested\n\nnested text\n")
            assert text.endswith("```\n\nmore turn text\n")

    def test_an_unknown_heading_raises_instead_of_returning_empty_text(self):
        with self.assertRaises(LookupError) as raised:
            read.section(DOC, "Merge")
        assert "turns, nested, severity" in str(raised.exception)

    def test_the_slug_matches_the_docs_checker_rule(self):
        assert read.slugify("Report and resolve blockers") == "report-and-resolve-blockers"
        assert read.slugify("Optional P2 findings") == "optional-p2-findings"
        assert read.slugify("`observe` and PR body") == "observe-and-pr-body"


class LaunchTest(unittest.TestCase):
    def test_the_tester_launch_prints_the_three_files_then_item_one_sections_in_order(self):
        text = read.launch("tester", ROOT)
        labels = [line for line in text.splitlines() if line.startswith("--- ")]
        assert labels[:3] == [
            "--- AGENTS.md ---",
            "--- agent/teams/roles/common.md ---",
            "--- agent/teams/roles/tester.md ---",
        ]
        assert labels[3:] == [
            "--- agent/teams/README.md#turns ---",
            "--- agent/teams/README.md#severity ---",
            "--- agent/teams/README.md#report-and-resolve-blockers ---",
            "--- agent/teams/README.md#constraints ---",
        ]
        assert "## Turns\n" in text
        assert "### Severity\n" in text
        assert "## PR review record" not in text, "step-linked sections are not launch reading"

    def test_every_role_file_launches_and_its_links_resolve(self):
        for role_file in sorted((TEAMS / "roles").glob("*.md")):
            with self.subTest(role=role_file.stem):
                text = read.launch(role_file.stem, ROOT)
                assert f"--- agent/teams/roles/{role_file.stem}.md ---" in text

    def test_an_unknown_role_raises_and_names_the_roles(self):
        with self.assertRaises(LookupError) as raised:
            read.launch("reviewer", ROOT)
        assert "tester" in str(raised.exception)

    def test_the_root_is_found_from_a_nested_directory(self):
        assert read.repository_root(TEAMS / "tests") == ROOT
        with self.assertRaises(LookupError):
            read.repository_root(Path("/"))


if __name__ == "__main__":
    unittest.main()
