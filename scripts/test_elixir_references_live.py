#!/usr/bin/env python3
"""Milestone smoke test: real MCP bridge + patched Expert in a cold Mix project."""
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
args = parser.parse_args()
tools = args.tools_dir.resolve()

with tempfile.TemporaryDirectory(prefix="tips-references-") as directory:
    root = Path(directory).resolve()
    (root / "mix.exs").write_text('''defmodule ReferencesContract.MixProject do
  use Mix.Project
  def project, do: [app: :references_contract, version: "0.1.0", elixir: "~> 1.15"]
end
''')
    (root / "lib").mkdir()
    source = root / "lib/sample.ex"
    source.write_text('''defmodule ReferencesContract do
  def used, do: :ok
  def unused, do: :ok
  def caller, do: used()
end

''')
    messages = queue.Queue()
    with (root / "bridge.log").open("w") as log:
        process = subprocess.Popen(
            [str(tools / "bin/mcp-language-server"), "--workspace", str(root),
             "--lsp", str(tools / "bin/expert"), "--", "--stdio"],
            cwd=root, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
            stderr=log, text=True, start_new_session=True,
        )
        def read():
            for line in process.stdout:
                try:
                    messages.put(json.loads(line))
                except ValueError:
                    pass
            messages.put(None)
        threading.Thread(target=read, daemon=True).start()

        def send(message):
            process.stdin.write(json.dumps(message) + "\n")
            process.stdin.flush()

        def request(identifier, method, params):
            start = time.monotonic()
            send(dict(jsonrpc="2.0", id=identifier, method=method, params=params))
            while True:
                reply = messages.get(timeout=max(0.01, 130 - (time.monotonic() - start)))
                if reply is None:
                    raise RuntimeError("Bridge exited")
                if reply.get("id") == identifier:
                    elapsed = time.monotonic() - start
                    print(json.dumps(dict(elapsed=round(elapsed, 3), response=reply)), flush=True)
                    return reply, elapsed

        def call(identifier, name, line, column):
            return request(identifier, "tools/call", dict(name=name, arguments=dict(
                filePath=str(source), line=line, column=column)))

        try:
            request(1, "initialize", dict(protocolVersion="2024-11-05", capabilities={},
                                         clientInfo=dict(name="references-contract-test", version="1")))
            send(dict(jsonrpc="2.0", method="notifications/initialized"))
            # First call arrives during startup. The only reference is the call on line 4.
            reply, _ = call(2, "references", 4, 19)
            assert not reply["result"].get("isError"), reply
            assert "L4:" in json.dumps(reply), reply
            # A resolved public function with no usages is a prompt, successful empty.
            reply, elapsed = call(3, "references", 3, 9)
            assert not reply["result"].get("isError"), reply
            assert "No references found" in json.dumps(reply), reply
            assert elapsed < 2, elapsed
            reply, _ = call(4, "references", 6, 1)
            assert reply["result"].get("isError"), reply
            assert "unconfirmed" in json.dumps(reply), reply
            reply, _ = call(5, "definition", 4, 19)
            assert "L2:" in json.dumps(reply), reply
            reply, _ = request(6, "tools/call", dict(name="diagnostics", arguments=dict(
                filePath=str(source), showLineNumbers=False)))
            assert "Latest published diagnostics" in json.dumps(reply), reply
            print("PASS: cold references, warm true empty, unresolved symbol, definition, diagnostics")
        except Exception:
            # Preserve evidence outside the disposable project on failure.
            import shutil
            evidence = Path(tempfile.mkdtemp(prefix="tips-references-failed-"))
            shutil.copytree(root, evidence / "project", dirs_exist_ok=True)
            print(f"Failure evidence: {evidence}", flush=True)
            raise
        finally:
            os.killpg(process.pid, signal.SIGTERM)
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                os.killpg(process.pid, signal.SIGKILL)
                process.wait()
