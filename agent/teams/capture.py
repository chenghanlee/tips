#!/usr/bin/env python3
"""Run a check and keep its complete output and exit status in a new log under tmp/checks.

Usage: agent/teams/capture.py <label> -- <command> [args...]

The log is created before the command starts and receives its output as it is produced, so
an interrupted run keeps what was emitted and two overlapping runs never share a file. This
tool never overwrites or deletes a log; the first failing run stays on disk until the PR
records its test, error and seed. The log is printed when the command exits, and the
command's exit status is returned.
"""

import re
import sys
import time
from datetime import UTC, datetime
from pathlib import Path
from typing import IO

from team import execute

LOGS = Path("tmp/checks")
USAGE = "Usage: agent/teams/capture.py <label> -- <command> [args...]"


def open_log(label: str, now: datetime) -> IO[str]:
    """Create this run's log exclusively; a clash gets a numbered name instead of overwriting."""
    slug = re.sub(r"[^A-Za-z0-9._-]+", "-", label).strip("-") or "check"
    stamp = now.strftime("%Y%m%dT%H%M%SZ")
    counter = 1
    while True:
        suffix = "" if counter == 1 else f"-{counter}"
        path = LOGS / f"{stamp}-{slug}{suffix}.log"
        try:
            return path.open("x", encoding="utf-8")
        except FileExistsError:
            counter += 1


def capture(label: str, command: list[str]) -> int:
    LOGS.mkdir(parents=True, exist_ok=True)
    started = datetime.now(UTC)
    clock = time.monotonic()
    with open_log(label, started) as log:
        log.write(
            f"# {label}\n# command: {' '.join(command)}\n"
            f"# cwd: {Path.cwd()}\n# started: {started.isoformat()}\n"
        )
        log.flush()
        result = execute(command, output=log)
        log.write(f"\n# exit {result.returncode} after {time.monotonic() - clock:.0f}s\n")
        path = Path(log.name)
    sys.stdout.write(path.read_text(encoding="utf-8"))
    print(f"capture: {path} exit {result.returncode}", file=sys.stderr)
    return result.returncode


def main() -> int:
    args = sys.argv[1:]
    if len(args) < 3 or args[1] != "--":
        print(USAGE, file=sys.stderr)
        return 2
    return capture(args[0], args[2:])


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, ValueError) as error:
        print(f"capture: {error}", file=sys.stderr)
        sys.exit(1)
