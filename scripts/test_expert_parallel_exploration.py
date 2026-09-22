#!/usr/bin/env python3
"""Exercise an exploratory Expert build with parallel, same-name Mix projects."""

import argparse
from concurrent.futures import ThreadPoolExecutor
import json
import os
from pathlib import Path
import queue
import re
import signal
import subprocess
import threading
import time


class Session:
    def __init__(self, tools_dir, root, evidence, label, process_env):
        self.root = root
        self.label = label
        self.lock = threading.Lock()
        self.pending = {}
        self.next_id = 0
        self.records = []
        self.log_path = evidence / f"{label}-bridge.log"
        self.log = self.log_path.open("w")
        self.process = subprocess.Popen(
            [
                str(tools_dir / "bin/mcp-language-server"),
                "--workspace",
                str(root),
                "--lsp",
                str(tools_dir / "bin/expert"),
                "--",
                "--stdio",
            ],
            cwd=root,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=self.log,
            text=True,
            start_new_session=True,
            env=process_env,
        )
        threading.Thread(target=self._read, daemon=True).start()
        self.request(
            "initialize",
            {
                "protocolVersion": "2024-11-05",
                "capabilities": {},
                "clientInfo": {"name": "expert-parallel-exploration", "version": "1"},
            },
            "initialize",
        )
        self.send({"jsonrpc": "2.0", "method": "notifications/initialized"})

    def _read(self):
        for line in self.process.stdout:
            try:
                reply = json.loads(line)
            except ValueError:
                continue
            with self.lock:
                receiver = self.pending.get(reply.get("id"))
            if receiver:
                receiver.put(reply)
        with self.lock:
            receivers = list(self.pending.values())
        for receiver in receivers:
            receiver.put({"error": "MCP process exited"})

    def send(self, payload):
        with self.lock:
            self.process.stdin.write(json.dumps(payload) + "\n")
            self.process.stdin.flush()

    def request(self, method, params, phase, timeout=130):
        receiver = queue.Queue()
        with self.lock:
            self.next_id += 1
            identifier = self.next_id
            self.pending[identifier] = receiver
        started = time.monotonic()
        self.send({"jsonrpc": "2.0", "id": identifier, "method": method, "params": params})
        try:
            reply = receiver.get(timeout=timeout)
        except queue.Empty:
            reply = {"error": f"MCP response exceeded {timeout} seconds"}
        elapsed = time.monotonic() - started
        with self.lock:
            self.pending.pop(identifier, None)
            self.records.append(
                {
                    "session": self.label,
                    "phase": phase,
                    "method": method,
                    "params": params,
                    "elapsed": elapsed,
                    "reply": reply,
                }
            )
        return reply, elapsed

    def references(self, path, line, column, phase):
        return self.request(
            "tools/call",
            {
                "name": "references",
                "arguments": {"filePath": str(path), "line": line, "column": column},
            },
            phase,
        )

    def close(self):
        if self.process.poll() is None:
            os.killpg(self.process.pid, signal.SIGTERM)
            try:
                self.process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                os.killpg(self.process.pid, signal.SIGKILL)
                self.process.wait()
        self.log.close()


def response_text(reply):
    return "\n".join(
        item.get("text", "") for item in reply.get("result", {}).get("content", [])
    )


def successful(reply):
    return "error" not in reply and not reply.get("result", {}).get("isError")


def locations(reply):
    return re.findall(
        r"File: (.+)\nRange: L(\d+):C(\d+) - L(\d+):C(\d+)", response_text(reply)
    )


def write_project(root, usage_count, value_offset=0):
    root.mkdir(parents=True)
    (root / "lib").mkdir()
    app = re.sub(r"[^a-z0-9_]", "_", root.name.lower())
    (root / "mix.exs").write_text(
        "defmodule ParallelFixture.MixProject do\n"
        "  use Mix.Project\n\n"
        f"  def project, do: [app: :{app}, version: \"0.1.0\", elixir: \"~> 1.18\"]\n"
        "end\n"
    )
    (root / "lib/target.ex").write_text(
        "defmodule ParallelFixture.Target do\n"
        "  @moduledoc false\n\n"
        "  def echo(value), do: value\n"
        "end\n"
    )
    for index in range(usage_count):
        (root / f"lib/caller_{index}.ex").write_text(
            f"defmodule ParallelFixture.Caller{value_offset + index} do\n"
            "  @moduledoc false\n\n"
            "  alias ParallelFixture.Target\n\n"
            f"  def run, do: Target.echo({value_offset + index})\n"
            "end\n"
        )


def call_position(path):
    for line_number, line in enumerate(path.read_text().splitlines(), 1):
        if "echo(" in line:
            return line_number, line.index("echo(") + 1
    raise ValueError(f"No echo call in {path}")


def expected_locations(root, count):
    return {
        (str(root / f"lib/caller_{index}.ex"), str(call_position(root / f"lib/caller_{index}.ex")[0]))
        for index in range(count)
    }


def query_exact(session, root, count, phase):
    caller = root / "lib/caller_0.ex"
    reply, elapsed = session.references(caller, *call_position(caller), phase)
    found = locations(reply)
    actual = {(item[0], item[1]) for item in found}
    expected = expected_locations(root, count)
    return {
        "name": f"{phase}/{session.label}/references-{count}",
        "passed": successful(reply) and actual == expected and len(found) == count,
        "detail": {
            "elapsed": elapsed,
            "expected": sorted(expected),
            "actual": sorted(actual),
            "response": "" if found else response_text(reply),
        },
    }


def log_failures(roots):
    patterns = re.compile(
        r"File\.Error|Build script exited|Failed to start project node|"
        r"Engine build script exited|Hex\.Registry\.Server|:eaccess|:eacces"
    )
    failures = []
    for root in roots:
        log = root / ".expert/expert.log"
        if not log.exists():
            continue
        for line_number, line in enumerate(log.read_text(errors="replace").splitlines(), 1):
            if patterns.search(line):
                failures.append({"file": str(log), "line": line_number, "text": line})
    return failures


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--tools-dir", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    tools = args.tools_dir.resolve()
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    cache = output / "cache"
    cache.mkdir()
    hex_home = cache / "hex"
    hex_home.mkdir()
    process_env = os.environ.copy()
    process_env["TIPS_EXPERT_TEST_CACHE"] = str(cache)
    process_env["HEX_HOME"] = str(hex_home)
    checks = []
    sessions = []
    started = time.monotonic()

    roots = [output / f"worker-{index}" for index in range(5)]
    nested = roots[0] / ".worktrees/nested" / roots[0].name
    for index, root in enumerate(roots):
        write_project(root, usage_count=index + 2, value_offset=index * 100)
    write_project(nested, usage_count=9, value_offset=1_000)

    def record(result):
        checks.append(result)
        print(json.dumps(result), flush=True)

    def start_and_query(index, phase):
        label = f"{phase}-session-{index}"
        session = Session(tools, roots[index], output, label, process_env)
        sessions.append(session)
        record(query_exact(session, roots[index], index + 2, phase))
        return session

    try:
        with ThreadPoolExecutor(max_workers=5) as pool:
            cold = list(pool.map(lambda index: start_and_query(index, "cold"), range(5)))

        # The nested project deliberately has the same basename and module names as its parent.
        # Querying inner then outer detects both wrong reads and writes polluting the leader table.
        record(query_exact(cold[0], nested, 9, "same-name-inner"))
        record(query_exact(cold[0], roots[0], 2, "same-name-outer-after-inner"))

        for session in cold:
            session.close()

        with ThreadPoolExecutor(max_workers=5) as pool:
            warm = list(pool.map(lambda index: start_and_query(index, "warm-restart"), range(5)))

        record(query_exact(warm[0], nested, 9, "warm-same-name-inner"))
        record(query_exact(warm[0], roots[0], 2, "warm-same-name-outer-after-inner"))
    except Exception as error:
        record({"name": "harness-exception", "passed": False, "detail": repr(error)})
    finally:
        for session in sessions:
            session.close()
        all_roots = roots + [nested]
        build_errors = log_failures(all_roots)
        record(
            {
                "name": "expert-logs/no-cache-build-errors",
                "passed": not build_errors,
                "detail": build_errors,
            }
        )
        records = [record for session in sessions for record in session.records]
        (output / "requests.json").write_text(json.dumps(records, indent=2))
        summary = {
            "tools_dir": str(tools),
            "elapsed": time.monotonic() - started,
            "requests": len(records),
            "checks": checks,
            "failures": [check for check in checks if not check["passed"]],
        }
        (output / "summary.json").write_text(json.dumps(summary, indent=2))
        print(
            json.dumps(
                {
                    "requests": len(records),
                    "checks": len(checks),
                    "failures": len(summary["failures"]),
                    "elapsed": summary["elapsed"],
                    "evidence": str(output),
                }
            ),
            flush=True,
        )
    return 1 if summary["failures"] else 0


if __name__ == "__main__":
    raise SystemExit(main())
