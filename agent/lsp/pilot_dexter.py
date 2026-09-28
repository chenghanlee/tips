#!/usr/bin/env python3
"""Opt-in, local-only two-worktree Dexter acceptance pilot; retain all evidence."""

import argparse
import concurrent.futures
import json
import os
import queue
import signal
import statistics
import subprocess
import sys
import threading
import time
from pathlib import Path


LAUNCHER = Path(__file__).with_name("launch_worktree_dexter.py").resolve()


def run(*args, cwd=None):
    return subprocess.run(args, cwd=cwd, check=True, capture_output=True, text=True).stdout


class Client:
    def __init__(self, root, output, launcher=LAUNCHER, environment=None):
        self.log = output.open("w")
        self.messages = queue.Queue()
        self.sequence = 0
        self.process = subprocess.Popen(
            [sys.executable, str(launcher), str(root)],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=self.log,
            start_new_session=True,
            env={**os.environ, "LOG_LEVEL": "DEBUG", "MIX_ENV": "test",
                 "DEXTER_DEBUG": "true", **(environment or {})},
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
        # BEAM helpers can briefly remain as zombies after the bridge is reaped.
        # Signal 0 on their process group can return EPERM on macOS; use the
        # process table to distinguish live descendants from exited processes.
        deadline = time.monotonic() + 2
        while True:
            processes = run("ps", "-axo", "pid=,pgid=,stat=")
            live = [line for line in processes.splitlines()
                    if line.split()[1] == str(self.process.pid)
                    and not line.split()[2].startswith("Z")]
            if not live:
                if forced or self.process.returncode:
                    raise RuntimeError("bridge did not shut down cleanly")
                return
            if time.monotonic() >= deadline:
                break
            time.sleep(0.02)
        os.killpg(self.process.pid, signal.SIGKILL)
        raise RuntimeError("bridge left descendants; terminated the pilot-owned process group")


def require(condition, message):
    if not condition:
        raise AssertionError(message)


def write_source(path, text, atomic=False):
    if atomic:
        temporary = path.with_suffix(".pending")
        temporary.write_text(text)
        temporary.replace(path)
    else:
        path.write_text(text)


def observe(client, tool, source, predicate, started=None, **args):
    started = time.perf_counter_ns() if started is None else started
    attempts = 0
    while True:
        attempts += 1
        result, text = client.tool(tool, source, **args)
        elapsed = (time.perf_counter_ns() - started) / 1_000_000
        if not result.get("isError") and predicate(text):
            return {"ms": elapsed, "attempts": attempts}
        if elapsed > 10_000:
            raise AssertionError(f"{tool} did not reflect the edit: {text}")
        time.sleep(0.005)


def setup_roots(output, project):
    if project:
        repository = project
        revision = run("git", "rev-parse", "HEAD", cwd=project).strip()
    else:
        repository = output / "repository"
        run("git", "init", "-q", str(repository))
        run("git", "config", "user.name", "Dexter Pilot", cwd=repository)
        run("git", "config", "user.email", "dexter-pilot@example.invalid", cwd=repository)
        (repository / ".gitignore").write_text("/_build/\n/deps/\n/.dexter/\n")
        (repository / "mix.exs").write_text(
            'defmodule Pilot.MixProject do\n  use Mix.Project\n'
            '  def project, do: [app: :pilot, version: "0.1.0", deps: []]\nend\n'
        )
        run("git", "add", ".", cwd=repository)
        run("git", "commit", "-qm", "Synthetic Dexter pilot", cwd=repository)
        revision = "HEAD"
    roots = []
    for name in ("a", "b"):
        root = output / name
        run("git", "worktree", "add", "--detach", str(root), revision, cwd=repository)
        roots.append(root)
    # Exercise Dexter's ancestor-marker precedence too: no server may use this DB.
    (output / ".dexter").mkdir()
    (output / ".dexter/dexter.db").touch()
    return roots


def target_text(marker, padding=0):
    return (
        'defmodule DexterPilot.Target do\n'
        + "\n" * padding
        + f'  @doc "{marker}"\n  def value, do: :ok\nend\n'
    )


def measure(client, root, files, rounds):
    target, caller, extra = files
    series = {name: [] for name in (
        "same_file_hover", "cross_file_definition", "cross_file_hover", "cross_file_references"
    )}
    for iteration in range(rounds):
        atomic = iteration % 2 == 1
        marker = f"Worktree {root.name} revision {iteration}"
        local = (
            'defmodule DexterPilot.Caller do\n'
            f'  @doc "{marker}"\n'
            '  def local, do: :ok\n  def call, do: local()\n'
            '  def remote, do: DexterPilot.Target.value()\nend\n'
        )
        started = time.perf_counter_ns()
        write_source(caller, local, atomic)
        series["same_file_hover"].append(observe(
            client, "hover", caller, lambda text: marker in text, started, line=4, column=17,
        ))

        padding = iteration + 1
        started = time.perf_counter_ns()
        write_source(target, target_text(marker, padding), atomic)
        expected_line = padding + 3
        series["cross_file_definition"].append(observe(
            client, "definition", caller,
            lambda text: str(target) in text and f"Range: L{expected_line}:" in text,
            started, line=5, column=39,
        ))
        # Measure a separate doc edit; the definition query above has already indexed its edit.
        marker += " hover"
        started = time.perf_counter_ns()
        write_source(target, target_text(marker, padding), atomic)
        series["cross_file_hover"].append(observe(
            client, "hover", caller, lambda text: marker in text,
            started, line=5, column=39,
        ))

        present = iteration % 2 == 0
        expression = "DexterPilot.Target.value()" if present else ":ok"
        started = time.perf_counter_ns()
        write_source(extra, f"defmodule DexterPilot.Extra do\n  def call, do: {expression}\nend\n", atomic)
        series["cross_file_references"].append(observe(
            client, "references", caller, lambda text: (str(extra) in text) == present,
            started, line=5, column=39,
        ))
    started = time.perf_counter_ns()
    write_source(target, "defmodule DexterPilot.Target do\n  def value, do: missing_function()\nend\n")
    _, diagnostic = client.tool("diagnostics", target)
    require("Compiler diagnostics unavailable" in diagnostic, diagnostic)
    return {"samples": series, "diagnostics": diagnostic,
            "diagnostics_response_ms": (time.perf_counter_ns() - started) / 1_000_000}


def summarize(samples):
    values = sorted(sample["ms"] for sample in samples)
    return {"n": len(values), "median_ms": round(statistics.median(values), 2),
            "p95_ms": round(values[max(0, (95 * len(values) + 99) // 100 - 1)], 2),
            "max_ms": round(max(values), 2)}


def pilot(output, project, rounds):
    output.mkdir(parents=True, exist_ok=False)
    roots = setup_roots(output, project)
    clients, fixtures = [], []
    evidence = {"server_version": run("dexter", "version").strip(),
                "transport": "MCP -> stdio LSP (dexter lsp); no CLI lookups",
                "project": str(project) if project else "synthetic",
                "rounds_per_worktree": rounds, "poll_interval_ms": 5,
                "timing": "before saved file write to first matching MCP response",
                "worktrees": [str(root) for root in roots], "checks": {}}
    try:
        for root in roots:
            directory = root / "lib/dexter_pilot_fixture"
            directory.mkdir(parents=True, exist_ok=False)
            target, caller, extra = [directory / name for name in ("target.ex", "caller.ex", "extra.ex")]
            target.write_text(target_text(f"Worktree {root.name} initial"))
            caller.write_text(
                'defmodule DexterPilot.Caller do\n  @doc "initial"\n'
                '  def local, do: :ok\n  def call, do: local()\n'
                '  def remote, do: DexterPilot.Target.value()\nend\n'
            )
            extra.write_text("defmodule DexterPilot.Extra do\n  def call, do: :ok\nend\n")
            fixtures.append((target, caller, extra))
            clients.append(Client(root, output / f"{root.name}.log"))
        with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
            list(pool.map(lambda client: client.initialize(), clients))
            for client, root, (target, caller, _) in zip(clients, roots, fixtures, strict=True):
                observe(client, "definition", caller,
                        lambda text: str(target) in text and "Range: L3:" in text,
                        line=5, column=39)
                require((root / ".dexter/dexter.db").stat().st_size > 0, "missing local index")
            require((output / ".dexter/dexter.db").stat().st_size == 0, "ancestor index used")
            evidence["checks"]["private_indexes_despite_ancestor_marker"] = True
            result, text = clients[0].tool("hover", fixtures[1][1], line=4, column=17)
            require(result.get("isError") and "outside" in text, "cross-worktree request accepted")
            evidence["checks"]["cross_worktree_rejection"] = True
            duplicate = subprocess.run(
                [sys.executable, str(LAUNCHER), str(roots[0])],
                capture_output=True, text=True, timeout=10,
            )
            require(duplicate.returncode != 0 and "already owns" in duplicate.stderr,
                    "duplicate owner accepted")
            evidence["checks"]["duplicate_owner_rejection"] = True
            futures = [pool.submit(measure, client, root, files, rounds)
                       for client, root, files in zip(clients, roots, fixtures, strict=True)]
            evidence["results"] = {root.name: future.result()
                                   for root, future in zip(roots, futures, strict=True)}
        evidence["summary"] = {
            name: summarize([sample for result in evidence["results"].values()
                             for sample in result["samples"][name]])
            for name in evidence["results"]["a"]["samples"]
        }
        clients.pop(0).close()
        _, text = clients[0].tool("hover", fixtures[1][1], line=4, column=17)
        require(f"Worktree b revision {rounds - 1}" in text, "closing A affected B")
        reopened = Client(roots[0], output / "a-reopened.log")
        clients.append(reopened)
        reopened.initialize()
        evidence["checks"]["independent_shutdown_and_lock_reuse"] = True
    except Exception as error:
        evidence["failure"] = str(error)
        raise
    finally:
        failed = sys.exc_info()[0] is not None
        errors = []
        for client in clients:
            try:
                client.close()
            except Exception as error:
                errors.append(str(error))
        evidence["checks"]["shutdown_errors"] = errors
        for target, _, _ in fixtures:
            target.write_text(target_text("Restored after pilot"))
        (output / "evidence.json").write_text(json.dumps(evidence, indent=2) + "\n")
        if not failed:
            require(not errors, str(errors))
    print(json.dumps({"summary": evidence["summary"], "checks": evidence["checks"]}, indent=2))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("output", type=Path)
    parser.add_argument("--project", type=Path, help="Use two detached worktrees of this repository")
    parser.add_argument("--rounds", type=int, default=20)
    args = parser.parse_args()
    if args.rounds < 1:
        parser.error("--rounds must be positive")
    pilot(args.output.resolve(), args.project.resolve() if args.project else None, args.rounds)
