#!/usr/bin/env python3
"""Try to falsify cache freshness and cleanup on unchanged upstream binaries."""

import argparse
import json
from pathlib import Path
import time

from probe import MCP, alive, prepare, run


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--bridge", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    output = args.output.resolve()
    output.mkdir(parents=True)
    alpha, beta, a_sha, _ = prepare(output)
    results = {}
    clients = []

    def save(name, data):
        results[name] = data
        (output / "results.json").write_text(json.dumps(results, indent=2) + "\n")
        print(name, json.dumps(data)[:500], flush=True)

    try:
        a = MCP(args.bridge.resolve(), alpha, output, "alpha")
        clients.append(a)
        save("cold_references_without_hover", a.nav("lsp_find_references", include_declaration=False))
        save("initial_hover", a.nav("lsp_hover"))
        target = alpha / "lib/target.ex"
        original = target.read_text()
        target.write_text(original.replace("ALPHA", "CHANGED_CALLEE"))
        observations = []
        for _ in range(6):
            observations.append(a.nav("lsp_hover"))
            if "CHANGED_CALLEE" in json.dumps(observations[-1]):
                break
            time.sleep(1)
        save("callee_edit_then_query_unchanged_caller", observations)
        save("explicit_callee_query", a.call("lsp_diagnostics", file_path=str(target)))
        refreshed = []
        for _ in range(6):
            refreshed.append(a.nav("lsp_hover"))
            if "CHANGED_CALLEE" in json.dumps(refreshed[-1]):
                break
            time.sleep(1)
        save("caller_after_explicit_callee_query", refreshed)
        save("stop_for_refresh_control", a.call("lsp_stop_server", server_id="elixir", workspace_root=str(alpha)))
        save("caller_after_server_restart", a.nav("lsp_hover"))
        target.write_text(original)

        b = MCP(args.bridge.resolve(), beta, output, "beta")
        clients.append(b)
        save("reviewer_before", b.nav("lsp_hover"))
        run(["git", "checkout", "--detach", a_sha], beta)
        revisions = []
        for _ in range(6):
            revisions.append({"hover": b.nav("lsp_hover"), "references": b.nav("lsp_find_references", include_declaration=False)})
            if "ALPHA" in json.dumps(revisions[-1]["hover"]):
                break
            time.sleep(1)
        save("reviewer_eventual_results", revisions)
        save("cross_root_response", a.call("lsp_hover", file_path=str(beta / "lib/caller.ex"), line=2, column=29))
        save("cross_root_server_status", a.call("lsp_server_status"))
        for client in clients:
            owned = client.remember()
            client.proc.terminate()
            deadline = time.monotonic() + 10
            while alive(owned) and time.monotonic() < deadline:
                time.sleep(0.2)
            save(f"{client.name}_sigterm_remaining", alive(owned))
    finally:
        for client in clients:
            client.cleanup()


if __name__ == "__main__":
    main()
