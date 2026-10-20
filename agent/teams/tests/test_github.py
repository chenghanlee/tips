"""Issue comments are read page by page until a short page; a truncated read raises."""

import json
import tomllib
import unittest
from collections.abc import Sequence
from typing import cast
from unittest import mock

import config as conf
import github
from config import READ_PAGES
from tests.harness import CONFIG


def comment(n: int, body: str) -> dict[str, object]:
    return {"id": n, "html_url": f"https://github.com/o/r/issues/29#issuecomment-{n}", "body": body}


def filler(count: int) -> list[dict[str, object]]:
    return [comment(n, f"QUESTION impl team-1-impl s\nfiller {n}") for n in range(1, count + 1)]


class CommentPagesTest(unittest.TestCase):
    """github.post_comment on brief 29 through a patched gh call that serves its comments
    100 per page, as GitHub does."""

    def setUp(self) -> None:
        self.enterContext(mock.patch.object(conf, "cfg", cast(conf.Config, tomllib.loads(CONFIG))))
        self.issue: list[dict[str, object]] = []
        self.pages: list[int] = []
        self.posted: list[str] = []
        self.enterContext(mock.patch.object(github, "github", self.gh))

    def gh(self, args: Sequence[str], deadline: float, label: str, input_text: str = "") -> str:
        if args[:2] == ["gh", "issue"]:
            self.posted.append(input_text)
            return "https://github.com/o/r/issues/29#issuecomment-new"
        assert args[:2] == ["gh", "api"], f"unexpected gh call {args}"
        page = int(args[2].rsplit("page=", 1)[1])
        self.pages.append(page)
        return json.dumps(self.issue[(page - 1) * 100 : page * 100])

    def test_a_comment_on_the_second_page_is_found_and_not_posted_again(self) -> None:
        self.issue = [*filler(149), comment(150, "EVENT tester team-1-tester s\nlaunched")]
        url = github.post_comment("29", "EVENT tester team-1-tester s\nlaunched")
        assert self.pages == [1, 2], f"150 comments must be read as two pages, read {self.pages}"
        assert url == self.issue[149]["html_url"], f"page-2 comment missed: {url}"
        assert self.posted == [], f"a duplicate was posted: {self.posted}"

    def test_a_history_longer_than_the_read_limit_is_refused(self) -> None:
        limit = READ_PAGES * 100
        self.issue = filler(limit)
        with self.assertRaisesRegex(RuntimeError, f"over {limit} comments; read incomplete"):
            github.post_comment("29", "EVENT tester team-1-tester s\nlaunched")
        assert self.pages == list(range(1, READ_PAGES + 1)), f"pages read: {self.pages}"
        assert self.posted == [], f"posted after an incomplete read: {self.posted}"


if __name__ == "__main__":
    unittest.main()
