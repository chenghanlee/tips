"""PR state observation: findings recorded on the PR, folded by key, and merge readiness."""

import json
import subprocess
import unittest
from typing import Any

from commands import execute
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
        self.bootstrap("team-1-impl")
        self.head = self.push("team-1-impl")
        self.tester = self.pane("team-1-tester")["pane_id"]

    def observe(self, ok: bool = True) -> subprocess.CompletedProcess[str]:
        result = execute(
            ["python3", str(self.repo / "agent/teams/pr_review.py"), "observe", "7"],
            cwd=self.allocation("team-1-tester")["root"],
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
        reads = len(self.events("gh", "api"))
        result = self.observe(ok=False)
        assert "not ready to merge" in result.stderr
        # One comment-history read for the whole observation, not one per finding.
        assert len([e for e in self.events("gh", "api")[reads:] if "/comments?" in e[2]]) == 1
        first = self.comments("7")[0]["body"].splitlines()
        session = self.launched_session("team-1-tester")
        assert first[0] == f"FINDING tester team-1-tester {session}"
        assert first[1] == (
            'TEAM_FINDING {"v":2,"pr":7,"check":"mergeability",'
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
        ids = [c["id"] for c in self.comments("7")[:3]]
        assert [f["supersedes"] for f in newer] == [[i] for i in ids]
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
        head = self.push("team-1-impl", "repair")
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

    def test_pass_read_before_a_concurrent_failure_never_resolves_it(self) -> None:
        self.update(checks=[check("checks", "fail")])
        self.observe(ok=False)
        open_url = self.comments("7")[0]["html_url"]
        self.update(checks=[check("checks", "pass")])
        self.observe(ok=False)  # not ready: release is not reported; the pass still counts
        assert '"state":"resolved"' in self.comments("7")[-1]["body"]
        # The check passes when this reader reads it; meanwhile another observer records a
        # failed rerun at the same head. The stale pass must not resolve that newer finding.
        newer = self.comments("7")[0]["body"].replace("fail", "fail again")
        self.update(checks=[check("checks", "pass", 2)], post_on_checks=newer)
        count = len(self.comments("7"))
        self.observe(ok=False)
        assert len(self.comments("7")) == count + 1  # only the concurrent post
        assert '"state":"open"' in self.comments("7")[-1]["body"]
        self.update(checks=[check("checks", "fail", 3)])
        assert "open finding" in self.observe(ok=False).stderr
        assert open_url != self.comments("7")[-1]["html_url"]

    def test_a_stale_pass_resolves_only_the_finding_events_it_saw_open(self) -> None:
        reviews = [review("tester", self.head, n=1), review("critic", self.head, n=2)]
        self.update(reviews=reviews, checks=[check("checks", "fail"), check("release", "pass")])
        self.observe(ok=False)
        first = self.comments("7")[0]
        # While this reader reads a pass, another observer resolves that finding and records
        # a new failure of the same check at the same head and base.
        header = first["body"].splitlines()[0]
        opened = marker(first["body"])
        resolution = opened | {"state": "resolved", "resolves": first["id"]}
        bodies = [
            f"{header}\nTEAM_FINDING {json.dumps(fields, separators=(',', ':'))}\n{text}"
            for fields, text in ((resolution, "Passed."), (opened, "Failed again."))
        ]
        self.update(checks=[check("checks", "pass", 2), check("release", "pass")])
        self.update(post_on_checks=bodies)
        assert f"ready to merge at {self.head}" in self.observe().stdout  # its own snapshot
        newer = self.comments("7")[2]["html_url"]
        # The newer failure is still open: an unavailable read reports it.
        self.update(checks_error="fixture checks unavailable")
        assert f"open finding {newer}" in self.observe(ok=False).stderr

    def test_a_finding_no_check_can_resolve_is_resolved_by_hand(self) -> None:
        # The required check was renamed: no later pass carries the old identity.
        renamed = [check("old", "fail"), check("checks", "pass"), check("release", "pass")]
        self.update(checks=renamed, required=["old", "checks", "release"])
        self.observe(ok=False)
        opened = self.comments("7")[0]
        url = opened["html_url"]
        self.update(checks=renamed[1:], required=["checks", "release"])
        assert f"open finding {url}" in self.observe(ok=False).stderr
        resolved = marker(opened["body"]) | {"state": "resolved", "resolves": opened["id"]}
        body = "TEAM_FINDING " + json.dumps(resolved, separators=(",", ":"))
        command = [
            "python3",
            str(self.repo / "agent/teams/board.py"),
            "post",
            "7",
            "FINDING",
            "--as",
            "tester",
            "team-1-tester",
            "s",
        ]
        text = f"{body}\nRenamed to check:CI/checks, which passes."
        posted = execute(command, cwd=self.repo, env=self.env, input_text=text, timeout=60)
        assert posted.returncode == 0, posted.stderr
        assert "open finding" not in self.observe(ok=False).stderr

    def test_configured_required_checks_decide_readiness(self) -> None:
        reviews = [review("tester", self.head, n=1), review("critic", self.head, n=2)]
        # Configured and reported: a failed optional check is shown, never recorded.
        passing = [check("checks", "pass"), check("release", "pass")]
        self.update(reviews=reviews, checks=[*passing, check("dexter", "fail")])
        result = self.observe()
        assert "optional check:CI/dexter fail https://ci/1" in result.stdout
        assert f"ready to merge at {self.head}" in result.stdout
        # Configured but not reported yet: unavailable, so never ready and nothing recorded.
        self.update(checks=[check("checks", "pass")])
        result = self.observe(ok=False)
        assert "required check release not reported" in result.stderr
        assert self.findings() == []
        # No required checks configured: readiness follows mergeability and reviews.
        self.update(required=[], checks=[check("dexter", "fail")])
        result = self.observe()
        assert "no required checks configured" in result.stdout
        assert f"ready to merge at {self.head}" in result.stdout
        assert self.findings() == []

    def test_only_current_head_lgtms_from_every_required_reviewer_allow_merge(self) -> None:
        old = self.head
        self.update(reviews=[review("tester", old, n=1), review("critic", old, n=2)])
        new = self.push("team-1-impl", "next")
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
