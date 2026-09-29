"""incoming-calls: Dexter reference lines owned by source blocks from Elixir's public parser."""

import hashlib
import tempfile
import unittest
from pathlib import Path
from typing import Any, cast
from unittest.mock import patch

from agent.lsp.dexter.dexter_client import incoming
from agent.lsp.dexter.dexter_client.protocol import JsonObject, Session
from agent.lsp.dexter.dexter_client.workflows import workflow
from agent.lsp.dexter.tests.support import dx_error

FIXTURES = Path(__file__).resolve().parent / "fixtures/owners"
PREPARE, REFERENCES = "textDocument/prepareCallHierarchy", "textDocument/references"


class StubSession:
    """Answers like pinned Dexter for one prepared item and its references; records requests."""

    def __init__(self, items: list[JsonObject], references: list[JsonObject]) -> None:
        self.timeout = 60.0
        self.items, self.references = items, references
        self.requests: list[tuple[str, JsonObject]] = []

    def request(self, method: str, params: JsonObject) -> Any:
        self.requests.append((method, params))
        if method == PREPARE:
            return self.items
        if method == REFERENCES:
            return self.references
        raise AssertionError(f"Unexpected request {method}")


def by_line(entries: list[JsonObject]) -> dict[tuple[str, int], JsonObject]:
    return {(entry["path"].rsplit("/", 1)[-1], entry["line"]): entry for entry in entries}


class IncomingCalls(unittest.TestCase):
    def setUp(self) -> None:
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.root = Path(temp.name).resolve() / "repo"
        (self.root / "lib").mkdir(parents=True)
        (self.root / "lib/admission.ex").write_text(
            "defmodule MyApp.Admission do\n  def admit(x), do: x\nend\n"
        )
        (self.root / "test").mkdir()
        # Fixtures are stored as .txt so no index reads them; install real source files.
        for stored, target in (
            *((f"four_call/{name}_test.exs", f"test/{name}_test.exs") for name in "abc"),
            ("aliased_test.exs", "test/aliased_test.exs"),
            ("rejects.ex", "lib/rejects.ex"),
        ):
            (self.root / target).write_bytes((FIXTURES / f"{stored}.txt").read_bytes())
        start = {"line": 1, "character": 6}
        self.item: JsonObject = {
            "name": "MyApp.Admission.admit/1",
            "kind": 12,
            "detail": "def",
            "uri": (self.root / "lib/admission.ex").as_uri(),
            "range": {"start": {"line": 1, "character": 0}, "end": {"line": 2, "character": 0}},
            "selectionRange": {"start": start, "end": {"line": 1, "character": 11}},
            "data": {"module": "MyApp.Admission", "function": "admit"},
        }

    def ref(self, path: Path | str, line: int, column: int = 5) -> JsonObject:
        uri = path.as_uri() if isinstance(path, Path) else (self.root / path).as_uri()
        start = {"line": line - 1, "character": column - 1}
        return {"uri": uri, "range": {"start": start, "end": {**start, "character": column + 4}}}

    def incoming(self, session: StubSession, report: JsonObject) -> Any:
        params: JsonObject = {"file": "lib/admission.ex", "line": 2, "column": 7}
        return workflow(cast(Session, session), self.root, "incoming-calls", params, report, {})

    def owners(self, result: Any) -> dict[tuple[str, int], JsonObject]:
        return {key: site["owner"] for key, site in by_line(result["sites"]).items()}

    def test_test_block_callers_resolve_from_one_references_request(self) -> None:
        refs = [
            self.ref("test/a_test.exs", 5),
            self.ref("test/b_test.exs", 9),
            self.ref("test/b_test.exs", 13),
            self.ref("test/c_test.exs", 5),
        ]
        session, report = StubSession([self.item], refs), cast(JsonObject, {})
        result = self.incoming(session, report)

        assert result["unavailable"] == []
        expected = {
            ("a_test.exs", 5): {"kind": "test", "module": "MyApp.ATest", "name": "a1"},
            ("b_test.exs", 9): {"kind": "test", "module": "MyApp.BTest", "name": "b1"},
            ("b_test.exs", 13): {"kind": "setup", "module": "MyApp.BTest"},
            ("c_test.exs", 5): {"kind": "test", "module": "MyApp.CTest", "name": "c1"},
        }
        owners = self.owners(result)
        assert owners.keys() == expected.keys()
        for key, fields in expected.items():
            assert fields.items() <= owners[key].items(), (key, owners[key])

        assert [method for method, _ in session.requests] == [PREPARE, REFERENCES]
        assert session.requests[1][1] == {
            "textDocument": {"uri": self.item["uri"]},
            "position": self.item["selectionRange"]["start"],
            "context": {"includeDeclaration": False},
        }
        assert report["result_kind"] == "source_call_owners_at_indexed_reference_lines"
        assert report["positions"] == "1-based source lines; not exact LSP ranges"
        assert report["block_followups"] == "unsupported"
        assert report["upstream_reference_count"] == 4
        files = [self.root / f"test/{name}_test.exs" for name in ("a", "b", "c")]
        assert sorted(report["caller_sources"], key=lambda source: source["path"]) == [
            {"path": str(path), "sha256": hashlib.sha256(path.read_bytes()).hexdigest()}
            for path in files
        ]

    def test_alias_import_and_repeated_references_resolve_once_per_line(self) -> None:
        refs = [
            self.ref("test/aliased_test.exs", 7, 12),
            self.ref("test/aliased_test.exs", 7, 28),
            self.ref("test/aliased_test.exs", 11, 12),
        ]
        report: JsonObject = {}
        result = self.incoming(StubSession([self.item], refs), report)

        assert result["unavailable"] == []
        owners = self.owners(result)
        assert owners.keys() == {("aliased_test.exs", 7), ("aliased_test.exs", 11)}
        assert owners["aliased_test.exs", 7]["name"] == "alias"
        assert owners["aliased_test.exs", 11]["name"] == "import"
        assert report["upstream_reference_count"] == 3

    def test_unsupported_lines_fail_but_keep_the_result(self) -> None:
        outside = self.root.parent / "outside.ex"
        outside.write_text("defmodule Outside do\n  def run, do: MyApp.Admission.admit(1)\nend\n")
        refs = [
            self.ref("lib/rejects.ex", 8),
            self.ref("lib/rejects.ex", 25),
            self.ref(outside, 2),
            self.ref("lib/deleted.ex", 3),
        ]
        report: JsonObject = {}
        error = dx_error(lambda: self.incoming(StubSession([self.item], refs), report))

        assert error.kind == "incoming_unavailable"
        result = report["result"]
        assert self.owners(result).keys() == {("rejects.ex", 25)}
        assert self.owners(result)["rejects.ex", 25]["name"] == "genuine"
        unavailable = by_line(result["unavailable"])
        assert unavailable.keys() == {("rejects.ex", 8), ("outside.ex", 2), ("deleted.ex", 3)}
        assert unavailable["rejects.ex", 8]["reason"]
        assert unavailable["outside.ex", 2]["reason"] == "source_unavailable"
        assert unavailable["deleted.ex", 3]["reason"] == "source_unavailable"
        assert [source["path"] for source in report["caller_sources"]] == [
            str(self.root / "lib/rejects.ex")
        ]

    def test_no_references_is_an_empty_result(self) -> None:
        report: JsonObject = {}
        result = self.incoming(StubSession([self.item], []), report)

        assert result == {"sites": [], "unavailable": []}
        assert report["upstream_reference_count"] == 0

    def test_no_prepared_item_is_a_selection_error(self) -> None:
        session = StubSession([], [self.ref("test/a_test.exs", 5)])
        error = dx_error(lambda: self.incoming(session, {}))

        assert error.kind == "selection"
        assert [method for method, _ in session.requests] == [PREPARE]

    def test_caller_change_during_parse_rejects_the_whole_result(self) -> None:
        path = self.root / "test/b_test.exs"
        parse = incoming.parse_owners

        def parse_then_edit(*args: Any) -> JsonObject:
            parsed = parse(*args)
            path.write_text(path.read_text() + "\n")
            return parsed

        session = StubSession([self.item], [self.ref("test/b_test.exs", 9)])
        report: JsonObject = {}
        with patch.object(incoming, "parse_owners", parse_then_edit):
            error = dx_error(lambda: self.incoming(session, report))

        assert error.kind == "changed_base"
        assert "result" not in report
