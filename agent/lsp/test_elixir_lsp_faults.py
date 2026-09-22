#!/usr/bin/env python3
"""Freeze a real Expert subprocess and verify bounded MCP failure and recovery."""

import argparse
import json
import os
from pathlib import Path
import queue
import signal
import subprocess
import tempfile
import threading
import time


parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--tools-dir", type=Path, required=True)
parser.add_argument("--evidence-dir", type=Path)
args = parser.parse_args()

tools = args.tools_dir.resolve()
evidence = (
    args.evidence_dir.resolve()
    if args.evidence_dir
    else Path(tempfile.mkdtemp(prefix="tips-expert-faults-"))
)
evidence.mkdir(parents=True, exist_ok=True)
root = evidence / "project"
root.mkdir()
(root / "mix.exs").write_text(
    """defmodule ExpertFaults.MixProject do
  use Mix.Project
  def project, do: [app: :expert_faults, version: "0.1.0", elixir: "~> 1.15"]
end
"""
)
(root / "lib").mkdir()
source = root / "lib/sample.ex"
source.write_text(
    """defmodule ExpertFaults do
  def target(value), do: {:ok, value}
  def first(value), do: target(value)
  def second(value), do: target(value + 1)
end
"""
)

messages = queue.Queue()
pending = {}
report = {
    "evidence_dir": str(evidence),
    "project": str(root),
    "bridge_log": str(evidence / "bridge.log"),
    "client_call_deadline_seconds": 60,
    "tool_deadline_seconds": 120,
    "calls": [],
}
process = None
expert_pid = None
expert_stopped = False
failure = None


def write_report(status, error=None):
    report["status"] = status
    if error is not None:
        report["error"] = repr(error)
    (evidence / "report.json").write_text(json.dumps(report, indent=2) + "\n")


def read_messages():
    for line in process.stdout:
        try:
            messages.put(json.loads(line))
        except ValueError:
            report.setdefault("non_json_stdout", []).append(line.rstrip())
    messages.put(None)


def send(message):
    process.stdin.write(json.dumps(message) + "\n")
    process.stdin.flush()


def receive(identifier, timeout):
    if identifier in pending:
        return pending.pop(identifier)
    deadline = time.monotonic() + timeout
    while True:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise TimeoutError(f"no MCP response for request {identifier} within {timeout}s")
        reply = messages.get(timeout=remaining)
        if reply is None:
            raise RuntimeError("MCP bridge exited before replying")
        reply_id = reply.get("id")
        if reply_id is None:
            continue
        if reply_id == identifier:
            return reply
        pending[reply_id] = reply


def request(identifier, method, params, timeout=130):
    started = time.monotonic()
    send({"jsonrpc": "2.0", "id": identifier, "method": method, "params": params})
    response = receive(identifier, timeout)
    elapsed = time.monotonic() - started
    report["calls"].append(
        {
            "id": identifier,
            "method": method,
            "client_elapsed_seconds": round(elapsed, 3),
            "response": response,
        }
    )
    return response, elapsed


def references_params():
    return {
        "name": "references",
        "arguments": {"filePath": str(source), "line": 3, "column": 25},
    }


def process_rows():
    output = subprocess.check_output(
        ["ps", "-axo", "pid=,ppid=,pgid=,stat=,command="], text=True
    )
    rows = []
    for line in output.splitlines():
        fields = line.strip().split(None, 4)
        if len(fields) != 5:
            continue
        pid, ppid, pgid = map(int, fields[:3])
        rows.append(
            {"pid": pid, "ppid": ppid, "pgid": pgid, "stat": fields[3], "command": fields[4]}
        )
    return rows


def find_owned_expert():
    deadline = time.monotonic() + 10
    while time.monotonic() < deadline:
        candidates = [
            row
            for row in process_rows()
            if row["ppid"] == process.pid
            and row["pgid"] == process.pid
            and ("beam.smp" in row["command"] or "start_expert" in row["command"])
        ]
        if len(candidates) == 1:
            return candidates[0]
        if len(candidates) > 1:
            raise RuntimeError(f"ambiguous owned Expert processes: {candidates}")
        time.sleep(0.1)
    raise RuntimeError("could not identify the bridge-owned Expert manager process")


def assert_reference_success(response):
    assert not response["result"].get("isError"), response
    text = json.dumps(response)
    assert "L3:" in text and "L4:" in text, response


try:
    with (evidence / "bridge.log").open("w") as bridge_log:
        process = subprocess.Popen(
            [
                str(tools / "bin/mcp-language-server"),
                "--workspace",
                str(root),
                "--lsp",
                str(tools / "bin/expert"),
                "--",
                "--stdio",
            ],
            cwd=root,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=bridge_log,
            text=True,
            start_new_session=True,
        )
        threading.Thread(target=read_messages, daemon=True).start()

        request(
            1,
            "initialize",
            {
                "protocolVersion": "2024-11-05",
                "capabilities": {},
                "clientInfo": {"name": "expert-fault-test", "version": "1"},
            },
        )
        send({"jsonrpc": "2.0", "method": "notifications/initialized"})

        warm_response, warm_elapsed = request(2, "tools/call", references_params())
        assert_reference_success(warm_response)
        report["warm_elapsed_seconds"] = round(warm_elapsed, 3)

        expert = find_owned_expert()
        expert_pid = expert["pid"]
        report["bridge_pid"] = process.pid
        report["expert_process"] = expert
        os.kill(expert_pid, signal.SIGSTOP)
        expert_stopped = True
        time.sleep(0.2)
        stopped = next(row for row in process_rows() if row["pid"] == expert_pid)
        report["expert_stopped_stat"] = stopped["stat"]
        assert "T" in stopped["stat"], stopped

        queued_at = time.monotonic()
        for identifier in (3, 4, 5):
            send(
                {
                    "jsonrpc": "2.0",
                    "id": identifier,
                    "method": "tools/call",
                    "params": references_params(),
                }
            )

        stalled_response = receive(3, 75)
        stalled_elapsed = time.monotonic() - queued_at
        report["calls"].append(
            {
                "id": 3,
                "method": "tools/call",
                "client_elapsed_seconds": round(stalled_elapsed, 3),
                "response": stalled_response,
            }
        )
        stalled_text = json.dumps(stalled_response).lower()
        assert stalled_response["result"].get("isError"), stalled_response
        assert "deadline exceeded" in stalled_text, stalled_response
        assert 50 <= stalled_elapsed < 75, stalled_elapsed
        report["stalled_elapsed_seconds"] = round(stalled_elapsed, 3)

        os.kill(expert_pid, signal.SIGCONT)
        expert_stopped = False
        report["resumed_at_monotonic"] = time.monotonic()

        queued_calls = []
        for identifier in (4, 5):
            queued_response = receive(identifier, 30)
            queued_elapsed = time.monotonic() - queued_at
            assert_reference_success(queued_response)
            call = {
                "id": identifier,
                "method": "tools/call",
                "client_elapsed_seconds": round(queued_elapsed, 3),
                "response": queued_response,
            }
            queued_calls.append(call)
            report["calls"].append(call)
        report["queued_calls_after_resume"] = queued_calls

        recovered_response, recovered_elapsed = request(
            6, "tools/call", references_params(), timeout=30
        )
        assert_reference_success(recovered_response)
        assert recovered_elapsed < 30, recovered_elapsed
        report["recovery_elapsed_seconds"] = round(recovered_elapsed, 3)
        write_report("PASS")
        print(json.dumps(report, indent=2), flush=True)
except BaseException as error:
    failure = error
    write_report("FAIL", error)
    raise
finally:
    if expert_stopped and expert_pid is not None:
        try:
            os.kill(expert_pid, signal.SIGCONT)
        except ProcessLookupError:
            pass
    if process is not None and process.poll() is None:
        try:
            os.killpg(process.pid, signal.SIGTERM)
            process.wait(timeout=5)
        except (ProcessLookupError, subprocess.TimeoutExpired):
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            process.wait()
    if failure is not None:
        print(f"Failure evidence: {evidence}", flush=True)
