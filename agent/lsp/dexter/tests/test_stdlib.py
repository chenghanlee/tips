"""Real daemon startup and saved configuration, using authentic Elixir sources."""

import json
import os
import sys
import tempfile
import unittest
from pathlib import Path

from agent.lsp.dexter.dexter_client import protocol as dx
from agent.teams.team import execute

DX = Path(__file__).resolve().parents[1] / "dx.py"
BINARY = os.environ.get("DEXTER_BINARY", "")
STDLIB = os.environ.get("DEXTER_ELIXIR_LIB_ROOT", "")


@unittest.skipUnless(BINARY and STDLIB, "set DEXTER_BINARY and DEXTER_ELIXIR_LIB_ROOT")
class StandardLibrary(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory(prefix="dx-stdlib-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.addCleanup(execute, [BINARY, "-C", str(self.root), "stop"])
        execute(["git", "init", "-q", str(self.root)], check=True)
        (self.root / "mix.exs").write_text(
            "defmodule Fixture.MixProject do\n  use Mix.Project\n"
            '  def project, do: [app: :fixture, version: "0.1.0"]\nend\n'
        )
        (self.root / "sample.ex").write_text(
            "defmodule Sample do\n  def run, do: Enum.map([1], & &1)\nend\n"
        )
        self.env = dict(os.environ)
        self.env["DEXTER_DAEMON_IDLE_TIMEOUT"] = "5s"
        self.env.pop("DEXTER_ELIXIR_LIB_ROOT", None)

    def invoke(
        self, op: str, params: dx.JsonObject | None = None, stdlib: str | Path | None = None
    ) -> tuple[int, dx.JsonObject]:
        env = dict(self.env)
        if stdlib is not None:
            env["DEXTER_ELIXIR_LIB_ROOT"] = str(stdlib)
        p = execute(
            [sys.executable, str(DX), "--json", "--binary", BINARY, "--root", str(self.root), op],
            input_text=json.dumps(params or {}),
            env=env,
            timeout=90,
        )
        assert p.stdout, p.stderr
        return p.returncode, json.loads(p.stdout)

    def test_saved_config_repairs_legacy_daemon_and_survives_restart(self) -> None:
        # A daemon already running without the new configuration must be restarted.
        execute([BINARY, "init", str(self.root)], env=self.env, check=True)
        execute([BINARY, "-C", str(self.root), "reindex"], env=self.env, check=True)
        code, report = self.invoke("start", stdlib=STDLIB)
        assert code == 0, report
        assert report["stdlib"]["status"] == "configured"
        assert "restart" in report
        code, again = self.invoke("start")
        assert code == 0, again
        assert "restart" not in again
        for restarted in (False, True):
            if restarted:
                execute([BINARY, "-C", str(self.root), "stop"], check=True)
            # New harness process: no env override. Both lookups need real sources.
            code, hover = self.invoke("hover", {"file": "sample.ex", "line": 2, "column": 22})
            assert code == 0, hover
            assert "enumerable" in json.dumps(hover["result"]).lower()
            code, definition = self.invoke(
                "definition", {"file": "sample.ex", "line": 2, "column": 22}
            )
            assert code == 0, definition
            assert (Path(STDLIB).resolve() / "elixir/lib/enum.ex").as_uri() in json.dumps(
                definition["result"]
            )
            assert definition["stdlib"]["root"] == str(Path(STDLIB).resolve())

    def test_missing_or_sourceless_config_is_rejected_before_indexing(self) -> None:
        for path in (None, self.root):
            code, report = self.invoke("start", stdlib=path)
            assert code != 0, report
            assert report["error"]["kind"] == "stdlib"
            assert not (self.root / ".dexter/dexter.db").exists()

    def test_version_mismatch_is_rejected_before_indexing(self) -> None:
        fake = self.root / "wrong-version"
        (fake / "lib/elixir/lib").mkdir(parents=True)
        (fake / "lib/elixir/lib/enum.ex").write_text("defmodule Enum do\nend\n")
        (fake / "VERSION").write_text("0.0.0")
        code, report = self.invoke("start", stdlib=fake / "lib")
        assert code != 0, report
        assert report["error"]["kind"] == "stdlib"
        assert "version" in str(report["error"]["detail"]).lower()
        assert not (self.root / ".dexter/dexter.db").exists()

    def test_configuration_restart_does_not_disconnect_attached_teammate(self) -> None:
        execute([BINARY, "init", str(self.root)], env=self.env, check=True)
        session = dx.Session(Path(BINARY), self.root, 15, env=self.env)
        try:
            session.initialize(self.root)
            code, report = self.invoke("start", stdlib=STDLIB)
            assert code != 0, report
            assert report["error"]["kind"] == "process"
            assert not (self.root / ".dexter/dx/stdlib.json").exists()
            assert session.request(
                "textDocument/documentSymbol",
                {"textDocument": {"uri": (self.root / "sample.ex").as_uri()}},
            )
        finally:
            session.close()
        code, report = self.invoke("start", stdlib=STDLIB)
        assert code == 0, report


if __name__ == "__main__":
    unittest.main()
