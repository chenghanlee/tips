#!/usr/bin/env python3
"""Warm-build phase probe: real hook after each edit, with per-phase timestamps.

Measurement only. Starts the given bundle through its supported `serve` entry,
edits a disposable Tips checkout, runs the real PostToolUse hook, and records
Neovim-side event times plus ElixirLS `[warm-phases]` lines (instrumented builds).
"""

import argparse
import json
import os
import statistics
import subprocess
import sys
import time
from pathlib import Path

E = Path(__file__).resolve().parent
sys.path.insert(0, str(E))

from bundle_probe import BundleMCP  # noqa: E402
from neovim_dogfood import environment  # noqa: E402
from neovim_probe import poll  # noqa: E402

OBSERVER = r"""
local m = require('neovim_sync')
if not _G.warm_observe then
  _G.warm_observe = m.observe
  m.observe = function(method, data)
    local s, us = vim.uv.gettimeofday()
    local t = s + us / 1e6
    local e = _G.warm_events
    if method == 'telemetry/event' then
      e[#e + 1] = { t = t, kind = 'telemetry', name = data.name,
        result = data.properties and data.properties['elixir_ls.build_result'] or vim.NIL,
        build_ms = data.measurements and data.measurements['elixir_ls.build_time'] or vim.NIL }
    elseif method == 'window/logMessage' then
      local msg = data.message or ''
      if msg:find('Starting build', 1, true) or msg:find("[warm", 1, true)
          or msg:find('Compile took', 1, true) or msg:find('Compiling', 1, true) then
        e[#e + 1] = { t = t, kind = 'log', message = msg:sub(1, 600) }
      end
    elseif method == 'textDocument/publishDiagnostics' then
      e[#e + 1] = { t = t, kind = 'diagnostics', uri = data.uri, count = #(data.diagnostics or {}) }
    elseif method:sub(1, 5) == 'sent:' then
      e[#e + 1] = { t = t, kind = 'sent', method = method:sub(6) }
    end
    return _G.warm_observe(method, data)
  end
end
_G.warm_events = {}
return true
"""

TAKE = "local e = _G.warm_events; _G.warm_events = {}; return e"


class Edits:
    """Content-changing edits that keep the checkout compilable."""

    def __init__(self, root: Path):
        self.root = root
        self.targets = {
            "ex_doc": root / "lib/tips/health.ex",
            "exs_test": root / "test/tips/release_test.exs",
            "router": root / "lib/tips_web/router.ex",
        }
        self.original = {k: p.read_text() for k, p in self.targets.items()}

    def apply(self, kind: str, index: int) -> Path:
        path, text = self.targets[kind], self.original[kind]
        if kind == "ex_doc":
            text = text.replace("can reach its database.", f"can reach its database. Probe {index:03}.")
        else:
            text = text + f"# warm probe {index:03}\n"
        assert text != self.original[kind]
        path.write_text(text)
        return path

    def restore(self) -> None:
        for kind, path in self.targets.items():
            if path.read_text() != self.original[kind]:
                path.write_text(self.original[kind])


def run_hook(bundle: Path, root: Path, state: Path, audit: Path) -> dict:
    started = time.time()
    then = time.monotonic()
    proc = subprocess.run(
        [sys.executable, str(bundle / "bundle.py"), "hook", "--workspace", str(root),
         "--state", str(state), "--budget-ms", "5000", "--audit", str(audit)],
        input=json.dumps({"hook_event_name": "PostToolUse", "tool_name": "apply_patch"}),
        text=True, capture_output=True, check=True, timeout=8)
    return {"start": started, "seconds": time.monotonic() - then, "output": json.loads(proc.stdout)}


def summarize(sample: dict) -> dict:
    t0 = sample["write_at"]
    out = {"hook_s": round(sample["hook"]["seconds"], 4)}
    phases = {}
    firsts = {}
    for event in sample["events"]:
        rel = round(event["t"] - t0, 4)
        kind = event["kind"]
        if kind == "sent":
            firsts.setdefault("notify_" + event["method"].split("/")[-1], rel)
        elif kind == "telemetry":
            firsts.setdefault("tele_" + event["name"], rel)
            if event["name"] == "build":
                out.setdefault("build_ms", event.get("build_ms"))
                out.setdefault("build_result", event.get("result"))
        elif kind == "log":
            message = event["message"]
            if "Starting build" in message:
                firsts.setdefault("build_start", rel)
            elif message.startswith("[warm-phases]"):
                if not phases:
                    for part in message.split()[1:]:
                        key, _, value = part.partition("=")
                        phases[key] = value if key == "result" else int(value)
            elif message.startswith("[warm-apps]"):
                out.setdefault("app_cache", message[len("[warm-apps] "):])
            elif message.startswith("[warm-prune]"):
                out.setdefault("prune_detail", message[len("[warm-prune] "):])
            elif "Compiling" in message:
                firsts.setdefault("compiling", rel)
        elif kind == "diagnostics":
            firsts["last_diagnostics"] = rel
    out["at"] = firsts
    out["phases_us"] = phases
    out["builds"] = sum(1 for e in sample["events"] if e["kind"] == "telemetry" and e["name"] == "build")
    return out


def stats(values: list[float]) -> dict:
    values = sorted(values)
    if not values:
        return {}
    return {"n": len(values), "median": round(statistics.median(values), 4),
            "p90": round(values[min(len(values) - 1, int(round(0.9 * (len(values) - 1))))], 4),
            "min": round(values[0], 4), "max": round(values[-1], 4)}


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--bundle", type=Path, required=True)
    parser.add_argument("--workspace", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--label", required=True)
    parser.add_argument("--rounds", type=int, default=10)
    parser.add_argument("--kinds", default="ex_doc,exs_test,router")
    parser.add_argument("--settle", type=float, default=0.6)
    args = parser.parse_args()
    bundle, root = args.bundle.resolve(), args.workspace.resolve()
    output = args.output.resolve() / args.label
    output.mkdir(parents=True, exist_ok=False)
    values = environment(root, 7, "warm", "beta", 300)
    values.pop("MIX_ENV")
    os.environ.update(values)
    os.environ.pop("MIX_ENV", None)
    sys.path.insert(0, str(bundle / "vendor/python"))
    kinds = args.kinds.split(",")
    edits = Edits(root)
    results: dict = {"label": args.label, "bundle": str(bundle), "kinds": kinds, "samples": []}

    def save() -> None:
        (output / "results.json").write_text(json.dumps(results, indent=2) + "\n")

    client = None
    try:
        then = time.monotonic()
        client = BundleMCP(bundle, root, output, "session")
        results["connection_s"] = round(time.monotonic() - then, 3)
        ready = poll(lambda: client.rpc().exec_lua("return require('neovim_sync').ready()"), bool, 240)
        assert ready["matched"], "session never became ready"
        results["ready_s"] = round(time.monotonic() - then, 3)
        client.rpc().exec_lua(OBSERVER)
        state = client.state_dir
        audit = output / "hook-audit.jsonl"
        index = 0
        for round_number in range(args.rounds + 1):
            for kind in kinds:
                index += 1
                write_at = time.time()
                edits.apply(kind, index)
                hook = run_hook(bundle, root, state, audit)
                settled = poll(lambda: client.rpc().exec_lua("return require('neovim_sync').status()"),
                               lambda s: s["status"] == "current", 10)
                time.sleep(args.settle)
                events = client.rpc().exec_lua(TAKE)
                sample = {"round": round_number, "kind": kind, "index": index, "write_at": write_at,
                          "hook": hook, "events": events, "settled": settled["matched"],
                          "status_after": settled["samples"][-1]["value"]}
                sample["summary"] = summarize(sample)
                if round_number > 0:  # round 0 warms the path and is excluded
                    results["samples"].append(sample)
                print(json.dumps({"kind": kind, "index": index, **sample["summary"]})[:400], flush=True)
                save()
        edits.restore()
        run_hook(bundle, root, state, audit)
        poll(lambda: client.rpc().exec_lua("return require('neovim_sync').status()"),
             lambda s: s["status"] == "current", 10)
        by_kind = {}
        for kind in kinds:
            rows = [s["summary"] for s in results["samples"] if s["kind"] == kind]
            phase_names = sorted({k for r in rows for k in r["phases_us"] if k != "result"})
            by_kind[kind] = {
                "hook_s": stats([r["hook_s"] for r in rows]),
                "build_ms": stats([r["build_ms"] for r in rows if isinstance(r.get("build_ms"), (int, float))]),
                "builds_per_edit": stats([r["builds"] for r in rows]),
                "phases_ms": {p: stats([r["phases_us"][p] / 1000 for r in rows if p in r["phases_us"]])
                              for p in phase_names},
                "at_s": {a: stats([r["at"][a] for r in rows if a in r["at"]])
                         for a in sorted({k for r in rows for k in r["at"]})},
            }
        results["by_kind"] = by_kind
        results["passed"] = all(s["settled"] for s in results["samples"])
        save()
    finally:
        edits.restore()
        if client:
            client.cleanup()


if __name__ == "__main__":
    main()
