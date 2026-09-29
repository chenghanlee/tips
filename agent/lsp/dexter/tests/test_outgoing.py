"""outgoing-calls: source call sites from Elixir's public parser, each prepared by Dexter."""

import tempfile
import unittest
from functools import partial
from pathlib import Path
from typing import Any, cast
from unittest.mock import patch

from agent.lsp.dexter.dexter_client import outgoing
from agent.lsp.dexter.dexter_client.protocol import JsonObject, Session
from agent.lsp.dexter.dexter_client.workflows import workflow
from agent.lsp.dexter.tests.support import dx_error

FIXTURES = Path(__file__).resolve().parent / "fixtures/sites"
PREPARE = "textDocument/prepareCallHierarchy"

GROUPED = """defmodule Shop.Mail do
  alias Shop.Token

  def check(user) do
    Token.verify(user)
    Token.verify(user, :strict)
    :crypto.strong_rand_bytes(8)
    Token.verify(user)
  end
end
"""


class StubSession:
    """Answers prepare like Dexter at known call positions only; records every request."""

    def __init__(self, answers: dict[tuple[int, int], list[JsonObject] | None]) -> None:
        self.timeout = 60.0
        self.answers = answers
        self.requests: list[tuple[str, JsonObject]] = []

    def request(self, method: str, params: JsonObject) -> Any:
        self.requests.append((method, params))
        if method != PREPARE:
            raise AssertionError(f"Unexpected request {method}")
        position = params["position"]
        key = (position["line"], position["character"])
        if key not in self.answers:
            raise AssertionError(f"prepare at {key} is not a call site")
        return self.answers[key]


def span(line: int, character: int, name: str) -> JsonObject:
    """Zero-based range over an ASCII call name."""
    return {
        "start": {"line": line, "character": character},
        "end": {"line": line, "character": character + len(name)},
    }


class OutgoingCalls(unittest.TestCase):
    def setUp(self) -> None:
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.root = Path(temp.name).resolve() / "repo"
        (self.root / "lib").mkdir(parents=True)
        # Fixtures are stored as .txt so no index reads them; install real source files.
        for name in ("accounts.ex", "unicode.ex", "broken.ex"):
            (self.root / "lib" / name).write_bytes((FIXTURES / f"{name}.txt").read_bytes())
        (self.root / "lib/mail.ex").write_text(GROUPED)

    def item(self, name: str, module: str, function: str) -> JsonObject:
        anchor = {"start": {"line": 0, "character": 0}, "end": {"line": 0, "character": 0}}
        return {
            "name": name,
            "kind": 12,
            "detail": "def",
            "uri": (self.root / "lib/target.ex").as_uri(),
            "range": anchor,
            "selectionRange": anchor,
            "data": {"module": module, "function": function},
        }

    def outgoing(self, session: StubSession, file: str, line: int, report: JsonObject) -> Any:
        params: JsonObject = {"file": file, "line": line, "column": 1}
        return workflow(cast(Session, session), self.root, "outgoing-calls", params, report, {})

    def test_default_head_query_prepares_every_admit_clause_site(self) -> None:
        normalize = self.item("Shop.Token.normalize/1", "Shop.Token", "normalize")
        call = self.item("GenServer.call/2", "GenServer", "call")
        # Erlang calls prepare to nothing and are counted, not reported as targets.
        session = StubSession({(22, 23): [normalize], (24, 13): None, (25, 16): [call]})
        report: JsonObject = {}
        result = self.outgoing(session, "lib/accounts.ex", 20, report)

        uri = (self.root / "lib/accounts.ex").as_uri()
        assert session.requests == [
            (PREPARE, {"textDocument": {"uri": uri}, "position": {"line": line, "character": c}})
            for line, c in ((22, 23), (24, 13), (25, 16))
        ]
        assert result == [
            {"to": normalize, "fromRanges": [span(22, 23, "normalize")]},
            {"to": call, "fromRanges": [span(25, 16, "call")]},
        ]
        assert report["caller"] == {"module": "Shop.Accounts", "name": "admit", "arity": 3}
        assert report["clauses"] == [{"line": 20, "end_line": 20}, {"line": 22, "end_line": 30}]
        assert report["unresolved_count"] == 1

    def test_identical_items_group_and_other_arities_stay_apart(self) -> None:
        # Same data and anchor; only the prepared arity differs.
        verify1 = self.item("Shop.Token.verify/1", "Shop.Token", "verify")
        verify2 = self.item("Shop.Token.verify/2", "Shop.Token", "verify")
        session = StubSession(
            {(4, 10): [verify1], (5, 10): [verify2], (6, 12): [], (7, 10): [verify1]}
        )
        report: JsonObject = {}
        result = self.outgoing(session, "lib/mail.ex", 5, report)

        assert [method for method, _ in session.requests] == [PREPARE] * 4
        assert result == [
            {"to": verify1, "fromRanges": [span(4, 10, "verify"), span(7, 10, "verify")]},
            {"to": verify2, "fromRanges": [span(5, 10, "verify")]},
        ]
        assert report["caller"] == {"module": "Shop.Mail", "name": "check", "arity": 1}
        assert report["unresolved_count"] == 1

    def test_function_without_calls_is_an_empty_list_without_requests(self) -> None:
        session, report = StubSession({}), cast(JsonObject, {})
        result = self.outgoing(session, "lib/accounts.ex", 45, report)

        assert result == []
        assert session.requests == []
        assert report["caller"] == {"module": "Shop.Accounts", "name": "version", "arity": 0}
        assert report["clauses"] == [{"line": 45, "end_line": 45}]
        assert report["unresolved_count"] == 0

    def test_positions_and_ranges_are_utf16(self) -> None:
        build = self.item("Shop.Token.build/2", "Shop.Token", "build")
        foo = self.item("Shop.Unicode.foo/1", "Shop.Unicode", "foo")
        session = StubSession({(2, 30): [build], (6, 20): [foo]})

        assert self.outgoing(session, "lib/unicode.ex", 3, {}) == [
            {"to": build, "fromRanges": [span(2, 30, "build")]}
        ]
        # One ZWJ family grapheme is eight UTF-16 units.
        assert self.outgoing(session, "lib/unicode.ex", 7, {}) == [
            {"to": foo, "fromRanges": [span(6, 20, "foo")]}
        ]

    def test_parser_failures_send_no_prepare(self) -> None:
        # An alias line, a blank line between functions, and a file that does not parse.
        for file, line in (("lib/accounts.ex", 2), ("lib/accounts.ex", 19), ("lib/broken.ex", 2)):
            with self.subTest(file=file, line=line):
                session, report = StubSession({}), cast(JsonObject, {})
                error = dx_error(partial(self.outgoing, session, file, line, report))

                assert error.kind == "outgoing_parser"
                assert session.requests == []
                assert "caller" not in report

    def test_source_change_during_parse_rejects_the_result(self) -> None:
        path = self.root / "lib/mail.ex"
        parse = outgoing.parse_sites

        def parse_then_edit(*args: Any) -> JsonObject:
            parsed = parse(*args)
            path.write_text(path.read_text() + "\n")
            return parsed

        verify = self.item("Shop.Token.verify/1", "Shop.Token", "verify")
        session = StubSession(
            {(4, 10): [verify], (5, 10): [verify], (6, 12): [], (7, 10): [verify]}
        )
        report: JsonObject = {}
        with patch.object(outgoing, "parse_sites", parse_then_edit):
            error = dx_error(lambda: self.outgoing(session, "lib/mail.ex", 4, report))

        assert error.kind == "changed_base"
        assert "result" not in report
