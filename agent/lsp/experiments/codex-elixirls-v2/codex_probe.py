#!/usr/bin/env python3
"""Run an actual read-only Codex session against the published bridge."""

import argparse
import json
from pathlib import Path
import subprocess
import time

from probe import alive, descendants, write_config


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--bridge", type=Path, required=True)
    parser.add_argument("--workspace", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--fixture", action="store_true", help="Use only generated synthetic source")
    args = parser.parse_args()
    root = args.workspace.resolve()
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    write_config(root)
    if args.fixture:
        source = root / "lib/caller.ex"
        line, column = 2, 29
    else:
        source = root / "lib/tips/search_probe.ex"
        # A known application call site; answers must come from MCP.
        lines = source.read_text().splitlines()
        line = next(i + 1 for i, text in enumerate(lines) if "&Tips.ProviderConfig.mode/0" in text)
        column = lines[line - 1].index("mode/0") + 1
    prompt = f"""This is a read-only integration acceptance check for an unmodified MCP server.
Use only the elixir_v2 MCP tools. Do not run shell commands, edit files, use other
servers, or delegate. The bridge should auto-start ElixirLS on a file query.
In sequence call:
1. lsp_hover at {source}, line {line}, column {column}.
2. lsp_goto_definition at that same position.
3. lsp_find_references there with include_declaration=false.
4. lsp_diagnostics for {source}.
5. lsp_server_status.
If a tool reports initialization/indexing in progress or empty results, retry at
most twice and report the first result as well. Report exact definition path,
documentation, reference count, diagnostics, and workspace root using only tool
evidence. Do not infer that empty diagnostics prove compilation is finished.
"""
    (output / "prompt.txt").write_text(prompt)
    names = ["lsp_hover", "lsp_goto_definition", "lsp_find_references", "lsp_diagnostics", "lsp_server_status"]
    config = {
        "mcp_servers.elixir_v2.command": "/opt/homebrew/bin/node",
        "mcp_servers.elixir_v2.args": [str(args.bridge.resolve())],
        "mcp_servers.elixir_v2.cwd": str(root),
        "mcp_servers.elixir_v2.enabled_tools": names,
        "mcp_servers.elixir_v2.startup_timeout_sec": 60,
        "mcp_servers.elixir_v2.tool_timeout_sec": 180,
        "mcp_servers.elixir_v2.required": True,
        "mcp_servers.elixir_v2.default_tools_approval_mode": "approve",
    }
    command = ["codex", "exec", "--ignore-user-config", "--ephemeral", "--json", "-s", "read-only", "-C", str(root)]
    for key, value in config.items():
        command.extend(["-c", f"{key}={json.dumps(value)}"])
    command.append(prompt)
    (output / "command.json").write_text(json.dumps(command, indent=2) + "\n")
    owned = {}
    with (output / "events.jsonl").open("w") as stdout, (output / "stderr.log").open("w") as stderr:
        proc = subprocess.Popen(command, stdin=subprocess.DEVNULL, stdout=stdout, stderr=stderr, start_new_session=True)
        deadline = time.monotonic() + 360
        while proc.poll() is None and time.monotonic() < deadline:
            owned.update(descendants(proc.pid))
            time.sleep(0.5)
        timed_out = proc.poll() is None
        if timed_out:
            proc.terminate()
            try:
                proc.wait(timeout=10)
            except subprocess.TimeoutExpired:
                proc.kill()
        proc.wait()
    deadline = time.monotonic() + 10
    while alive(owned) and time.monotonic() < deadline:
        time.sleep(0.2)
    result = {"exit_code": proc.returncode, "timed_out": timed_out, "owned": owned, "remaining": alive(owned)}
    (output / "process-results.json").write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps({"exit_code": proc.returncode, "timed_out": timed_out, "remaining_pids": list(result["remaining"])}), flush=True)


if __name__ == "__main__":
    main()
