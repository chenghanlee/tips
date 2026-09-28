#!/usr/bin/env python3
"""Compare cold and warm LSP readiness on equal, dependency-populated Tips worktrees."""

import argparse
import datetime
import json
import shutil
import time
from pathlib import Path

from pilot_dexter import Client, require, run


def prepare(repository, output):
    revision = run("git", "rev-parse", "HEAD", cwd=repository).strip()
    roots = {}
    for backend in ("dexter", "elixirls"):
        root = output / backend
        run("git", "worktree", "add", "--detach", str(root), revision, cwd=repository)
        # Ordinary independent copies. Existing dependency downloads are outside
        # this benchmark; no _build, .dexter or .elixir_ls cache is copied.
        shutil.copytree(repository / "deps", root / "deps")
        fixture = root / "lib/lsp_startup_probe.ex"
        require(not fixture.exists(), "startup fixture already exists")
        fixture.write_text(
            "defmodule LspStartupProbe do\n"
            "  def account(email), do: Tips.Accounts.get_user_by_email(email)\n"
            "  def changeset(data), do: Ecto.Changeset.change(data)\n"
            "end\n"
        )
        roots[backend] = root
    return roots, revision


def readiness(client, root, started):
    source = root / "lib/lsp_startup_probe.ex"
    lines = source.read_text().splitlines()
    project_column = lines[1].index("get_user_by_email") + 1
    dependency_column = lines[2].index("change(data)") + 1
    checks = [
        ("project_definition", "definition", 2, project_column, str(root / "lib/tips/accounts.ex")),
        ("dependency_definition", "definition", 3, dependency_column,
         str(root / "deps/ecto/lib/ecto/changeset.ex")),
        ("project_hover", "hover", 2, project_column, "Gets a user by email"),
        ("project_references", "references", 2, project_column, str(source)),
    ]
    observed = {}
    deadline = started + 300
    while len(observed) != len(checks):
        for label, tool, line, column, expected in checks:
            if label in observed:
                continue
            result, text = client.tool(tool, source, line=line, column=column)
            if not result.get("isError") and expected in text:
                observed[label] = round(time.perf_counter() - started, 4)
            elif time.perf_counter() >= deadline:
                raise AssertionError(f"{label} not ready: {text}")
        time.sleep(0.05)
    return observed


def completion(log, backend, started_wall):
    # Use the bridge's microsecond timestamp, not the coarser server log text.
    for line in log.read_text().splitlines():
        matched = (
            "Background reindex:" in line if backend == "dexter"
            else '"elixir_ls.build_result":"mix_compile_ok"' in line
            or '"elixir_ls.build_result":"mix_compile_noop"' in line
        )
        if matched:
            stamp = datetime.datetime.strptime(line[:26], "%Y/%m/%d %H:%M:%S.%f").timestamp()
            return {"seconds": round(stamp - started_wall, 4), "event": line}
        if backend == "elixirls" and '"elixir_ls.build_result":"mix_compile_error"' in line:
            raise AssertionError("ElixirLS compilation failed; inspect retained log")
    return None


def measure(backend, label, root, output, launcher, tools):
    log = output / f"{backend}-{label}.log"
    started_wall, started = time.time(), time.perf_counter()
    client = Client(root, log, launcher=launcher, environment={
        "TIPS_ELIXIR_TOOLS": str(tools), "TIPS_DB_SUFFIX": f"_startup_{backend}",
        "TIPS_TEST_PORT": "4961" if backend == "dexter" else "4962",
    })
    try:
        client.initialize()
        protocol_seconds = time.perf_counter() - started
        navigation = readiness(client, root, started)
        finished = completion(log, backend, started_wall)
        while finished is None and time.perf_counter() - started < 300:
            time.sleep(0.1)
            finished = completion(log, backend, started_wall)
        require(finished is not None, "no successful background completion within 300 seconds")
        return {"protocol_seconds": round(protocol_seconds, 4),
                "navigation_seconds": navigation,
                "all_navigation_ready_seconds": max(navigation.values()),
                "background_completion": finished}
    finally:
        client.close()


def compare(args):
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    roots, revision = prepare(args.repository.resolve(), output)
    evidence = {"revision": revision, "cold": "no per-worktree server index/build cache",
                "warm": "restart retaining server state; identical source and dependency files",
                "excluded": "dependency fetching, tool installation; OS filesystem cache not flushed",
                "execution": "one LSP server at a time", "results": {}}
    try:
        for backend in ("dexter", "elixirls"):
            launcher = args.dexter_launcher if backend == "dexter" else args.elixirls_launcher
            tools = args.dexter_tools if backend == "dexter" else args.elixirls_tools
            evidence["results"][backend] = {}
            for label in ("cold", "warm-1", "warm-2"):
                print(f"Measuring {backend} {label}", flush=True)
                result = measure(backend, label, roots[backend], output,
                                 launcher.resolve(), tools.resolve())
                evidence["results"][backend][label] = result
                print(json.dumps(result), flush=True)
                (output / "evidence.json").write_text(json.dumps(evidence, indent=2) + "\n")
    except Exception as error:
        evidence["failure"] = str(error)
        raise
    finally:
        (output / "evidence.json").write_text(json.dumps(evidence, indent=2) + "\n")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("output", type=Path)
    parser.add_argument("--repository", required=True, type=Path,
                        help="Tips checkout with dependencies already fetched")
    parser.add_argument("--dexter-launcher", required=True, type=Path)
    parser.add_argument("--dexter-tools", required=True, type=Path)
    parser.add_argument("--elixirls-launcher", required=True, type=Path)
    parser.add_argument("--elixirls-tools", required=True, type=Path)
    compare(parser.parse_args())
