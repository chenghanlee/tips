"""Approval validation, thread reads and the refusal paths that never post a status."""

import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from typing import Any

from pr_review import RefusalError
from publish_review import approval_problem, review_api_path
from team import execute

TEAMS = Path(__file__).resolve().parents[1]
PR = "https://github.com/o/tips/pull/7"
RECORD = PR + "#pullrequestreview-5"
SHA = "a" * 40
FAKE_GH = r"""#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
a = sys.argv[1:]
with Path(os.environ["FAKE_GH_LOG"]).open("a") as stream:
    stream.write(json.dumps(a) + "\n")
fake = json.loads(os.environ["FAKE_GH"])
query = next((arg for arg in a if arg.startswith("query=")), "")
if a[:2] == ["pr", "view"]:
    print(json.dumps({"headRefOid": fake["head"], "url": "https://github.com/o/tips/pull/7"}))
elif a[:2] == ["pr", "comment"]:
    print("https://github.com/o/tips/pull/7#issuecomment-99")
elif "resolveReviewThread" in query:
    print(json.dumps({"data": {"resolveReviewThread": {"thread": {"isResolved": True}}}}))
elif query:
    name = "reviewThreads" if "reviewThreads" in query else "reviews"
    page = next((int(arg[len("after="):]) for arg in a if arg.startswith("after=")), 0)
    pages = fake[name]
    if pages == "broken":
        print(json.dumps({"data": {"repository": None}}))
        sys.exit(0)
    info = {"hasNextPage": page + 1 < len(pages), "endCursor": str(page + 1)}
    nodes = pages[page] if pages else []
    connection = {"pageInfo": info, "nodes": nodes}
    print(json.dumps({"data": {"repository": {"pullRequest": {name: connection}}}}))
elif a[:1] == ["api"] and "--method" not in a:
    print(json.dumps(fake["review"]))
"""


def review(**changes: Any) -> dict[str, Any]:
    base = {"state": "COMMENTED", "commit_id": SHA, "body": "LGTM\nteam-1-lead, session abc"}
    return {**base, **changes}


def thread(resolved: bool, path: str = "lib/a.ex", comments: int = 1) -> dict[str, Any]:
    opened = {"url": RECORD}
    nodes = [
        {"databaseId": 40 + n, "body": f"comment {n}", "pullRequestReview": opened}
        for n in range(comments)
    ]
    return {
        "id": "T_" + path,
        "isResolved": resolved,
        "path": path,
        "line": 12,
        "originalLine": 12,
        "comments": {"totalCount": comments, "nodes": nodes},
    }


Result = tuple[subprocess.CompletedProcess[str], list[Any]]


def listed(number: int, state: str, body: str, oid: str = SHA) -> dict[str, Any]:
    url = f"{PR}#pullrequestreview-{number}"
    return {"databaseId": number, "state": state, "body": body, "url": url, "commit": {"oid": oid}}


def run(script: str, *args: str, **fake: Any) -> Result:
    """Run one script against a fake gh; return its result and the gh calls it made."""
    defaults: dict[str, Any] = {"head": SHA, "review": review(), "reviewThreads": [], "reviews": []}
    state = {**defaults, **fake}
    with tempfile.TemporaryDirectory() as tmp:
        gh = Path(tmp) / "gh"
        gh.write_text(FAKE_GH)
        gh.chmod(0o755)
        log = Path(tmp) / "log"
        env = dict(
            os.environ,
            PATH=tmp + os.pathsep + os.environ["PATH"],
            FAKE_GH_LOG=str(log),
            FAKE_GH=json.dumps(state),
        )
        result = execute([sys.executable, str(TEAMS / script), *args], env=env)
        calls = [json.loads(line) for line in log.read_text().splitlines()] if log.exists() else []
        return result, calls


def publish(*source: str, **fake: Any) -> Result:
    record = source or ("--record", RECORD)
    return run("publish_review.py", "--pr", "7", "--sha", SHA, *record, **fake)


def posts(calls: list[Any]) -> list[Any]:
    return [call for call in calls if "--method" in call]


class ApprovalTest(unittest.TestCase):
    def test_lgtm_on_the_head_with_a_reviewer_line_is_an_approval(self) -> None:
        assert approval_problem(review(), SHA) is None
        scoped = review(state="APPROVED", body="LGTM\nlead\nScope: docs")
        assert approval_problem(scoped, SHA) is None

    def test_each_defect_is_named(self) -> None:
        cases = {
            "state": review(state="PENDING"),
            "not the reviewed": review(commit_id="b" * 40),
            "only LGTM": review(body="LGTM, nice work\nteam-1-lead"),
            "role and session": review(body="LGTM"),
        }
        for expected, candidate in cases.items():
            problem = approval_problem(candidate, SHA)
            assert problem is not None, expected
            assert expected in problem, (expected, problem)
        assert approval_problem(review(state="CHANGES_REQUESTED"), SHA) is not None
        assert approval_problem(review(body=None), SHA) is not None

    def test_review_links_map_to_rest_paths(self) -> None:
        assert review_api_path(RECORD) == "repos/o/tips/pulls/7/reviews/5"
        elsewhere = "https://example.com/o/tips/pull/7#pullrequestreview-5"
        for link in (PR, PR + "#issuecomment-1", elsewhere):
            try:
                review_api_path(link)
            except RefusalError:
                continue
            self.fail(f"accepted {link}")


class PublishTest(unittest.TestCase):
    def test_approval_with_resolved_threads_posts_once(self) -> None:
        result, calls = publish(reviewThreads=[[thread(True)], [thread(True, "lib/b.ex")]])
        assert result.returncode == 0, result.stderr
        assert len(posts(calls)) == 1
        assert f"repos/o/tips/statuses/{SHA}" in posts(calls)[0]
        assert "context=tips/independent-review" in posts(calls)[0]
        assert f"target_url={RECORD}" in posts(calls)[0]

    def test_refusals_never_post_a_status(self) -> None:
        second_page_open = [[thread(True)], [thread(False, "lib/b.ex")]]
        cases: dict[str, dict[str, Any]] = {
            "PR head": {"head": "b" * 40},
            "only LGTM": {"review": review(body="Looks fine")},
            "state": {"review": review(state="PENDING")},
            "not the reviewed": {"review": review(commit_id="b" * 40)},
            "1 unresolved review threads: lib/a.ex:12": {"reviewThreads": [[thread(False)]]},
            "unresolved review threads: lib/b.ex:12": {"reviewThreads": second_page_open},
            "incomplete reviewThreads": {"reviewThreads": "broken"},
        }
        for expected, fake in cases.items():
            result, calls = publish(**fake)
            assert result.returncode != 0, expected
            assert expected in result.stderr, (expected, result.stderr)
            assert posts(calls) == [], expected

    def test_long_resolved_thread_does_not_block_publication(self) -> None:
        long = thread(True)
        long["comments"]["totalCount"] = 101
        result, calls = publish(reviewThreads=[[long]])
        assert result.returncode == 0, result.stderr
        assert len(posts(calls)) == 1

    def test_record_from_another_pull_request_is_refused(self) -> None:
        other = "https://github.com/o/tips/pull/8#pullrequestreview-5"
        result, calls = publish("--record", other)
        assert result.returncode != 0
        assert "does not belong" in result.stderr
        assert posts(calls) == []

    def test_owner_waiver_posts_comment_then_status_without_a_record(self) -> None:
        result, calls = publish("--owner-waiver", "docs-only process change")
        assert result.returncode == 0, result.stderr
        assert calls[0][:2] == ["pr", "view"]
        assert calls[1][:2] == ["pr", "comment"]
        assert "Owner waiver" in calls[1][4]
        assert len(posts(calls)) == 1
        assert f"target_url={PR}#issuecomment-99" in posts(calls)[0]
        assert "description=Owner waiver: independent review skipped" in posts(calls)[0]

    def test_owner_waiver_needs_a_reason_and_matching_head(self) -> None:
        result, calls = publish("--owner-waiver", "short")
        assert result.returncode != 0
        assert "reason" in result.stderr
        assert calls == []
        result, calls = publish("--owner-waiver", "docs-only process change", head="b" * 40)
        assert result.returncode != 0
        assert "PR head" in result.stderr
        assert not any(call[:2] == ["pr", "comment"] for call in calls)


class ThreadReadTest(unittest.TestCase):
    def test_list_prints_reviews_and_unresolved_threads_with_their_reviewer(self) -> None:
        reviews = [
            listed(2, "COMMENTED", ""),
            listed(3, "PENDING", "draft"),
            listed(5, "COMMENTED", "team-1-test, session t\nGeneral: split the module."),
            listed(6, "COMMENTED", "LGTM\nteam-1-lead, session l"),
        ]
        mine = thread(False, "lib/open.ex", comments=2)
        theirs = thread(False, "lib/lead.ex")
        theirs["comments"]["nodes"][0]["pullRequestReview"] = {"url": PR + "#pullrequestreview-6"}
        theirs["comments"]["totalCount"] = 3
        threads = [[thread(True, "lib/done.ex")], [mine, theirs]]
        result, _ = run("pr_review.py", "list", "7", reviews=[reviews], reviewThreads=threads)
        assert result.returncode == 0, result.stderr
        out = result.stdout
        assert out.startswith(f"head {SHA}\n")
        assert f"review {RECORD} aaaaaaa\nteam-1-test, session t\nGeneral: split" in out
        for absent in ("draft", "pullrequestreview-2", "lib/done.ex"):
            assert absent not in out, absent
        open_thread = "thread T_lib/open.ex reply-to 40 lib/open.ex:12 by team-1-test, session t"
        assert open_thread + "\ncomment 0\n> comment 1" in out
        assert "lib/lead.ex:12 by team-1-lead, session l\ncomment 0\n> (2 later replies" in out

    def test_body_feedback_on_the_previous_head_stays_visible_after_a_push(self) -> None:
        reviews = [
            listed(1, "COMMENTED", "oldest head", "c" * 40),
            listed(4, "COMMENTED", "Required: rethink the lock order.", "b" * 40),
        ]
        after_push, _ = run("pr_review.py", "list", "7", reviews=[reviews])
        assert "rethink the lock order" in after_push.stdout
        assert "oldest head" in after_push.stdout
        reviews.append(listed(5, "COMMENTED", "LGTM\nteam-1-test, session t"))
        reviewed, _ = run("pr_review.py", "list", "7", reviews=[reviews])
        assert "rethink the lock order" in reviewed.stdout
        assert "oldest head" not in reviewed.stdout
        every, _ = run("pr_review.py", "list", "7", "--all", reviews=[reviews])
        assert "oldest head" in every.stdout

    def test_incomplete_answer_is_an_error_not_an_empty_list(self) -> None:
        result, _ = run("pr_review.py", "list", "7", reviews="broken")
        assert result.returncode != 0
        assert "incomplete reviews" in result.stderr

    def test_resolve_sends_the_thread_id(self) -> None:
        result, calls = run("pr_review.py", "resolve", "T_1")
        assert result.returncode == 0, result.stderr
        assert result.stdout.strip() == "resolved T_1"
        assert "id=T_1" in calls[0]
