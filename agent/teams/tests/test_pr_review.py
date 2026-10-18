"""PR state observation: findings recorded on the PR, folded by key, and merge readiness."""

import contextlib
import io
import json
import os
import re
import subprocess
import tempfile
import tomllib
import unittest
from pathlib import Path
from typing import Any, NamedTuple, cast
from unittest import mock

import board
import config as conf
import pr_review
from commands import execute
from tests.harness import CONFIG, FAKE_GH, FakeState, Harness, fake

HEAD = "a" * 40
TESTER = ("tester", "team-1-tester", "session-team-1-tester")
# Brief 29's required reviewers.
REQUIRED = ["tester", "critic"]


class Observation(NamedTuple):
    printed: str  # what `observe` prints: the state and the open findings
    blockers: str  # why the PR cannot merge, one reason per line; empty when it can


def marker(body: str) -> dict[str, Any]:
    line = next(line for line in body.splitlines() if line.startswith("TEAM_FINDING "))
    finding: dict[str, Any] = json.loads(line.removeprefix("TEAM_FINDING "))
    return finding


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


class ObserveTest(FakeState, unittest.TestCase):
    """pr_review.observe and blockers in this process, as the tester, against the fake gh's
    PR 7: gh state in, findings and blockers out."""

    def setUp(self) -> None:
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        bin_dir = Path(directory.name)
        (bin_dir / "gh").symlink_to(fake("gh", FAKE_GH))
        self.state_path = bin_dir / "state.json"
        self.head = HEAD
        self.save({"events": [], "pr_head": HEAD})
        path = f"{bin_dir}{os.pathsep}{os.environ['PATH']}"
        fixture = str(self.state_path)
        self.enterContext(mock.patch.dict(os.environ, PATH=path, HERDR_FIXTURE=fixture))
        self.enterContext(mock.patch.object(conf, "cfg", cast(conf.Config, tomllib.loads(CONFIG))))

    def observe(self, ready: bool = False) -> Observation:
        """Observe as `pr_review.py observe 7` does for the tester of brief 29."""
        printed = io.StringIO()
        with contextlib.redirect_stdout(printed):
            state, known = pr_review.observe(7, TESTER)
            pr_review.print_state(state, known)
        reasons = pr_review.blockers(state, REQUIRED, known)
        assert (not reasons) == ready, reasons
        return Observation(printed.getvalue(), "\n".join(reasons))

    def push(self, head: str) -> str:
        """The implementer pushes a new head to the PR."""
        self.update(pr_head=head)
        return head

    def findings(self) -> list[dict[str, Any]]:
        return [marker(c["body"]) for c in self.comments("7") if c["body"].startswith("FINDING")]

    def test_each_failure_is_recorded_once_per_check_head_and_base(self) -> None:
        base = "b" * 40
        self.update(
            pr_mergeable="CONFLICTING", checks=[check("checks", "fail"), check("release", "cancel")]
        )
        reads = len(self.events("gh", "api"))
        self.observe()
        # One comment-history read for the whole observation, not one per finding.
        assert len([e for e in self.events("gh", "api")[reads:] if "/comments?" in e[2]]) == 1
        first = self.comments("7")[0]["body"].splitlines()
        assert first[0] == "FINDING tester team-1-tester session-team-1-tester"
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
        self.observe()
        assert len(self.findings()) == 3
        # The base moves under the same head: each failure is a new finding at the new base
        # that supersedes the old one; reading again stays quiet.
        self.update(pr_base="c" * 40)
        self.observe()
        newer = self.findings()[3:]
        assert [(f["check"], f["base"]) for f in newer] == [
            ("mergeability", "c" * 40),
            ("check:CI/checks", "c" * 40),
            ("check:CI/release", "c" * 40),
        ]
        ids = [c["id"] for c in self.comments("7")[:3]]
        assert [f["supersedes"] for f in newer] == [[i] for i in ids]
        assert f"Supersedes {self.comments('7')[0]['html_url']}." in self.comments("7")[3]["body"]
        self.observe()
        assert len(self.findings()) == 6

    def test_unavailable_reads_and_a_new_head_alone_resolve_nothing(self) -> None:
        self.update(pr_mergeable="CONFLICTING", checks=[check("checks", "fail")])
        self.observe()
        urls = [c["html_url"] for c in self.comments("7")]
        self.update(pr_mergeable="UNKNOWN", checks_error="fixture checks unavailable")
        observed = self.observe()
        assert "mergeability unavailable: GitHub reports UNKNOWN" in observed.blockers
        assert "required checks unavailable: fixture checks unavailable" in observed.blockers
        assert all(f"open finding {url}" in observed.blockers for url in urls)
        # A repair head with checks still running proves nothing yet.
        head = self.push("f" * 40)
        self.update(checks_error="", checks=[check("checks", "pending", 2)])
        observed = self.observe()
        assert len(self.comments("7")) == 2
        assert "check:CI/checks is pending" in observed.blockers
        # Passing evidence for the same checks resolves each with a new event.
        self.update(pr_mergeable="MERGEABLE", checks=[check("checks", "pass", 3)])
        observed = self.observe()
        resolved = self.comments("7")[2:]
        assert [marker(c["body"])["state"] for c in resolved] == ["resolved", "resolved"]
        assert f"Resolves {urls[0]}." in resolved[0]["body"]
        assert f"Mergeable at head {head}" in resolved[0]["body"]
        assert "https://ci/3" in resolved[1]["body"]
        assert "open finding" not in observed.blockers

    def test_head_change_during_the_read_records_nothing(self) -> None:
        self.update(pr_mergeable="CONFLICTING", head_after_checks="d" * 40)
        moved = f"headRefOid changed from {self.head} to {'d' * 40} during the read"
        with self.assertRaisesRegex(pr_review.RefusalError, re.escape(moved)):
            self.observe()
        assert self.comments("7") == []

    def test_pass_read_before_a_concurrent_failure_never_resolves_it(self) -> None:
        self.update(checks=[check("checks", "fail")])
        self.observe()
        open_url = self.comments("7")[0]["html_url"]
        self.update(checks=[check("checks", "pass")])
        self.observe()  # not ready: release is not reported; the pass still counts
        assert '"state":"resolved"' in self.comments("7")[-1]["body"]
        # The check passes when this reader reads it; meanwhile another observer records a
        # failed rerun at the same head. The stale pass must not resolve that newer finding.
        newer = self.comments("7")[0]["body"].replace("fail", "fail again")
        self.update(checks=[check("checks", "pass", 2)], post_on_checks=newer)
        count = len(self.comments("7"))
        self.observe()
        assert len(self.comments("7")) == count + 1  # only the concurrent post
        assert '"state":"open"' in self.comments("7")[-1]["body"]
        self.update(checks=[check("checks", "fail", 3)])
        assert "open finding" in self.observe().blockers
        assert open_url != self.comments("7")[-1]["html_url"]

    def test_a_stale_pass_resolves_only_the_finding_events_it_saw_open(self) -> None:
        reviews = [review("tester", self.head, n=1), review("critic", self.head, n=2)]
        self.update(reviews=reviews, checks=[check("checks", "fail"), check("release", "pass")])
        self.observe()
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
        self.observe(ready=True)  # its own snapshot
        newer = self.comments("7")[2]["html_url"]
        # The newer failure is still open: an unavailable read reports it.
        self.update(checks_error="fixture checks unavailable")
        assert f"open finding {newer}" in self.observe().blockers

    def test_a_finding_no_check_can_resolve_is_resolved_by_hand(self) -> None:
        # The required check was renamed: no later pass carries the old identity.
        renamed = [check("old", "fail"), check("checks", "pass"), check("release", "pass")]
        self.update(checks=renamed, required=["old", "checks", "release"])
        self.observe()
        opened = self.comments("7")[0]
        url = opened["html_url"]
        self.update(checks=renamed[1:], required=["checks", "release"])
        assert f"open finding {url}" in self.observe().blockers
        resolved = marker(opened["body"]) | {"state": "resolved", "resolves": opened["id"]}
        body = "TEAM_FINDING " + json.dumps(resolved, separators=(",", ":"))
        text = f"{body}\nRenamed to check:CI/checks, which passes."
        board.post_as("7", "FINDING", ("tester", "team-1-tester", "s"), text)
        assert "open finding" not in self.observe().blockers

    def test_configured_required_checks_decide_readiness(self) -> None:
        reviews = [review("tester", self.head, n=1), review("critic", self.head, n=2)]
        # Configured and reported: a failed optional check is shown, never recorded.
        passing = [check("checks", "pass"), check("release", "pass")]
        self.update(reviews=reviews, checks=[*passing, check("dexter", "fail")])
        printed = self.observe(ready=True).printed
        assert "optional check:CI/dexter fail https://ci/1" in printed
        # Configured but not reported yet: unavailable, so never ready and nothing recorded.
        self.update(checks=[check("checks", "pass")])
        observed = self.observe()
        assert "required check release not reported" in observed.blockers
        assert self.findings() == []
        # No required checks configured: readiness follows mergeability and reviews.
        self.update(required=[], checks=[check("dexter", "fail")])
        assert "no required checks configured" in self.observe(ready=True).printed
        assert self.findings() == []

    def test_only_current_head_lgtms_from_every_required_reviewer_allow_merge(self) -> None:
        old = self.head
        self.update(reviews=[review("tester", old, n=1), review("critic", old, n=2)])
        new = self.push("e" * 40)
        observed = self.observe()
        assert f"tester has not reviewed head {new}" in observed.blockers
        assert f"critic has not reviewed head {new}" in observed.blockers
        reviews = [review("tester", new, n=3), review("critic", new, "Findings: P1", n=4)]
        self.update(reviews=reviews, reviewThreads=[{"isResolved": False}])
        observed = self.observe()
        assert "critic's latest review of this head has findings" in observed.blockers
        assert "1 unresolved review threads" in observed.blockers
        reviews.append(review("critic", new, n=5))
        self.update(reviews=reviews, reviewThreads=[{"isResolved": True}])
        assert f"head {new}" in self.observe(ready=True).printed
        # A binding decision can invalidate acceptance without changing the code SHA.
        reviews.append(review("tester", new, "Hold: pending decision", n=6))
        self.update(reviews=reviews)
        assert "tester's latest review of this head has findings" in self.observe().blockers


class ObserveCommandTest(Harness):
    """The one observe through a started pair: the caller's record supplies the poster, the
    brief the PR must close and the required reviewers."""

    def test_observe_posts_as_the_caller_and_requires_its_briefs_reviewers(self) -> None:
        self.team("start", "29")
        self.bootstrap("team-1-impl")
        head = self.push("team-1-impl")
        tester = self.pane("team-1-tester")["pane_id"]

        def observe(ok: bool) -> subprocess.CompletedProcess[str]:
            result = execute(
                ["python3", str(self.repo / "agent/teams/pr_review.py"), "observe", "7"],
                cwd=self.allocation("team-1-tester")["root"],
                env=dict(self.env, HERDR_PANE_ID=tester),
                timeout=60,
            )
            assert (result.returncode == 0) == ok, result.stdout + result.stderr
            return result

        # A PR that does not close the caller's brief is refused and nothing is recorded.
        self.update(pr_briefs={"7": ["30"]}, checks=[check("checks", "fail")])
        assert "PR 7 does not close brief #29" in observe(ok=False).stderr
        assert self.comments("7") == []
        # Findings carry the caller's launched session; brief 29 requires tester and critic.
        self.update(pr_briefs={"7": ["29"]})
        refused = observe(ok=False).stderr
        session = self.launched_session("team-1-tester")
        header = self.comments("7")[0]["body"].splitlines()[0]
        assert header == f"FINDING tester team-1-tester {session}"
        assert "not ready to merge" in refused
        assert f"tester has not reviewed head {head}" in refused
        assert f"critic has not reviewed head {head}" in refused
        reviews = [review("tester", head, n=1), review("critic", head, n=2)]
        passing = [check("checks", "pass", 2), check("release", "pass", 2)]
        self.update(reviews=reviews, checks=passing)
        assert f"ready to merge at {head}" in observe(ok=True).stdout


class ListTest(Harness):
    def test_a_thread_names_the_reviewer_that_opened_it(self) -> None:
        findings = review("critic", "a" * 40, "Request changes: 1 P1 finding", n=2)
        comment = {"databaseId": 11, "body": "P1: fix it", "pullRequestReview": findings}
        thread = {"id": "T_1", "isResolved": False, "path": "a.ex", "line": 3}
        nodes = {"totalCount": 1, "nodes": [comment]}
        self.update(reviews=[findings], reviewThreads=[{**thread, "comments": nodes}])
        result = execute(
            ["python3", str(self.repo / "agent/teams/pr_review.py"), "list", "7"],
            cwd=self.repo,
            env=self.env,
            timeout=60,
        )
        assert result.returncode == 0, result.stderr
        assert "thread T_1 reply-to 11 a.ex:3 by critic\n" in result.stdout, result.stdout


if __name__ == "__main__":
    unittest.main()
