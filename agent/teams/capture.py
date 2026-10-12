#!/usr/bin/env python3
"""Run a check and keep its complete output and exit status in a new log under tmp/checks.

Usage: agent/teams/capture.py <label> -- <command> [args...]

The log is never overwritten or deleted by this tool, so the first failing run stays on disk
until the PR records its test, error and seed. The command's output is also printed, and its
exit status is returned.
"""

import re
import sys
import time
from datetime import UTC, datetime
from pathlib import Path

from team import execute

LOGS = Path("tmp/checks")
USAGE = "Usage: agent/teams/capture.py <label> -- <command> [args...]"


def log_path(label: str, now: datetime) -> Path:
    """A new file for this run; a second run in the same second gets a numbered name."""
    slug = re.sub(r"[^A-Za-z0-9._-]+", "-", label).strip("-") or "check"
    stamp = now.strftime("%Y%m%dT%H%M%SZ")
    path = LOGS / f"{stamp}-{slug}.log"
    counter = 1
    while path.exists():
        counter += 1
        path = LOGS / f"{stamp}-{slug}-{counter}.log"
    return path


def capture(label: str, command: list[str]) -> int:
    LOGS.mkdir(parents=True, exist_ok=True)
    started = datetime.now(UTC)
    path = log_path(label, started)
    clock = time.monotonic()
    result = execute(command)
    elapsed = time.monotonic() - clock
    header = (
        f"# {label}\n# command: {' '.join(command)}\n"
        f"# cwd: {Path.cwd()}\n# started: {started.isoformat()}\n"
    )
    footer = f"\n# exit {result.returncode} after {elapsed:.0f}s\n"
    path.write_text(header + result.stdout + result.stderr + footer)
    sys.stdout.write(result.stdout)
    sys.stderr.write(result.stderr)
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
