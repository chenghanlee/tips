#!/usr/bin/env python3
"""Local MCP checks on Tips; no model/API request is made by this script."""

import argparse
import json
from pathlib import Path
import time

from probe import MCP, write_config


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--bridge", type=Path, required=True)
    parser.add_argument("--workspace", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    root, output = args.workspace.resolve(), args.output.resolve()
    output.mkdir(parents=True)
    write_config(root)
    source = root / "lib/tips/search_probe.ex"
    lines = source.read_text().splitlines()
    line = next(i + 1 for i, text in enumerate(lines) if "&Tips.ProviderConfig.mode/0" in text)
    column = lines[line - 1].index("mode/0") + 1
    diagnostic_file = root / "lib/codex_elixirls_v2_probe.ex"
    if diagnostic_file.exists():
        raise RuntimeError("Refusing to overwrite existing probe file")
    good = 'defmodule Tips.CodexElixirLSV2Probe do\n  def value, do: :ok\nend\n'
    results = {}
    client = MCP(args.bridge.resolve(), root, output, "tips")

    def save(name, data):
        results[name] = data
        (output / "results.json").write_text(json.dumps(results, indent=2) + "\n")
        print(name, json.dumps(data)[:400], flush=True)

    try:
        for name in ["lsp_hover", "lsp_goto_definition", "lsp_find_references"]:
            save(name, client.call(name, file_path=str(source), line=line, column=column))
        save("server_status", client.call("lsp_server_status"))
        save("baseline_diagnostics", client.call("lsp_diagnostics", file_path=str(source)))
        for name in ["lsp_hover", "lsp_goto_definition"]:
            save("after_initial_build_" + name, client.call(name, file_path=str(source), line=line, column=column))
        diagnostic_file.write_text(good)
        save("new_file_diagnostics", client.call("lsp_diagnostics", file_path=str(diagnostic_file)))
        diagnostic_file.write_text(good.replace(":ok", "missing_local()"))
        errors = []
        for _ in range(15):
            result = client.call("lsp_diagnostics", file_path=str(diagnostic_file))
            errors.append(result)
            if result["data"].get("summary", {}).get("errors", 0) > 0:
                break
            time.sleep(1)
        save("saved_error", errors)
        diagnostic_file.write_text(good)
        repaired = []
        for _ in range(15):
            result = client.call("lsp_diagnostics", file_path=str(diagnostic_file))
            repaired.append(result)
            if result["data"].get("summary", {}).get("errors") == 0:
                break
            time.sleep(1)
        save("repaired", repaired)
    finally:
        if diagnostic_file.exists():
            diagnostic_file.unlink()
        client.cleanup()


if __name__ == "__main__":
    main()
