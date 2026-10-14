#!/usr/bin/env python3
"""Report the calling worker's clone state for retirement; change nothing.

A worker runs this under its own authority when the dispatcher asks it to retire:
`python3 <harness>/retirement.py`. It fetches origin, then posts one EVENT on its issue with
a `TEAM_RETIREMENT` line: whether the clone is clean, how many local commits no origin
branch holds, whether HEAD is merged into origin/main, and HEAD. `team.py stop` reads the
latest report as advisory evidence before it drops any database. This script never calls
Herdr, never deletes a file and never resets the clone.
"""

import json
import os
import re
import subprocess
import sys
from pathlib import Path


from team import RETIREMENT, comment_header, execute, object_fields

GIT_SECONDS = 120
GITHUB_SECONDS = 60
IDENT = re.compile(r"g[0-9]+-[a-z0-9][a-z0-9-]*")


class RetirementError(RuntimeError):
    pass


def own_allocation() -> tuple[str, dict[str, object], dict[str, object], Path]:
    """The issue, this client's recorded allocation, its bootstrap settings and project."""
    ident = os.environ.get("TIPS_TEAM_ALLOCATION_ID", "")
    state = Path(os.environ.get("TIPS_TEAM_STATE", "/nonexistent"))
    if not IDENT.fullmatch(ident) or not state.is_absolute() or state.resolve() != state:
        raise RetirementError(
            "TIPS_TEAM_ALLOCATION_ID and TIPS_TEAM_STATE are not set; run this from the pane "
            "team.py launched"
        )
    for path in sorted(p for p in state.glob("*.json") if p.stem.isdecimal()):
        record = object_fields(json.loads(path.read_text()), str(path))
        agents = object_fields(record.get("agents"), f"{path}: agents")
        for value in agents.values():
            allocation = object_fields(value, f"{path}: agent")
            if allocation.get("id") == ident:
                settings_file = state / ident / "bootstrap.json"
                settings = object_fields(json.loads(settings_file.read_text()), "settings")
                project = Path(str(allocation.get("root"))) / "project"
                if str(project) != settings.get("project"):
                    raise RetirementError(f"{path}: {ident} does not own {project}")
                return str(record.get("brief")), allocation, settings, project
    raise RetirementError(f"No allocation record in {state} names {ident}")


def git(project: Path, *args: str, ok: tuple[int, ...] = (0,)) -> tuple[int, str]:
    try:
        result = execute(
            ["git", "-C", str(project), *args], cwd=project, timeout=GIT_SECONDS, input_text=""
        )
    except subprocess.TimeoutExpired as error:
        raise RetirementError(f"git {args[0]} did not finish within {GIT_SECONDS} s") from error
    if result.returncode not in ok:
        error = (result.stderr or result.stdout).strip()
        raise RetirementError(f"git {' '.join(args)} failed: {error}")
    return result.returncode, result.stdout.strip()


def clone_state(project: Path) -> dict[str, object]:
    """Clean, unpushed and merged evidence. A project with no clone holds no work only
    when it is empty."""
    if not (project / ".git").exists():
        empty = not project.exists() or not any(project.iterdir())
        return {"cloned": False, "clean": empty, "unpushed": 0, "merged": empty, "head": ""}
    git(project, "fetch", "-q", "origin")
    dirty = git(project, "status", "--porcelain", "--untracked-files=all")[1]
    unpushed = git(project, "rev-list", "--count", "HEAD", "--branches", "--not", "--remotes")
    merged = git(project, "merge-base", "--is-ancestor", "HEAD", "origin/main", ok=(0, 1))[0]
    return {
        "cloned": True,
        "clean": not dirty,
        "unpushed": int(unpushed[1]),
        "merged": merged == 0,
        "head": git(project, "rev-parse", "HEAD")[1],
    }


def report() -> str:
    issue, allocation, settings, project = own_allocation()
    fields = {"v": 1, "id": allocation["id"], **clone_state(project)}
    role = str(allocation.get("role", "")).split()[-1]
    header = comment_header(
        "EVENT", role, str(allocation.get("name")), str(allocation.get("session") or "")
    )
    summary = (
        f"retirement report for {project}: clean {fields['clean']}, unpushed commits "
        f"{fields['unpushed']}, merged into origin/main {fields['merged']}"
    )
    body = f"{header}\n{RETIREMENT}{json.dumps(fields, separators=(',', ':'))}\n{summary}"
    repository = str(settings.get("repository"))
    args = ["gh", "issue", "comment", issue, "--repo", repository, "--body-file", "-"]
    try:
        result = execute(args, cwd=project.parent, timeout=GITHUB_SECONDS, input_text=body)
    except subprocess.TimeoutExpired as error:
        raise RetirementError(f"Posting on #{issue} timed out; it may have posted") from error
    if result.returncode:
        raise RetirementError(f"Posting on #{issue} failed: {result.stderr.strip()}")
    return result.stdout.strip()


def main() -> None:
    try:
        print(f"Retirement reported: {report()}")
    except (RetirementError, OSError, ValueError) as error:
        print(f"retirement: {error}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
