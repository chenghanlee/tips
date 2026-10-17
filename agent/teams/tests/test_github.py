"""Issue comments are read page by page until a short page; a truncated read raises."""

import json
import tomllib
import unittest
from collections.abc import Sequence
from typing import cast
from unittest import mock

import config as conf
import github
from config import READ_PAGES, RETIREMENT, Record
from tests.harness import CONFIG

LAUNCH = "launch-1"


def comment(n: int, body: str) -> dict[str, object]:
    return {"id": n, "html_url": f"https://github.com/o/r/issues/29#issuecomment-{n}", "body": body}


def filler(count: int) -> list[dict[str, object]]:
    return [comment(n, "QUESTION impl team-1-impl s\nfiller") for n in range(1, count + 1)]


def report(n: int, line: str) -> dict[str, object]:
    return comment(n, f"EVENT tester team-1-tester session-1\n{RETIREMENT}{line}")


class CommentPagesTest(unittest.TestCase):
    """github.retirement_reports reads brief 29's comments through a patched gh call that
    serves them 100 per page, as GitHub does."""

    def setUp(self) -> None:
        self.enterContext(mock.patch.object(conf, "cfg", cast(conf.Config, tomllib.loads(CONFIG))))
        self.issue: list[dict[str, object]] = []
        self.pages: list[int] = []
        self.enterContext(mock.patch.object(github, "github", self.gh))

    def gh(self, args: Sequence[str], deadline: float, label: str, input_text: str = "") -> str:
        assert args[:2] == ["gh", "api"], f"unexpected gh call {args}"
        page = int(args[2].rsplit("page=", 1)[1])
        self.pages.append(page)
        return json.dumps(self.issue[(page - 1) * 100 : page * 100])

    def reports(self) -> dict[str, tuple[dict[str, object], str]]:
        agent = {"id": "t1g1r", "launch": LAUNCH}
        record = {"brief": "29", "agents": {"tester": agent}}
        return github.retirement_reports(cast(Record, record))

    def test_a_report_on_the_second_page_is_found_and_a_malformed_one_skipped(self) -> None:
        self.issue = filler(148)
        fields = {"id": "t1g1r", "launch": LAUNCH, "clean": True}
        self.issue += [report(149, json.dumps(fields)), report(150, "{not json")]
        reports = self.reports()
        assert self.pages == [1, 2], f"150 comments must be read as two pages, read {self.pages}"
        found = reports.get("t1g1r")
        assert found == (fields, self.issue[148]["html_url"]), f"page-2 report missed: {reports}"

    def test_a_history_longer_than_the_read_limit_is_refused(self) -> None:
        limit = READ_PAGES * 100
        self.issue = filler(limit)
        with self.assertRaisesRegex(RuntimeError, f"over {limit} comments; read incomplete"):
            self.reports()
        assert self.pages == list(range(1, READ_PAGES + 1)), f"pages read: {self.pages}"


if __name__ == "__main__":
    unittest.main()
