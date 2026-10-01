"""Exercise build installation with isolated tool and process snapshots."""

import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


class BuildSafetyTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve() / "checkout [beta].v1"
        self.root.mkdir()
        shutil.copyfile(Path(__file__).with_name("build.sh"), self.root / "build.sh")
        (self.root / "patches").mkdir()
        (self.root / "patches/dexter-go.patch").write_text("fixture patch\n")
        (self.root / "vendor").mkdir()
        self.binary = self.root / "vendor/dexter"
        self.binary.write_text("existing executable\n")
        self.metadata = self.root / "vendor/build.json"
        self.metadata.write_text("existing metadata\n")
        tools = self.root / "tools"
        tools.mkdir()
        stub = tools / "stub"
        stub.write_text(
            f"#!{sys.executable}\n"
            + """
import os, pathlib, sys, tarfile
tool = pathlib.Path(sys.argv[0]).name
if tool == "ps":
    marker = pathlib.Path(os.environ["PS_MARKER"])
    key = "PS_AFTER" if marker.exists() else "PS_BEFORE"
    marker.touch()
    if os.environ.get(key) == "ERROR":
        sys.exit(1)
    print(os.environ.get(key, ""))
elif tool == "git" and "archive" in sys.argv:
    with tarfile.open(fileobj=sys.stdout.buffer, mode="w|"):
        pass
elif tool == "go":
    if sys.argv[1] == "version":
        print("go version fixture")
    else:
        output = pathlib.Path(sys.argv[sys.argv.index("-o") + 1])
        flags = sys.argv[sys.argv.index("-ldflags") + 1]
        build_id = flags.split("=")[-1]
        output.write_text("#!/bin/sh\\nprintf 'local_build_id " + build_id + "\\\\n'\\n")
        output.chmod(0o755)
"""
        )
        stub.chmod(0o755)
        for name in ("ps", "git", "go"):
            (tools / name).symlink_to(stub)
        self.env = dict(
            os.environ,
            PATH=f"{tools}:{os.environ['PATH']}",
            PS_MARKER=str(self.root / "ps-called"),
        )

    def run_build(self, before="", after=""):
        self.env.update(PS_BEFORE=before, PS_AFTER=after)
        return subprocess.run(
            ["bash", str(self.root / "build.sh"), "fixture-repository"],
            env=self.env,
            text=True,
            capture_output=True,
            check=False,
        )

    def assert_preserved(self, result, message):
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertIn(message, result.stderr)
        self.assertEqual(self.binary.read_text(), "existing executable\n")
        self.assertEqual(self.metadata.read_text(), "existing metadata\n")

    def test_running_daemon_refuses_replacement(self):
        self.assert_preserved(
            self.run_build(before=f"{self.binary} daemon /a/worktree"),
            "running daemon",
        )

    def test_failed_process_inspection_refuses_replacement(self):
        self.assert_preserved(self.run_build(before="ERROR"), "inspect processes")

    def test_daemon_started_during_build_refuses_replacement(self):
        self.assert_preserved(
            self.run_build(after=f"{self.binary} daemon /a/worktree"),
            "running daemon",
        )

    def test_failed_final_inspection_refuses_replacement(self):
        self.assert_preserved(self.run_build(after="ERROR"), "inspect processes")

    def test_unrelated_daemon_does_not_block(self):
        # Would match if the literal path were used as a regular expression.
        unrelated = str(self.binary).replace("[beta].", "bX")
        result = self.run_build(before=f"{unrelated} daemon /other")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("local_build_id", self.binary.read_text())
        self.assertIn('"sha256"', self.metadata.read_text())


if __name__ == "__main__":
    unittest.main()
