"""PR state observation: findings recorded on the PR, folded by key, and merge readiness."""

import json
import subprocess
import unittest
from typing import Any

from team import execute
from tests.test_team import Harness


def marker(body: str) -> dict[str, Any]:
    line = next(line for line in body.splitlines() if line.startswith("TEAM_FINDING "))
    return json.loads(line.removeprefix("TEAM_FINDING "))


def check(name: str, bucket: str, run: int = 1) -> dict[str, str]:
    return {"name": name, "workflow": "CI", "bucket": bucket, "link": f"https://ci/{run}"}


def review(entry: str, head: str, verdict: str = "LGTM", n: int = 1) -> dict[str, Any]:
    return {
        "databaseId": n,
        "state": "COMMENTED",
        "body": f"{verdict}\n{entry}, session-{entry}",
        "url": f"https://github.com/o/r/pull/7#pullrequestreview-{n}",
        "commit": {"oid": head},
    }


class ObserveTest(Harness):
    def setUp(self) -> None:
        super().setUp()
        self.team("start", "29")
        self.head = self.push(self.worktree("29"))
        self.tester = self.pane("team-1-tester")["pane_id"]

    def observe(self, ok: bool = True) -> subprocess.CompletedProcess[str]:
        result = execute(
            ["python3", str(self.repo / "agent/teams/pr_review.py"), "observe", "7"],
            cwd=self.worktree("29"),
            env=dict(self.env, HERDR_PANE_ID=self.tester),
            timeout=60,
        )
        assert (result.returncode == 0) == ok, result.stdout + result.stderr
        return result

    def findings(self) -> list[dict[str, Any]]:
        return [marker(c["body"]) for c in self.comments("7") if c["body"].startswith("FINDING")]

    def test_each_failure_is_recorded_once_per_check_head_and_base(self) -> None:
        base = "b" * 40
        self.update(
            pr_mergeable="CONFLICTING", checks=[check("checks", "fail"), check("release", "cancel")]
        )
        result = self.observe(ok=False)
        assert "not ready to merge" in result.stderr
        first = self.comments("7")[0]["body"].splitlines()
        assert first[0] == "FINDING tester team-1-tester session-team-1-tester"
        assert first[1] == (
            'TEAM_FINDING {"v":1,"pr":7,"check":"mergeability",'
            f'"head":"{self.head}","base":"{base}","state":"open"}}'
        )
        assert first[2] == f"Merge conflict at head {self.head} and base main {base}."
        # Two failed checks at one head are two findings, each with its evidence link.
        assert [(f["check"], f["state"]) for f in self.findings()] == [
            ("mergeability", "open"),
            ("check:CI/checks", "open"),
            ("check:CI/release", "open"),
        ]
        assert "https://ci/1" in self.comments("7")[1]["body"]
        # A repeated observation posts nothing.
        self.observe(ok=False)
        assert len(self.findings()) == 3
        # The base moves under the same head: each failure is a new finding at the new base
        # that supersedes the old one; reading again stays quiet.
        self.update(pr_base="c" * 40)
        self.observe(ok=False)
        newer = self.findings()[3:]
        assert [(f["check"], f["base"]) for f in newer] == [
            ("mergeability", "c" * 40),
            ("check:CI/checks", "c" * 40),
            ("check:CI/release", "c" * 40),
        ]
        assert all(f["supersedes"] == [{"head": self.head, "base": base}] for f in newer)
        assert f"Supersedes {self.comments('7')[0]['html_url']}." in self.comments("7")[3]["body"]
        self.observe(ok=False)
        assert len(self.findings()) == 6

    def test_unavailable_reads_and_a_new_head_alone_resolve_nothing(self) -> None:
        self.update(pr_mergeable="CONFLICTING", checks=[check("checks", "fail")])
        self.observe(ok=False)
        urls = [c["html_url"] for c in self.comments("7")]
        self.update(pr_mergeable="UNKNOWN", checks_error="fixture checks unavailable")
        result = self.observe(ok=False)
        assert "mergeability unavailable: GitHub reports UNKNOWN" in result.stderr
        assert "required checks unavailable: fixture checks unavailable" in result.stderr
        assert all(f"open finding {url}" in result.stderr for url in urls)
        # A repair head with checks still running proves nothing yet.
        head = self.push(self.worktree("29"), "repair")
        self.update(checks_error="", checks=[check("checks", "pending", 2)])
        result = self.observe(ok=False)
        assert len(self.comments("7")) == 2
        assert "check:CI/checks is pending" in result.stderr
        # Passing evidence for the same checks resolves each with a new event.
        self.update(pr_mergeable="MERGEABLE", checks=[check("checks", "pass", 3)])
        result = self.observe(ok=False)
        resolved = self.comments("7")[2:]
        assert [marker(c["body"])["state"] for c in resolved] == ["resolved", "resolved"]
        assert f"Resolves {urls[0]}." in resolved[0]["body"]
        assert f"Mergeable at head {head}" in resolved[0]["body"]
        assert "https://ci/3" in resolved[1]["body"]
        assert "open finding" not in result.stderr

    def test_head_change_during_the_read_records_nothing(self) -> None:
        self.update(pr_mergeable="CONFLICTING", head_after_checks="d" * 40)
        moved = f"headRefOid changed from {self.head} to {'d' * 40} during the read"
        assert moved in self.observe(ok=False).stderr
        assert self.comments("7") == []

    def test_only_current_head_lgtms_from_every_required_reviewer_allow_merge(self) -> None:
        old = self.head
        self.update(reviews=[review("tester", old, n=1), review("critic", old, n=2)])
        new = self.push(self.worktree("29"), "next")
        result = self.observe(ok=False)
        assert f"tester has not reviewed head {new}" in result.stderr
        assert f"critic has not reviewed head {new}" in result.stderr
        reviews = [review("tester", new, n=3), review("critic", new, "Findings: P1", n=4)]
        self.update(reviews=reviews, reviewThreads=[{"isResolved": False}])
        result = self.observe(ok=False)
        assert "critic's latest review of this head has findings" in result.stderr
        assert "1 unresolved review threads" in result.stderr
        reviews.append(review("critic", new, n=5))
        self.update(reviews=reviews, reviewThreads=[{"isResolved": True}])
        assert f"ready to merge at {new}" in self.observe().stdout


if __name__ == "__main__":
    unittest.main()
