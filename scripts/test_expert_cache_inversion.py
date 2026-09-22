#!/usr/bin/env python3
"""Probe whether a live Expert survives forced rebuilds of its disposable cache."""

import argparse
import json
import os
from pathlib import Path
import queue
import re
import signal
import subprocess
import sys
import threading
import time

sys.path.insert(0, str(Path(__file__).resolve().parent))
from stress_elixir_lsp import Session, locations, success, text  # noqa: E402


def create_fixture(root):
    (root / "lib").mkdir(parents=True)
    (root / "mix.exs").write_text(
        """defmodule CacheInversion.MixProject do
  use Mix.Project

  def project do
    [app: :cache_inversion, version: "0.1.0", elixir: "~> 1.15"]
  end
end
"""
    )
    source = root / "lib/cache_inversion.ex"
    source.write_text(
        """defmodule CacheInversion do
  def target(value), do: {:ok, value}
  def first(value), do: target(value)
  def second(value), do: target(value + 1)
end
"""
    )
    return source


def builder_command(tools, cache):
    metadata_path = tools.parent / "exploration.json"
    if metadata_path.is_file():
        metadata = json.loads(metadata_path.read_text())
        builder = Path(metadata["builder"]).resolve()
        source = Path(metadata["engine_source"]).resolve()
        version = metadata["version"]
        if not builder.is_file() or not source.is_dir():
            raise RuntimeError(f"invalid release metadata in {metadata_path}")
        return [
            "elixir",
            str(builder),
            "--vsn",
            version,
            "--source-path",
            str(source),
            "--cache-dir",
            str(cache),
            "--force",
        ]

    expert = (tools / "bin/expert").resolve()
    release = expert.parent.parent
    priv_candidates = sorted(release.glob("lib/*expert-*/priv"))
    if len(priv_candidates) != 1:
        raise RuntimeError(f"expected one Expert priv directory under {release}: {priv_candidates}")
    priv = priv_candidates[0]
    return [
        "elixir",
        str(priv / "build_engine.exs"),
        "--vsn",
        release.name.removeprefix("expert-"),
        "--source-path",
        str(priv / "engine_source/apps/engine"),
        "--cache-dir",
        str(cache),
        "--force",
    ]


def query(session, source, phase):
    reply, elapsed = session.call("references", source, 3, 25, phase=phase)
    found = locations(reply)
    expected = {(str(source), "3"), (str(source), "4")}
    actual = {(item[0], item[1]) for item in found}
    return {
        "phase": phase,
        "elapsed_seconds": round(elapsed, 3),
        "passed": success(reply) and len(found) == 2 and actual == expected,
        "locations": found,
        "error": None if success(reply) else text(reply) or reply,
    }


def first_method_queries_while_cache_absent(session, source):
    definition, definition_elapsed = session.call(
        "definition", source, 3, 25, phase="absent-cache-first-definition"
    )
    definition_locations = locations(definition)
    diagnostics, diagnostics_elapsed = session.call(
        "diagnostics", source, phase="absent-cache-first-diagnostics"
    )
    return {
        "definition": {
            "elapsed_seconds": round(definition_elapsed, 3),
            "passed": success(definition)
            and any(item[0] == str(source) and item[1] == "2" for item in definition_locations),
            "locations": definition_locations,
            "error": None if success(definition) else text(definition) or definition,
        },
        "diagnostics": {
            "elapsed_seconds": round(diagnostics_elapsed, 3),
            "passed": success(diagnostics) and "Diagnostics in File: 0" in text(diagnostics),
            "response": text(diagnostics),
        },
    }


def run_builder(command, log_path, kill_at_namespacing=False, timeout=180):
    started = time.monotonic()
    process = subprocess.Popen(
        command,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        bufsize=1,
        start_new_session=True,
    )
    lines = []
    namespacing = threading.Event()

    def capture():
        for line in process.stdout:
            lines.append(line)
            if re.search(r"Namespacing", line, re.IGNORECASE):
                namespacing.set()

    reader = threading.Thread(target=capture, daemon=True)
    reader.start()
    killed = False
    try:
        if kill_at_namespacing:
            deadline = time.monotonic() + min(timeout, 120)
            while not namespacing.wait(timeout=0.1):
                if process.poll() is not None:
                    raise RuntimeError(
                        f"builder exited {process.returncode} before reporting Namespacing"
                    )
                if time.monotonic() >= deadline:
                    raise TimeoutError("builder never reported Namespacing")
            os.killpg(process.pid, signal.SIGKILL)
            killed = True
        returncode = process.wait(timeout=timeout)
    except BaseException:
        if process.poll() is None:
            os.killpg(process.pid, signal.SIGKILL)
            process.wait()
        raise
    finally:
        reader.join(timeout=5)
        log_path.write_text("".join(lines))
    return {
        "command": command,
        "returncode": returncode,
        "killed_after_namespacing_log": killed,
        "saw_namespacing": namespacing.is_set(),
        "elapsed_seconds": round(time.monotonic() - started, 3),
        "log": str(log_path),
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--tools-dir", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--query-interval", type=float, default=0.1)
    args = parser.parse_args()

    tools = args.tools_dir.resolve()
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    cache = output / "cache"
    project = output / "project"
    source = create_fixture(project)
    command = builder_command(tools, cache)
    report = {
        "tools_dir": str(tools),
        "cache_dir": str(cache),
        "project": str(project),
        "builder_command": command,
        "queries": [],
        "builders": [],
        "checks": [],
        "limitations": [
            "Warm references can succeed from loaded BEAM modules even if cached files vanish.",
            "A first method call does not prove its implementing module was unloaded.",
            "SIGKILL is sent after the Namespacing log; the harness does not prove it interrupted a file copy.",
        ],
    }
    sessions = []
    previous_cache = os.environ.get("TIPS_EXPERT_TEST_CACHE")
    previous_hex_home = os.environ.get("HEX_HOME")
    os.environ["TIPS_EXPERT_TEST_CACHE"] = str(cache)
    os.environ["HEX_HOME"] = str(cache / "hex")

    def check(name, passed, detail=None):
        item = {"name": name, "passed": bool(passed), "detail": detail}
        report["checks"].append(item)
        print(json.dumps(item), flush=True)

    try:
        live = Session(tools, project, output, "live-reader")
        sessions.append(live)
        warm = query(live, source, "warm-before-force")
        report["queries"].append(warm)
        check("live-reader-warm", warm["passed"], warm)
        if not warm["passed"]:
            raise RuntimeError("live Expert did not satisfy the oracle before rebuilding")

        dev_ns_candidates = sorted(cache.glob("**/_build/dev_ns"))
        if len(dev_ns_candidates) != 1:
            raise RuntimeError(f"expected one cached dev_ns directory: {dev_ns_candidates}")
        dev_ns = dev_ns_candidates[0]
        report["dev_ns_path"] = str(dev_ns)

        builder_result = queue.Queue()
        dev_ns_absent = threading.Event()
        stop_observer = threading.Event()

        def observe_dev_ns():
            while not stop_observer.is_set():
                if not dev_ns.exists():
                    report["dev_ns_absent_at_monotonic"] = time.monotonic()
                    dev_ns_absent.set()
                    return
                time.sleep(0.002)

        def rebuild():
            try:
                builder_result.put(run_builder(command, output / "forced-builder.log"))
            except BaseException as error:
                builder_result.put(error)

        worker = threading.Thread(target=rebuild)
        observer = threading.Thread(target=observe_dev_ns, daemon=True)
        worker.start()
        observer.start()
        first_method_result = None
        while worker.is_alive():
            if dev_ns_absent.is_set() and first_method_result is None:
                first_method_result = first_method_queries_while_cache_absent(live, source)
                report["first_method_queries_while_cache_absent"] = first_method_result
            result = query(live, source, "during-force")
            report["queries"].append(result)
            time.sleep(args.query_interval)
        worker.join()
        stop_observer.set()
        observer.join(timeout=1)
        forced = builder_result.get()
        if isinstance(forced, BaseException):
            raise forced
        report["builders"].append(forced)
        check("forced-builder-completed", forced["returncode"] == 0, forced)
        check(
            "first-method-queries-while-cache-absent",
            dev_ns_absent.is_set()
            and first_method_result is not None
            and first_method_result["definition"]["passed"]
            and first_method_result["diagnostics"]["passed"],
            {
                "absence_observed": dev_ns_absent.is_set(),
                "dev_ns": str(dev_ns),
                "queries": first_method_result,
            },
        )
        during = [item for item in report["queries"] if item["phase"] == "during-force"]
        check(
            "live-reader-served-through-force",
            bool(during) and all(item["passed"] for item in during),
            {
                "queries": len(during),
                "failures": [item for item in during if not item["passed"]],
                "scope": "warm references queries; loaded BEAM modules may mask missing files",
            },
        )
        after = query(live, source, "after-force")
        report["queries"].append(after)
        check("live-reader-after-force", after["passed"], after)

        killed = run_builder(command, output / "killed-builder.log", kill_at_namespacing=True)
        report["builders"].append(killed)
        check(
            "builder-killed-after-namespacing-log",
            killed["saw_namespacing"] and killed["returncode"] != 0,
            killed,
        )

        ordinary = Session(tools, project, output, "ordinary-post-kill-reader")
        sessions.append(ordinary)
        try:
            ordinary_result = query(ordinary, source, "ordinary-post-kill")
        except Exception as error:
            ordinary_result = {
                "phase": "ordinary-post-kill",
                "passed": False,
                "locations": [],
                "error": repr(error),
            }
        report["queries"].append(ordinary_result)
        report["ordinary_recovery"] = ordinary_result
        check("ordinary-expert-after-kill", ordinary_result["passed"], ordinary_result)

        if not ordinary_result["passed"]:
            ordinary.close()
            recovery = run_builder(command, output / "forced-repair-builder.log")
            report["builders"].append(recovery)
            check("forced-repair-after-ordinary-failure", recovery["returncode"] == 0, recovery)

            repaired = Session(tools, project, output, "post-repair-reader")
            sessions.append(repaired)
            repaired_result = query(repaired, source, "post-forced-repair")
            report["queries"].append(repaired_result)
            check("expert-after-forced-repair", repaired_result["passed"], repaired_result)
    except BaseException as error:
        report["exception"] = repr(error)
        check("harness-completed", False, repr(error))
    finally:
        for session in sessions:
            session.close()
        if previous_cache is None:
            os.environ.pop("TIPS_EXPERT_TEST_CACHE", None)
        else:
            os.environ["TIPS_EXPERT_TEST_CACHE"] = previous_cache
        if previous_hex_home is None:
            os.environ.pop("HEX_HOME", None)
        else:
            os.environ["HEX_HOME"] = previous_hex_home
        report["status"] = "PASS" if report["checks"] and all(
            item["passed"] for item in report["checks"]
        ) else "FAIL"
        (output / "report.json").write_text(json.dumps(report, indent=2) + "\n")
        print(json.dumps({"status": report["status"], "evidence": str(output)}), flush=True)
    return 0 if report["status"] == "PASS" else 1


if __name__ == "__main__":
    raise SystemExit(main())
