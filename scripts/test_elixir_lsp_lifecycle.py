#!/usr/bin/env python3
"""Check real concurrent task sessions: eager startup, own-root results, EOF cleanup."""
import argparse
from concurrent.futures import ThreadPoolExecutor
import hashlib
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import time

from stress_elixir_lsp import Session, locations, success


def session_processes(pid, known=None):
    snapshot = subprocess.check_output(["/bin/ps", "-axo", "pid=,ppid=,pgid=,command="], text=True)
    processes = {}
    for line in snapshot.splitlines():
        fields = line.split(None, 3)
        if len(fields) == 4:
            processes[int(fields[0])] = (int(fields[1]), int(fields[2]), fields[3])
    owned = {pid}
    if known:
        owned.update(child for child, command in known.items()
                     if child in processes and processes[child][2] == command)
    while True:
        expanded = owned | {child for child, (parent, group, _) in processes.items()
                            if parent in owned or group == pid}
        if expanded == owned:
            break
        owned = expanded
    return {child: processes[child][2] for child in owned if child in processes}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--tools-dir", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("roots", type=Path, nargs="+")
    args = parser.parse_args()
    roots = [path.resolve() for path in args.roots]
    assert len(roots) == len(set(roots)) and len(roots) >= 2
    assert all((root / "mix.exs").is_file() for root in roots)
    args.output.mkdir(parents=True, exist_ok=False)
    results = []

    def check(root):
        log = root / ".expert/expert.log"
        log_offset = log.stat().st_size if log.exists() else 0
        launched = time.monotonic()
        owned = {}
        session = Session(args.tools_dir.resolve(), root, args.output, root.name)
        result = dict(root=str(root), bridge_pid=session.process.pid, checks={}, timings={})
        try:
            # No tools/call yet: model issue reading/planning time overlaps compilation.
            deadline = time.monotonic() + 20
            while time.monotonic() < deadline:
                if log.exists() and "Building " in log.read_bytes()[log_offset:].decode(errors="replace"):
                    break
                time.sleep(0.2)
            result["checks"]["build_before_first_tool"] = (
                log.exists() and "Building " in log.read_bytes()[log_offset:].decode(errors="replace"))
            result["timings"]["first_tool_after_launch"] = time.monotonic() - launched
            target = root / "test/tips/content/schema_test.exs"
            expected = {(str(target), str(line)) for line in
                        (89, 154, 160, 165, 179, 189, 200, 245, 408, 549, 552, 554, 569)}
            expected.add((str(root / "test/support/fixtures/content_fixtures.ex"), "24"))
            for phase in ("first-call", "warm-repeat"):
                reply, elapsed = session.call("references", target, 165, 13, phase)
                found = locations(reply)
                result["checks"][phase] = (success(reply) and len(found) == 14 and
                                          {(entry[0], entry[1]) for entry in found} == expected)
                result["timings"][phase] = elapsed
                print(json.dumps(dict(root=root.name, phase=phase,
                                      passed=result["checks"][phase], elapsed=elapsed)), flush=True)
            owned = session_processes(session.process.pid)
            result["processes_before_eof"] = owned
            closed = time.monotonic()
            session.process.stdin.close()
            try:
                result["checks"]["bridge_exits_on_eof"] = session.process.wait(timeout=10) == 0
            except subprocess.TimeoutExpired:
                result["checks"]["bridge_exits_on_eof"] = False
            # Expert's engine monitors its parent; allow its normal disconnect cleanup.
            deadline = time.monotonic() + 10
            remaining = session_processes(session.process.pid, owned)
            while remaining and time.monotonic() < deadline:
                time.sleep(0.2)
                remaining = session_processes(session.process.pid, owned)
            result["timings"]["shutdown"] = time.monotonic() - closed
            result["remaining_processes"] = remaining
            result["checks"]["no_expert_children"] = not remaining
        finally:
            remaining = session_processes(session.process.pid, owned)
            if remaining:
                # Failed-test cleanup, never counted as graceful shutdown.
                for pid in remaining:
                    try:
                        os.kill(pid, signal.SIGKILL)
                    except ProcessLookupError:
                        pass
            session.close()
            (args.output / f"{root.name}-requests.json").write_text(json.dumps(session.records, indent=2))
            if log.exists():
                shutil.copy2(log, args.output / f"{root.name}-expert.log")
        return result

    with ThreadPoolExecutor(max_workers=len(roots)) as pool:
        results = list(pool.map(check, roots))
    summary = dict(passed=all(all(r["checks"].values()) for r in results), sessions=results,
                   bridge_sha256=hashlib.sha256((args.tools_dir / "bin/mcp-language-server").read_bytes()).hexdigest())
    (args.output / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")
    print(json.dumps(summary), flush=True)
    return 0 if summary["passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
