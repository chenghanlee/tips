"""Run the harness tests in parallel processes.

The suite is about 90 Harness tests that each build a repository, fakes and child
processes, so a serial run takes 4 to 5 minutes. This splits the discovered tests over
worker processes, one `python -m unittest` each, and reports the combined result. The
tests already isolate their files per test; the fakes are written once per process.
The real-daemon and real-client opt-ins share ports, so they run in one worker.

    agent/teams/.venv/bin/python agent/teams/tests/parallel.py [-j N] [-k SUBSTRING]...
"""

import argparse
import os
import re
import subprocess
import sys
import time
import unittest
from pathlib import Path

TESTS = Path(__file__).resolve().parent
TEAMS = TESTS.parent
SERIAL = "real_"


def test_ids(patterns: list[str]) -> list[str]:
    suite = unittest.TestLoader().discover(str(TESTS), "test_*.py", str(TEAMS))
    ids: list[str] = []
    pending: list[unittest.TestSuite | unittest.TestCase] = [suite]
    while pending:
        item = pending.pop()
        if isinstance(item, unittest.TestSuite):
            pending.extend(item)
        else:
            ids.append(item.id())
    broken = [i for i in ids if i.startswith("unittest.loader")]
    if broken:
        sys.exit(f"parallel: discovery failed: {broken}")
    return sorted(i for i in ids if not patterns or any(p in i for p in patterns))


def chunks(ids: list[str], jobs: int) -> list[list[str]]:
    serial = [i for i in ids if SERIAL in i]
    rest = [i for i in ids if SERIAL not in i]
    workers = max(1, min(jobs - bool(serial), len(rest)))
    groups = [rest[n::workers] for n in range(workers)]
    return [g for g in [*groups, serial] if g]


def main() -> int:
    parser = argparse.ArgumentParser(description="Run the harness tests in parallel processes.")
    parser.add_argument("-j", "--jobs", type=int, default=os.cpu_count() or 2)
    parser.add_argument("-k", action="append", default=[], help="keep ids containing this")
    args = parser.parse_args()
    ids = test_ids(args.k)
    if not ids:
        return int(print("parallel: no tests selected", file=sys.stderr) or 1)
    started = time.monotonic()
    # Reviewed S603: this interpreter and discovered test ids, no shell.
    runs = [
        subprocess.Popen(  # noqa: S603
            [sys.executable, "-m", "unittest", *group],
            cwd=TEAMS,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
        )
        for group in chunks(ids, args.jobs)
    ]
    outputs = [run.communicate()[0] for run in runs]
    ran = skipped = 0
    failed = False
    for run, output in zip(runs, outputs, strict=True):
        tail = output.rstrip().splitlines()[-3:]
        counts = re.search(r"Ran (\d+) tests?", output)
        ran += int(counts.group(1)) if counts else 0
        skips = re.search(r"skipped=(\d+)", output)
        skipped += int(skips.group(1)) if skips else 0
        if run.returncode or not counts:
            failed = True
            print(output)
        elif tail:
            print(tail[-1])
    seconds = time.monotonic() - started
    print(f"\nRan {ran} of {len(ids)} tests in {seconds:.1f}s over {len(runs)} processes")
    print("FAILED" if failed or ran != len(ids) else f"OK (skipped={skipped})")
    return int(failed or ran != len(ids))


if __name__ == "__main__":
    sys.exit(main())
