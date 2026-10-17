#!/usr/bin/env python3
"""Prepare the calling worker's own project from its trusted allocation configuration.

A worker runs this under its own authority: `python3 <harness>/bootstrap.py [--commit SHA]`.
team.py wrote the configuration to `<harness root>/state/<id>/bootstrap.json`; the worker
cannot change it. An empty project gets a fresh clone on the configured branch, at the
configured commit, or at origin/main. A reused clone is fetched and never reset: `--commit`
moves it only when it is clean, and refuses otherwise. Then this fetches locked
dependencies, writes the Dexter wrapper and the skills link in git-ignored paths, starts
Dexter and updates its index.

Every command's full output goes to a log in the allocation's logs directory; the console
shows at most CONSOLE_BYTES. This script never calls Herdr.
"""

import argparse
import datetime
import hashlib
import json
import os
import re
import shlex
import subprocess
import sys
from pathlib import Path
from typing import IO, cast

from commands import execute
from config import TEMPORARY
from dexter import dexter_invocation

CONSOLE_BYTES = 8192
GIT_SECONDS = 300
# A cold Hex cache downloads every package; anything slower is a hung fetch.
DEPS_FETCH_SECONDS = 300
# Dexter's query gives up this long after --wait: its allowance to reach the daemon.
DEXTER_CONNECT_SECONDS = 30
SHA = re.compile(r"[0-9a-f]{40}")
IDENT = re.compile(r"g[0-9]+-[a-z0-9][a-z0-9-]*")
SETTINGS = {
    "id": str,
    "kind": str,
    "project": str,
    "logs": str,
    "clone_url": str,
    "repository": str,
    "branch": str,
    "commit": str,
    "dexter": str,
    "sources": str,
    "skills": str,
    "startup_seconds": int,
    "writable": list,
}


class BootstrapError(RuntimeError):
    pass


class Console:
    """Print to the console within CONSOLE_BYTES; the log keeps everything."""

    def __init__(self, log: IO[str]) -> None:
        self.log = log
        self.left = CONSOLE_BYTES

    def say(self, text: str) -> None:
        self.log.write(text + "\n")
        self.log.flush()
        data = (text + "\n").encode()
        if self.left <= 0:
            return
        if len(data) > self.left:
            sys.stdout.write(data[: self.left].decode(errors="ignore"))
            sys.stdout.write(f"\n[console output truncated; full log: {self.log.name}]\n")
        else:
            sys.stdout.write(text + "\n")
        sys.stdout.flush()
        self.left -= len(data)


def settings_path() -> tuple[str, Path]:
    """The allocation ID and its launcher configuration file, from the launch environment."""
    ident = os.environ.get("TIPS_TEAM_ALLOCATION_ID", "")
    state = os.environ.get("TIPS_TEAM_STATE", "")
    if not IDENT.fullmatch(ident) or not state:
        raise BootstrapError(
            "TIPS_TEAM_ALLOCATION_ID and TIPS_TEAM_STATE are not set; run this from the pane "
            "team.py launched"
        )
    state_dir = Path(state)
    if not state_dir.is_absolute() or state_dir.resolve() != state_dir:
        raise BootstrapError(f"TIPS_TEAM_STATE {state} is not a canonical absolute path")
    return ident, state_dir / ident / "bootstrap.json"


def load_settings() -> dict[str, object]:
    """Read and check the launcher configuration; the project must be this allocation's."""
    ident, path = settings_path()
    try:
        fields = json.loads(path.read_text())
    except (OSError, ValueError) as error:
        raise BootstrapError(f"Cannot read {path}: {error}") from error
    if not isinstance(fields, dict):
        raise BootstrapError(f"{path} must hold an object")
    settings = cast(dict[str, object], fields)
    for key, kind in SETTINGS.items():
        if type(settings.get(key)) is not kind:
            raise BootstrapError(f"{path}: {key} must be {kind.__name__}")
    own_paths(path, ident, settings)
    trusted_layout(path.parent.parent, cast(list[object], settings["writable"]))
    return settings


def own_paths(path: Path, ident: str, settings: dict[str, object]) -> None:
    """The project and logs must be this allocation's own, reached without a symlink."""
    allocation = path.parent.parent.parent / "allocations" / ident
    expected = {"id": ident, "project": str(allocation / "project")}
    expected["logs"] = str(allocation / "logs")
    for key, value in expected.items():
        if settings[key] != value:
            raise BootstrapError(f"{path}: {key} must be {value}")
    for directory in (allocation, allocation / "project", allocation / "logs"):
        if directory.is_symlink() or directory.resolve() != directory:
            raise BootstrapError(f"{directory} passes through a symlink; refused")


def trusted_layout(state: Path, writable: list[object]) -> None:
    """Refuse a layout in which the harness or the trusted state sits in a temporary
    directory or under a directory the launch lets this worker write. This detects a layout
    error; it does not enforce the client's sandbox."""
    temporary = [Path(p).resolve() for p in (*TEMPORARY, os.environ.get("TMPDIR", "/tmp"))]  # noqa: S108 - refused roots
    grants = [Path(str(p)).resolve() for p in writable]
    for trusted in (Path(__file__).resolve().parent, state.resolve()):
        for parent in (*temporary, *grants):
            if trusted == parent or parent in trusted.parents:
                raise BootstrapError(f"Trusted {trusted} is inside {parent}; refused")


def command(
    console: Console,
    args: list[str],
    cwd: Path,
    timeout: float,
    env: dict[str, str] | None = None,
) -> str:
    """Run one command without a shell; log its full output; raise with its tail."""
    console.say("$ " + shlex.join(args))
    try:
        result = execute(args, cwd=cwd, env=env, timeout=timeout, input_text="")
    except FileNotFoundError as error:
        raise BootstrapError(str(error)) from error
    except subprocess.TimeoutExpired as error:
        raise BootstrapError(f"{args[0]} did not finish within {timeout:.0f} s") from error
    output = (result.stdout or "") + (result.stderr or "")
    console.log.write(output)
    console.log.flush()
    if result.returncode:
        tail = output.strip()[-2000:]
        raise BootstrapError(f"{shlex.join(args)} failed with {result.returncode}:\n{tail}")
    return result.stdout.strip()


def git(console: Console, project: Path, *args: str) -> str:
    return command(console, ["git", "-C", str(project), *args], project, GIT_SECONDS)


def clone(console: Console, settings: dict[str, object], project: Path) -> None:
    """Clone into the empty project, then check out the configured branch or commit."""
    url, branch, commit = (str(settings[k]) for k in ("clone_url", "branch", "commit"))
    command(console, ["git", "clone", "-q", url, str(project)], project.parent, GIT_SECONDS)
    if commit:
        checkout_commit(console, project, commit)
    else:
        check_out_start(console, project, branch)


def check_out_start(console: Console, project: Path, branch: str) -> None:
    """Create the configured branch from its origin branch or origin/main, or detach at
    origin/main when there is none."""
    if branch:
        remote = f"origin/{branch}"
        known = git(console, project, "branch", "-r", "--list", remote)
        start = remote if known else "origin/main"
        git(console, project, "checkout", "-q", "--no-track", "-b", branch, start)
    else:
        git(console, project, "checkout", "-q", "--detach", "origin/main")


def finish_start(console: Console, project: Path, branch: str) -> None:
    """Finish the checkout that a first run killed after its clone never reached. Only a
    clean clone with nothing outside origin moves; anything else is refused."""
    current = git(console, project, "branch", "--show-current")
    if current == branch:
        return
    dirty = git(console, project, "status", "--porcelain", "--untracked-files=all")
    if dirty or git(console, project, "rev-list", "HEAD", "--not", "--remotes=origin"):
        raise BootstrapError(
            f"{project} is on {current or 'a detached HEAD'}, not {branch or 'a detached HEAD'}"
            ", and has commits or files not on origin; nothing changed. Push or remove them, "
            f"check out {branch or 'origin/main detached'}, then run this again."
        )
    check_out_start(console, project, branch)


def checkout_commit(console: Console, project: Path, commit: str) -> None:
    if not SHA.fullmatch(commit):
        raise BootstrapError(f"--commit must be a full 40-character SHA; received {commit!r}")
    refused = f"Commit {commit} is not on origin; push it first"
    try:
        git(console, project, "cat-file", "-e", f"{commit}^{{commit}}")
    except BootstrapError as error:
        raise BootstrapError(refused) from error
    # A local commit exists here too; only an origin branch that contains it proves a push.
    if not git(console, project, "branch", "-r", "--contains", commit, "--list", "origin/*"):
        raise BootstrapError(refused)
    git(console, project, "checkout", "-q", "--detach", commit)


def reuse(console: Console, settings: dict[str, object], project: Path, commit: str) -> None:
    """Fetch the worker's existing clone. Move it to `commit` only when it is clean;
    without one, finish an interrupted start checkout."""
    if Path(git(console, project, "rev-parse", "--show-toplevel")).resolve() != project:
        raise BootstrapError(f"{project} is not the top of its own clone; nothing changed")
    origin = git(console, project, "remote", "get-url", "origin")
    if origin != settings["clone_url"]:
        raise BootstrapError(f"{project}'s origin is {origin}, not {settings['clone_url']}")
    git(console, project, "fetch", "-q", "origin")
    if not commit:
        finish_start(console, project, str(settings["branch"]))
        return
    if git(console, project, "status", "--porcelain", "--untracked-files=all"):
        raise BootstrapError(
            f"{project} has uncommitted or untracked files; nothing changed. Commit, push or "
            "remove your own changes, then run this again. It never resets a clone."
        )
    checkout_commit(console, project, commit)


def ignored(console: Console, project: Path, path: Path) -> None:
    """Refuse to write a helper file the repository would track."""
    relative = str(path.relative_to(project))
    try:
        git(console, project, "check-ignore", "-q", relative)
    except BootstrapError as error:
        raise BootstrapError(f"{relative} is not git-ignored; refusing to write it") from error


def wrapper_text(binary: str, root: Path, sources: str) -> str:
    """The project's Dexter wrapper: the trusted binary bound to the project and sources."""
    argv, env = dexter_invocation(binary, root, sources)
    exports = "".join(f"export {key}={shlex.quote(value)}\n" for key, value in env.items())
    return f'#!/bin/sh\n{exports}exec {shlex.join(argv)} "$@"\n'


def write_helpers(console: Console, settings: dict[str, object], project: Path) -> Path:
    """Write the Dexter wrapper and the skills link; both are git-ignored."""
    wrapper = project / ".dexter/dexter.sh"
    link = project / ".agents/skills"
    for path in (wrapper, link):
        ignored(console, project, path)
    content = wrapper_text(str(settings["dexter"]), project, str(settings["sources"]))
    files = {wrapper: content, project / ".dexter/.gitignore": "*\n"}
    for path, text in files.items():
        path.parent.mkdir(parents=True, exist_ok=True)
        if not path.is_file() or path.read_text() != text:
            path.write_text(text)
    wrapper.chmod(0o755)
    shared = str(settings["skills"])
    if not (link.is_symlink() and os.readlink(link) == shared):
        if link.exists() and not link.is_symlink():
            raise BootstrapError(f"Refusing to replace existing skills: {link}")
        link.parent.mkdir(parents=True, exist_ok=True)
        link.unlink(missing_ok=True)
        link.symlink_to(shared)
    return wrapper


def lock_digest(project: Path) -> str:
    lock = project / "mix.lock"
    return hashlib.sha256(lock.read_bytes()).hexdigest() if lock.is_file() else "none"


def fetch_deps(console: Console, project: Path, fetched: Path) -> None:
    """Fetch locked dependencies unless a fetch for this exact mix.lock already succeeded.
    The marker is written only after success, so a failed or partial fetch, or a new
    lock, fetches again; deps/ existing proves nothing."""
    digest = lock_digest(project)
    if (project / "deps").is_dir() and fetched.is_file() and fetched.read_text() == digest:
        return
    fetched.unlink(missing_ok=True)
    # --check-locked never rewrites the lock.
    command(console, ["mix", "deps.get", "--check-locked"], project, DEPS_FETCH_SECONDS)
    fetched.write_text(digest)


def prepare(console: Console, settings: dict[str, object], project: Path, fetched: Path) -> None:
    """Fetch locked dependencies, start Dexter and update its index."""
    fetch_deps(console, project, fetched)
    wrapper = write_helpers(console, settings, project)
    seconds = cast(int, settings["startup_seconds"])
    budget = seconds + DEXTER_CONNECT_SECONDS + 5
    query = ["query", "workspace-symbols", "--raw", "--wait", f"{seconds}s", "MixProject"]
    output = command(console, ["/bin/sh", str(wrapper), *query], project, budget)
    try:
        found = json.loads(output)
    except ValueError as error:
        raise BootstrapError(f"Dexter answered {output[:200]!r}") from error
    if not found:
        raise BootstrapError("Dexter indexed no MixProject module; inspect its daemon log.")
    # A daemon that was already running does not watch deps/: reconcile it with the disk.
    command(console, ["/bin/sh", str(wrapper), "reindex"], project, budget)


def bootstrap(commit: str) -> None:
    settings = load_settings()
    project, logs = Path(str(settings["project"])), Path(str(settings["logs"]))
    stamp = datetime.datetime.now(datetime.UTC).strftime("%Y%m%dT%H%M%S%fZ")
    log_path = logs / f"bootstrap-{stamp}.log"
    with log_path.open("w") as log:
        console = Console(log)
        console.say(f"Bootstrap {settings['id']}: full log {log_path}")
        try:
            fresh = not project.exists() or not any(project.iterdir())
            if fresh:
                project.mkdir(exist_ok=True)
                clone(console, settings | {"commit": commit or settings["commit"]}, project)
            else:
                reuse(console, settings, project, commit)
            prepare(console, settings, project, logs / "deps-fetched")
            head = git(console, project, "rev-parse", "HEAD")
            if commit and head != commit:
                raise BootstrapError(f"HEAD is {head}, not {commit}")
            console.say(f"Bootstrap ready: {project} at {head}")
        except BootstrapError as error:
            console.say(f"Bootstrap failed: {error}")
            raise


def main() -> None:
    parser = argparse.ArgumentParser(description="Prepare this worker's own project.")
    parser.add_argument("--commit", default="", help="Check out this pushed commit")
    args = parser.parse_args()
    try:
        bootstrap(args.commit)
    except (BootstrapError, OSError) as error:
        print(f"bootstrap: {str(error)[-CONSOLE_BYTES:]}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
