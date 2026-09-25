#!/usr/bin/env python3
"""Hook text contract gate after Astra's D1 decision (2026-09-25), for any installed bundle.

Through the installed hook (`bundle.py hook`), on the first-touch acceptance fixture:
  S1  edited PostToolUse while one open document never gets its publication: keeps the
      publication-pending reason (not "Compilation is still pending"), stays qualified,
      no restart advice. Whether it names the file is recorded, not judged.
  S2  Stop after S1: blocks; validation unfinished because document diagnostics have not
      arrived; not "Compilation is still pending"; no restart advice.
  S3  repeated Stop (stop_hook_active): {} (once per turn).
  D1  PostToolUse whose deadline passes before any RPC (--budget-ms 1): deadline-only
      text (unfinished; not confirmed within the budget), no restart advice.
  D2  PostToolUse whose deadline passes before collection (--budget-ms 300): same.
  D3  Stop with a deadline: blocks with the same deadline-only text.
  D4  repeated Stop with a deadline (stop_hook_active): {}.
Every check also needs the hook to exit 0: a crashed hook prints nothing, which reads as {}.
Real build pending, detected exit and disconnection are in the runtime-review stop_probe.py.

Run: python3 hook_contract_probe.py --bundle <installed bundle> --output <new directory>
It exits 0 only when every check passed, EOF cleanup worked and no process survived.
Once the harness has started, a failed check or an exception still cleans up, writes
results.json and exits nonzero.
It imports first_touch_acceptance, neovim_probe and probe from this directory.
"""

import argparse
import json
import re
import subprocess
import sys
import time
from pathlib import Path

from first_touch_acceptance import BOUNDARY, Harness
from neovim_probe import poll
from probe import alive

BUILD = "Compilation is still pending"
CLEAN = {"failed": [], "eof_cleanup": True, "survivors_after_cleanup": []}


def restart(text):
    return re.search(r"restart|has stopped|reconnect", text, re.I) is not None


def publication(text):
    return (
        re.search(r"publish|arriv|document diagnostics", text, re.I) is not None
        and BUILD not in text
    )


def deadline(text):
    return (
        not restart(text)
        and re.search(r"unfinished", text, re.I) is not None
        and re.search(r"budget|deadline|confirm", text, re.I) is not None
    )


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--bundle", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    bundle, output = args.bundle.resolve(), args.output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    sys.path.insert(0, str(bundle / "vendor/python"))
    h = Harness(bundle, output)
    audit = output / "hook-audit.jsonl"
    results = {"bundle": str(bundle), "steps": [], "checks": []}

    def hook(label, event="PostToolUse", budget=5000, active=False):
        started = time.monotonic()
        run = subprocess.run(  # noqa: S603 - current Python, bundled entry point, no shell
            [
                sys.executable,
                str(bundle / "bundle.py"),
                "hook",
                "--workspace",
                str(h.root),
                "--state",
                str(h.client.state_dir),
                "--budget-ms",
                str(budget),
                "--audit",
                str(audit),
            ],
            input=json.dumps(
                {"hook_event_name": event, "tool_name": "apply_patch", "stop_hook_active": active}
            ),
            capture_output=True,
            text=True,
            timeout=30,
        )
        raw = json.loads(run.stdout or "null") or {}
        text = raw.get("reason") or raw.get("hookSpecificOutput", {}).get("additionalContext", "")
        row = {
            "step": label,
            "seconds": round(time.monotonic() - started, 2),
            "exit": run.returncode,
            "stderr": run.stderr[-600:],
            "empty": raw == {},
            "block": raw.get("decision") == "block",
            "text": text,
        }
        results["steps"].append(row)
        return row

    def check(name, condition, row):
        passed = bool(condition) and row["exit"] == 0
        results["checks"].append({"name": name, "pass": passed})
        shown = json.dumps(row["text"][:260]) if row["text"] else "{}"
        timing = f"[{row['seconds']} s, exit {row['exit']}]"
        print(f"{'PASS' if passed else 'FAIL'} {name}  {timing} {shown}", flush=True)

    try:
        results["ready"] = h.ready()
        time.sleep(2)
        if not h.lua(BOUNDARY, {"lost_test.exs": "drop"}):
            raise RuntimeError("boundary not installed")
        h.call("diagnostics", "test/lost_test.exs")
        time.sleep(1.5)
        alpha = h.root / "lib/alpha.ex"
        alpha.write_text(alpha.read_text() + "# edited\n")

        s1 = hook("S1")
        check(
            "S1 edited PostToolUse, publication missing: publication reason, qualified, no restart",
            publication(s1["text"])
            and re.search(r"not a clean result|may be stale", s1["text"], re.I)
            and not restart(s1["text"]),
            s1,
        )
        results["S1_names_file"] = "lost_test.exs" in s1["text"]
        print("MEASURED S1 names the pending file:", results["S1_names_file"], flush=True)
        s2 = hook("S2", event="Stop")
        check(
            "S2 Stop blocks: unfinished because document diagnostics have not arrived, no restart",
            s2["block"]
            and publication(s2["text"])
            and re.search(r"unfinished", s2["text"], re.I)
            and not restart(s2["text"]),
            s2,
        )
        s3 = hook("S3", event="Stop", active=True)
        check("S3 repeated Stop {} (once per turn)", s3["empty"], s3)

        d1 = hook("D1", budget=1)
        check(
            "D1 PostToolUse, deadline before RPC: deadline-only text, no restart",
            deadline(d1["text"]),
            d1,
        )
        d2 = hook("D2", budget=300)
        check(
            "D2 PostToolUse, deadline before collection: deadline-only text, no restart",
            deadline(d2["text"]),
            d2,
        )
        d3 = hook("D3", event="Stop", budget=1)
        check(
            "D3 Stop with a deadline: blocks with deadline-only text",
            d3["block"] and deadline(d3["text"]),
            d3,
        )
        d4 = hook("D4", event="Stop", budget=1, active=True)
        check("D4 repeated Stop with a deadline: {}", d4["empty"], d4)

        h.client.remember()
        h.client.proc.stdin.close()
        h.client.proc.wait(timeout=10)
        results["eof_cleanup"] = poll(lambda: alive(h.client.owned), lambda p: not p, 6)["matched"]
    finally:
        try:
            h.client.cleanup()
            results["survivors_after_cleanup"] = sorted(alive(h.client.owned))
        finally:
            lines = audit.read_text().splitlines() if audit.exists() else []
            results["audit"] = [json.loads(line) for line in lines]
            (output / "results.json").write_text(json.dumps(results, indent=2) + "\n")
    summary = {
        "failed": [c["name"][:2] for c in results["checks"] if not c["pass"]],
        "eof_cleanup": results.get("eof_cleanup"),
        "survivors_after_cleanup": results.get("survivors_after_cleanup"),
    }
    print(json.dumps(summary), flush=True)
    if summary != CLEAN:
        raise SystemExit(1)


if __name__ == "__main__":
    main()
