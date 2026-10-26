"""Run the harness tests in parallel processes.

The suite is about 90 Harness tests that each build a repository, fakes and child
processes, so a serial run takes 4 to 5 minutes. This splits the discovered tests over
worker processes, one `python -m unittest` each, and reports the combined result. The
tests already isolate their files per test; the fakes are written once per process.
Each worker gets its own port range through `TIPS_TEST_PORT_BASE`.
The real-daemon and real-client opt-ins share ports, so they run in one worker.

    agent/teams/.venv/bin/python agent/teams/tests/parallel.py [-j N] [-k SUBSTRING]...
"""

import argparse
import os
import re
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path

TESTS = Path(__file__).resolve().parent
TEAMS = TESTS.parent
SERIAL = "real_"
PORT_BASE = 24100
PORT_RANGE = 100  # six teams of ten ports each
# The opt-in test groups: the id marker, the variables they need (the first one's absence
# skips them), and the
# change that requires them (development.md, Required checks). A bare `skipped=N` cannot
# tell an opt-in from a platform skip, so the summary names the opt-in it skipped.
OPT_INS = (
    (
        "real_daemons",
        ("TIPS_TEST_REAL_DEXTER", "DEXTER_ELIXIR_LIB_ROOT"),
        "real-daemon tests",
        "non-Markdown agent/teams changes",
    ),
    (
        "codex_started_in_the_allocation",
        ("TIPS_TEST_REAL_CODEX",),
        "installed-Codex tests",
        "Codex launch argument changes",
    ),
)


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
    if jobs == 1:
        return [rest + serial]
    workers = max(1, min(jobs - bool(serial), len(rest)))
    groups = [rest[n::workers] for n in range(workers)]
    return [g for g in [*groups, serial] if g]


def skipped_opt_ins(ids: list[str], environ: dict[str, str]) -> list[str]:
    """One line per opt-in whose selected tests this environment skips, with the change
    that requires them."""
    lines: list[str] = []
    for marker, variables, name, required_for in OPT_INS:
        count = sum(marker in test_id for test_id in ids)
        if count and not environ.get(variables[0]):
            lines.append(
                f"skipped opt-in: {name} ({count}): set {' and '.join(variables)}; required for "
                f"{required_for} (agent/teams/development.md#required-checks)"
            )
    return lines


def start_worker(group: list[str], log: Path, index: int) -> subprocess.Popen[bytes]:
    """Start one unittest process writing to a log file. A pipe would stay open while a
    background child of a failed test still holds the inherited descriptors. Each worker
    gets its own port range: team tests bind and probe real ports."""
    env = {**os.environ, "TIPS_TEST_PORT_BASE": str(PORT_BASE + PORT_RANGE * index)}
    with log.open("wb") as sink:
        # Reviewed S603: this interpreter and discovered test ids, no shell.
        return subprocess.Popen(  # noqa: S603
            [sys.executable, "-m", "unittest", *group], cwd=TEAMS, stdout=sink, stderr=sink, env=env
        )


def main() -> int:
    parser = argparse.ArgumentParser(description="Run the harness tests in parallel processes.")
    parser.add_argument("-j", "--jobs", type=int, default=os.cpu_count() or 2)
    parser.add_argument("-k", action="append", default=[], help="keep ids containing this")
    args = parser.parse_args()
    if args.jobs < 1:
        parser.error("--jobs must be at least 1")
    ids = test_ids(args.k)
    if not ids:
        return int(print("parallel: no tests selected", file=sys.stderr) or 1)
    started = time.monotonic()
    groups = chunks(ids, args.jobs)
    with tempfile.TemporaryDirectory(prefix="parallel-") as logs:
        files = [Path(logs) / f"{n}.log" for n in range(len(groups))]
        workers = [
            start_worker(g, f, n) for n, (g, f) in enumerate(zip(groups, files, strict=True))
        ]
        runs = [(w.wait(), f.read_text()) for w, f in zip(workers, files, strict=True)]
    ran = skipped = 0
    failed = False
    for code, output in runs:
        tail = output.rstrip().splitlines()[-3:]
        counts = re.search(r"Ran (\d+) tests?", output)
        ran += int(counts.group(1)) if counts else 0
        skips = re.search(r"skipped=(\d+)", output)
        skipped += int(skips.group(1)) if skips else 0
        if code or not counts:
            failed = True
            print(output)
        elif tail:
            print(tail[-1])
    seconds = time.monotonic() - started
    print(f"\nRan {ran} of {len(ids)} tests in {seconds:.1f}s over {len(runs)} processes")
    for line in skipped_opt_ins(ids, dict(os.environ)):
        print(line)
    print("FAILED" if failed or ran != len(ids) else f"OK (skipped={skipped})")
    return int(failed or ran != len(ids))


if __name__ == "__main__":
    sys.exit(main())
