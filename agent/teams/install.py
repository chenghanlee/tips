#!/usr/bin/env python3
"""Install a reviewed harness release for the operator: `install.py <commit> [--root DIR]`.

Run from the main checkout with teams drained. The commit must be merged into origin/main
and the checkout's tracked files clean. The release holds AGENTS.md and agent/teams from
that commit, plus the locked adapter environment, under <root>/releases/. <root>/harness
then points at it; the switch is one atomic rename. state/ and allocations/ are never
touched. A failed install removes only its own unfinished release, so the previous
harness keeps running. Default root: ~/.local/share/tips-agent-teams/<repo-key>/, where
repo-key is the first 16 hex characters of SHA-256 of the configured owner/name.
"""

import argparse
import datetime
import hashlib
import json
import re
import shutil
import subprocess
import sys
import tarfile
import tomllib
from pathlib import Path

from team import REPOSITORY, execute, run

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


def default_root(name: str) -> Path:
    key = hashlib.sha256(name.encode()).hexdigest()[:16]
    return Path.home() / ".local/share/tips-agent-teams" / key


def claim_root(root: Path, name: str) -> None:
    """Create the root for this repository, or refuse a root that records another one."""
    identity = root / "repository.json"
    if identity.exists():
        recorded = json.loads(identity.read_text()).get("repository")
        if recorded != name:
            raise RuntimeError(f"{root} belongs to {recorded}, not {name}")
    else:
        root.mkdir(parents=True, exist_ok=True)
        identity.write_text(json.dumps({"repository": name}) + "\n")
    for directory in ("releases", "state", "allocations"):
        (root / directory).mkdir(exist_ok=True)


def require_drained(source: Path) -> None:
    # PR4 integration point (#441): check <root>/state/ allocation records instead.
    records = sorted((source / "agent/teams/allocations").glob("*.json"))
    if records:
        raise RuntimeError(f"Teams are running ({len(records)} records); drain them first")


def export(source: Path, commit: str, release: Path) -> None:
    archive = release.with_suffix(".tar")
    try:
        git(source, "archive", "--format=tar", "-o", str(archive), commit, *RELEASE_FILES)
        with tarfile.open(archive) as tar:
            tar.extractall(release, filter="data")
    finally:
        archive.unlink(missing_ok=True)


def locked_packages(lock: Path) -> list[str]:
    return re.findall(r"^([A-Za-z0-9_.-]+)==", lock.read_text(), re.MULTILINE)


def build_environment(teams: Path) -> None:
    """Create teams/.venv and install exactly the locked, hashed wheels; build nothing."""
    venv, lock = teams / ".venv", teams / "requirements.lock"
    run(sys.executable, "-m", "venv", venv, timeout=INSTALL_SECONDS)
    python = venv / "bin/python"
    pip = [python, "-m", "pip", "install", "--quiet", "--disable-pip-version-check"]
    locked = ["--require-hashes", "--no-deps", "--only-binary=:all:", "-r", lock]
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
    root = (root or default_root(repo)).resolve()
    claim_root(root, repo)
    require_drained(source)
    stamp = datetime.datetime.now(datetime.UTC).strftime("%Y%m%dT%H%M%SZ")
    release = root / "releases" / f"{commit[:12]}-{stamp}"
    release.mkdir()
    try:
        export(source, commit, release)
        teams = release / "agent/teams"
        build_environment(teams)
        record = {"commit": commit, "repository": repo, "source": str(source), "installed": stamp}
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
    release = install(source, args.commit, args.root)
    print(f"Installed {release}; {release.parent.parent / 'harness'} points at it")


if __name__ == "__main__":
    try:
        main()
    except (RuntimeError, OSError, ValueError, KeyError, subprocess.SubprocessError) as error:
        print(f"install: {error}", file=sys.stderr)
        sys.exit(1)
