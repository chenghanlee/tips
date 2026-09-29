"""Real Dexter tests. Set DEXTER_BINARY to the audited build."""

import hashlib
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from typing import Any
from unittest.mock import patch

from agent.lsp.dexter.dexter_client import protocol as dx
from agent.teams.team import execute

DX = Path(__file__).resolve().parents[1] / "dx.py"
BINARY = os.environ.get("DEXTER_BINARY", "")


@unittest.skipUnless(BINARY, "set DEXTER_BINARY to run real-server integration tests")
class StockDexter(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        idle = patch.dict(os.environ, {"DEXTER_DAEMON_IDLE_TIMEOUT": "5s"})
        idle.start()
        cls.addClassCleanup(idle.stop)
        cls.temp = tempfile.TemporaryDirectory(prefix="dx-integration-")
        cls.addClassCleanup(cls.temp.cleanup)
        cls.repo = (Path(cls.temp.name) / "repo").resolve()
        cls.repo.mkdir()
        cls.git(cls.repo, "init", "-q")
        (cls.repo / ".gitignore").write_text(".dexter/\n_build/\ndeps/\n")
        (cls.repo / "mix.exs").write_text(
            "defmodule Fixture.MixProject do\n  use Mix.Project\n"
            '  def project, do: [app: :fixture, version: "0.1.0", elixir: ">= 1.14.0"]\nend\n'
        )
        (cls.repo / "lib").mkdir()
        (cls.repo / "lib/sample.ex").write_text(
            'defmodule Sample do\n  @doc "Original documentation"\n'
            '  def greet(name), do: name\n  def call, do: greet("world")\nend\n'
        )
        cls.git(cls.repo, "add", ".")
        cls.git(
            cls.repo,
            "-c",
            "user.name=Fixture",
            "-c",
            "user.email=fixture@example.invalid",
            "commit",
            "-qm",
            "fixture",
        )
        cls.a, cls.b = [(Path(cls.temp.name) / name).resolve() for name in ("a", "b")]
        cls.git(cls.repo, "worktree", "add", "-q", "-b", "a", str(cls.a))
        cls.git(cls.repo, "worktree", "add", "-q", "-b", "b", str(cls.b))
        for root in (cls.a, cls.b):
            cls.addClassCleanup(execute, [BINARY, "-C", str(root), "stop"])
            execute(
                [
                    sys.executable,
                    str(DX),
                    "--json",
                    "--binary",
                    BINARY,
                    "--root",
                    str(root),
                    "start",
                ],
                input_text="{}",
                check=True,
                timeout=90,
            )

    @staticmethod
    def git(root: Path, *args: str) -> subprocess.CompletedProcess[str]:
        return execute(["git", "-C", str(root), *args], check=True)

    def dx(self, root: Path, op: str, **params: Any) -> dx.JsonObject:
        p = execute(
            [sys.executable, str(DX), "--json", "--binary", BINARY, "--root", str(root), op],
            input_text=json.dumps(params),
            timeout=90,
        )
        assert p.stdout, p.stderr
        data = json.loads(p.stdout)
        assert p.returncode == 0, data
        assert data["freshness"] == "unverified"
        if "frontend_stderr" in data:
            assert Path(data["daemon_log"]).is_file()
            assert data["daemon_log"] in data["frontend_stderr"]
        return data

    def test_saved_atomic_edit_and_worktree_isolation(self) -> None:
        self.dx(self.a, "start")
        self.dx(self.b, "start")
        a = self.dx(self.a, "hover", file="lib/sample.ex", line=3, column=8)
        assert "Original documentation" in json.dumps(a["result"])
        tmp = self.a / "lib/.replace"
        tmp.write_text(
            (self.a / "lib/sample.ex")
            .read_text()
            .replace("Original documentation", "Changed documentation")
        )
        tmp.replace(self.a / "lib/sample.ex")
        changed = self.dx(self.a, "hover", file="lib/sample.ex", line=3, column=8)
        assert "Changed documentation" in json.dumps(changed["result"])
        other = self.dx(self.b, "hover", file="lib/sample.ex", line=3, column=8)
        assert "Original documentation" in json.dumps(other["result"])
        definition = self.dx(self.a, "definition", file="lib/sample.ex", line=4, column=18)
        assert self.a.as_uri() in json.dumps(definition["result"])
        assert self.b.as_uri() not in json.dumps(definition["result"])

    def test_capability_workflows_and_no_disconnect_shutdown(self) -> None:
        caps = self.dx(self.b, "capabilities")["result"]["capabilities"]
        assert caps["renameProvider"]
        for op in (
            "definition",
            "type-definition",
            "declaration",
            "implementation",
            "references",
            "hover",
            "highlights",
            "symbols",
            "signature",
            "folding",
            "prepare-rename",
            "call-hierarchy",
            "incoming-calls",
            "outgoing-calls",
            "completion",
            "code-actions",
        ):
            with self.subTest(op=op):
                self.dx(self.b, op, file="lib/sample.ex", line=3, column=8)
        self.dx(self.b, "workspace-symbols", query="Sample")
        self.dx(self.b, "format", file="lib/sample.ex")
        diag = self.dx(self.b, "diagnostics", file="lib/sample.ex")
        assert diag["diagnostic_kind"] == "syntax"
        # Each preceding invocation shut down its frontend, not the shared daemon.
        assert self.dx(self.b, "symbols", file="lib/sample.ex")["result"]

    def test_explicit_mutation_and_stale_base_rejection(self) -> None:
        path = self.b / "lib/mutate.ex"
        path.write_text("defmodule Mutate do\n  def value, do: 1\n  def call, do: value()\nend\n")
        result = self.dx(
            self.b, "rename", file="lib/mutate.ex", line=2, column=8, new_name="updated", apply=True
        )
        assert "def updated" in path.read_text()
        assert "updated()" in path.read_text()
        assert result["snapshot"]
        p = execute(
            [sys.executable, str(DX), "--json", "--binary", BINARY, "--root", str(self.b), "write"],
            input_text=json.dumps(
                {"file": "lib/mutate.ex", "text": "bad", "expected_sha256": "wrong"}
            ),
        )
        assert p.returncode != 0
        assert "base" in p.stdout.lower()
        assert "def updated" in path.read_text()

    def test_completion_resolution_application_and_code_action(self) -> None:
        path = self.a / "lib/completer.ex"
        path.write_text("defmodule Completer do\n  def run, do: Sample.gr\nend\n")
        result = self.dx(
            self.a, "completion", file="lib/completer.ex", line=2, column=25, select="greet/1"
        )
        assert result["resolved_item"]["label"] == "greet/1"
        result = self.dx(
            self.a,
            "completion",
            file="lib/completer.ex",
            line=2,
            column=25,
            select="greet/1",
            apply=True,
            insert_text='greet("world")',
            replace_range={
                "start": {"line": 1, "character": 22},
                "end": {"line": 1, "character": 24},
            },
        )
        assert 'Sample.greet("world")' in path.read_text()
        (self.a / "lib/nested.ex").write_text(
            "defmodule Example.Nested do\n  def value, do: 1\nend\n"
        )
        path.write_text("defmodule Completer do\n  def run, do: Example.Nested.value()\nend\n")
        actions = self.dx(self.a, "code-actions", file="lib/completer.ex", line=2, column=20)
        assert actions["result"]
        self.dx(
            self.a,
            "code-actions",
            file="lib/completer.ex",
            line=2,
            column=20,
            select="Add alias Example.Nested",
            apply=True,
        )
        assert "alias Example.Nested" in path.read_text()
        assert "Nested.value()" in path.read_text()

    def test_local_rename_format_and_syntax_diagnostics(self) -> None:
        path = self.a / "lib/locals.ex"
        path.write_text("defmodule Locals do\n  def identity(value), do: value\nend\n")
        result = self.dx(
            self.a, "rename", file="lib/locals.ex", line=2, column=17, new_name="item", apply=True
        )
        assert result["applied"]
        assert "identity(item), do: item" in path.read_text()
        path.write_text("defmodule Locals do\ndef identity(item),do: item\nend\n")
        formatted = self.dx(self.a, "format", file="lib/locals.ex", apply=True)
        assert formatted["applied"]
        assert "  def identity(item), do: item" in path.read_text()
        path.write_text("defmodule Locals do\n  def broken(\nend\n")
        bad = self.dx(self.a, "diagnostics", file="lib/locals.ex")
        assert bad["result"]["diagnostics"]
        path.write_text("defmodule Locals do\n  def good, do: :ok\nend\n")
        good = self.dx(self.a, "diagnostics", file="lib/locals.ex")
        assert good["result"]["diagnostics"] == []

    def test_create_delete_reconcile_and_hierarchy(self) -> None:
        path = self.b / "lib/new_file.ex"
        self.dx(
            self.b,
            "write",
            file="lib/new_file.ex",
            text="defmodule AddedUnique do\n  def value, do: 1\nend\n",
            expected_sha256=None,
        )
        assert "AddedUnique" in json.dumps(
            self.dx(self.b, "workspace-symbols", query="AddedUnique")["result"]
        )
        assert "AddedUnique" not in json.dumps(
            self.dx(self.a, "workspace-symbols", query="AddedUnique")["result"]
        )
        path.unlink()
        assert "AddedUnique" not in json.dumps(
            self.dx(self.b, "workspace-symbols", query="AddedUnique")["result"]
        )
        incoming = self.dx(self.b, "incoming-calls", file="lib/sample.ex", line=3, column=8)
        assert incoming["result"]
        # The unqualified local call that stock outgoingCalls dropped is a prepared site.
        local = self.dx(self.b, "outgoing-calls", file="lib/sample.ex", line=4, column=8)
        assert local["caller"] == {"module": "Sample", "name": "call", "arity": 0}
        assert local["unresolved_count"] == 0
        assert [(call["to"]["name"], call["fromRanges"]) for call in local["result"]] == [
            (
                "Sample.greet/1",
                [{"start": {"line": 3, "character": 16}, "end": {"line": 3, "character": 21}}],
            )
        ]
        (self.b / "lib/caller.ex").write_text(
            'defmodule Caller do\n  def run do\n    Sample.greet("world")\n  end\nend\n'
        )
        outgoing = self.dx(self.b, "outgoing-calls", file="lib/caller.ex", line=2, column=8)
        assert outgoing["unresolved_count"] == 0
        assert [(call["to"]["name"], call["fromRanges"]) for call in outgoing["result"]] == [
            (
                "Sample.greet/1",
                [{"start": {"line": 2, "character": 11}, "end": {"line": 2, "character": 16}}],
            )
        ]

    def test_competing_saved_writes_reject_stale_base(self) -> None:
        path = self.a / "lib/race.ex"
        original = "defmodule Race do\n  def value, do: 0\nend\n"
        path.write_text(original)
        processes: list[subprocess.Popen[bytes]] = []
        for value in (1, 2):
            payload = {
                "file": "lib/race.ex",
                "text": original.replace("do: 0", f"do: {value}"),
                "expected_sha256": hashlib.sha256(original.encode()).hexdigest(),
            }
            p = dx.spawn_process(
                [
                    sys.executable,
                    str(DX),
                    "--json",
                    "--binary",
                    BINARY,
                    "--root",
                    str(self.a),
                    "write",
                ],
                self.a,
            )
            assert p.stdin is not None
            p.stdin.write(json.dumps(payload).encode())
            p.stdin.close()
            processes.append(p)
        results: list[dx.JsonObject] = []
        for p in processes:
            assert p.stdout is not None
            assert p.stderr is not None
            output = p.stdout.read()
            p.wait(timeout=60)
            results.append(json.loads(output))
            p.stdout.close()
            p.stderr.close()
        assert sum(r["ok"] for r in results) == 1
        saved = json.loads(Path(next(r["snapshot"] for r in results if r["ok"])).read_text())
        assert set(saved["files"]) == {"lib/race.ex"}
        assert [r["error"]["kind"] for r in results if not r["ok"]] == ["changed_base"]
        assert path.read_text() in [original.replace("do: 0", f"do: {v}") for v in (1, 2)]

    def test_shared_daemon_survives_other_frontend_exit_and_crash(self) -> None:
        self.dx(self.b, "start")
        first = dx.Session(Path(BINARY).resolve(), self.b, 10)
        second = dx.Session(Path(BINARY).resolve(), self.b, 10)
        try:
            first.initialize(self.b)
            second.initialize(self.b)
            self.dx(self.b, "symbols", file="lib/sample.ex")
            second.proc.kill()
            second.proc.wait(timeout=5)
            result = first.request(
                "textDocument/documentSymbol",
                {"textDocument": {"uri": (self.b / "lib/sample.ex").as_uri()}},
            )
            assert result
            stop = execute([BINARY, "-C", str(self.b), "stop"])
            assert stop.returncode != 0, "Stock stop must refuse the active teammate"
        finally:
            second.close()
            first.close()

    def test_nested_worktree_does_not_select_parent_database(self) -> None:
        # Parent really owns an index. The child starts with its own .git and mix.exs,
        # but without a DB; stock -C alone would silently choose the parent.
        self.dx(self.repo, "start")
        child = self.repo / "nested"
        self.git(self.repo, "worktree", "add", "-q", "-b", "nested", str(child))
        try:
            p = execute(
                [
                    sys.executable,
                    str(DX),
                    "--json",
                    "--binary",
                    BINARY,
                    "--root",
                    str(child),
                    "hover",
                ],
                input_text=json.dumps({"file": "lib/sample.ex", "line": 3, "column": 8}),
            )
            assert json.loads(p.stdout)["error"]["kind"] == "not_initialized"
            parent = execute(
                [
                    sys.executable,
                    str(DX),
                    "--json",
                    "--binary",
                    BINARY,
                    "--root",
                    str(self.repo),
                    "workspace-symbols",
                ],
                input_text="{}",
            )
            assert json.loads(parent.stdout)["error"]["kind"] == "isolation"
            self.dx(child, "start")
            assert (child / ".dexter/dexter.db").is_file()
            path = child / "lib/sample.ex"
            path.write_text(path.read_text().replace("Original documentation", "Nested child only"))
            result = self.dx(child, "definition", file="lib/sample.ex", line=4, column=18)
            assert child.as_uri() + "/lib/sample.ex" in json.dumps(result["result"])
            assert self.repo.as_uri() + "/lib/sample.ex" not in json.dumps(result["result"])
            self.dx(
                child,
                "rename",
                file="lib/sample.ex",
                line=3,
                column=8,
                new_name="child_only",
                apply=True,
            )
            assert "def child_only" in path.read_text()
            assert "def greet" in (self.repo / "lib/sample.ex").read_text()
        finally:
            execute([BINARY, "-C", str(child), "stop"])
            execute([BINARY, "-C", str(self.repo), "stop"])
            self.git(self.repo, "worktree", "remove", "--force", str(child))

    def test_module_rename_moves_file_and_reports_both_paths(self) -> None:
        path = self.a / "lib/old_module.ex"
        path.write_text("defmodule OldModule do\n  def value, do: 1\nend\n")
        result = self.dx(
            self.a,
            "rename",
            file="lib/old_module.ex",
            line=1,
            column=14,
            new_name="NewModule",
            apply=True,
        )
        target = self.a / "lib/new_module.ex"
        assert not path.exists()
        assert "defmodule NewModule" in target.read_text()
        assert set(result["changed_files"]) == {"lib/old_module.ex", "lib/new_module.ex"}
        assert not any("error" in r for r in result["post_reconcile"])

    def test_unregistered_nested_clone_is_refused(self) -> None:
        nested = self.a / "tmp/clone"
        nested.mkdir(parents=True)
        self.git(nested, "init", "-q")
        try:
            p = execute(
                [
                    sys.executable,
                    str(DX),
                    "--json",
                    "--binary",
                    BINARY,
                    "--root",
                    str(self.a),
                    "workspace-symbols",
                ],
                input_text="{}",
            )
            assert json.loads(p.stdout)["error"]["kind"] == "isolation"
        finally:
            import shutil

            shutil.rmtree(nested)

    def test_alias_rename_and_ignored_source_snapshot(self) -> None:
        path = self.a / "lib/alias_user.ex"
        (self.a / "lib/alias_target.ex").write_text(
            "defmodule AliasTarget do\n  def value, do: 1\nend\n"
        )
        alias_line = "  alias AliasTarget, as: Short"
        path.write_text(
            "defmodule AliasUser do\n" + alias_line + "\n  def value, do: Short.value()\nend\n"
        )
        result = self.dx(
            self.a,
            "rename",
            file="lib/alias_user.ex",
            line=2,
            column=alias_line.index("Short") + 1,
            new_name="Scoped",
            apply=True,
        )
        assert "as: Scoped" in path.read_text()
        assert "Scoped.value()" in path.read_text()
        assert result["applied"]
        # A plain ignored source copy has no .git marker. It is still indexed by Dexter,
        # so include it in recovery and mutation reporting rather than hiding its changes.
        with (self.a / ".gitignore").open("a") as handle:
            handle.write("scratch.ex\n")
        scratch = self.a / "scratch.ex"
        scratch.write_text("defmodule Scratch do\n  def run, do: AliasTarget.value()\nend\n")
        renamed = self.dx(
            self.a,
            "rename",
            file="lib/alias_target.ex",
            line=2,
            column=8,
            new_name="changed",
            apply=True,
        )
        assert "scratch.ex" in renamed["changed_files"]
        assert "AliasTarget.changed()" in scratch.read_text()
        snapshot = json.loads(Path(renamed["snapshot"]).read_text())
        assert "scratch.ex" in snapshot["files"]


if __name__ == "__main__":
    unittest.main()
