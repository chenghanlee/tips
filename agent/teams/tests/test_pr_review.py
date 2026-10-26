"""PR state observation: a pure read of the live state and why the PR cannot merge."""

import contextlib
import io
import os
import re
import subprocess
import tempfile
import tomllib
import unittest
from pathlib import Path
from typing import Any, NamedTuple, cast
from unittest import mock

import config as conf
import pr_review
import team
from commands import execute
from github import PullRequest
from tests.harness import CONFIG, FAKE_GH, FakeState, Harness, fake

HEAD = "a" * 40
# Brief 29's required reviewers.
REQUIRED = ["tester", "critic"]


class Observation(NamedTuple):
    printed: str  # what `observe` prints: the live state
    blockers: str  # why the PR cannot merge, one reason per line; empty when it can


def check(name: str, bucket: str, run: int = 1) -> dict[str, str]:
    return {"name": name, "workflow": "CI", "bucket": bucket, "link": f"https://ci/{run}"}


def review(
    entry: str, head: str, verdict: str = "LGTM", n: int = 1, state: str = "COMMENTED"
) -> dict[str, Any]:
    return {
        "databaseId": n,
        "state": state,
        "body": f"{verdict}\n{entry}, session-{entry}",
        "url": f"https://github.com/o/r/pull/7#pullrequestreview-{n}",
        "commit": {"oid": head},
    }


class FakeGhTest(FakeState, unittest.TestCase):
    """pr_review in this process against the fake gh's PR 7."""

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


class ObserveTest(FakeGhTest):
    """pr_review.read_state and blockers, as `pr_review.py observe 7` uses them: gh state
    in, blockers out, nothing posted."""

    def observe(self, ready: bool = False) -> Observation:
        """Observe as `pr_review.py observe 7` does for the tester of brief 29."""
        printed = io.StringIO()
        with contextlib.redirect_stdout(printed):
            state = pr_review.read_state(7)
            pr_review.print_state(state)
        reasons = pr_review.blockers(state, REQUIRED)
        assert (not reasons) == ready, reasons
        return Observation(printed.getvalue(), "\n".join(reasons))

    def push(self, head: str) -> str:
        """The implementer pushes a new head to the PR."""
        self.update(pr_head=head)
        return head

    def test_a_live_conflict_and_failed_checks_block_and_post_nothing(self) -> None:
        reviews = [review("tester", self.head, n=1), review("critic", self.head, n=2)]
        failed = [check("checks", "fail"), check("release", "cancel")]
        self.update(reviews=reviews, pr_mergeable="CONFLICTING", checks=failed)
        observed = self.observe()
        assert f"merge conflict at {self.head}" in observed.blockers
        assert "check:CI/checks is fail: https://ci/1" in observed.blockers
        assert "check:CI/release is cancel: https://ci/1" in observed.blockers
        # A pure read: no comment is posted and the comment history is not read.
        assert self.events("gh", "issue", "comment") == []
        assert not [e for e in self.events("gh", "api") if "/comments?" in e[2]]
        # The live state alone decides: once it is mergeable and passing, nothing blocks.
        passing = [check("checks", "pass", 2), check("release", "pass", 2)]
        self.update(pr_mergeable="MERGEABLE", checks=passing)
        self.observe(ready=True)

    def test_unknown_mergeability_and_unavailable_checks_block(self) -> None:
        self.update(pr_mergeable="UNKNOWN", checks_error="fixture checks unavailable")
        observed = self.observe()
        assert "mergeability unavailable: GitHub reports UNKNOWN" in observed.blockers
        assert "required checks unavailable: fixture checks unavailable" in observed.blockers
        assert "mergeable UNAVAILABLE" in observed.printed
        # A head with checks still running proves nothing yet.
        self.push("f" * 40)
        self.update(pr_mergeable="MERGEABLE", checks_error="")
        self.update(checks=[check("checks", "pending", 2), check("release", "pass", 2)])
        assert "check:CI/checks is pending" in self.observe().blockers

    def test_head_change_during_the_read_is_refused(self) -> None:
        self.update(pr_mergeable="CONFLICTING", head_after_checks="d" * 40)
        moved = f"headRefOid changed from {self.head} to {'d' * 40} during the read"
        with self.assertRaisesRegex(pr_review.RefusalError, re.escape(moved)):
            self.observe()
        # The base moves while the head stays: refused the same way.
        self.update(base_after_checks="c" * 40)
        moved = f"baseRefOid changed from {'b' * 40} to {'c' * 40} during the read"
        with self.assertRaisesRegex(pr_review.RefusalError, re.escape(moved)):
            self.observe()

    def test_a_head_other_than_the_handed_off_one_is_refused(self) -> None:
        # turn read head 0...0 from the PR, then the PR moved before its state was read.
        expected = "0" * 40
        pr = PullRequest("7", "https://github.com/o/r/pull/7", expected, ["29"])
        moved = f"PR 7 moved from {expected} to {self.head}; nothing sent"
        with self.assertRaisesRegex(RuntimeError, re.escape(moved)):
            team.observe_pr(pr)

    def test_configured_required_checks_decide_readiness(self) -> None:
        reviews = [review("tester", self.head, n=1), review("critic", self.head, n=2)]
        # Configured and reported: a failed optional check is only shown.
        passing = [check("checks", "pass"), check("release", "pass")]
        self.update(reviews=reviews, checks=[*passing, check("dexter", "fail")])
        printed = self.observe(ready=True).printed
        assert "optional check:CI/dexter fail https://ci/1" in printed
        # Configured but not reported yet: unavailable, so never ready.
        self.update(checks=[check("checks", "pass")])
        assert "required check release not reported" in self.observe().blockers
        # No required checks configured: readiness follows mergeability and reviews.
        self.update(required=[], checks=[check("dexter", "fail")])
        assert "no required checks configured" in self.observe(ready=True).printed

    def test_only_current_head_lgtms_from_every_required_reviewer_allow_merge(self) -> None:
        old = self.head
        self.update(reviews=[review("tester", old, n=1), review("critic", old, n=2)])
        new = self.push("e" * 40)
        observed = self.observe()
        assert f"tester has not reviewed head {new}" in observed.blockers
        assert f"critic has not reviewed head {new}" in observed.blockers
        reviews = [review("tester", new, n=3), review("critic", new, "Findings: P1", n=4)]
        # A draft LGTM is not submitted, so it never replaces the submitted findings.
        reviews.append(review("critic", new, n=5, state="PENDING"))
        self.update(reviews=reviews, reviewThreads=[{"isResolved": False}])
        observed = self.observe()
        assert "critic's latest review of this head has findings" in observed.blockers
        assert "1 unresolved review threads" in observed.blockers
        reviews.append(review("critic", new, n=6))
        self.update(reviews=reviews, reviewThreads=[{"isResolved": True}])
        assert f"head {new}" in self.observe(ready=True).printed
        # A binding decision can invalidate acceptance without changing the code SHA.
        reviews.append(review("tester", new, "Hold: pending decision", n=7))
        self.update(reviews=reviews)
        assert "tester's latest review of this head has findings" in self.observe().blockers


class ObserveCommandTest(Harness):
    """The one observe through a started pair: the caller's record supplies the brief the
    PR must close and the required reviewers."""

    def test_observe_requires_the_callers_brief_and_its_reviewers(self) -> None:
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

        self.update(pr_briefs={"7": ["30"]}, checks=[check("checks", "fail")])
        assert "PR 7 does not close brief #29" in observe(ok=False).stderr
        # Brief 29 requires tester and critic; a failed check blocks and is not posted.
        self.update(pr_briefs={"7": ["29"]})
        refused = observe(ok=False).stderr
        assert "not ready to merge" in refused
        assert "check:CI/checks is fail: https://ci/1" in refused
        assert f"tester has not reviewed head {head}" in refused
        assert f"critic has not reviewed head {head}" in refused
        assert self.comments("7") == []
        reviews = [review("tester", head, n=1), review("critic", head, n=2)]
        passing = [check("checks", "pass", 2), check("release", "pass", 2)]
        self.update(reviews=reviews, checks=passing)
        assert f"ready to merge at {head}" in observe(ok=True).stdout


class HandoffTest(FakeGhTest):
    """handoff prints the PR only after the reviewer's own concerns name its head."""

    def setUp(self) -> None:
        super().setUp()
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.concerns = Path(directory.name) / "concerns.md"
        self.update(pr_body="## Outcome\nImplementer's account of the change.")

    def handoff(self, head: str = HEAD) -> str:
        printed = io.StringIO()
        with contextlib.redirect_stdout(printed):
            pr_review.handoff(head, self.concerns)
        return printed.getvalue()

    def refused(self, head: str = HEAD) -> str:
        with self.assertRaises(pr_review.RefusalError) as raised:
            self.handoff(head)
        return str(raised.exception)

    def test_the_body_waits_for_a_concerns_file_that_names_the_head(self) -> None:
        assert "write your concerns to" in self.refused()
        assert "No such file" in self.refused()
        self.concerns.write_text("")
        assert f"does not name head {HEAD[:7]}" in self.refused()
        self.concerns.write_text(f"head {'c' * 40}\n- old concern\n")
        assert f"does not name head {HEAD[:7]}" in self.refused(), "a stale file is not consent"
        assert not self.events("gh", "api"), "the PR was read before the concerns existed"
        self.concerns.write_text(f"head {HEAD[:7]}\n- the diff drops the origin reset\n")
        out = self.handoff()
        assert out.startswith(f"PR https://github.com/o/r/pull/7 head {HEAD} base main\n")
        assert "--- PR body ---\n## Outcome\nImplementer's account of the change.\n" in out
        assert f"--- reviews ---\nhead {HEAD}\n" in out

    def test_the_handed_off_head_must_be_the_one_open_pr_head(self) -> None:
        self.concerns.write_text(f"head {HEAD}\n")
        assert "not a full head SHA" in self.refused(HEAD[:7])
        self.update(pr_head="0" * 40)
        assert f"No open PR has head {HEAD}" in self.refused()
        other = {
            "number": 8,
            "state": "open",
            "html_url": "https://github.com/o/r/pull/8",
            "head": {"sha": HEAD},
            "base": {"ref": "main"},
            "body": "",
        }
        self.update(pr_head=HEAD, pulls=[other])
        assert f"PRs 7, 8 share head {HEAD}" in self.refused()
        self.update(pulls=[{**other, "state": "closed"}])
        assert "pull/7" in self.handoff(), "a closed PR at the head does not count"

    def test_it_shows_the_recent_reviews_and_threads_after_the_body(self) -> None:
        self.concerns.write_text(f"{HEAD}\n")
        self.update(reviews=[review("critic", HEAD, "Findings: P1 lost write")])
        out = self.handoff()
        assert (
            out.index("--- PR body ---") < out.index("--- reviews ---") < out.index("P1 lost write")
        )


class ListTest(FakeGhTest):
    def test_list_shows_the_last_two_reviewed_heads_and_each_thread_with_its_replies(
        self,
    ) -> None:
        heads = ["1" * 40, "2" * 40, self.head]
        verdicts = ["Findings: oldest head", "Findings: P1 middle head", "LGTM"]
        reviews = [
            review("critic", head, verdict, n=n)
            for n, (head, verdict) in enumerate(zip(heads, verdicts, strict=True), start=1)
        ]
        comment = {"databaseId": 11, "body": "P1: fix it", "pullRequestReview": reviews[1]}
        reply = {"databaseId": 12, "body": "Fixed.\nSee the test.", "pullRequestReview": None}
        thread = {"id": "T_1", "isResolved": False, "path": "a.ex", "line": 3}
        nodes = {"totalCount": 2, "nodes": [comment, reply]}
        self.update(reviews=reviews, reviewThreads=[{**thread, "comments": nodes}])
        printed = io.StringIO()
        with contextlib.redirect_stdout(printed):
            pr_review.show(7, every_head=False)
        out = printed.getvalue()
        assert "Findings: oldest head" not in out, f"the oldest head's review is shown:\n{out}"
        assert "Findings: P1 middle head" in out, f"the previous head's review is missing:\n{out}"
        assert f"review {reviews[2]['url']} {self.head[:7]}\nLGTM" in out, f"latest missing:\n{out}"
        assert "thread T_1 reply-to 11 a.ex:3 by critic\n" in out, f"thread owner wrong:\n{out}"
        assert "\n> Fixed.\n> See the test.\n" in out, f"the reply is not quoted:\n{out}"


if __name__ == "__main__":
    unittest.main()
