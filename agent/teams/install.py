#!/usr/bin/env python3
"""Install a reviewed harness release for the operator: `install.py <commit> [--root DIR]`.

Run from the main checkout with teams drained. The commit must be merged into origin/main
and the checkout's tracked files clean. The release holds AGENTS.md and agent/teams from
that commit, plus the locked adapter environment, under <root>/releases/. <root>/harness
then points at it; the switch is one atomic rename. state/ and allocations/ are never
touched. A failed install removes only its own unfinished release, so the previous
harness keeps running. Default root: agent_teams/<repository name>/ in the main checkout's
parent directory, created on first use. The root is a copy target, not write-protected.
"""

import argparse
import datetime
import json
import re
import shutil
import subprocess
import sys
import tarfile
import tomllib
from pathlib import Path

from commands import execute, run
from config import REPOSITORY, claim_root, default_root
from team import load_record

# Creating the environment and fetching locked wheels; the same budget as dependency fetches.
INSTALL_SECONDS = 300
RELEASE_FILES = ("AGENTS.md", "agent/teams")


def git(source: Path, *args: str) -> str:
    return run("git", "-C", source, *args, timeout=INSTALL_SECONDS)


def reviewed_commit(source: Path, name: str) -> str:
    """The full SHA of a commit already merged into the fetched origin/main."""
    commit = git(source, "rev-parse", "--verify", f"{name}^{{commit}}")
    merged = execute(["git", "-C", source, "merge-base", "--is-ancestor", commit, "origin/main"])
    if merged.returncode:
        raise RuntimeError(f"{name} is not merged into origin/main; install only reviewed commits")
    return commit


def require_clean(source: Path) -> None:
    # Untracked files cannot reach the release: it is exported from the commit itself.
    if git(source, "status", "--porcelain", "--untracked-files=no"):
        raise RuntimeError(f"{source} has uncommitted tracked changes; commit or discard them")


def repository(source: Path, commit: str) -> str:
    config = tomllib.loads(git(source, "show", f"{commit}:agent/teams/config.toml"))
    name = str(config.get("github", {}).get("repository", ""))
    if not re.fullmatch(REPOSITORY, name):
        raise RuntimeError(f"agent/teams/config.toml at {commit} has no github.repository")
    return name


def require_drained(root: Path) -> None:
    """Refuse while the root being changed holds a team record, readable or not, or an
    allocation that is neither recorded nor retired."""
    state = root / "state"
    busy: list[str] = []
    for path in sorted(p for p in state.glob("*.json") if p.stem.isdecimal()):
        try:
            busy.append(f"slot {path.stem} (#{load_record(path)['brief']})")
        except (RuntimeError, ValueError, KeyError, OSError) as error:
            busy.append(f"slot {path.stem} (unreadable: {error})")
    if busy:
        raise RuntimeError(f"Teams are running in {root}: {', '.join(busy)}; drain them first")
    unfinished = [
        path.parent.name
        for path in sorted(state.glob("*/bootstrap.json"))
        if not (path.parent / "retired.json").exists()
    ]
    if unfinished:
        raise RuntimeError(
            f"Allocations {', '.join(unfinished)} in {root} are neither recorded nor retired; "
            "retire them first"
        )


def export(source: Path, commit: str, release: Path) -> None:
    archive = release.with_suffix(".tar")
    try:
        git(source, "archive", "--format=tar", "-o", str(archive), commit, *RELEASE_FILES)
        with tarfile.open(archive) as tar:
            tar.extractall(release, filter="data")
    finally:
        archive.unlink(missing_ok=True)


def locked_packages(lock: Path) -> list[str]:
    """Names of the locked packages that install on every platform. A requirement with
    an environment marker (`name==1.0 ; sys_platform == 'win32'`) installs only where the
    marker holds, and pip decides that; this check does not demand it."""
    names: list[str] = []
    for line in lock.read_text().splitlines():
        match = re.match(r"([A-Za-z0-9_.-]+)==", line)
        if match and ";" not in line:
            names.append(match.group(1))
    return names


def build_environment(teams: Path) -> None:
    """Create teams/.venv and install exactly the locked, hashed wheels; build nothing."""
    venv, lock = teams / ".venv", teams / "requirements.lock"
    run(sys.executable, "-m", "venv", venv, timeout=INSTALL_SECONDS)
    python = venv / "bin/python"
    pip: list[str | Path] = [
        python,
        "-m",
        "pip",
        "install",
        "--quiet",
        "--disable-pip-version-check",
    ]
    locked: list[str | Path] = ["--require-hashes", "--no-deps", "--only-binary=:all:", "-r", lock]
    run(*pip, *locked, timeout=INSTALL_SECONDS)
    names = locked_packages(lock)
    check = "import importlib.metadata as m, sys; [m.version(n) for n in sys.argv[1:]]"
    run(python, "-E", "-s", "-c", check, *names, timeout=INSTALL_SECONDS)


def switch(root: Path, release: Path) -> None:
    """Point <root>/harness at the release with one atomic rename."""
    harness = root / "harness"
    if harness.exists() and not harness.is_symlink():
        raise RuntimeError(f"{harness} is not a release link; move it aside first")
    staged = root / "harness.next"
    staged.unlink(missing_ok=True)
    staged.symlink_to(release.relative_to(root))
    staged.replace(harness)


def install(source: Path, name: str, root: Path | None) -> Path:
    require_clean(source)
    commit = reviewed_commit(source, name)
    repo = repository(source, commit)
    root = (root or default_root(source, repo)).absolute()
    claim_root(root, repo, source)
    (root / "releases").mkdir(exist_ok=True)
    require_drained(root)
    stamp = datetime.datetime.now(datetime.UTC).strftime("%Y%m%dT%H%M%SZ")
    release = root / "releases" / f"{commit[:12]}-{stamp}"
    release.mkdir()
    try:
        export(source, commit, release)
        teams = release / "agent/teams"
        build_environment(teams)
        record = {
            "commit": commit,
            "repository": repo,
            "source": str(source),
            "root": str(root),
            "installed": stamp,
        }
        (teams / "install.json").write_text(json.dumps(record, indent=2) + "\n")
        switch(root, release)
    except BaseException:
        shutil.rmtree(release)
        raise
    return release


def main() -> None:
    parser = argparse.ArgumentParser(description="Install a reviewed harness release.")
    parser.add_argument("commit", help="A commit merged into origin/main")
    parser.add_argument("--root", type=Path, help="Harness root; default is per repository")
    args = parser.parse_args()
    source = Path.cwd().resolve()
    if Path(git(source, "rev-parse", "--show-toplevel")).resolve() != source:
        raise RuntimeError("Run install.py from the root of the main checkout")
    # A linked worktree would record itself as the source the release reads (#451).
    own = Path(git(source, "rev-parse", "--absolute-git-dir")).resolve()
    common = Path(git(source, "rev-parse", "--path-format=absolute", "--git-common-dir"))
    if own != common.resolve():
        main_checkout = common.resolve().parent
        raise RuntimeError(f"Run install.py from the main checkout {main_checkout}, not a worktree")
    release = install(source, args.commit, args.root)
    print(f"Installed {release}; {release.parent.parent / 'harness'} points at it")


if __name__ == "__main__":
    try:
        main()
    except (RuntimeError, OSError, ValueError, KeyError, subprocess.SubprocessError) as error:
        print(f"install: {error}", file=sys.stderr)
        sys.exit(1)
