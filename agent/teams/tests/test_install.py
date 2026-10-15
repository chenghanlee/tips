"""Operator install of a reviewed harness release, with a disposable source repository.

pip runs offline (PIP_NO_INDEX): the fixture lock is empty, or names a package that
cannot be found, which stands in for any failure while building the environment.
"""

import json
import os
import tempfile
import unittest
from pathlib import Path

from team import execute, repo_key
from tests.test_team import TEST_RUNS

TEAMS = Path(__file__).resolve().parents[1]
IDENTITY = ["-c", "user.name=Test", "-c", "user.email=test@example.invalid"]
CONFIG = '[github]\nrepository = "o/r"\n'
MISSING = "nonexistent-package==1.0 --hash=sha256:" + "0" * 64 + "\n"


class InstallTest(unittest.TestCase):
    def setUp(self) -> None:
        TEST_RUNS.mkdir(parents=True, exist_ok=True)
        self.tmp = tempfile.TemporaryDirectory(prefix="install test ", dir=TEST_RUNS)
        self.addCleanup(self.tmp.cleanup)
        base = Path(self.tmp.name).resolve()
        self.source, self.root = base / "source", base / "harness root"
        self.env = dict(os.environ, GIT_CONFIG_GLOBAL=os.devnull, PIP_NO_INDEX="1")
        teams = self.source / "agent/teams"
        teams.mkdir(parents=True)
        self.git("init", "-q", "-b", "main", ".")
        for name in ("team.py", "install.py"):
            (teams / name).write_text((TEAMS / name).read_text())
        (teams / "config.toml").write_text(CONFIG)
        (teams / "requirements.lock").write_text("# no packages\n")
        (self.source / "AGENTS.md").write_text("Release one.\n")
        (self.source / ".gitignore").write_text("/agent/teams/allocations/\n")
        self.first = self.commit("release one")
        self.git("remote", "add", "origin", str(self.source))
        self.git("update-ref", "refs/remotes/origin/main", "HEAD")
        for directory, name in (("state", ".lock"), ("allocations", "kept/project.txt")):
            data = self.root / directory / name
            data.parent.mkdir(parents=True)
            data.write_text("operator data\n")

    def git(self, *args: str) -> str:
        result = execute(["git", *IDENTITY, *args], cwd=self.source, env=self.env, check=True)
        return result.stdout.strip()

    def commit(self, message: str) -> str:
        self.git("add", "-A")
        self.git("commit", "-q", "-m", message)
        return self.git("rev-parse", "HEAD")

    def install(self, commit: str, ok: bool = True, root: Path | None = None) -> str:
        script = self.source / "agent/teams/install.py"
        result = execute(
            ["python3", script, commit, "--root", root or self.root],
            cwd=self.source,
            env=self.env,
            timeout=300,
        )
        assert (result.returncode == 0) == ok, result.stdout + result.stderr
        return result.stdout + result.stderr

    def installed(self) -> Path:
        return (self.root / "harness").resolve()

    def operator_data_kept(self) -> None:
        assert (self.root / "state/.lock").read_text() == "operator data\n"
        assert (self.root / "allocations/kept/project.txt").read_text() == "operator data\n"

    def test_install_switches_releases_and_a_failed_one_keeps_the_previous(self) -> None:
        self.install(self.first)
        release = self.installed()
        assert release.parent == self.root / "releases"
        record = json.loads((release / "agent/teams/install.json").read_text())
        assert record == {**record, "commit": self.first, "repository": "o/r"}
        assert record["root"] == str(self.root)
        assert record["source"] == str(self.source)
        assert (release / "AGENTS.md").read_text() == "Release one.\n"
        execute([release / "agent/teams/.venv/bin/python", "-c", "pass"], check=True)
        self.operator_data_kept()
        # The second release cannot build its environment.
        (self.source / "AGENTS.md").write_text("Release two.\n")
        (self.source / "agent/teams/requirements.lock").write_text(MISSING)
        second = self.commit("release two")
        self.git("update-ref", "refs/remotes/origin/main", "HEAD")
        assert "nonexistent-package" in self.install(second, ok=False)
        assert self.installed() == release
        assert (release / "AGENTS.md").read_text() == "Release one.\n"
        execute([release / "agent/teams/.venv/bin/python", "-c", "pass"], check=True)
        assert sorted((self.root / "releases").iterdir()) == [release]
        self.operator_data_kept()

    def test_a_package_for_another_platform_is_skipped_not_demanded(self) -> None:
        # pip skips a requirement whose environment marker fails here, so the check after
        # the install must not demand it; 2026-10-15 the real lock's emscripten-only
        # `httpx2-jsfetch` made every macOS install fail after pip had succeeded.
        marker = "; sys_platform == 'emscripten'" if os.name != "nt" else "; os_name == 'posix'"
        lock = self.source / "agent/teams/requirements.lock"
        lock.write_text(f"nonexistent-package==1.0 {marker} --hash=sha256:{'0' * 64}\n")
        marked = self.commit("release with a marked package")
        self.git("update-ref", "refs/remotes/origin/main", "HEAD")
        self.install(marked)
        execute([self.installed() / "agent/teams/.venv/bin/python", "-c", "pass"], check=True)

    def test_refuses_dirty_unreviewed_busy_or_foreign_installs(self) -> None:
        (self.source / "AGENTS.md").write_text("Uncommitted.\n")
        assert "uncommitted tracked changes" in self.install(self.first, ok=False)
        self.git("checkout", "--", "AGENTS.md")
        self.git("checkout", "-q", "-b", "unreviewed")
        (self.source / "AGENTS.md").write_text("Not merged.\n")
        unmerged = self.commit("not merged")
        assert "not merged into origin/main" in self.install(unmerged, ok=False)
        self.git("checkout", "-q", "main")
        # The root being changed must be drained: a team record, readable or not, or an
        # allocation that is neither recorded nor retired refuses the install.
        record = self.root / "state/1.json"
        record.write_text("{}\n")
        assert "drain them first" in self.install(self.first, ok=False)
        record.unlink()
        allocation = self.root / "state/g1-impl"
        allocation.mkdir()
        (allocation / "bootstrap.json").write_text("{}\n")
        assert "g1-impl" in self.install(self.first, ok=False)
        (allocation / "retired.json").write_text("{}\n")
        # A root inside the checkout or a temporary directory is refused before any write.
        inside = self.install(self.first, ok=False, root=self.source / "agent_teams/r")
        assert "inside" in inside
        assert not (self.source / "agent_teams").exists()
        with tempfile.TemporaryDirectory() as temporary:
            refused = self.install(self.first, ok=False, root=Path(temporary).resolve() / "r")
            assert "inside" in refused
        # The same repository name under another owner is refused.
        (self.root / "repository.json").write_text(json.dumps({"repository": "x/r"}))
        assert "belongs to x/r, not o/r" in self.install(self.first, ok=False)
        assert not (self.root / "harness").exists()
        self.operator_data_kept()

    def test_the_default_root_is_agent_teams_beside_the_checkout(self) -> None:
        output = execute(
            ["python3", self.source / "agent/teams/install.py", self.first],
            cwd=self.source,
            env=self.env,
            timeout=300,
        )
        assert output.returncode == 0, output.stdout + output.stderr
        root = self.source.parent / "agent_teams" / repo_key("o/r")
        assert (root / "harness").resolve().parent == root / "releases"
        assert json.loads((root / "repository.json").read_text()) == {"repository": "o/r"}
