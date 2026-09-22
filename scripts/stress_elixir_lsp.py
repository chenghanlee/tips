#!/usr/bin/env python3
"""Stress the installed MCP/Expert pair against disposable copies of the Tips project."""
import argparse
from concurrent.futures import ThreadPoolExecutor
import hashlib
import io
import json
import os
from pathlib import Path
import queue
import re
import signal
import subprocess
import tarfile
import threading
import time


class Session:
    def __init__(self, tools, root, evidence, label):
        self.root, self.label = root, label
        self.lock = threading.Lock()
        self.pending = {}
        self.next_id = 0
        self.records = []
        self.log = (evidence / f"{label}-bridge.log").open("w")
        self.process = subprocess.Popen(
            [str(tools / "bin/mcp-language-server"), "--workspace", str(root),
             "--lsp", str(tools / "bin/expert"), "--", "--stdio"],
            cwd=root, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=self.log,
            text=True, start_new_session=True,
        )
        threading.Thread(target=self.read, daemon=True).start()
        self.request("initialize", dict(protocolVersion="2024-11-05", capabilities={},
                     clientInfo=dict(name="tips-stress", version="1")), "initialize")
        self.send(dict(jsonrpc="2.0", method="notifications/initialized"))

    def read(self):
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
            for receiver in self.pending.values():
                receiver.put(dict(error="MCP process exited"))

    def send(self, payload):
        with self.lock:
            self.process.stdin.write(json.dumps(payload) + "\n")
            self.process.stdin.flush()

    def request(self, method, params, phase):
        receiver = queue.Queue()
        with self.lock:
            self.next_id += 1
            identifier = self.next_id
            self.pending[identifier] = receiver
        start = time.monotonic()
        self.send(dict(jsonrpc="2.0", id=identifier, method=method, params=params))
        try:
            reply = receiver.get(timeout=130)
        except queue.Empty:
            reply = dict(error="MCP response exceeded 130 seconds")
        elapsed = time.monotonic() - start
        with self.lock:
            self.pending.pop(identifier, None)
            self.records.append(dict(session=self.label, phase=phase, method=method,
                                     params=params, elapsed=elapsed, reply=reply))
        return reply, elapsed

    def call(self, name, path, line=1, column=1, phase="warm"):
        arguments = dict(filePath=str(path))
        if name == "diagnostics":
            arguments["showLineNumbers"] = False
        else:
            arguments.update(line=line, column=column)
        return self.request("tools/call", dict(name=name, arguments=arguments), phase)

    def close(self):
        if self.process.poll() is None:
            os.killpg(self.process.pid, signal.SIGTERM)
            try:
                self.process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                os.killpg(self.process.pid, signal.SIGKILL)
                self.process.wait()
        self.log.close()


def text(reply):
    return "\n".join(item.get("text", "") for item in reply.get("result", {}).get("content", []))


def success(reply):
    return "error" not in reply and not reply.get("result", {}).get("isError")


def locations(reply):
    return re.findall(r"File: (.+)\nRange: L(\d+):C(\d+) - L(\d+):C(\d+)", text(reply))


def fixture_source(index):
    return (f"defmodule Tips.LspStress.Caller{index} do\n"
            "  @moduledoc false\n\n"
            "  alias Tips.LspStress.Target\n\n"
            f"  def run, do: Target.echo({index})\nend\n")


def call_position(path):
    for number, line in enumerate(path.read_text().splitlines(), 1):
        if "echo(" in line:
            return number, line.index("echo(") + 1
    raise ValueError(f"No echo call in {path}")


def fixture_paths(root):
    directory = root / "lib/tips/lsp_stress"
    return directory, directory / "target.ex", directory / "caller_0.ex"


def prepare(repo, root, archive):
    root.mkdir(parents=True)
    with tarfile.open(fileobj=io.BytesIO(archive)) as bundle:
        bundle.extractall(root, filter="data")
    # Private dependency copies avoid writes through symlinks into the real checkout.
    command = ["cp", "-cR"] if os.uname().sysname == "Darwin" else ["cp", "-a"]
    subprocess.run(command + [str(repo / "deps"), str(root / "deps")], check=True)
    directory, target, _ = fixture_paths(root)
    directory.mkdir(parents=True)
    target.write_text('''defmodule Tips.LspStress.Target do
  @moduledoc "Known targets for an isolated language-server stress run."
  @doc "Echo a value during the LSP stress test."
  def echo(value), do: value
  def unused, do: :unused
end
''')
    for index in range(16):
        (directory / f"caller_{index}.ex").write_text(fixture_source(index))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", type=Path, required=True)
    parser.add_argument("--tools-dir", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--rounds", type=int, default=15)
    parser.add_argument("--sessions", type=int, choices=(3, 5), default=3)
    args = parser.parse_args()
    repo, tools, output = args.repo.resolve(), args.tools_dir.resolve(), args.output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    checks, sessions = [], []
    start = time.monotonic()
    head = subprocess.check_output(["git", "-C", str(repo), "rev-parse", "HEAD"], text=True).strip()
    archive = subprocess.check_output(["git", "-C", str(repo), "archive", head])
    roots = [output / "team-a", output / "team-a/.worktrees/team-b",
             output / "team-a/.worktrees/nested/team-a"]
    roots.extend(output / f"team-a/.worktrees/team-{index}"
                 for index in range(3, args.sessions))

    def check(name, condition, detail="", category="correctness"):
        checks.append(dict(name=name, passed=bool(condition), detail=detail, category=category))
        print(json.dumps(checks[-1]), flush=True)

    def exact_refs(session, root, count, phase):
        _, target, caller = fixture_paths(root)
        reply, elapsed = session.call("references", caller, *call_position(caller), phase=phase)
        locs = locations(reply)
        expected = {(str(root / f"lib/tips/lsp_stress/caller_{i}.ex"),
                     str(call_position(root / f"lib/tips/lsp_stress/caller_{i}.ex")[0])) for i in range(count)}
        actual = {(loc[0], loc[1]) for loc in locs}
        check(f"{phase}/{session.label}/references-{count}",
              success(reply) and len(locs) == count and len(set(locs)) == count
              and actual == expected and (phase not in {"warm", "post-edit", "return-to-original"} or elapsed < 2),
              dict(elapsed=elapsed, count=len(locs), response=text(reply) if not locs else ""))
        return reply

    def cold(session):
        path = session.root / "test/tips/content/schema_test.exs"
        reply, elapsed = session.call("references", path, 165, 13, "cold")
        locs = locations(reply)
        expected = set()
        for relative in ["test/tips/content/schema_test.exs", "test/support/fixtures/content_fixtures.ex"]:
            source = session.root / relative
            for number, line in enumerate(source.read_text().splitlines(), 1):
                if "tip_fixture(" in line and not re.search(r"\bdef tip_fixture\(", line):
                    expected.add((str(source), str(number)))
        correct = success(reply) and len(locs) == 14 and {(loc[0], loc[1]) for loc in locs} == expected
        # A server-declared error preserves uncertainty; an absent response does not.
        explicit_error = (reply.get("result", {}).get("isError") is True and bool(text(reply))) or isinstance(reply.get("error"), dict)
        detail = dict(elapsed=elapsed, count=len(locs), response=text(reply) if not locs else "")
        check(f"cold-contract/{session.label}/explicit-outcome", correct or explicit_error,
              detail, category="error-contract")
        # Keep this failure visible even when error reporting itself is correct.
        check(f"cold/{session.label}/imported-fixture", correct, detail, category="first-call-success")
        exact_refs(session, session.root, 16, "cold-followup")

    def warm(session):
        root = session.root
        _, target, caller = fixture_paths(root)
        reply, elapsed = session.call("references", target, 6, 1, "unresolved")
        check(f"unresolved/{session.label}", not success(reply)
              and "unconfirmed" in text(reply) and elapsed < 2, text(reply))
        for index in range(args.rounds):
            exact_refs(session, root, 16, "warm")
            reply, elapsed = session.call("references", target, 5, 9, "warm-empty")
            check(f"warm-empty/{session.label}/{index}", success(reply)
                  and "No references found" in text(reply) and elapsed < 2, elapsed)
            reply, elapsed = session.call("definition", caller, *call_position(caller), phase="warm-definition")
            check(f"warm-definition/{session.label}/{index}", success(reply)
                  and any(loc[0] == str(target) and loc[1] == "4" for loc in locations(reply)), elapsed)
            reply, elapsed = session.call("hover", caller, *call_position(caller), phase="warm-hover")
            check(f"warm-hover/{session.label}/{index}", success(reply)
                  and "echo" in text(reply).lower(), dict(elapsed=elapsed, text=text(reply)[:150]))
            if index % 5 == 0:
                reply, elapsed = session.call("diagnostics", target, phase="warm-diagnostics")
                check(f"warm-diagnostics/{session.label}/{index}", success(reply)
                      and "Diagnostics in File: 0" in text(reply), elapsed)

    def edits(session):
        root = session.root
        directory, target, caller = fixture_paths(root)
        added = directory / "caller_16.ex"
        added.write_text(fixture_source(16))
        reply, _ = session.call("diagnostics", added, phase="edit-add-sync")
        check(f"edit-add/{session.label}/diagnostics", success(reply) and "Diagnostics in File: 0" in text(reply), text(reply))
        observed = []
        limit = time.monotonic() + 25
        while time.monotonic() < limit:
            reply, elapsed = session.call("references", caller, *call_position(caller), phase="edit-settle")
            count = len(locations(reply)); observed.append(count)
            if success(reply) and count == 17:
                break
            time.sleep(1)
        check(f"edit-add/{session.label}/eventually-17", success(reply) and count == 17, observed)
        # Removing one use must not pollute other projects with identical module names.
        added.write_text("defmodule Tips.LspStress.Caller16 do\n  @moduledoc false\n\n  def run, do: :removed\nend\n")
        session.call("diagnostics", added, phase="edit-remove-sync")
        observed = []; limit = time.monotonic() + 25
        while time.monotonic() < limit:
            reply, _ = session.call("references", caller, *call_position(caller), phase="edit-settle")
            count = len(locations(reply)); observed.append(count)
            if success(reply) and count == 16:
                break
            time.sleep(1)
        check(f"edit-remove/{session.label}/eventually-16", success(reply) and count == 16, observed)
        # A common incomplete edit should publish an error and clear after repair.
        original = added.read_text()
        added.write_text("defmodule Tips.LspStress.Caller16 do\n  def run, do: (\nend\n")
        reply, _ = session.call("diagnostics", added, phase="syntax-error")
        check(f"syntax/{session.label}/reported", success(reply)
              and re.search(r"Diagnostics in File: [1-9]", text(reply)), text(reply))
        added.write_text(original)
        reply, _ = session.call("diagnostics", added, phase="syntax-repaired")
        check(f"syntax/{session.label}/cleared", success(reply)
              and "Diagnostics in File: 0" in text(reply), text(reply))
        exact_refs(session, root, 16, "post-edit")

    try:
        for root in roots:
            prepare(repo, root, archive)
        # Each session initializes and sends its first request immediately.
        def start_cold(index):
            session = Session(tools, roots[index], output, f"session-{index}")
            sessions.append(session)
            cold(session)
            return session
        with ThreadPoolExecutor(max_workers=args.sessions) as pool:
            ordered = list(pool.map(start_cold, range(args.sessions)))
            print("PHASE warm", flush=True)
            list(pool.map(warm, ordered))
            print("PHASE edits", flush=True)
            # Run edit traffic beside warm reads in the other projects.
            list(pool.map(edits, ordered))
        print("PHASE cross-project", flush=True)
        # Expert restricts discovery to its initialized workspace boundary.
        # These nested worktrees reproduce the real main-rooted navigation setup.
        exact_refs(ordered[0], roots[1], 16, "cross-project")
        exact_refs(ordered[0], roots[2], 16, "same-basename-project")
        exact_refs(ordered[0], roots[0], 16, "return-to-original")
        print("PHASE restart", flush=True)
        ordered[1].close()
        restarted = Session(tools, roots[1], output, "session-restarted")
        sessions.append(restarted)
        exact_refs(restarted, roots[1], 16, "restart")
    except Exception as exc:
        check("harness-exception", False, repr(exc))
    finally:
        for session in sessions:
            session.close()
        records = [record for session in sessions for record in session.records]
        (output / "requests.json").write_text(json.dumps(records, indent=2))
        summary = dict(head=head, expert=str((tools / "bin/expert").resolve()),
                       bridge_sha256=hashlib.sha256((tools / "bin/mcp-language-server").read_bytes()).hexdigest(),
                       elapsed=time.monotonic()-start, checks=checks, requests=len(records),
                       failures=[item for item in checks if not item["passed"]])
        summary["results_by_category"] = {}
        for item in checks:
            counts = summary["results_by_category"].setdefault(item["category"], dict(checks=0, passed=0))
            counts["checks"] += 1
            counts["passed"] += int(item["passed"])
        summary["initial_project_compile_seconds"] = {}
        for root in roots:
            log = root / ".expert/expert.log"
            if log.exists():
                match = re.search(r"Compiled " + re.escape(root.name) + r" in ([0-9.]+) seconds", log.read_text(errors="replace"))
                if match:
                    summary["initial_project_compile_seconds"][str(root)] = float(match.group(1))
        (output / "summary.json").write_text(json.dumps(summary, indent=2))
        print(json.dumps(dict(requests=len(records), checks=len(checks), failures=len(summary["failures"]),
                              elapsed=summary["elapsed"], evidence=str(output))), flush=True)
    return 1 if summary["failures"] else 0


if __name__ == "__main__":
    raise SystemExit(main())
