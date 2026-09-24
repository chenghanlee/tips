"""Protocol client, isolated fixtures and process checks reused from the ElixirLS pilot."""
import argparse

import json

import os

from pathlib import Path

import queue

import signal

import subprocess

import threading

import time

def run(argv, cwd):
    return subprocess.check_output(argv, cwd=cwd, text=True, stderr=subprocess.STDOUT)

def process_table():
    rows = {}
    for line in run(["ps", "-axo", "pid=,ppid=,stat=,command="], "/").splitlines():
        pid, parent, state, command = line.strip().split(None, 3)
        rows[int(pid)] = {"parent": int(parent), "state": state, "command": command}
    return rows

def descendants(pid):
    rows = process_table()
    found = {pid}
    while True:
        expanded = found | {p for p, info in rows.items() if info["parent"] in found}
        if expanded == found:
            return {p: rows[p] for p in found if p in rows}
        found = expanded

def alive(pids):
    rows = process_table()
    return {p: rows[p] for p in pids if p in rows and not rows[p]["state"].startswith("Z")}

class MCP:

    def _read(self):
        for line in self.proc.stdout:
            self.transcript.write(line)
            self.transcript.flush()
            try:
                message = json.loads(line)
            except json.JSONDecodeError:
                self.responses.put({"error": {"message": "non-JSON stdout", "line": line}})
                continue
            if "id" in message and "method" not in message:
                self.responses.put(message)

    def send(self, message):
        self.proc.stdin.write(json.dumps(message) + "\n")
        self.proc.stdin.flush()

    def request(self, method, params, timeout=180):
        self.counter += 1
        request = {"jsonrpc": "2.0", "id": self.counter, "method": method, "params": params}
        self.transcript.write(json.dumps({"sent": request, "time": time.time()}) + "\n")
        self.transcript.flush()
        self.send(request)
        reply = self.responses.get(timeout=timeout)
        if reply.get("id") != self.counter:
            raise RuntimeError(f"Unexpected MCP response: {reply}")
        if "error" in reply:
            raise RuntimeError(reply["error"])
        return reply["result"]

    def call(self, name, **arguments):
        result = self.request("tools/call", {"name": name, "arguments": arguments})
        text = "\n".join(c.get("text", "") for c in result.get("content", []))
        try:
            data = json.loads(text)
        except json.JSONDecodeError:
            data = {"text": text}
        return {"isError": result.get("isError", False), "data": data}

    def nav(self, name, file="lib/caller.ex", line=2, column=29, **extra):
        return self.call(name, file_path=str(self.root / file), line=line, column=column, **extra)

    def remember(self):
        self.owned.update(descendants(self.proc.pid))
        return self.owned

    def cleanup(self):
        try:
            self.remember()
        except PermissionError:
            # Do not leave the bridge running if the host denies ps. The run
            # must still fail; termination here is only best-effort cleanup.
            if self.proc.poll() is None:
                self.proc.terminate()
            raise
        if self.proc.poll() is None:
            self.proc.terminate()
            try:
                self.proc.wait(timeout=10)
            except subprocess.TimeoutExpired:
                self.proc.kill()
                self.proc.wait(timeout=5)
        # Only descendants recorded for this experiment are eligible for cleanup.
        for pid in alive(self.owned):
            try:
                os.kill(pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
        deadline = time.monotonic() + 5
        while alive(self.owned) and time.monotonic() < deadline:
            time.sleep(0.2)
        for pid in alive(self.owned):
            try:
                os.kill(pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
        self.log.close()

def fixture(root, version):
    (root / "lib").mkdir(exist_ok=True)
    (root / "test").mkdir(exist_ok=True)
    (root / "mix.exs").write_text('''defmodule V2Fixture.MixProject do
  use Mix.Project
  def project, do: [app: :v2_fixture, version: "0.1.0", elixir: "~> 1.20"]
end
''')
    (root / ".gitignore").write_text("/_build/\n/.expert/\n")
    (root / "lib/target.ex").write_text(f'''defmodule V2Target do
  @doc "{version.upper()} documentation for the worktree experiment."
  def answer, do: :{version}
end
''')
    calls = "".join(f"  def call_{n}, do: V2Target.answer()\n" for n in range(1, 3 if version == "alpha" else 4))
    (root / "lib/caller.ex").write_text("defmodule V2Caller do\n" + calls + "end\n")
    (root / "test/test_helper.exs").write_text("ExUnit.start()\n")
    (root / "test/fixture_test.exs").write_text(f'''defmodule V2FixtureTest do
  use ExUnit.Case, async: true

  test "fixture revision" do
    assert V2Caller.call_1() == :{version}
  end
end
''')

def prepare(output):
    alpha, beta = output / "alpha", output / "beta"
    alpha.mkdir()
    run(["git", "init", "-q"], alpha)
    fixture(alpha, "alpha")
    run(["git", "add", "."], alpha)
    run(["git", "-c", "user.name=Tips experiment", "-c", "user.email=experiment@localhost", "commit", "-qm", "Alpha fixture"], alpha)
    a_sha = run(["git", "rev-parse", "HEAD"], alpha).strip()
    fixture(alpha, "beta")
    run(["git", "add", "."], alpha)
    run(["git", "-c", "user.name=Tips experiment", "-c", "user.email=experiment@localhost", "commit", "-qm", "Beta fixture"], alpha)
    b_sha = run(["git", "rev-parse", "HEAD"], alpha).strip()
    run(["git", "worktree", "add", "--detach", str(beta), b_sha], alpha)
    run(["git", "checkout", "--detach", a_sha], alpha)
    for root in (alpha, beta):
        (output / f"{root.name}-mix.log").write_text(
            run(["unbuffer", "mix", "compile", "--warnings-as-errors"], root)
            + run(["unbuffer", "mix", "test"], root)
        )
    return alpha, beta, a_sha, b_sha
