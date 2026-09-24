#!/usr/bin/env python3
"""Attack freshness assumptions with perfect, injected LSP file notifications.

This is a direct ElixirLS protocol probe, not a test of an implemented watcher
or MCP bridge fix. All source files are synthetic and live under --output.
"""

import argparse
import json
import os
from pathlib import Path
import signal
import subprocess
import threading
import time


SETTINGS = {"dialyzerEnabled": False, "suggestSpecs": False, "fetchDeps": False}


class LSP:
    def __init__(self, root, output):
        self.root = root
        self.messages = []
        self.responses = {}
        self.condition = threading.Condition()
        self.write_lock = threading.Lock()
        self.counter = 0
        self.stderr = (output / "server.stderr.log").open("wb")
        self.transcript = (output / "protocol.jsonl").open("w")
        self.proc = subprocess.Popen(
            ["/opt/homebrew/bin/elixir-ls"], cwd=root,
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=self.stderr,
            start_new_session=True,
        )
        threading.Thread(target=self.read, daemon=True).start()

    def send(self, message):
        data = json.dumps(message).encode()
        with self.write_lock:
            self.proc.stdin.write(f"Content-Length: {len(data)}\r\n\r\n".encode() + data)
            self.proc.stdin.flush()

    def notify(self, method, params):
        self.send({"jsonrpc": "2.0", "method": method, "params": params})

    def read(self):
        while True:
            headers = {}
            while True:
                line = self.proc.stdout.readline()
                if not line:
                    return
                if line in (b"\r\n", b"\n"):
                    break
                key, value = line.decode().strip().split(":", 1)
                headers[key.lower()] = value.strip()
            message = json.loads(self.proc.stdout.read(int(headers["content-length"])))
            entry = {"time": time.monotonic(), "message": message}
            with self.condition:
                self.messages.append(entry)
                self.transcript.write(json.dumps(entry) + "\n")
                self.transcript.flush()
                if "id" in message and "method" not in message:
                    self.responses[message["id"]] = message
                self.condition.notify_all()
            if "id" in message and "method" in message:
                result = None
                if message["method"] == "workspace/configuration":
                    result = [SETTINGS for _ in message["params"]["items"]]
                self.send({"jsonrpc": "2.0", "id": message["id"], "result": result})

    def request(self, method, params, timeout=90):
        self.counter += 1
        request_id = self.counter
        self.send({"jsonrpc": "2.0", "id": request_id, "method": method, "params": params})
        deadline = time.monotonic() + timeout
        with self.condition:
            while request_id not in self.responses:
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    raise TimeoutError(method)
                self.condition.wait(remaining)
            return self.responses.pop(request_id)

    def wait_for(self, predicate, since=0, timeout=30):
        deadline = time.monotonic() + timeout
        with self.condition:
            while True:
                for index in range(since, len(self.messages)):
                    entry = self.messages[index]
                    if predicate(entry["message"]):
                        return index, entry
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    raise TimeoutError("Expected protocol event")
                self.condition.wait(remaining)

    def build(self, since):
        return self.wait_for(lambda m: m.get("method") == "telemetry/event"
                             and m.get("params", {}).get("name") == "build", since)

    def open(self, file):
        self.notify("textDocument/didOpen", {"textDocument": {
            "uri": file.as_uri(), "languageId": "elixir", "version": 1,
            "text": file.read_text(),
        }})

    def changed(self, file):
        self.notify("workspace/didChangeWatchedFiles", {
            "changes": [{"uri": file.as_uri(), "type": 2}],
        })

    def hover(self):
        start = time.monotonic()
        response = self.request("textDocument/hover", {
            "textDocument": {"uri": (self.root / "lib/caller.ex").as_uri()},
            "position": {"line": 1, "character": 28},
        })
        return {"elapsed_ms": round((time.monotonic() - start) * 1000, 2),
                "response": response}

    def stop(self):
        if self.proc.poll() is None:
            try:
                self.request("shutdown", None, timeout=5)
                self.notify("exit", None)
                self.proc.wait(timeout=5)
            except (TimeoutError, subprocess.TimeoutExpired, BrokenPipeError):
                os.killpg(self.proc.pid, signal.SIGTERM)
                try:
                    self.proc.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    os.killpg(self.proc.pid, signal.SIGKILL)
                    self.proc.wait(timeout=5)
        self.stderr.close()


def target_text(marker, delay=0):
    return ("defmodule V2Target do\n"
            + (f'  IO.puts("INVERSION_{marker}_STARTED")\n  Process.sleep({delay})\n' if delay else "")
            + f'  @doc "{marker} documentation."\n  def answer, do: :ok\nend\n')


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--overlap-gap-seconds", type=float, default=0)
    parser.add_argument("--overlap-b-marker", default="OVERLAP_B")
    parser.add_argument("--recover-with-clean", action="store_true")
    parser.add_argument("--edit-during-recovery", action="store_true")
    args = parser.parse_args()
    if args.edit_during_recovery and not args.recover_with_clean:
        parser.error("--edit-during-recovery requires --recover-with-clean")
    output = args.output.resolve()
    output.mkdir(parents=True)
    root = output / "fixture"
    (root / "lib").mkdir(parents=True)
    (root / "mix.exs").write_text('''defmodule V2Inversion.MixProject do
  use Mix.Project

  def project, do: [app: :v2_inversion, version: "0.1.0", elixir: "~> 1.20"]
end
''')
    (root / "lib/caller.ex").write_text(
        "defmodule V2Caller do\n  def call_1, do: V2Target.answer()\nend\n")
    target = root / "lib/target.ex"
    target.write_text(target_text("BASELINE"))
    results = {}

    def save(name, value):
        results[name] = value
        (output / "results.json").write_text(json.dumps(results, indent=2) + "\n")
        print(name, json.dumps(value)[:800], flush=True)

    client = LSP(root, output)
    try:
        initialized = client.request("initialize", {
            "processId": os.getpid(), "rootUri": root.as_uri(),
            "capabilities": {
                "workspace": {"configuration": True,
                              "didChangeWatchedFiles": {"dynamicRegistration": True}},
                "window": {"workDoneProgress": True},
                "textDocument": {"hover": {"contentFormat": ["markdown"]}},
            },
            "workspaceFolders": [{"uri": root.as_uri(), "name": "inversion"}],
        })
        client.notify("initialized", {})
        client.open(root / "lib/caller.ex")
        client.build(0)
        time.sleep(0.2)
        save("baseline", client.hover())
        assert "BASELINE documentation" in json.dumps(results["baseline"])

        mark = len(client.messages)
        target.write_text(target_text("SLOW_A", delay=1500))
        client.changed(target)
        save("perfect_event_immediate_hover", client.hover())
        save("slow_a_build", client.build(mark)[1])
        save("perfect_event_after_build", client.hover())

        mark = len(client.messages)
        target.write_text(target_text("BROKEN").replace("def answer, do: :ok", "def answer(, do: :ok"))
        client.changed(target)
        save("broken_build", client.build(mark)[1])
        diagnostics = client.wait_for(lambda m: m.get("method") == "textDocument/publishDiagnostics"
                                     and any(d.get("severity") == 1 for d in m["params"]["diagnostics"]), mark)
        save("broken_diagnostics", diagnostics[1])
        save("hover_after_failed_build", client.hover())

        mark = len(client.messages)
        target.write_text(target_text("OVERLAP_A", delay=1500))
        a_stat = target.stat()
        client.changed(target)
        started = client.wait_for(lambda m: m.get("method") == "window/logMessage"
                                  and "INVERSION_OVERLAP_A_STARTED" in m.get("params", {}).get("message", ""), mark)
        save("overlap_a_started", started[1])
        time.sleep(args.overlap_gap_seconds)
        target.write_text(target_text(args.overlap_b_marker, delay=1500))
        b_stat = target.stat()
        save("overlap_disk_edits", {
            "a": {"size": a_stat.st_size, "mtime_ns": a_stat.st_mtime_ns},
            "b": {"size": b_stat.st_size, "mtime_ns": b_stat.st_mtime_ns},
            "b_source": target.read_text(),
        })
        client.changed(target)
        first = client.build(mark)
        save("overlap_first_build", first[1])
        save("hover_after_first_overlapping_build", client.hover())
        save("overlap_second_build", client.build(first[0] + 1)[1])
        save("hover_after_second_overlapping_build", client.hover())

        if args.recover_with_clean:
            commands = initialized["result"]["capabilities"]["executeCommandProvider"]["commands"]
            clean = next(command for command in commands if command.startswith("mixClean:"))
            started = time.monotonic()
            save("application_clean", client.request("workspace/executeCommand", {
                "command": clean, "arguments": [False],
            }))
            mark = len(client.messages)
            client.changed(target)
            if args.edit_during_recovery:
                client.wait_for(lambda m: m.get("method") == "window/logMessage"
                                and f"INVERSION_{args.overlap_b_marker}_STARTED" in
                                m.get("params", {}).get("message", ""), mark)
                recovery_marker = args.overlap_b_marker[:-1] + "C"
                target.write_text(target_text(recovery_marker, delay=1500))
                client.changed(target)
                save("recovery_concurrent_source", target.read_text())
            first_recovery = client.build(mark)
            save("recovery_build", first_recovery[1])
            if args.edit_during_recovery:
                save("recovery_queued_build", client.build(first_recovery[0] + 1)[1])
            save("hover_after_application_clean_rebuild", client.hover())
            save("recovery_elapsed_seconds", round(time.monotonic() - started, 3))
            if args.edit_during_recovery:
                save("concurrent_recovery_fresh", f"{recovery_marker} documentation" in
                     json.dumps(results["hover_after_application_clean_rebuild"]))
                save("application_clean_retry", client.request("workspace/executeCommand", {
                    "command": clean, "arguments": [False],
                }))
                mark = len(client.messages)
                client.changed(target)
                save("recovery_retry_build", client.build(mark)[1])
                save("hover_after_quiet_recovery_retry", client.hover())
                assert f"{recovery_marker} documentation" in json.dumps(results["hover_after_quiet_recovery_retry"])
            else:
                assert f"{args.overlap_b_marker} documentation" in json.dumps(results["hover_after_application_clean_rebuild"])

        client.open(target)
        mark = len(client.messages)
        target.write_text(target_text("OPEN_UPDATED"))
        client.changed(target)
        time.sleep(0.5)
        save("open_file_watch_only", client.hover())
        save("open_file_watch_only_build_count", sum(
            e["message"].get("method") == "telemetry/event"
            and e["message"].get("params", {}).get("name") == "build"
            for e in client.messages[mark:]))
        mark = len(client.messages)
        client.notify("textDocument/didChange", {
            "textDocument": {"uri": target.as_uri(), "version": 2},
            "contentChanges": [{"text": target.read_text()}],
        })
        client.notify("textDocument/didSave", {"textDocument": {"uri": target.as_uri()}})
        client.build(mark)
        save("open_file_after_change_save", client.hover())
        save("standard_progress_event_count", sum(
            e["message"].get("method") in ("$/progress", "window/workDoneProgress/create")
            for e in client.messages))
        save("observations", {
            "immediate_hover_stale": "BASELINE documentation" in json.dumps(results["perfect_event_immediate_hover"]),
            "unopened_file_eventually_fresh": "SLOW_A documentation" in json.dumps(results["perfect_event_after_build"]),
            "failed_compile_hover_null": results["hover_after_failed_build"]["response"].get("result") is None,
            "first_overlap_completion_stale": "OVERLAP_A documentation" in json.dumps(results["hover_after_first_overlapping_build"]),
            "second_overlap_completion_fresh": f"{args.overlap_b_marker} documentation" in json.dumps(results["hover_after_second_overlapping_build"]),
            "open_file_change_save_fresh": "OPEN_UPDATED documentation" in json.dumps(results["open_file_after_change_save"]),
        })
        assert results["observations"]["unopened_file_eventually_fresh"], "Notification control did not refresh"
        assert results["observations"]["open_file_change_save_fresh"], "Open-document repair control did not refresh"
        save("completed", True)
    finally:
        client.stop()
        save("server_exit_code", client.proc.returncode)


if __name__ == "__main__":
    main()
