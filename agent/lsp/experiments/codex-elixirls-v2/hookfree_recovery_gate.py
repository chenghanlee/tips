#!/usr/bin/env python3
"""pS hook-free recovery and lifecycle gate (Solution 2), through real stdio MCP, any bundle.

Triggers are ordinary `lsp` MCP requests only: no hook command, no neovim_sync.collect, no direct
scan() call. Labelled fault injection over the registry socket: the native watcher is cancelled for
the whole run and the first workspace/didChangeWatchedFiles is rejected. RPC also reads a
delivery-attempt log (observation only).

Oracles: the hover doc of V2Target.answer carries the external resource value, so an MCP answer
shows what ElixirLS compiled; `mix run --no-compile` against the ElixirLS build checks the resource
owner and a compile-time caller. Invariant: an answer labelled current never shows older content.

Negative controls (must FAIL): --mutant no-scan (requests do not reconcile disk),
--mutant drop-failed (a rejected delivery is not kept for retry).
Replaces neovim_reconcile_probe.py (hook-driven); reuses its fixture and the probe helpers.
Run: python3.14 hookfree_recovery_gate.py --bundle <bundle> --output <new dir> [--mutant NAME]
"""

import argparse
import hashlib
import json
import os
import re
import subprocess
import sys
import time
from pathlib import Path

from bundle_probe import BundleMCP
from neovim_probe import poll
from probe import alive, descendants, prepare

SETTLE_S = 30.0
TARGET = """defmodule V2Target do
  @external_resource Path.expand("value.heex", __DIR__)
  @value (case File.read(@external_resource) do
    {:ok, text} -> text
    {:error, :enoent} -> "missing"
  end)
  # Black-box progress marker (tmp/ is outside the scan and the watcher): this compile read @value.
  File.write!(Path.expand("../tmp/read-#{@value}", __DIR__), "")
  WAIT
  @doc "Value #{@value}"
  def answer, do: @value
end
"""
CALLER = "defmodule V2Caller do\n  @value V2Target.answer()\n  def call_1, do: @value\nend\n"
ACCEPTANCE = """ExUnit.start()
defmodule ReconcileTest do
  use ExUnit.Case, async: true
  test "resource owner matches saved state" do
    assert V2Target.answer() == System.fetch_env!("EXPECTED")
  end
  test "compile-time caller matches saved state" do
    assert V2Caller.call_1() == System.fetch_env!("EXPECTED")
  end
end
"""
# Fault injection (labelled): no native watcher; the first watched-file notification is rejected.
FAULTS = r"""
local c = vim.lsp.get_clients({ name = 'elixirls' })[1]
require('vim.lsp._watchfiles').cancel(c.id)
_G.ps_watch = {}
local notify = c.notify
c.notify = function(self, method, params, ...)
  if method == 'workspace/didChangeWatchedFiles' then
    local accepted = #_G.ps_watch > 0
    for _, change in ipairs(params.changes) do
      table.insert(_G.ps_watch, { uri = change.uri, type = change.type, accepted = accepted })
    end
    if not accepted then return false end
  end
  return notify(self, method, params, ...)
end
return c.id
"""
MUTANTS = {
    # Models a candidate whose requests no longer reconcile disk (scan assumed to be hook-only).
    "no-scan": "require('neovim_sync').scan = function() return true end return true",
    # Models deleting failed-delivery bookkeeping as if it were delivery-only state.
    "drop-failed": r"""
local s = require('neovim_sync')
local inner = s.scan
s.scan = function(...)
  local ok = inner(...)
  for path in pairs(s.sync_errors) do s.pending[path], s.sync_errors[path] = nil, nil end
  return ok
end
return true
""",
}


class Gate:
    def __init__(self, bundle, output):
        self.output, self.t0, self.checks = output, time.monotonic(), []
        self.root, _, _, _ = prepare(output)
        r = self.root
        self.target, self.resource = r / "lib/target.ex", r / "lib/value.heex"
        self.caller, self.broken = r / "lib/caller.ex", r / "lib/broken.ex"
        (r / "tmp").mkdir()
        self.target.write_text(TARGET.replace("WAIT", "Process.sleep(800)"))
        self.resource.write_text("aa")
        self.caller.write_text(CALLER)
        (r / "acceptance.exs").write_text(ACCEPTANCE)
        self.bundle = bundle
        self.client = BundleMCP(bundle, r, output, "recovery")

    def save(self):
        (self.output / "results.json").write_text(
            json.dumps({"checks": self.checks}, indent=2) + "\n"
        )

    def check(self, name, passed, detail, inconclusive=False, measured=False):
        # A failed check stays FAIL; INCONCLUSIVE only marks a check that could not discriminate.
        if measured:
            result = "MEASURED"
        elif passed:
            result = "PASS"
        else:
            result = "INCONCLUSIVE" if inconclusive else "FAIL"
        self.checks.append({"check": name, "result": result, "detail": detail})
        self.save()
        print(f"{result:<12} {name}: {json.dumps(detail)[:300]}", flush=True)
        return passed

    def ask(self, operation, path, **extra):
        extra.setdefault("timeoutMs", 10000)
        reply = self.client.call("lsp", operation=operation, uri=str(path), **extra)
        data = reply["data"] if isinstance(reply.get("data"), dict) else {}
        error = data.get("error") if isinstance(data.get("error"), dict) else {}
        feedback = data.get("feedback") or error.get("feedback") or {}
        value = re.search(r"Value (\w+)", "\n".join(data.get("items") or []))
        diagnostics = {
            str(Path(p).resolve().relative_to(self.root.resolve()))
            if str(p).startswith("/")
            else p: [str(d.get("message") if isinstance(d, dict) else d)[:160] for d in items]
            for p, items in (data.get("diagnostics") or {}).items()
        }
        return {
            "t": round(time.monotonic() - self.t0, 3),
            "op": operation,
            "status": feedback.get("status") or (f"error:{error.get('code')}" if error else None),
            "code": error.get("code"),
            "retryable": error.get("retryable"),
            "building": feedback.get("building"),
            "queued": feedback.get("queued"),
            "generation": feedback.get("generation"),
            "completed": feedback.get("completed"),
            "value": value.group(1) if value else None,
            "errors": data.get("errors"),
            "diagnostics": diagnostics,
            "message": (feedback.get("message") or error.get("message") or "")[:240],
        }

    def hover(self, **extra):
        return self.ask("hover", self.caller, line=2, character=20, **extra)

    def settle(self, request, done=("current",)):
        """Labelled bounded retry of one ordinary request until a settled status or SETTLE_S."""
        samples, begun = [], time.monotonic()
        while True:
            samples.append(request())
            if samples[-1]["status"] in done or time.monotonic() - begun > SETTLE_S:
                return samples
            time.sleep(0.25)

    def stale_current(self, samples, expected):
        return [s for s in samples if s["status"] == "current" and s["value"] != expected]

    def fresh(self, name, expected):
        samples = self.settle(self.hover)
        final = samples[-1]
        self.check(
            name + " settles current with the disk value",
            final["status"] == "current"
            and final["value"] == expected
            and not self.stale_current(samples, expected),
            {
                "expected": expected,
                "attempts": len(samples),
                "final": final,
                "statuses": [s["status"] for s in samples],
            },
        )
        self.accept(name + " ElixirLS build (owner + compile-time caller)", expected)
        return samples

    def accept(self, name, expected):
        env = os.environ | {
            "MIX_ENV": "test",
            "MIX_BUILD_PATH": str(self.root / ".elixir_ls/build/test"),
            "EXPECTED": expected,
        }
        r = subprocess.run(
            # Fixed argv, no shell; mix resolves to the bundle toolchain first on PATH.
            ["unbuffer", "mix", "run", "--no-start", "--no-compile", "acceptance.exs"],  # noqa: S607
            cwd=self.root,
            env=env,
            capture_output=True,
            text=True,
            timeout=60,
        )
        return self.check(
            name,
            r.returncode == 0,
            {"expected": expected, "exit": r.returncode, "tail": (r.stdout + r.stderr)[-300:]},
        )

    def lua(self, code, *args):
        return self.client.rpc().exec_lua(code, *args)

    def attempts(self):
        """Watched-file deliveries for the resource (observation of the fault-injection log)."""
        return [
            a for a in self.lua("return _G.ps_watch") or [] if a["uri"].endswith("/lib/value.heex")
        ]

    def compiling(self, name):
        """Ordinary requests (they reconcile disk) until a V2Target compile read the resource."""
        for marker in (self.root / "tmp").glob("read-*"):
            marker.unlink()
        samples, deadline = [], time.monotonic() + 8
        while time.monotonic() < deadline:
            samples.append(self.hover())
            if any((self.root / "tmp").glob("read-*")):
                return samples, True
            time.sleep(0.05)
        self.check(
            name + ": compile start observed",
            False,
            {"statuses": [s["status"] for s in samples]},
            inconclusive=True,
        )
        return samples, False


def run(g, mutant):
    ready = g.settle(lambda: g.ask("workspace_diagnostics", g.root))
    g.check(
        "R0 initial workspace settles current",
        ready[-1]["status"] == "current",
        {"attempts": len(ready), "final": ready[-1]},
    )
    g.fresh("R1 baseline", "aa")
    g.check(
        "F0 fault injection: watcher cancelled, first notification rejected",
        bool(g.lua(FAULTS)),
        {},
    )
    if mutant:
        g.check("M0 mutant installed: " + mutant, bool(g.lua(MUTANTS[mutant])), {})

    # S1: metadata-preserved resource edit; ONLY ordinary requests may trigger (re)delivery.
    old = g.resource.stat()
    g.resource.write_text("bb")
    os.utime(g.resource, ns=(old.st_atime_ns, old.st_mtime_ns))
    time.sleep(1.5)
    g.check(
        "A1 no delivery without a request (no watcher, hook, timer or build)",
        g.attempts() == [],
        {"attempts": g.attempts()},
    )
    first = g.hover()
    g.check(
        "A2 first request after the missed edit is not current, and retryable",
        first["status"] != "current" and first["retryable"] is not False,
        {"first": first, "attempts": g.attempts()},
    )
    time.sleep(1.5)
    after_first = g.attempts()
    g.check(
        "A3 exactly one (rejected) delivery; nothing retried it without a request",
        [a["accepted"] for a in after_first] == [False],
        {"attempts": after_first},
    )
    g.accept("A3 ElixirLS still built from the old resource (edit missed)", "aa")
    second = g.hover()
    g.check(
        "A4 the next ordinary request retried the delivery",
        [a["accepted"] for a in g.attempts()] == [False, True]
        and not g.stale_current([second], "bb"),
        {"second": second, "attempts": g.attempts()},
    )
    g.fresh("A5 missed + rejected + request retry", "bb")
    if mutant:
        return

    # S2: delete and recreate the external resource (unopened, watcher still missed).
    g.resource.unlink()
    g.fresh("B1 resource deleted", "missing")
    g.resource.write_text("cc")
    g.fresh("B2 resource recreated", "cc")
    kinds = [(a["type"], a["accepted"]) for a in g.attempts()]
    g.check(
        "B3 deletion and creation were delivered by requests",
        (3, True) in kinds and (1, True) in kinds,
        {"deliveries": kinds},
    )

    # S3: first touch of a new, never-opened file with a syntax error.
    g.broken.write_text("defmodule V2Broken do\n  def broken(, do: 1\nend\n")
    first = g.ask("diagnostics", g.broken)
    g.check(
        "C1 first diagnostics read is not a false clean",
        not (first["status"] == "current" and not first["diagnostics"].get("lib/broken.ex")),
        {"first": first},
    )
    samples = g.settle(lambda: g.ask("diagnostics", g.broken), done=("current", "failed"))
    g.check(
        "C2 settles failed with the syntax error",
        samples[-1]["status"] == "failed" and bool(samples[-1]["diagnostics"].get("lib/broken.ex")),
        {"attempts": len(samples), "final": samples[-1]},
    )
    during = g.hover()
    g.check(
        "C3 hover still answers while failed and is not labelled current",
        during["status"] == "failed" and during["value"] == "cc",
        {"hover": during},
    )
    g.broken.write_text("defmodule V2Broken do\n  def broken, do: 1\nend\n")
    samples = g.settle(lambda: g.ask("workspace_diagnostics", g.root))
    g.check(
        "C4 repair of the opened file clears the error",
        samples[-1]["status"] == "current" and not samples[-1]["diagnostics"].get("lib/broken.ex"),
        {"attempts": len(samples), "final": samples[-1]},
    )

    # S4: an edit lands while a build of the previous edit runs; one request times out meanwhile.
    g.resource.write_text("dd")
    before, seen = g.compiling("D1")
    if seen:
        g.resource.write_text("ee")
        written = time.monotonic() - g.t0
        timed = g.hover(timeoutMs=1)
        last = before[-1]
        g.check(
            "D1 edit landed during the running compile of dd, and answers said so",
            (g.root / "tmp/read-dd").exists() and bool(last["building"] or last["queued"]),
            {"last_answer_before_write": last},
            inconclusive=(g.root / "tmp/read-dd").exists(),
        )
        # Current with ee: it did not time out (not discriminating). Any other current: FAIL.
        g.check(
            "D2 an unanswered or pending request is not current",
            timed["status"] != "current",
            {"answer": timed},
            inconclusive=timed["status"] == "current" and timed["value"] == "ee",
        )
        samples = g.fresh("D3 edit during build", "ee")
        late = [s for s in samples if s["t"] > written]
        g.check(
            "D4 no current answer after the second write shows the first write",
            not g.stale_current(late, "ee"),
            {"statuses": [(s["status"], s["value"]) for s in late]},
        )


def close(g, long_build):
    client = g.client
    if long_build:
        # The compile now waits on a compiler program (an OS child of ElixirLS) when EOF arrives.
        g.target.write_text(TARGET.replace("WAIT", 'System.cmd("sleep", ["20"])'))
        _, seen = g.compiling("L0")
        child = (
            poll(
                lambda: [
                    p
                    for p, row in descendants(client.proc.pid).items()
                    if re.search(r"(^|/)sleep 20$", row["command"])
                ],
                bool,
                3,
            )
            if seen
            else {"matched": False}
        )
        g.check(
            "L0 EOF arrives while the compile waits on its own program (sleep 20)",
            child["matched"],
            {"sleep_pids": child.get("samples", [{}])[-1].get("value")},
            inconclusive=not child["matched"],
        )
    client.remember()
    started = time.monotonic()
    client.proc.stdin.close()
    client.proc.wait(timeout=15)
    gone = poll(lambda: alive(client.owned), lambda p: not p, 6)
    stderr = Path(client.log.name).read_text()
    state = client.state_dir
    locks = [
        g.root / ".elixir_ls/session.lock",
        g.root / ".elixir_ls/server.lock",
        state / "session.lock",
        state / "server.lock",
    ]
    holders = subprocess.run(  # noqa: S603 - fixed system tool, paths from this run
        ["/usr/sbin/lsof", "-t", *map(str, locks)], capture_output=True, text=True
    ).stdout.split()
    g.check(
        "L1 EOF cleanup: exit 0, empty stderr, owned gone, no lock holder, records removed",
        client.proc.returncode == 0
        and not stderr
        and gone["matched"]
        and not holders
        and not (state / "compiler-groups").exists()
        and not Path(client.instance["socket"]).exists(),
        {
            "exit": client.proc.returncode,
            "stderr": stderr[-300:],
            "seconds": round(time.monotonic() - started, 2),
            "owned_at_eof": len(client.owned),
            "survivors": sorted(alive(client.owned)),
            "lock_holders": holders,
            "compiler_groups": (state / "compiler-groups").exists(),
        },
    )
    entries = sorted(p.name for p in state.glob("registry/*.json"))
    g.check(
        "L2 registry entry after EOF (measured; the next start removes stale entries)",
        True,
        {
            "entries": entries,
            "mtimes": [
                time.strftime("%T", time.localtime((state / "registry" / e).stat().st_mtime))
                for e in entries
            ],
        },
        measured=True,
    )
    return entries


def restart(g, stale):
    """Same worktree and state: next start removes stale entries, answers, exits idle cleanly."""
    for name in ("recovery.stderr.log", "recovery.jsonl"):
        (g.output / name).rename(g.output / name.replace("recovery", "recovery-1"))
    g.target.write_text(TARGET.replace("WAIT", "Process.sleep(800)"))
    g.client = client = BundleMCP(g.bundle, g.root, g.output, "recovery")
    client.rpc()
    entries = sorted(p.name for p in client.state_dir.glob("registry/*.json"))
    samples = g.settle(g.hover)
    g.check(
        "L3 restart: stale entries gone, one live entry, answers current",
        not set(stale) & set(entries)
        and entries == [f"{client.instance['pid']}.json"]
        and samples[-1]["status"] == "current"
        and samples[-1]["value"] == "ee",
        {"stale": stale, "entries": entries, "final": samples[-1]},
    )
    client.remember()
    client.proc.stdin.close()
    client.proc.wait(timeout=15)
    gone = poll(lambda: alive(client.owned), lambda p: not p, 6)
    stderr = Path(client.log.name).read_text()
    left = sorted(p.name for p in client.state_dir.glob("registry/*.json"))
    g.check(
        "L4 idle EOF: exit 0, empty stderr, owned processes gone, registry empty",
        client.proc.returncode == 0 and not stderr and gone["matched"] and not left,
        {
            "exit": client.proc.returncode,
            "stderr": stderr[-300:],
            "registry": left,
            "survivors": sorted(alive(client.owned)),
        },
    )


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--bundle", type=Path, required=True)
    p.add_argument("--output", type=Path, required=True)
    p.add_argument("--mutant", choices=sorted(MUTANTS))
    args = p.parse_args()
    bundle, output = args.bundle.resolve(), args.output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    os.environ.update(
        {
            "PYTHONDONTWRITEBYTECODE": "1",
            "ERL_FLAGS": "+S 4:4",
            "PATH": str(bundle / "toolchain/bin") + os.pathsep + os.environ["PATH"],
        }
    )
    sys.path.insert(0, str(bundle / "vendor/python"))
    identity = {
        "bundle": str(bundle),
        "mutant": args.mutant,
        "manifest_sha256": hashlib.sha256((bundle / "manifest.json").read_bytes()).hexdigest(),
        "gate_sha256": hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
    }
    (output / "identity.json").write_text(json.dumps(identity, indent=2) + "\n")
    g = None
    try:
        g = Gate(bundle, output)
        g.client.rpc()  # records the instance (socket) for the cleanup check
        records = [
            n
            for n in ("owner.json", "environment.startup.json", "feedback-unavailable")
            if (g.client.state_dir / n).exists()
        ]
        g.check(
            "S0 session writes no hook-era records (red on r24 by design)",
            not records,
            {"records": records},
        )
        run(g, args.mutant)
        stale = close(g, long_build=not args.mutant)
        if not args.mutant:
            restart(g, stale)
    finally:
        if g:
            g.client.cleanup()
            g.check(
                "Z survivors after harness cleanup",
                not alive(g.client.owned),
                sorted(alive(g.client.owned)),
            )
    failed = [c["check"] for c in g.checks if c["result"] == "FAIL"]
    inconclusive = [c["check"] for c in g.checks if c["result"] == "INCONCLUSIVE"]
    print(
        json.dumps(
            {
                "failed": failed,
                "inconclusive": inconclusive,
                "elapsed_s": round(time.monotonic() - g.t0, 1),
            },
            indent=1,
        )
    )
    sys.exit(1 if failed else (2 if inconclusive else 0))


if __name__ == "__main__":
    main()
