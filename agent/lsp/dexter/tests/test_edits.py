"""Wide-impact edit coordinate and validation logic; no language-server mocks."""

import tempfile
import unittest
from pathlib import Path

from agent.lsp.dexter.dexter_client import edits as dx
from agent.lsp.dexter.dexter_client.cli import compact_report
from agent.lsp.dexter.dexter_client.protocol import JsonObject
from agent.lsp.dexter.tests.support import dx_error


class Edits(unittest.TestCase):
    def test_compact_output_keeps_every_location_and_actionable_notification(self) -> None:
        location = {
            "uri": "file:///project/lib/a%20b.ex",
            "range": {"start": {"line": 1, "character": 2}, "end": {"line": 3, "character": 4}},
        }
        diagnostics: JsonObject = {
            "method": "textDocument/publishDiagnostics",
            "params": {"diagnostics": []},
        }
        warning = {"method": "window/logMessage", "params": {"type": 2, "message": "warning"}}
        error = {"method": "window/showMessage", "params": {"type": 1, "message": "error"}}
        report: JsonObject = {
            "operation": "references",
            "ok": True,
            "root": "/project",
            "freshness": "unverified",
            "result": [location] * 224,
            "daemon_log": "/fixture/project.log",
            "binary_sha256": "static",
            "notifications": [diagnostics, warning, error, {"method": "client/registerCapability"}],
        }
        compact = compact_report(report)
        assert compact["result"] == ["lib/a b.ex:2:3-4:5"] * 224
        assert compact["notifications"] == [diagnostics, warning, error]
        assert compact["freshness"] == "unverified"
        assert compact["daemon_log"] == report["daemon_log"]
        assert "binary_sha256" not in compact
        assert report["result"][0] == location
        report["ok"] = False
        assert compact_report(report) is report

    def test_utf16_crlf_and_overlaps(self) -> None:
        text = "a😀b\r\nnext\r\n"
        edit = {
            "range": {"start": {"line": 0, "character": 1}, "end": {"line": 0, "character": 3}},
            "newText": "é",
        }
        assert dx.edit_text(text, [edit]) == "aéb\r\nnext\r\n"
        assert dx.offset("a\u2028b\nnext", {"line": 0, "character": 3}) == 3
        assert dx.offset("ab\rc", {"line": 1, "character": 1}) == 4
        dx_error(lambda: dx.offset(text, {"line": 0, "character": 2}))
        dx_error(lambda: dx.edit_text(text, [edit, edit]))

    def test_validate_all_files_before_writing_and_preserve_dirty_base(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp).resolve()
            a, b = root / "a.ex", root / "b.ex"
            a.write_text("dirty a")
            b.write_text("dirty b")
            before = {a: a.read_bytes(), b: b.read_bytes()}
            b.write_text("teammate edit")
            edit = {
                "range": {"start": {"line": 0, "character": 0}, "end": {"line": 0, "character": 0}},
                "newText": "# new\n",
            }
            dx_error(
                lambda: dx.apply_workspace_edit(
                    root, {"changes": {a.as_uri(): [edit], b.as_uri(): [edit]}}, before
                )
            )
            assert a.read_text() == "dirty a"
            assert b.read_text() == "teammate edit"

    def test_resource_order_and_scope(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp).resolve()
            a, b = root / "a.ex", root / "b.ex"
            a.write_text("original")
            edits = {
                "documentChanges": [
                    {"kind": "rename", "oldUri": a.as_uri(), "newUri": b.as_uri()},
                    {
                        "textDocument": {"uri": b.as_uri()},
                        "edits": [
                            {
                                "range": {
                                    "start": {"line": 0, "character": 0},
                                    "end": {"line": 0, "character": 8},
                                },
                                "newText": "updated",
                            }
                        ],
                    },
                ]
            }
            dx.apply_workspace_edit(root, edits, {a: a.read_bytes()})
            assert not a.exists()
            assert b.read_text() == "updated"
            dx_error(lambda: dx.bound_path(root, "../sibling/lib.ex"))


if __name__ == "__main__":
    unittest.main()
