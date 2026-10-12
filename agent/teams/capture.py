#!/usr/bin/env python3
"""Run a check and keep its complete output and exit status in a new log under tmp/checks.

Usage: agent/teams/capture.py <label> -- <command> [args...]

The log is created before the command starts and receives its output as it is produced, so
an interrupted run keeps what was emitted and two overlapping runs never share a file. This
tool never overwrites or deletes a log; the first failing run stays on disk until the PR
records its test, error and seed. When the command exits, the last lines of the log and
its path are printed, and the command's exit status is returned. Read the log for the rest.
"""

import re
import shutil
import subprocess
import sys
import time
from datetime import UTC, datetime
from pathlib import Path
from typing import IO

LOGS = Path("tmp/checks")
USAGE = "Usage: agent/teams/capture.py <label> -- <command> [args...]"
TAIL = 40


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


def run_into(command: list[str], log: IO[str]) -> int:
    """Run the resolved command without a shell, both streams into `log`; return its status."""
    executable = shutil.which(command[0])
    if executable is None:
        raise FileNotFoundError(f"Executable not found: {command[0]}")
    # Reviewed S603: argv[0] resolved on PATH, no shell, caller-supplied arguments kept separate.
    completed = subprocess.run(  # noqa: S603
        [executable, *command[1:]], stdout=log, stderr=subprocess.STDOUT, check=False
    )
    return completed.returncode


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
        status = run_into(command, log)
        elapsed = time.monotonic() - clock
        log.write(f"\n# exit {status} after {elapsed:.0f}s\n")
        path = Path(log.name)
    lines = path.read_text(encoding="utf-8").splitlines()
    body = lines[4:-2]
    if len(body) > TAIL:
        print(f"... {len(body) - TAIL} earlier lines in {path}")
    print("\n".join(body[-TAIL:]))
    print(f"capture: {path} exit {status} after {elapsed:.0f}s", file=sys.stderr)
    return status


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
