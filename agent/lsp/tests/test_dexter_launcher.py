"""Exercise launcher ownership using real Git and a test-owned bridge process."""

import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


LAUNCHER = Path(__file__).resolve().parents[1] / "launch_worktree_dexter.py"


class LauncherTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        subprocess.run(["git", "init", "-q", str(self.root)], check=True)
        (self.root / "mix.exs").write_text("# launcher fixture\n")
        tools = self.root / "tools/bin"
        tools.mkdir(parents=True)
        bridge = tools / "mcp-language-server"
        bridge.write_text(
            f"#!{sys.executable}\n"
            "import json,os,sys\n"
            "print(json.dumps({'args':sys.argv[1:], 'cwd':os.getcwd(), "
            "'env':{k:os.environ.get(k) for k in "
            "['MIX_BUILD_PATH','MIX_BUILD_ROOT','MIX_DEPS_PATH','MIX_ENV',"
            "'TIPS_DB_SUFFIX','TIPS_TEST_PORT']}}),flush=True)\n"
            "sys.stdin.read()\n"
        )
        bridge.chmod(0o755)
        self.env = {
            **os.environ,
            "TIPS_ELIXIR_TOOLS": str(tools.parent),
            "TIPS_DEXTER_COMMAND": sys.executable,
            "MIX_BUILD_PATH": "/shared/build/dev",
            "MIX_BUILD_ROOT": "/shared/build",
            "MIX_DEPS_PATH": "/shared/deps",
            "MIX_ENV": "test",
            "TIPS_DB_SUFFIX": "_owned_fixture",
            "TIPS_TEST_PORT": "4931",
        }

    def run_launcher(self, root=None):
        return subprocess.run(
            [sys.executable, str(LAUNCHER), str(root or self.root)],
            env=self.env, input="", capture_output=True, text=True, timeout=10,
        )

    def test_explicit_root_and_project_paths_preserve_database_allocation(self):
        result = self.run_launcher()
        self.assertEqual(result.returncode, 0, result.stderr)
        reply = json.loads(result.stdout)
        self.assertEqual(reply["cwd"], str(self.root))
        self.assertEqual(
            reply["args"],
            ["--workspace", str(self.root), "--lsp", sys.executable,
             "--dexter", "--", "lsp", str(self.root)],
        )
        self.assertTrue((self.root / ".dexter/dexter.db").is_file())
        self.assertEqual(reply["env"], {
            "MIX_BUILD_PATH": None, "MIX_BUILD_ROOT": None, "MIX_DEPS_PATH": None,
            "MIX_ENV": "test", "TIPS_DB_SUFFIX": "_owned_fixture", "TIPS_TEST_PORT": "4931",
        })

    def test_rejects_subdirectory(self):
        child = self.root / "child"
        child.mkdir()
        result = self.run_launcher(child)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("root of a Git checkout", result.stderr)

    def test_rejects_symlinked_index_database(self):
        state = self.root / ".dexter"
        state.mkdir()
        shared = self.root / "shared.db"
        shared.touch()
        (state / "dexter.db").symlink_to(shared)
        result = self.run_launcher()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("symlinked Dexter state", result.stderr)

    def test_rejects_shared_project_directories(self):
        for name in ("deps", "_build", ".dexter"):
            with self.subTest(name=name):
                link = self.root / name
                link.symlink_to(self.root / "tools", target_is_directory=True)
                try:
                    result = self.run_launcher()
                    self.assertNotEqual(result.returncode, 0)
                    self.assertIn("symlinked project directory", result.stderr)
                finally:
                    link.unlink()

    def test_duplicate_owner_refused_then_lock_released_on_exit(self):
        with subprocess.Popen(
            [sys.executable, str(LAUNCHER), str(self.root)], env=self.env,
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
        ) as first:
            self.assertTrue(first.stdout.readline())
            try:
                second = self.run_launcher()
                self.assertNotEqual(second.returncode, 0)
                self.assertIn("already owns", second.stderr)
            finally:
                first.communicate(timeout=10)
        self.assertEqual(self.run_launcher().returncode, 0)


if __name__ == "__main__":
    unittest.main()
