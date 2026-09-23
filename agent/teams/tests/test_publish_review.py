"""Review-record validation and the refusal path that never reaches GitHub."""

import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

from publish_review import SECTIONS, RefusalError, comment_api_path, missing_sections
from team import execute

SCRIPT = Path(__file__).resolve().parents[1] / "publish_review.py"
FAKE_GH = r"""#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
log = Path(os.environ["FAKE_GH_LOG"])
with log.open("a") as stream:
    stream.write(json.dumps(sys.argv[1:]) + "\n")
a = sys.argv[1:]
if a[:1] == ["api"] and "--method" not in a:
    print(json.dumps({"body": os.environ["FAKE_GH_BODY"]}))
elif a[:2] == ["pr", "view"]:
    print(json.dumps({"headRefOid": os.environ["FAKE_GH_HEAD"], "url": "https://github.com/o/tips/pull/7"}))
elif a[:2] == ["pr", "comment"]:
    print("https://github.com/o/tips/pull/7#issuecomment-99")
"""


def record(*present: str) -> str:
    return "\n".join(f"## {name}\n\nchecked.\n" for name in present)


class RecordValidationTest(unittest.TestCase):
    def test_all_sections_with_text_pass(self) -> None:
        assert missing_sections(record(*SECTIONS)) == []

    def test_missing_and_empty_sections_are_named(self) -> None:
        body = record(*SECTIONS[:3]) + "\n## Design challenge\n\n## Defect pass\n\nran mix test.\n"
        assert missing_sections(body) == ["Design challenge"]

    def test_headings_are_case_insensitive_and_allow_h3(self) -> None:
        body = "\n".join(f"### {name.upper()}\n\ntext\n" for name in SECTIONS)
        assert missing_sections(body) == []

    def test_comment_links_map_to_rest_paths(self) -> None:
        issue = "https://github.com/o/tips/pull/7#issuecomment-123"
        review = "https://github.com/o/tips/pull/7#discussion_r456"
        assert comment_api_path(issue) == "repos/o/tips/issues/comments/123"
        assert comment_api_path(review) == "repos/o/tips/pulls/comments/456"
        try:
            comment_api_path("https://github.com/o/tips/pull/7")
        except RefusalError:
            return
        raise AssertionError("bare PR link accepted")


class PublishRefusalTest(unittest.TestCase):
    def run_script(
        self, body: str, head: str, sha: str, *source: str
    ) -> tuple[subprocess.CompletedProcess[str], list[list[str]]]:
        with tempfile.TemporaryDirectory() as tmp:
            fake = Path(tmp) / "gh"
            fake.write_text(FAKE_GH)
            fake.chmod(0o755)
            log = Path(tmp) / "log"
            env = dict(
                os.environ,
                PATH=tmp + os.pathsep + os.environ["PATH"],
                FAKE_GH_LOG=str(log),
                FAKE_GH_BODY=body,
                FAKE_GH_HEAD=head,
            )
            result = execute(
                [
                    sys.executable,
                    str(SCRIPT),
                    "--pr",
                    "7",
                    "--sha",
                    sha,
                    *(source or ("--record", "https://github.com/o/tips/pull/7#issuecomment-1")),
                ],
                env=env,
            )
            calls = (
                [json.loads(line) for line in log.read_text().splitlines()] if log.exists() else []
            )
            return result, calls

    def test_incomplete_record_never_posts_a_status(self) -> None:
        sha = "a" * 40
        result, calls = self.run_script(record(*SECTIONS[:4]), sha, sha)
        assert result.returncode != 0
        assert "Defect pass" in result.stderr
        assert not any("--method" in call for call in calls)

    def test_changed_head_never_posts_a_status(self) -> None:
        result, calls = self.run_script(record(*SECTIONS), "b" * 40, "a" * 40)
        assert result.returncode != 0
        assert "PR head" in result.stderr
        assert not any("--method" in call for call in calls)

    def test_complete_record_on_reviewed_head_posts_once(self) -> None:
        sha = "a" * 40
        result, calls = self.run_script(record(*SECTIONS), sha, sha)
        assert result.returncode == 0, result.stderr
        posts = [call for call in calls if "--method" in call]
        assert len(posts) == 1
        assert f"repos/o/tips/statuses/{sha}" in posts[0]
        assert "context=tips/independent-review" in posts[0]

    def test_owner_waiver_posts_comment_then_status_without_a_record(self) -> None:
        sha = "a" * 40
        result, calls = self.run_script("", sha, sha, "--owner-waiver", "docs-only process change")
        assert result.returncode == 0, result.stderr
        assert calls[0][:2] == ["pr", "view"]
        assert calls[1][:2] == ["pr", "comment"]
        assert "Owner waiver" in calls[1][4]
        posts = [call for call in calls if "--method" in call]
        assert len(posts) == 1
        assert "target_url=https://github.com/o/tips/pull/7#issuecomment-99" in posts[0]
        assert "description=Owner waiver: independent review skipped" in posts[0]

    def test_owner_waiver_needs_a_reason_and_matching_head(self) -> None:
        sha = "a" * 40
        result, calls = self.run_script("", sha, sha, "--owner-waiver", "short")
        assert result.returncode != 0
        assert "reason" in result.stderr
        assert calls == []
        result, calls = self.run_script(
            "", "b" * 40, sha, "--owner-waiver", "docs-only process change"
        )
        assert result.returncode != 0
        assert "PR head" in result.stderr
        assert not any(call[:2] == ["pr", "comment"] for call in calls)

    def test_record_from_another_pull_request_is_refused(self) -> None:
        sha = "a" * 40
        result, calls = self.run_script(
            record(*SECTIONS),
            sha,
            sha,
            "--record",
            "https://github.com/o/tips/pull/8#issuecomment-1",
        )
        assert result.returncode != 0
        assert "does not belong" in result.stderr
        assert not any("--method" in call for call in calls)
