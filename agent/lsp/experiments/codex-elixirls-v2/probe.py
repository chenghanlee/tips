#!/usr/bin/env python3
"""Black-box experiment for the unmodified published lsp-mcp-server package.

Artifacts and disposable Git worktrees are written under --output. No global
client configuration or installed server source is changed.
"""

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
    def __init__(self, bridge, root, output, name):
        self.root = root
        self.name = name
        self.counter = 0
        self.responses = queue.Queue()
        self.log = (output / f"{name}.stderr.log").open("w")
        self.transcript = (output / f"{name}.jsonl").open("w")
        self.proc = subprocess.Popen(
            ["node", str(bridge)], cwd=root, stdin=subprocess.PIPE,
            stdout=subprocess.PIPE, stderr=self.log, text=True, bufsize=1,
            start_new_session=True,
        )
        self.owned = {}
        threading.Thread(target=self._read, daemon=True).start()
        self.initialize = self.request("initialize", {
            "protocolVersion": "2024-11-05", "capabilities": {},
            "clientInfo": {"name": "tips-elixirls-v2-probe", "version": "1"},
        })
        self.send({"jsonrpc": "2.0", "method": "notifications/initialized"})
        self.tools = self.request("tools/list", {})

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


def write_config(root):
    config = {
        "servers": [{
            "id": "elixir", "command": "/opt/homebrew/bin/elixir-ls", "args": [],
            "extensions": [".ex", ".exs", ".heex"],
            "languageIds": ["elixir", "eelixir", "phoenix-heex"],
            "rootPatterns": ["mix.exs"],
            "workspaceConfigurations": {str(root): {"elixirLS": {
                "dialyzerEnabled": False, "suggestSpecs": False,
                "fetchDeps": False,
            }}},
        }],
        "requestTimeout": 120000, "idleTimeout": 1800000, "logLevel": "debug",
    }
    (root / ".lsp-mcp.json").write_text(json.dumps(config, indent=2) + "\n")


def fixture(root, version):
    (root / "lib").mkdir(exist_ok=True)
    (root / "test").mkdir(exist_ok=True)
    (root / "mix.exs").write_text('''defmodule V2Fixture.MixProject do
  use Mix.Project
  def project, do: [app: :v2_fixture, version: "0.1.0", elixir: "~> 1.20"]
end
''')
    (root / ".gitignore").write_text("/_build/\n/.elixir_ls/\n/.lsp-mcp.json\n")
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
        write_config(root)
        (output / f"{root.name}-mix.log").write_text(
            run(["unbuffer", "mix", "compile", "--warnings-as-errors"], root)
            + run(["unbuffer", "mix", "test"], root)
        )
    return alpha, beta, a_sha, b_sha


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--bridge", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    args.output = args.output.resolve()
    args.output.mkdir(parents=True, exist_ok=True)
    process_table()  # Fail before starting anything if lifecycle checks are blocked.
    results = {"checks": {}, "observations": {}}
    clients = []

    def check(name, passed, details):
        results["checks"][name] = {"passed": bool(passed), "details": details}
        (args.output / "results.json").write_text(json.dumps(results, indent=2) + "\n")
        print(f"{'PASS' if passed else 'FAIL'} {name}", flush=True)

    try:
        alpha, beta, a_sha, b_sha = prepare(args.output)
        results["fixture_commits"] = {"alpha": a_sha, "beta": b_sha}
        for root in (alpha, beta):
            client = MCP(args.bridge.resolve(), root, args.output, root.name)
            clients.append(client)
            check(f"{root.name}_mcp", client.initialize["serverInfo"]["name"] == "lsp-mcp-server", client.initialize["serverInfo"])
            # First-call results are retained separately from eventual results.
            hover = client.nav("lsp_hover")
            definition = client.nav("lsp_goto_definition")
            refs = client.nav("lsp_find_references", include_declaration=False)
            diagnostics = client.call("lsp_diagnostics", file_path=str(root / "lib/caller.ex"))
            results["observations"][root.name] = {"hover": hover, "definition": definition, "references": refs, "diagnostics": diagnostics}
            check(f"{root.name}_hover", root.name.upper() in json.dumps(hover), hover)
            check(f"{root.name}_definition", str(root / "lib/target.ex") in json.dumps(definition), definition)
            check(f"{root.name}_references", not refs["isError"] and refs["data"].get("total_count") == (2 if root == alpha else 3), refs)
            client.remember()
        a, b = clients
        error_file = alpha / "lib/caller.ex"
        original = error_file.read_text()
        error_file.write_text(original.replace("V2Target.answer()", "missing_local()", 1))
        error_seen = False
        error_results = []
        for _ in range(10):
            result = a.call("lsp_diagnostics", file_path=str(error_file))
            error_results.append(result)
            if "missing_local" in json.dumps(result) and result["data"].get("summary", {}).get("errors", 0) > 0:
                error_seen = True
                break
            time.sleep(1)
        check("saved_error_diagnostic", error_seen, error_results)
        other = b.call("lsp_diagnostics", file_path=str(beta / "lib/caller.ex"))
        check("diagnostic_isolation", not other["isError"] and other["data"].get("summary", {}).get("errors") == 0, other)
        error_file.write_text(original)
        repair_results = []
        repaired = False
        for _ in range(10):
            result = a.call("lsp_diagnostics", file_path=str(error_file))
            repair_results.append(result)
            if not result["isError"] and result["data"].get("summary", {}).get("errors") == 0:
                repaired = True
                break
            time.sleep(1)
        check("repair_clears_diagnostic", error_seen and repaired, repair_results)
        run(["git", "checkout", "--detach", a_sha], beta)
        advanced = {"hover": b.nav("lsp_hover"), "references": b.nav("lsp_find_references", include_declaration=False)}
        check("reviewer_revision_advance", "ALPHA" in json.dumps(advanced["hover"]) and advanced["references"]["data"].get("total_count") == 2, advanced)
        check("separate_builds", (alpha / ".elixir_ls/build").is_dir() and (beta / ".elixir_ls/build").is_dir(), [str(alpha), str(beta)])
        # Test accidental access to another worktree only after isolation checks.
        cross = a.call("lsp_hover", file_path=str(beta / "lib/caller.ex"), line=2, column=29)
        check("outside_worktree_rejected", cross["isError"], cross)
        for client in clients:
            owned = client.remember()
            client.proc.stdin.close()
            deadline = time.monotonic() + 8
            while alive(owned) and time.monotonic() < deadline:
                time.sleep(0.2)
            check(f"{client.name}_stdin_cleanup", not alive(owned), {"before": owned, "remaining": alive(owned)})
            if client is a:
                survivor = b.nav("lsp_hover")
                check("other_session_survives", not survivor["isError"] and "ALPHA" in json.dumps(survivor), survivor)
            client.cleanup()
    except Exception as error:
        results["exception"] = repr(error)
        print(f"EXCEPTION {error!r}", flush=True)
        raise
    finally:
        for client in clients:
            client.cleanup()
        (args.output / "results.json").write_text(json.dumps(results, indent=2) + "\n")
    if not all(item["passed"] for item in results["checks"].values()):
        raise SystemExit(1)


if __name__ == "__main__":
    main()
