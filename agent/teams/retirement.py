#!/usr/bin/env python3
"""Report the calling worker's clone state for retirement; change nothing.

A worker runs this under its own authority when the dispatcher asks it to retire:
`python3 <harness>/retirement.py`. It fetches origin, then posts one EVENT on its issue with
a `TEAM_RETIREMENT` line naming its launch: whether the clone is clean and its first dirty
paths, how many local commits no origin branch holds, whether HEAD is merged into
origin/main, and HEAD.
`team.py stop` reads the latest report as advisory evidence before it drops any database.

The dispatcher's turns start only on messages, so this script then tells it:
`herdr agent prompt dispatcher "<report URL> retired"`. If the report cannot be made, it
posts a BLOCKED comment with the error and sends `"<comment URL> blocked"` (the issue URL
when even that comment fails). When the prompt cannot be sent, as outside Herdr or with no
dispatcher running, it prints the command instead. It never deletes a file and never
resets the clone.
"""

import json
import os
import shlex
import subprocess
import sys
from pathlib import Path
from typing import cast

from commands import execute, object_fields
from config import RETIREMENT, launch_identity, slot_record_paths
from github import comment_header

GIT_SECONDS = 120
GITHUB_SECONDS = 60
HERDR_SECONDS = 30
DIRTY_PATHS = 5  # status lines kept in a report of a dirty clone


class RetirementError(RuntimeError):
    pass


def own_allocation() -> tuple[str, dict[str, object], dict[str, object], Path]:
    """The issue, this client's recorded allocation, its bootstrap settings and project."""
    ident, state = launch_identity()
    for path in slot_record_paths(state):
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
                launch = os.environ.get("TIPS_TEAM_LAUNCH", "")
                if not launch or launch != allocation.get("launch"):
                    raise RetirementError(
                        f"This pane's launch {launch or '(none)'} is not {ident}'s current "
                        f"launch {allocation.get('launch') or '(none)'}; a report from it would "
                        "describe another session"
                    )
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
        detail = (result.stderr or result.stdout).strip()
        raise RetirementError(f"git {' '.join(args)} failed: {detail}")
    return result.returncode, result.stdout.rstrip("\n")  # porcelain lines start with a space


def clone_state(project: Path) -> dict[str, object]:
    """Clean, unpushed and merged evidence, with the first dirty status lines so a refusal
    names its cause. A project with no clone holds no work only when it is empty."""
    if not (project / ".git").exists():
        empty = not project.exists() or not any(project.iterdir())
        return {
            "cloned": False,
            "clean": empty,
            "dirty": [],
            "unpushed": 0,
            "merged": empty,
            "head": "",
        }
    git(project, "fetch", "-q", "origin")
    dirty = git(project, "status", "--porcelain", "--untracked-files=all")[1].splitlines()
    unpushed = git(project, "rev-list", "--count", "HEAD", "--branches", "--not", "--remotes")
    merged = git(project, "merge-base", "--is-ancestor", "HEAD", "origin/main", ok=(0, 1))[0]
    return {
        "cloned": True,
        "clean": not dirty,
        "dirty": dirty[:DIRTY_PATHS],
        "unpushed": int(unpushed[1]),
        "merged": merged == 0,
        "head": git(project, "rev-parse", "HEAD")[1],
    }


def header(kind: str, allocation: dict[str, object]) -> str:
    role = str(allocation.get("role", "")).split()[-1]
    name, session = str(allocation.get("name")), str(allocation.get("session") or "")
    return comment_header(kind, role, name, session)


def post(issue: str, repository: str, project: Path, body: str) -> str:
    args = ["gh", "issue", "comment", issue, "--repo", repository, "--body-file", "-"]
    try:
        result = execute(args, cwd=project.parent, timeout=GITHUB_SECONDS, input_text=body)
    except subprocess.TimeoutExpired as error:
        raise RetirementError(f"Posting on #{issue} timed out; it may have posted") from error
    if result.returncode:
        raise RetirementError(f"Posting on #{issue} failed: {result.stderr.strip()}")
    return result.stdout.strip()


def report(issue: str, allocation: dict[str, object], repository: str, project: Path) -> str:
    state = clone_state(project)
    fields = {"v": 1, "id": allocation["id"], "launch": allocation["launch"], **state}
    summary = (
        f"retirement report for {project}: clean {state['clean']}, unpushed commits "
        f"{state['unpushed']}, merged into origin/main {state['merged']}"
    )
    if dirty := cast(list[str], state["dirty"]):
        summary += f"; dirty: {', '.join(dirty)}"
    evidence = f"{RETIREMENT}{json.dumps(fields, separators=(',', ':'))}"
    return post(issue, repository, project, f"{header('EVENT', allocation)}\n{evidence}\n{summary}")


def tell_dispatcher(text: str) -> None:
    """Wake the dispatcher; without one to tell, print the command for the operator."""
    command = ["herdr", "agent", "prompt", "dispatcher", text]
    try:
        sent = (
            os.environ.get("HERDR_ENV") == "1"
            and not execute(command, timeout=HERDR_SECONDS).returncode
        )
    except (RuntimeError, OSError, subprocess.TimeoutExpired):
        sent = False
    if sent:
        print("Notified dispatcher")
    else:
        print(f"No dispatcher was notified; run: {shlex.join(command)}")


def main() -> None:
    try:
        issue, allocation, settings, project = own_allocation()
    except (RetirementError, OSError, ValueError) as error:
        print(f"retirement: {error}", file=sys.stderr)
        sys.exit(1)
    repository = str(settings.get("repository"))
    try:
        url = report(issue, allocation, repository, project)
    except (RetirementError, OSError, ValueError) as error:
        print(f"retirement: {error}", file=sys.stderr)
        body = f"{header('BLOCKED', allocation)}\nRetirement report failed: {error}"
        try:
            blocked = post(issue, repository, project, body)
        except RetirementError:
            blocked = f"https://github.com/{repository}/issues/{issue}"
        tell_dispatcher(f"{blocked} blocked")
        sys.exit(1)
    print(f"Retirement reported: {url}")
    tell_dispatcher(f"{url} retired")


if __name__ == "__main__":
    main()
