"""wait_for_team's read loop with GitHub replaced by an in-memory comment list."""

import json
import time
import unittest
from typing import Any
from unittest import mock

import pending
import team

REQUEST = "BLOCKED implementer team-1-impl s1\nNeed a decision."


def skip(_: float) -> None:
    """Return at once instead of sleeping."""


class WaitTest(unittest.TestCase):
    def setUp(self) -> None:
        self.comments: dict[int, list[dict[str, Any]]] = {29: [], 7: []}
        self.reads: list[str] = []
        self.broken = False
        record: Any = {"brief": "29", "agents": {"critic": {"pr": "7"}}}
        for name, value in (
            ("records", lambda: {1: record}),
            ("repository", lambda: "o/r"),
            ("run", self.serve),
        ):
            patcher = mock.patch.object(team, name, value)
            patcher.start()
            self.addCleanup(patcher.stop)

    def serve(self, *args: str, **_: Any) -> str:
        """Serve `gh api repos/o/r/issues/<n>/comments?per_page=..&page=..`."""
        query = args[2]
        self.reads.append(query)
        if self.broken:
            raise RuntimeError("HTTP 502")
        route, _sep, params = query.partition("?")
        issue = int(route.split("/")[-2])
        fields = dict(pair.split("=") for pair in params.split("&"))
        size, page = int(fields["per_page"]), int(fields["page"])
        return json.dumps(self.comments.get(issue, [])[(page - 1) * size : page * size])

    def add(self, issue: int, body: str) -> int:
        number = sum(len(c) for c in self.comments.values()) + 1
        self.comments.setdefault(issue, []).append({"id": number, "body": body})
        return number

    def test_first_read_is_immediate_and_counts_requests(self) -> None:
        source = self.add(7, REQUEST)
        started = time.monotonic()
        found = pending.wait(300)
        assert time.monotonic() - started < 1
        assert found["result"] == "requests"
        assert found["watched"] == [7, 29]
        assert [r["comment_id"] for r in found["requests"]] == [source]  # type: ignore[index]
        assert found["github_requests"] == 2 == len(self.reads)

    def test_a_request_arriving_during_the_wait_ends_it(self) -> None:
        def arrive(_: float) -> None:
            self.add(29, REQUEST)

        with mock.patch.object(pending.time, "sleep", arrive):
            found = pending.wait(60)
        assert found["result"] == "requests"
        assert found["github_requests"] == 4

    def test_timeout_unavailable_and_incomplete_are_explicit(self) -> None:
        found = pending.wait(0.05, poll=0.01)
        assert found["result"] == "timeout"
        assert found["github_requests"] == len(self.reads) >= 2
        self.broken = True
        found = pending.wait(5)
        assert found == {**found, "result": "unavailable", "github_requests": 1}
        assert "HTTP 502" in str(found["detail"])
        self.broken = False
        self.comments[29] = [{"id": n, "body": "EVENT x y z\nnote"} for n in range(1, 1002)]
        self.reads.clear()
        found = pending.wait(5)
        assert found["result"] == "incomplete"
        assert found["github_requests"] == pending.PAGES + 1 == len(self.reads)

    def test_total_github_requests_are_bounded_whatever_the_wait(self) -> None:
        with (
            mock.patch.object(pending, "REQUEST_BUDGET", 5),
            mock.patch.object(pending.time, "sleep", skip),
        ):
            found = pending.wait(300)
        assert found["result"] == "timeout"
        assert "budget" in str(found["detail"])
        assert found["github_requests"] == 5 == len(self.reads)

    def test_records_decide_by_exact_comment_id(self) -> None:
        first, second = self.add(29, REQUEST), self.add(29, REQUEST.replace("BLOCKED", "DONE"))
        self.add(29, "EVENT dispatcher dispatcher s\nunrelated")
        self.add(29, f"ANSWER dispatcher dispatcher s\nyes\n{pending.marker([first], 'done')}")
        # A worker cannot mark requests handled with a marker under its own header.
        self.add(29, f"DONE implementer team-1-impl s1\n{pending.marker([second], 'done')}")
        found = pending.wait(0)
        ids = [r["comment_id"] for r in found["requests"]]  # type: ignore[index]
        assert second in ids
        assert first not in ids
        assert pending.marker([3, 2, 3], "pending") == (
            'TEAM_ACTION {"v": 1, "sources": [2, 3], "state": "pending"}'
        )
