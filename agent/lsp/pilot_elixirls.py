#!/usr/bin/env python3
"""Opt-in, local-only two-worktree ElixirLS acceptance pilot; retain all evidence."""

import concurrent.futures
import json
import os
import queue
import signal
import subprocess
import sys
import threading
import time
from pathlib import Path


LAUNCHER = Path(__file__).with_name("launch_worktree_elixirls.py").resolve()


def run(*args, cwd=None):
    return subprocess.run(args, cwd=cwd, check=True, capture_output=True, text=True).stdout


class Client:
    def __init__(self, root, output):
        self.log = output.open("w")
        self.messages = queue.Queue()
        self.sequence = 0
        self.process = subprocess.Popen(
            [sys.executable, str(LAUNCHER), str(root)],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=self.log,
            start_new_session=True, env={**os.environ, "LOG_LEVEL": "DEBUG", "MIX_ENV": "test"},
        )
        input_pipe, output_pipe = self.process.stdin, self.process.stdout
        if input_pipe is None or output_pipe is None:
            raise RuntimeError("pilot requires stdin/stdout pipes")
        self.input = input_pipe
        self.output = output_pipe
        self.reader = threading.Thread(target=self.read, daemon=True)
        self.reader.start()

    def read(self):
        try:
            for line in self.output:
                self.messages.put(json.loads(line))
        finally:
            self.messages.put(None)

    def call(self, method, params):
        self.sequence += 1
        request = {"jsonrpc": "2.0", "id": self.sequence, "method": method, "params": params}
        self.input.write((json.dumps(request) + "\n").encode())
        self.input.flush()
        deadline = time.monotonic() + 120
        while True:
            reply = self.messages.get(timeout=max(0.01, deadline - time.monotonic()))
            if reply is None:
                raise RuntimeError("bridge exited; inspect its retained log")
            if reply.get("id") == self.sequence:
                if "error" in reply:
                    raise RuntimeError(reply)
                return reply["result"]

    def initialize(self):
        return self.call("initialize", {
            "protocolVersion": "2024-11-05", "capabilities": {},
            "clientInfo": {"name": "worktree-isolation-pilot", "version": "1"},
        })

    def tool(self, name, source, **args):
        result = self.call("tools/call", {
            "name": name, "arguments": {"filePath": str(source), **args},
        })
        return result, "\n".join(item.get("text", "") for item in result.get("content", []))

    def close(self):
        self.input.close()
        forced = False
        try:
            self.process.wait(timeout=10)
        except subprocess.TimeoutExpired:
            forced = True
            os.killpg(self.process.pid, signal.SIGTERM)
            try:
                self.process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                os.killpg(self.process.pid, signal.SIGKILL)
                self.process.wait(timeout=5)
        self.reader.join(timeout=1)
        self.output.close()
        self.log.close()
        try:
            os.killpg(self.process.pid, 0)
        except ProcessLookupError:
            if forced or self.process.returncode:
                raise RuntimeError("bridge did not shut down cleanly")
            return
        os.killpg(self.process.pid, signal.SIGKILL)
        raise RuntimeError("bridge left descendants; terminated the pilot-owned process group")


def require(condition, message):
    if not condition:
        raise AssertionError(message)


def wait_diagnostics(client, source, predicate):
    deadline = time.monotonic() + 45
    while True:
        result, text = client.tool("diagnostics", source)
        require(not result.get("isError"), text)
        require("compiler completion unverified" in text, "diagnostics claimed compiler freshness")
        if predicate(text):
            return text
        if time.monotonic() >= deadline:
            raise AssertionError(f"diagnostic transition not observed: {text}")
        time.sleep(0.1)


def fixtures(output):
    repo = output / "repository"
    run("git", "init", "-q", str(repo))
    run("git", "config", "user.name", "ElixirLS Pilot", cwd=repo)
    run("git", "config", "user.email", "elixirls-pilot@example.invalid", cwd=repo)
    (repo / "lib").mkdir()
    (repo / ".gitignore").write_text("/_build/\n/deps/\n/.elixir_ls/\n")
    (repo / "mix.exs").write_text(
        'defmodule Pilot.MixProject do\n  use Mix.Project\n'
        '  def project, do: [app: :pilot, version: "0.1.0", deps: []]\nend\n'
    )
    (repo / "lib/pilot.ex").write_text("defmodule Pilot do\nend\n")
    run("git", "add", ".", cwd=repo)
    run("git", "commit", "-qm", "Synthetic pilot fixture", cwd=repo)
    roots = []
    for name in ("a", "b"):
        root = output / name
        run("git", "worktree", "add", "-b", f"pilot-{name}", str(root), cwd=repo)
        (root / "lib/pilot.ex").write_text(
            f'defmodule Pilot do\n  @doc "Worktree {name}"\n'
            f'  def value, do: :{name}\n  def call, do: value()\nend\n'
        )
        run("git", "add", ".", cwd=root)
        run("git", "commit", "-qm", f"Worktree {name}", cwd=root)
        roots.append(root)
    return roots


def pilot(output):
    output.mkdir(parents=True, exist_ok=False)
    roots = fixtures(output)
    clients = []
    evidence = {"worktrees": [str(root) for root in roots], "checks": {}}
    checks = evidence["checks"]
    try:
        for root in roots:
            clients.append(Client(root, output / f"{root.name}.log"))
        with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
            list(pool.map(lambda client: client.initialize(), clients))
        checks["concurrent_initialization"] = True
        for root, client in zip(roots, clients, strict=True):
            source = root / "lib/pilot.ex"
            for tool in ("definition", "references", "hover"):
                result, text = client.tool(tool, source, line=4, column=17)
                require(not result.get("isError"), text)
                expected = str(source) if tool != "hover" else f"Worktree {root.name}"
                require(expected in text, text)
            require((root / ".elixir_ls/build").is_dir(), "missing private ElixirLS build")
        checks["navigation_and_private_builds"] = True

        result, text = clients[0].tool("definition", roots[1] / "lib/pilot.ex", line=4, column=17)
        require(result.get("isError") and "outside" in text, "cross-worktree query accepted")
        checks["cross_worktree_rejection"] = True
        duplicate = subprocess.run(
            [sys.executable, str(LAUNCHER), str(roots[0])],
            capture_output=True, text=True, timeout=10,
        )
        require(
            duplicate.returncode != 0 and "already owns" in duplicate.stderr,
            "duplicate owner accepted",
        )
        checks["duplicate_owner_rejection"] = True

        source = roots[0] / "lib/pilot.ex"
        original = source.read_text()
        try:
            source.write_text(original.replace(":a", "missing_from_a()"))
            checks["error_publication"] = wait_diagnostics(
                clients[0], source, lambda text: "undefined function missing_from_a" in text,
            )
            _, other = clients[1].tool("diagnostics", roots[1] / "lib/pilot.ex")
            require("missing_from_a" not in other, "diagnostics crossed worktrees")
            source.write_text(original)
            checks["repair_publication"] = wait_diagnostics(
                clients[0], source, lambda text: "Diagnostics in File: 0" in text,
            )
        finally:
            source.write_text(original)
        checks["diagnostic_isolation"] = True
        clients.pop(0).close()
        _, text = clients[0].tool("hover", roots[1] / "lib/pilot.ex", line=4, column=17)
        require("Worktree b" in text, "closing one session stopped the other")
        reopened = Client(roots[0], output / "a-reopened.log")
        clients.append(reopened)
        reopened.initialize()
        checks["independent_shutdown_and_lock_reuse"] = True
    finally:
        failed = sys.exc_info()[0] is not None
        errors = []
        for client in clients:
            try:
                client.close()
            except Exception as error:
                errors.append(str(error))
        checks["shutdown_errors"] = errors
        (output / "evidence.json").write_text(json.dumps(evidence, indent=2) + "\n")
        if not failed:
            require(not errors, str(errors))
    # Preserve logs, worktrees and branches for inspection. Never force-delete on failure.
    print(json.dumps(evidence, indent=2))


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit("usage: pilot_elixirls.py /absolute/new-evidence-directory")
    pilot(Path(sys.argv[1]).resolve())
