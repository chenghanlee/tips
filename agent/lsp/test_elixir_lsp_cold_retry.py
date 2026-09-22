#!/usr/bin/env python3
"""Five cold Tips worktrees: immediate references, same-session retry, warm check."""
import argparse
from concurrent.futures import ThreadPoolExecutor, as_completed
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import threading
import time

from stress_elixir_lsp import Session, locations, success, text


def utc_now():
    return datetime.now(timezone.utc).isoformat()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--tools-dir", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("roots", type=Path, nargs=5)
    args = parser.parse_args()
    roots = [root.resolve() for root in args.roots]
    tools, output = args.tools_dir.resolve(), args.output.resolve()
    assert len(set(roots)) == 5, "Use five different worktrees"
    preflight = []
    for root in roots:
        assert (root / "mix.exs").is_file() and (root / "deps").is_dir(), root
        assert not (root / ".expert").exists(), f"Expert state already exists: {root}"
        assert not (root / "_build").exists(), f"Build state already exists: {root}"
        preflight.append(dict(root=str(root), cold_expert_state=True,
                              cold_project_build=True,
                              head=subprocess.check_output(
                                  ["git", "-C", str(root), "rev-parse", "HEAD"],
                                  text=True).strip()))
    output.mkdir(parents=True, exist_ok=False)
    metadata = dict(started=utc_now(), roots=preflight,
                    tools=str(tools), expert=str((tools / "bin/expert").resolve()),
                    bridge_sha256=hashlib.sha256(
                        (tools / "bin/mcp-language-server").read_bytes()).hexdigest(),
                    shared_engine_cache="existing installed cache; not removed",
                    load_average=os.getloadavg(), cpu_count=os.cpu_count(),
                    deadline_seconds=120, harness_timeout_seconds=130)
    (output / "preflight.json").write_text(json.dumps(metadata, indent=2) + "\n")
    sessions, results = [], []
    barrier = threading.Barrier(5)
    started = time.monotonic()

    def worker(number, root):
        label = f"agent-{number}"
        barrier.wait(timeout=30)
        launch = time.monotonic()
        session = Session(tools, root, output, label)
        sessions.append(session)
        expected = {(str(root / "test/tips/content/schema_test.exs"), str(line))
                    for line in (89, 154, 160, 165, 179, 189, 200, 245,
                                 408, 549, 552, 554, 569)}
        expected.add((str(root / "test/support/fixtures/content_fixtures.ex"), "24"))
        result = dict(session=label, root=str(root), bridge_pid=session.process.pid,
                      launch_seconds=launch - started, calls=[])

        def query(phase):
            sent = time.monotonic()
            timestamp = utc_now()
            reply, elapsed = session.call("references",
                root / "test/tips/content/schema_test.exs", 165, 13, phase)
            found = locations(reply)
            correct = (success(reply) and len(found) == 14
                       and len(set(found)) == 14
                       and {(entry[0], entry[1]) for entry in found} == expected)
            explicit_error = (
                reply.get("result", {}).get("isError") is True and bool(text(reply))
            ) or isinstance(reply.get("error"), dict)
            call = dict(phase=phase, sent=timestamp, since_launch=sent - launch,
                        elapsed=elapsed, correct=correct, count=len(found),
                        explicit_error=explicit_error,
                        deadline_error=explicit_error and "context deadline exceeded" in text(reply),
                        response=text(reply) if not correct else "14 exact own-project references",
                        reply=reply)
            result["calls"].append(call)
            print(json.dumps(dict(session=label, **{key: value for key, value in call.items()
                                                   if key != "reply"})), flush=True)
            return correct

        try:
            initialized = success(session.records[0]["reply"])
            result["initialized"] = initialized
            if initialized:
                cold_ok = query("cold-first-call")
                # Retry immediately, using the identical parameters and the same processes.
                recovered = query("warm-control" if cold_ok else "immediate-retry")
                if recovered:
                    query("warm-repeat")
            result["same_bridge_alive"] = session.process.poll() is None
        finally:
            (output / f"{label}-requests.json").write_text(
                json.dumps(session.records, indent=2) + "\n")
            (output / f"{label}-result.json").write_text(json.dumps(result, indent=2) + "\n")
        return result

    try:
        with ThreadPoolExecutor(max_workers=5) as pool:
            futures = [pool.submit(worker, number, root)
                       for number, root in enumerate(roots, 1)]
            for future in as_completed(futures):
                results.append(future.result())
    finally:
        for session in sessions:
            session.close()
        for number, root in enumerate(roots, 1):
            log = root / ".expert/expert.log"
            if log.exists():
                shutil.copy2(log, output / f"agent-{number}-expert.log")

    issues = []
    for result in results:
        label, calls = result["session"], result["calls"]
        if not result["initialized"] or not result["same_bridge_alive"] or len(calls) != 3:
            issues.append(f"{label}: incomplete or failed session")
        for call in calls:
            if call["phase"] == "cold-first-call":
                valid = call["correct"] or call["deadline_error"]
            else:
                valid = call["correct"]
            if not valid or call["elapsed"] > 125:
                issues.append(f"{label}/{call['phase']}: incorrect outcome or exceeded deadline")
        log_path = output / f"{label}-expert.log"
        log = log_path.read_text(errors="replace") if log_path.exists() else ""
        result["compile_events"] = re.findall(r".*Compiled .* in .*", log)
        result["startup_errors"] = re.findall(
            r".*(?:File\.Error|Build script exited|Failed to start project node).*", log)
        if not log or result["startup_errors"]:
            issues.append(f"{label}: missing log or startup failure")
    summary = dict(finished=utc_now(), elapsed=time.monotonic() - started,
                   first_call_passed=len(results) == 5 and all(
                       r["calls"] and r["calls"][0]["correct"] and r["calls"][0]["elapsed"] < 120
                       for r in results),
                   cold_successes=sum(bool(r["calls"] and r["calls"][0]["correct"]) for r in results),
                   cold_deadlines=sum(bool(r["calls"] and r["calls"][0]["deadline_error"]) for r in results),
                   recovered_on_next_call=sum(any(c["phase"] == "immediate-retry" and c["correct"]
                                                 for c in r["calls"]) for r in results),
                   passed=not issues and len(results) == 5, issues=issues,
                   sessions=sorted(results, key=lambda r: r["session"]))
    (output / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")
    print(json.dumps({key: value for key, value in summary.items() if key != "sessions"}), flush=True)
    return 0 if summary["passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
