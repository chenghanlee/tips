#!/usr/bin/env python3
"""Seven-operation acceptance gate, hook-free, through real stdio MCP, for any installed bundle.

Black box: only ordinary `lsp` MCP requests (hover, definition, references, document_symbols,
workspace_symbols, diagnostics, workspace_diagnostics) and plain file writes on a fixed disposable
fixture it builds under --output. No hook command, no Lua introspection of the adapter's state, no
manual diagnostics polling protocol.

An ordinary request may honestly answer pending/superseded/unanswered/starting. The gate then
repeats the SAME request (labelled "bounded retry", at most RETRY_S seconds, RETRY_GAP apart)
until the answer is settled: `current`; `failed` settles only E1-E3, where the fixture has a
compile error. exited/conflict (retryable=false) are terminal and fail at once, not retried.
Verdicts (FAIL):
  * wrong settled: a settled answer whose content misses what disk already says (old doc/spec,
    moved definition, removed/renamed symbol, removed caller, missing new caller, false clean);
  * never settled: no settled answer within the retry bound (unfinished, reported as such);
  * wrong empty: a controlled valid empty is non-empty or an error; timeoutMs=1 without an answer
    labelled `current`.
INCONCLUSIVE: a required case whose discriminating condition did not occur in this run (U1 column
controls, B1 build before the write, P timeout, X2 LS build during the CLI).
Measured: first-attempt status of each first read, attempts and ms to a settled answer (edit to
fresh), UTF-16 controls, warm per-operation latency (--timing N).

--control always-current relabels every answer `current` at vv-mcp's public request entry point.
The gate must then fail (exit 1) with `control_caught` true.
--compose runs the explicit check from AGENTS.md (`MIX_ENV=test timeout --foreground -k 5 90 mix
compile --force --warnings-as-errors`) beside the live LS, with `mix` and GNU `timeout` from PATH.

Exit: 0 pass; 1 any FAIL or a launcher exit/stderr, EOF cleanup or survivor problem;
2 INCONCLUSIVE only (rerun, not a pass).
Run: python3 seven_ops_acceptance.py --bundle <bundle> --output <new dir> [--compose]
"""

import argparse
import hashlib
import json
import os
import shutil
import statistics
import subprocess
import sys
import time
from pathlib import Path

from bundle_probe import BundleMCP
from neovim_probe import poll
from probe import alive

RETRY_S, RETRY_GAP = 20.0, 0.25
# failed settles only E1-E3 (broken fixture)
CURRENT, FAILED_BUILD = ("current",), ("current", "failed")
# retryable=false
TERMINAL = ("exited", "conflict", "error:elixirls_exited", "error:elixirls_conflict")
# Negative control only (--control always-current): relabel every answer `current` at vv-mcp's
# public request entry point, outside the adapter. A correct gate must then report wrong answers.
ALWAYS_CURRENT = r"""
local lsp = require('vv-mcp.lsp')
local inner = lsp.request
lsp.request = function(params)
  local result = inner(params)
  local feedback = result.feedback or (type(result.error) == 'table' and result.error.feedback)
  if feedback then feedback.status = 'current' end
  return result
end
return true
"""
# Timing only (--timing): Neovim-side time of the vv-mcp request and of ElixirLS request_sync.
TIMERS = r"""
local lsp = require('vv-mcp.lsp')
local inner = lsp.request
_G.pp_times = {}
local function now() return vim.uv.hrtime() / 1e6 end
lsp.request = function(params)
  local row, t0 = { op = params.operation, server_ms = 0, scan_ms = 0 }, now()
  _G.pp_row = row
  local result = inner(params)
  row.nvim_ms, _G.pp_row = now() - t0, nil
  table.insert(_G.pp_times, row)
  return result
end
local ok, sync = pcall(require, 'neovim_sync')
if ok and sync.scan then
  local scan = sync.scan
  sync.scan = function(...)
    local t0 = now()
    local a, b = scan(...)
    if _G.pp_row then _G.pp_row.scan_ms = _G.pp_row.scan_ms + now() - t0 end
    return a, b
  end
end
for _, client in ipairs(vim.lsp.get_clients({ name = 'elixirls' })) do
  local request_sync = client.request_sync
  client.request_sync = function(self, ...)
    local t0 = now()
    local a, b = request_sync(self, ...)
    if _G.pp_row then _G.pp_row.server_ms = _G.pp_row.server_ms + now() - t0 end
    return a, b
  end
end
return true
"""
MIX = (
    "defmodule Sv.MixProject do\n  use Mix.Project\n"
    '  def project, do: [app: :sv, version: "0.1.0", elixirc_paths: elixirc_paths(Mix.env())]\n'
    '  defp elixirc_paths(:test), do: ["lib", "test/support"]\n'
    '  defp elixirc_paths(_), do: ["lib"]\nend\n'
)
SHARED = (
    'defmodule Sv.Shared do\n  @moduledoc "Shared helpers."\n{pad}'
    '  @doc "Doubles {doc}."\n  @spec twice({t}) :: {t}\n  def twice(x), do: x * 2\n{extra}end\n'
)
TRIPLE = '\n  @doc "Triples."\n  @spec triple(integer()) :: integer()\n  def triple(x), do: x * 3\n'
CALLER = "defmodule Sv.{name} do\n  def value(x), do: Sv.Shared.{fun}(x)\nend\n"
UNICODE = 'defmodule Sv.Unicode do\n  def greet, do: {"😀😀😀é", Sv.Shared.twice(1)}\nend\n'
SLOW = "defmodule Sv.Slow do\n{sleep}  def s, do: 1\nend\n"
WARN = "defmodule Sv.Warn do\n  def unused({var}), do: 1\nend\n"
BROKEN = "defmodule Sv.BrokenTest do\n  use ExUnit.Case\n  def broken(, do: 1\nend\n"
OUTLINE = "defmodule Sv.Outline do\n  def one, do: 1\n  {two}\n  defmacro three, do: 3\nend\n"


def git(root, *args):
    # Fixed tool and arguments; paths come from this run.
    subprocess.run(["git", *args], cwd=root, check=True)  # noqa: S603, S607


def fixture(root):
    for directory in ("lib", "test/support"):
        (root / directory).mkdir(parents=True)
    files = {
        "mix.exs": MIX,
        ".gitignore": "/_build/\n/deps/\n",
        "lib/shared.ex": SHARED.format(pad="", doc="v1", t="integer()", extra=""),
        "lib/unicode.ex": UNICODE,
        "lib/outline.ex": OUTLINE.format(two="defp two, do: 2"),
        "lib/empty.ex": "# Intentionally no declarations.\n",
        "lib/legacy.ex": "defmodule Sv.LegacyName do\n  def legacy, do: :ok\nend\n",
        "lib/gone.ex": "defmodule Sv.GoneSoon do\n  def gone, do: :ok\nend\n",
        "lib/slow.ex": SLOW.format(sleep=""),
        "lib/warn.ex": WARN.format(var="w0"),
        "test/test_helper.exs": "ExUnit.start()\n",
        "test/broken_test.exs": BROKEN,
        "test/clean_test.exs": "defmodule Sv.CleanTest do\n  use ExUnit.Case\n"
        '  test "x", do: assert Sv.Shared.twice(1) == 2\nend\n',
    }
    for name in ("CallerA", "CallerB", "CallerC", "CallerE", "CallerF"):
        files[f"lib/{name.lower()}.ex"] = CALLER.format(name=name, fun="twice")
    for rel, text in files.items():
        (root / rel).write_text(text)
    git(root, "init", "-q")
    git(root, "add", ".")
    git(root, "-c", "user.email=p@x", "-c", "user.name=p", "commit", "-qm", "fixture")


def position(path, token, nth=0, unit="utf-16"):
    """1-based line and column on the 2nd character of the nth `token`, counted in `unit`."""
    hits = [(i, line) for i, line in enumerate(path.read_text().split("\n")) if token in line]
    line_no, line = hits[nth]
    prefix = line[: line.index(token) + 1]
    width = {
        "utf-16": len(prefix.encode("utf-16-le")) // 2,
        "utf-8": len(prefix.encode()),
        "utf-32": len(prefix),
    }[unit]
    return line_no + 1, width + 1


def summarize(operation, data, root):
    def rel(path):
        if str(path).startswith("/"):
            return str(Path(path).resolve().relative_to(root.resolve()))
        return path

    if operation == "hover":
        return {"text": "\n".join(data.get("items") or [])[:600]}
    if operation in ("definition", "references"):
        return {rel(p): r for p, r in (data.get("locations") or {}).items()}
    if operation in ("document_symbols", "workspace_symbols"):
        symbols = data.get("symbols") or {}
        return sorted(s.get("name", "") for items in symbols.values() for s in items)
    if operation.endswith("diagnostics"):
        return {
            rel(p): [
                f"{d.get('range')} {d.get('message', '')[:100]}"
                if isinstance(d, dict)
                else str(d)[:100]
                for d in items
            ]
            for p, items in (data.get("diagnostics") or {}).items()
        }
    return None


class Acceptance:
    def __init__(self, bundle, output):
        self.root = output / "sv"
        fixture(self.root)
        self.client = BundleMCP(bundle, self.root, output, "seven")
        self.cases, self.started = [], time.monotonic()

    def call(self, operation, file, token=None, nth=0, unit="utf-16", **extra):
        args = dict(extra)
        if token:
            args["line"], args["character"] = position(self.root / file, token, nth, unit)
        if operation == "references":
            args.setdefault("includeDeclaration", True)
        started = time.monotonic()
        reply = self.client.call("lsp", operation=operation, uri=str(self.root / file), **args)
        data = reply["data"] if isinstance(reply.get("data"), dict) else {}
        error = data.get("error") if isinstance(data.get("error"), dict) else {}
        feedback = data.get("feedback") or error.get("feedback") or {}
        status = feedback.get("status") or ("error:" + str(error.get("code")) if error else None)
        return {
            "op": operation,
            "file": file,
            "args": {k: v for k, v in args.items() if k != "includeDeclaration"},
            "ms": round((time.monotonic() - started) * 1000, 1),
            "status": status,
            "message": (feedback.get("message") or error.get("message") or "")[:400],
            "is_error": reply.get("isError"),
            "errors": data.get("errors"),
            "building": feedback.get("building"),
            "queued": feedback.get("queued"),
            "generation": feedback.get("generation"),
            "completed": feedback.get("completed"),
            "answer": summarize(operation, data, self.root),
        }

    def ask(self, operation, file, token=None, retry=True, settled=CURRENT, **extra):
        """One ordinary request, repeated (bounded retry) until settled, terminal or RETRY_S."""
        attempts, begun = [], time.monotonic()
        while True:
            attempts.append(self.call(operation, file, token, **extra))
            status = attempts[-1]["status"]
            done = status in settled or status in TERMINAL
            if not retry or done or time.monotonic() - begun > RETRY_S:
                return attempts, round((time.monotonic() - begun) * 1000, 1)
            time.sleep(RETRY_GAP)

    def check(
        self,
        label,
        operation,
        file,
        token=None,
        fresh=None,
        since=None,
        measure_only=False,
        settled=CURRENT,
        **extra,
    ):
        """fresh(answer) -> bool. `since` = monotonic time of the causing edit (edit-to-settled)."""
        attempts, total = self.ask(operation, file, token, settled=settled, **extra)
        problems = []
        for a in attempts:
            a["fresh"] = None if fresh is None else bool(fresh(a["answer"]))
            if a["status"] in settled and a["fresh"] is False:
                problems.append(f"wrong settled ({a['status']})")
        final = attempts[-1]
        if final["status"] in TERMINAL:
            problems.append(f"terminal {final['status']}")
        elif final["status"] not in settled:
            problems.append(
                f"never settled in {RETRY_S:.0f} s bounded retry (last {final['status']})"
            )
        result = "MEASURED" if measure_only else ("FAIL" if problems else "PASS")
        row = {
            "case": label,
            "result": result,
            "problems": [] if measure_only else problems,
            "attempts": len(attempts),
            "retry_ms": total,
            "first_status": attempts[0]["status"],
            "final_status": final["status"],
            "first_fresh": attempts[0]["fresh"],
            "edit_to_settled_ms": round((time.monotonic() - since) * 1000, 1) if since else None,
            "final_answer": final["answer"],
            "final_message": final["message"],
            "samples": attempts,
        }
        self.cases.append(row)
        self.show(row)
        return row

    def record(self, label, samples, problems, measure_only=False, inconclusive=None):
        if measure_only:
            result = "MEASURED"
        else:
            result = "FAIL" if problems else ("INCONCLUSIVE" if inconclusive else "PASS")
        row = {
            "case": label,
            "result": result,
            "note": inconclusive,
            "problems": [] if measure_only else problems,
            "attempts": len(samples),
            "samples": samples,
            "final_status": samples[-1]["status"],
            "final_answer": samples[-1]["answer"],
        }
        self.cases.append(row)
        self.show(row)
        return row

    @staticmethod
    def inconclusive(row, note):
        """A required case whose discriminating condition did not occur cannot pass."""
        if row["result"] == "PASS":
            row["result"], row["note"] = "INCONCLUSIVE", f"NOT DISCRIMINATING: {note}"
            print("   " + row["note"], flush=True)

    @staticmethod
    def show(row):
        retry = ""
        if row.get("retry_ms") and row["attempts"] > 1:
            retry = f" bounded retry {row['attempts']}x/{row['retry_ms']}ms"
        edit = (
            f" edit->settled {row['edit_to_settled_ms']}ms" if row.get("edit_to_settled_ms") else ""
        )
        print(
            f"{row['result']:<8} {row['case']}: {row.get('first_status')}->{row['final_status']}"
            f"{retry}{edit} {json.dumps(row['final_answer'])[:220]} {','.join(row['problems'])}",
            flush=True,
        )

    def lua(self, code, *args):
        return self.client.rpc().exec_lua(code, *args)

    def quiet(self):
        """Wait (ordinary workspace_diagnostics, bounded) until the worktree reports current."""
        attempts, _ = self.ask("workspace_diagnostics", ".")
        if attempts[-1]["status"] != "current":
            raise SystemExit(f"never quiet: {attempts[-1]}")
        time.sleep(0.3)

    def write(self, rel, text):
        (self.root / rel).write_text(text)
        return time.monotonic()


def first_reads(a, callers):
    """1. First reads of never-opened files: first status measured, settled content judged."""
    a.check(
        "F1 hover first read (remote call doc + spec)",
        "hover",
        "lib/callera.ex",
        "twice",
        fresh=lambda x: "Doubles v1." in x["text"] and "twice(integer())" in x["text"],
    )
    a.check(
        "F2 definition first read",
        "definition",
        "lib/callerb.ex",
        "twice",
        fresh=lambda x: any(p.startswith("5:") for p in x.get("lib/shared.ex", [])),
    )
    a.check(
        "F3 references first read (all lib/ callers + declaration)",
        "references",
        "lib/callerc.ex",
        "twice",
        fresh=lambda x: callers | {"lib/shared.ex"} <= set(x),
    )
    a.check(
        "F4 document_symbols first read",
        "document_symbols",
        "lib/outline.ex",
        fresh=lambda x: {"Sv.Outline", "one/0", "two/0", "three/0"} <= set(x),
    )
    a.check(
        "F5 workspace_symbols",
        "workspace_symbols",
        ".",
        query="Sv.LegacyName",
        fresh=lambda x: "Sv.LegacyName" in x,
    )
    a.check(
        "F6 diagnostics first read of a test file with a syntax error (not in build)",
        "diagnostics",
        "test/broken_test.exs",
        fresh=lambda x: bool(x.get("test/broken_test.exs")),
    )
    a.check(
        "F7 workspace_diagnostics root has the unused-variable warning",
        "workspace_diagnostics",
        ".",
        fresh=lambda x: any('"w0" is unused' in m for m in x.get("lib/warn.ex", [])),
    )


def empties_and_columns(a):
    """2. Controlled valid empties and scope; UTF-16 columns against UTF-8/UTF-32 controls."""
    a.check(
        "V1 document_symbols of a file with no declarations is empty",
        "document_symbols",
        "lib/empty.ex",
        fresh=lambda x: x == [],
    )
    a.check(
        "V2 workspace_symbols for an absent name is empty",
        "workspace_symbols",
        ".",
        query="Zqxjv",
        fresh=lambda x: x == [],
    )
    a.check(
        "V3 diagnostics of a clean file is empty (document scope excludes warn.ex)",
        "diagnostics",
        "lib/callera.ex",
        fresh=lambda x: not any(x.values()),
    )
    a.check(
        "V4 workspace_diagnostics scoped to test/ excludes lib/warn.ex",
        "workspace_diagnostics",
        "test",
        fresh=lambda x: "lib/warn.ex" not in x and bool(x.get("test/broken_test.exs")),
    )
    u1 = a.check(
        "U1 hover at the UTF-16 column after multi-unit characters",
        "hover",
        "lib/unicode.ex",
        "twice",
        fresh=lambda x: "Doubles v1." in x["text"],
    )
    controls = [
        a.check(
            f"U2 control: same token addressed in {unit} columns (expected not twice)",
            "hover",
            "lib/unicode.ex",
            "twice",
            unit=unit,
            fresh=lambda x: "Doubles v1." not in x["text"],
            measure_only=True,
        )
        for unit in ("utf-8", "utf-32")
    ]
    if not all(c["final_status"] == "current" and c["samples"][-1]["fresh"] for c in controls):
        a.inconclusive(u1, "a UTF-8 or UTF-32 control column also reached twice (or unsettled)")


def edits(a, callers):
    """3-6. Changed hover doc/spec, moved definition, references, symbols, error and repair."""
    r = a.root
    a.quiet()
    t = a.write("lib/shared.ex", SHARED.format(pad="", doc="v2", t="number()", extra=""))
    a.check(
        "C1 hover after @doc and @spec change (caller file unchanged)",
        "hover",
        "lib/callera.ex",
        "twice",
        since=t,
        fresh=lambda x: (
            "Doubles v2." in x["text"] and "number()" in x["text"] and "integer()" not in x["text"]
        ),
    )
    a.quiet()
    t = a.write("lib/shared.ex", SHARED.format(pad="\n\n\n", doc="v2", t="number()", extra=""))
    a.check(
        "C2 definition after the def moved 3 lines down",
        "definition",
        "lib/callerb.ex",
        "twice",
        since=t,
        fresh=lambda x: any(p.startswith("8:") for p in x.get("lib/shared.ex", [])),
    )

    # 4. References: old API loses a caller, new API gains callers; deleted file drops out.
    a.quiet()
    t = a.write("lib/shared.ex", SHARED.format(pad="\n\n\n", doc="v2", t="number()", extra=TRIPLE))
    a.write("lib/callerb.ex", CALLER.format(name="CallerB", fun="triple"))
    a.write("lib/callerd.ex", CALLER.format(name="CallerD", fun="triple"))
    (r / "lib/callerf.ex").unlink()
    old = (callers - {"lib/callerb.ex", "lib/callerf.ex"}) | {"lib/shared.ex"}
    a.check(
        "R1 references old API: switched caller and deleted file gone, others kept",
        "references",
        "lib/callera.ex",
        "twice",
        since=t,
        fresh=lambda x: old <= set(x) and not {"lib/callerb.ex", "lib/callerf.ex"} & set(x),
    )
    a.check(
        "R2 references new API: new and switched callers",
        "references",
        "lib/callerd.ex",
        "triple",
        fresh=lambda x: (
            {"lib/callerb.ex", "lib/callerd.ex", "lib/shared.ex"} <= set(x)
            and "lib/callera.ex" not in x
        ),
    )

    # 5. workspace_symbols rename and removal.
    a.quiet()
    t = a.write("lib/legacy.ex", "defmodule Sv.ModernName do\n  def legacy, do: :ok\nend\n")
    (r / "lib/gone.ex").unlink()
    a.check(
        "S1 workspace_symbols finds the renamed module",
        "workspace_symbols",
        ".",
        query="Sv.ModernName",
        since=t,
        fresh=lambda x: "Sv.ModernName" in x,
    )
    a.check(
        "S2 workspace_symbols no longer returns the old name",
        "workspace_symbols",
        ".",
        query="Sv.LegacyName",
        fresh=lambda x: "Sv.LegacyName" not in x,
    )
    a.check(
        "S3 workspace_symbols no longer returns the removed module",
        "workspace_symbols",
        ".",
        query="Sv.GoneSoon",
        fresh=lambda x: "Sv.GoneSoon" not in x,
    )
    a.check(
        "S4 document_symbols after rename",
        "document_symbols",
        "lib/legacy.ex",
        fresh=lambda x: "Sv.ModernName" in x and "Sv.LegacyName" not in x,
    )

    # 6. Syntax error in a compiled file, then repair; warning change.
    a.quiet()
    t = a.write("lib/broken_lib.ex", "defmodule Sv.BrokenLib do\n  def broken(, do: 1\nend\n")
    a.check(
        "E1 diagnostics of a new compiled file with a syntax error",
        "diagnostics",
        "lib/broken_lib.ex",
        since=t,
        settled=FAILED_BUILD,
        fresh=lambda x: bool(x.get("lib/broken_lib.ex")),
    )
    a.check(
        "E2 hover still answers while the build is failed",
        "hover",
        "lib/callera.ex",
        "twice",
        settled=FAILED_BUILD,
        fresh=lambda x: "Doubles v2." in x["text"],
    )
    a.check(
        "E3 document_symbols of the broken file (qualified, empty does not prove absence)",
        "document_symbols",
        "lib/broken_lib.ex",
        fresh=None,
        measure_only=True,
        settled=FAILED_BUILD,
    )
    t = a.write("lib/broken_lib.ex", "defmodule Sv.BrokenLib do\n  def broken, do: 1\nend\n")
    a.write("lib/warn.ex", WARN.format(var="w1"))
    a.check(
        "E4 workspace_diagnostics after repair: error cleared, new warning text",
        "workspace_diagnostics",
        ".",
        since=t,
        fresh=lambda x: (
            not x.get("lib/broken_lib.ex")
            and any('"w1" is unused' in m for m in x.get("lib/warn.ex", []))
            and not any('"w0"' in m for m in x.get("lib/warn.ex", []))
        ),
    )
    a.check(
        "E5 diagnostics of the repaired file is empty",
        "diagnostics",
        "lib/broken_lib.ex",
        fresh=lambda x: not any(x.values()),
    )


def concurrent_build(a):
    """7. An edit lands while a slow (3 s compile-time sleep) build runs."""
    a.quiet()
    a.write("lib/slow.ex", SLOW.format(sleep="  Process.sleep(3000)\n"))
    time.sleep(0.8)
    probe = a.call("document_symbols", "lib/outline.ex")  # ordinary request: is a build running?
    t = a.write("lib/shared.ex", SHARED.format(pad="\n\n\n", doc="v3", t="number()", extra=TRIPLE))
    b1 = a.check(
        "B1 hover after an edit made during a running build",
        "hover",
        "lib/callera.ex",
        "twice",
        since=t,
        fresh=lambda x: "Doubles v3." in x["text"],
    )
    b1["build_before_write"] = {k: probe[k] for k in ("status", "building", "queued")}
    if not (probe["building"] or probe["queued"]):
        a.inconclusive(b1, "no build running before the write")
    a.write("lib/slow.ex", SLOW.format(sleep=""))
    a.check(
        "B2 workspace_symbols during/after build churn",
        "workspace_symbols",
        ".",
        query="Sv.Slow",
        fresh=lambda x: "Sv.Slow" in x,
    )


def unanswered(a):
    """8. No answer is not an empty current answer."""
    a.quiet()
    requests = (
        ("references", "lib/callera.ex", "twice"),
        ("hover", "lib/callera.ex", "twice"),
        ("definition", "lib/callera.ex", "twice"),
        ("document_symbols", "lib/outline.ex", None),
    )
    samples = [a.call(op, f, tok, timeoutMs=1) for op, f, tok in requests]

    def empty(s):
        return not (s["answer"].get("text") if s["op"] == "hover" else s["answer"])

    problems = [
        f"{s['op']}: current without an answer"
        for s in samples
        if s["status"] == "current" and (s["errors"] or empty(s))
    ]
    timed_out = any(s["errors"] or s["status"] == "unanswered" for s in samples)
    a.record(
        "P timeoutMs=1: an unanswered request is not an empty current answer",
        samples,
        problems,
        inconclusive=None if timed_out else "NOT DISCRIMINATING: no request timed out",
    )


def run(a, timing):
    callers = {
        "lib/callera.ex",
        "lib/callerb.ex",
        "lib/callerc.ex",
        "lib/callere.ex",
        "lib/callerf.ex",
        "lib/unicode.ex",
    }
    a.quiet()
    first_reads(a, callers)
    empties_and_columns(a)
    edits(a, callers)
    concurrent_build(a)
    unanswered(a)
    if timing:
        warm(a, timing)


# Observation only (compose): every workspace/didChangeWatchedFiles Neovim sends ElixirLS, ElixirLS
# "Starting build" log lines (build starts), and neovim_sync.builds (observed build ends).
WATCHED = r"""
if not _G.pp_watched then
  _G.pp_watched, _G.pp_starts = {}, 0
  local client = vim.lsp.get_clients({ name = 'elixirls' })[1]
  local log = client.handlers['window/logMessage']
  client.handlers['window/logMessage'] = function(err, data, ...)
    if (data and data.message or ''):find('Starting build', 1, true) then
      _G.pp_starts = _G.pp_starts + 1
    end
    return log(err, data, ...)
  end
  vim.api.nvim_create_autocmd('LspNotify', { callback = function(args)
    if args.data.method == 'workspace/didChangeWatchedFiles' then
      for _, change in ipairs(args.data.params.changes or {}) do
        table.insert(_G.pp_watched, { uri = change.uri, type = change.type })
      end
    end
  end })
end
return true
"""
OBSERVE = """local w = _G.pp_watched; _G.pp_watched = {}
return { watched = w, builds = require('neovim_sync').builds, starts = _G.pp_starts }"""
# The explicit check from AGENTS.md, with stock `mix` and GNU `timeout` from PATH.
VALIDATE = [
    "timeout",
    "--foreground",
    "-k",
    "5",
    "90",
    "mix",
    "compile",
    "--force",
    "--warnings-as-errors",
]


def sample(a, rows, phase, seconds=None, until=None):
    """Ordinary document_symbols requests every 0.25 s, for `seconds` or while until() is false."""
    end = time.monotonic() + (seconds or 0)
    while (until and not until()) or (seconds and time.monotonic() < end):
        rows.append(a.call("document_symbols", "lib/outline.ex") | {"phase": phase})
        time.sleep(0.25)


def validate(a, label, settle_s=5.0):
    """The explicit check beside the live LS; the LS is sampled while it runs and settle_s after."""
    a.lua(WATCHED)
    first = a.lua(OBSERVE)
    samples, started = [], time.monotonic()
    proc = subprocess.Popen(  # noqa: S603 - fixed command from AGENTS.md, no shell
        VALIDATE,
        cwd=a.root,
        env=os.environ | {"MIX_ENV": "test"},
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
    )
    try:
        sample(a, samples, "during", until=lambda: proc.poll() is not None)
        output, seconds = proc.stdout.read(), round(time.monotonic() - started, 2)
    finally:
        if proc.poll() is None:  # the gate failed mid-check: leave no CLI behind
            proc.terminate()  # timeout relays SIGTERM to mix; SIGKILL would orphan it
            try:
                proc.wait(timeout=10)
            except subprocess.TimeoutExpired:
                proc.kill()
                proc.wait()
    sample(a, samples, "after", seconds=settle_s)
    seen = a.lua(OBSERVE)
    busy = [s for s in samples if s["building"] or s["queued"] or s["status"] != "current"]
    since = time.time() - (time.monotonic() - started)
    written = sorted(
        str(p.relative_to(a.root))
        for p in (a.root / "_build").rglob("*")
        if p.is_file() and p.stat().st_mtime >= since
    )
    generations = sorted({s["generation"] for s in samples if s.get("generation") is not None})
    row = {
        "case": label,
        "exit": proc.returncode,
        "seconds": seconds,
        "output": output[-1500:],
        "lsp_samples": len(samples),
        "lsp_busy_samples": len(busy),
        "ls_builds": seen["builds"] - first["builds"],
        "ls_build_starts": seen["starts"] - first["starts"],
        "watched_notifications": seen["watched"],
        "build_files_written": len(written),
        "build_lock_files": [w for w in written if w.endswith(".lock")],
        "lsp_busy_phases": sorted({s["phase"] for s in busy}),
        "generations": generations,
        "lsp_ms_during": [s["ms"] for s in samples if s["phase"] == "during"],
        "lsp_ms_after": [s["ms"] for s in samples if s["phase"] == "after"],
    }
    print(
        f"MEASURED {label}: exit {row['exit']} in {seconds} s; LS samples {len(samples)}, busy "
        f"{len(busy)} {row['lsp_busy_phases']}, generations {generations}; LS build starts "
        f"{row['ls_build_starts']}, ends {row['ls_builds']}, watched notifications "
        f"{len(row['watched_notifications'])}, _build files written {len(written)} (locks "
        f"{row['build_lock_files']})",
        flush=True,
    )
    return row


def idle_problems(x, name):
    """X1/X4: with no source edit, a forced compile must write _build and leave the LS idle."""
    problems = []
    if x["build_files_written"] == 0:
        problems.append(f"{name} NOT DISCRIMINATING: the CLI wrote nothing under _build")
    moved = len(x["generations"]) > 1
    if x["lsp_busy_samples"] or moved or x["ls_builds"] or x["ls_build_starts"]:
        problems.append(f"{name} LS built/pending or generation moved while only _build changed")
    if x["watched_notifications"]:
        problems.append(f"{name} _build writes reached ElixirLS as watched-file notifications")
    return problems


def compose(a):
    """Explicit forced compile beside the live LS: no LS rebuild storm from _build writes,
    CLI and LS agree on warnings, and seven-op answers stay correct after ordinary edits."""
    a.quiet()
    x1 = validate(a, "X1 explicit check on the warned tree, LS idle")
    problems = idle_problems(x1, "X1")
    if x1["exit"] != 1 or "lib/warn.ex" not in x1["output"] or "w1" not in x1["output"]:
        problems.append('X1 expected exit 1 naming the lib/warn.ex "w1" warning')
    a.check(
        "X1b LS workspace_diagnostics agrees on the warning the CLI reported",
        "workspace_diagnostics",
        ".",
        fresh=lambda x: any('"w1" is unused' in m for m in x.get("lib/warn.ex", [])),
    )
    row = a.record(
        "X1 forced compile beside the idle LS",
        [a.call("document_symbols", "lib/outline.ex")],
        problems,
    )
    row["validate"] = x1

    # Ordinary edits, then the explicit check at once (overlaps the LS build of the same edits).
    a.write("lib/warn.ex", WARN.format(var="_w2"))
    a.write("lib/outline.ex", OUTLINE.format(two="def two, do: 2"))
    a.write("lib/shared.ex", SHARED.format(pad="\n\n\n", doc="v4", t="number()", extra=TRIPLE))
    x2 = validate(a, "X2 explicit check right after ordinary edits (LS building the same edits)")
    problems = [] if x2["exit"] == 0 else [f"X2 expected exit 0, got {x2['exit']}"]
    if "after" in x2["lsp_busy_phases"] and len(x2["generations"]) > 1:
        problems.append("X2 LS generation moved after the CLI ended (a rebuild without an edit)")
    row = a.record(
        "X2 forced compile overlapping the LS build of the same edits",
        [a.call("hover", "lib/callera.ex", "twice")],
        problems,
    )
    row["validate"] = x2
    if "during" not in x2["lsp_busy_phases"] or x2["ls_build_starts"] < 1:
        a.inconclusive(row, "no LS build observed while the CLI ran (no overlap)")
    after_explicit_check(a)

    # Unchanged tree: a second forced check must not start LS builds.
    x4 = validate(a, "X4 explicit check on an unchanged clean tree")
    problems = idle_problems(x4, "X4")
    if x4["exit"] != 0:
        problems.append(f"X4 expected exit 0, got {x4['exit']}")
    row = a.record(
        "X4 forced compile on an unchanged tree beside the idle LS",
        [a.call("document_symbols", "lib/outline.ex")],
        problems,
    )
    row["validate"] = x4
    source_edit_control(a)
    lock_sensitivity(a)


def after_explicit_check(a):
    """X3: all seven operations after edits + explicit check."""
    a.check(
        "X3 hover after edits + explicit check",
        "hover",
        "lib/callera.ex",
        "twice",
        fresh=lambda x: "Doubles v4." in x["text"],
    )
    a.check(
        "X3 definition",
        "definition",
        "lib/callerc.ex",
        "twice",
        fresh=lambda x: any(p.startswith("8:") for p in x.get("lib/shared.ex", [])),
    )
    a.check(
        "X3 references",
        "references",
        "lib/callera.ex",
        "twice",
        fresh=lambda x: (
            {"lib/callera.ex", "lib/callerc.ex", "lib/shared.ex"} <= set(x)
            and "lib/callerb.ex" not in x
        ),
    )
    a.check(
        "X3 document_symbols (two/0 now public)",
        "document_symbols",
        "lib/outline.ex",
        fresh=lambda x: {"Sv.Outline", "one/0", "two/0", "three/0"} <= set(x),
    )
    a.check(
        "X3 workspace_symbols",
        "workspace_symbols",
        ".",
        query="Sv.ModernName",
        fresh=lambda x: "Sv.ModernName" in x,
    )
    a.check(
        "X3 diagnostics of the fixed file is empty",
        "diagnostics",
        "lib/warn.ex",
        fresh=lambda x: not any(x.values()),
    )
    a.check(
        "X3 workspace_diagnostics: lib/ warnings gone (CLI exit 0 agrees)",
        "workspace_diagnostics",
        "lib",
        fresh=lambda x: not any(x.values()),
    )


def source_edit_control(a):
    """X5 positive control for the same observers: one source edit must reach ElixirLS and build."""
    a.lua(WATCHED)
    first = a.lua(OBSERVE)
    t = a.write("lib/shared.ex", SHARED.format(pad="\n\n\n", doc="v5", t="number()", extra=TRIPLE))
    x5 = a.check(
        "X5 positive control: source edit gives a fresh hover",
        "hover",
        "lib/callera.ex",
        "twice",
        since=t,
        fresh=lambda x: "Doubles v5." in x["text"],
    )
    seen = a.lua(OBSERVE)
    x5["ls_builds"], x5["watched_notifications"] = seen["builds"] - first["builds"], seen["watched"]
    x5["ls_build_starts"] = seen["starts"] - first["starts"]
    if x5["ls_builds"] < 1 or x5["ls_build_starts"] < 1:
        x5["result"] = "FAIL"
        x5["problems"].append("X5 source edit did not produce an observed LS build (observer)")
    print(
        f"   X5 LS build starts {x5['ls_build_starts']}, ends {x5['ls_builds']}, "
        f"watched notifications {seen['watched']}",
        flush=True,
    )


def lock_sensitivity(a):
    """X6 (measured): write the Mix compile.lock marker directly, as a deps/lock change would."""
    a.quiet()
    a.lua(WATCHED)
    first = a.lua(OBSERVE)
    lock = a.root / "_build/test/lib/sv/.mix/compile.lock"
    existed = lock.exists()
    samples = []
    lock.touch()
    sample(a, samples, "create", seconds=5)
    time.sleep(1.2)  # then rewritten (Mix writes it empty too)
    lock.write_text("")
    sample(a, samples, "modify", seconds=5)
    seen = a.lua(OBSERVE)
    row = a.record(
        "X6 sensitivity: touch _build/test/lib/sv/.mix/compile.lock directly (measured)",
        samples,
        [],
        measure_only=True,
    )
    busy = sum(1 for x in samples if x["building"] or x["queued"] or x["status"] != "current")
    row.update(
        {
            "lock_existed": existed,
            "ls_builds": seen["builds"] - first["builds"],
            "ls_build_starts": seen["starts"] - first["starts"],
            "watched_notifications": seen["watched"],
            "busy_samples": busy,
        }
    )
    print(
        f"   X6 lock existed {existed}; LS build starts {row['ls_build_starts']}, ends "
        f"{row['ls_builds']}, busy samples {busy}, watched {seen['watched']}",
        flush=True,
    )


def warm(a, n):
    """Warm, settled, unchanged fixture: n ordinary requests per operation (measured)."""
    a.quiet()
    if not a.lua(TIMERS):
        raise SystemExit("timing wrappers were not installed")
    ops = [
        ("hover", "lib/callera.ex", "twice", {}),
        ("definition", "lib/callera.ex", "twice", {}),
        ("references", "lib/callera.ex", "twice", {}),
        ("document_symbols", "lib/outline.ex", None, {}),
        ("workspace_symbols", ".", None, {"query": "Sv.Shared"}),
        ("diagnostics", "lib/callera.ex", None, {}),
        ("workspace_diagnostics", ".", None, {}),
    ]
    for op, f, tok, extra in ops:
        a.call(op, f, tok, **extra)  # warm-up, discarded
    a.lua("_G.pp_times = {} return true")
    table = {}
    for _ in range(n):
        for op, f, tok, extra in ops:  # interleaved rounds
            s = a.call(op, f, tok, **extra)
            inner = a.lua("local t = _G.pp_times; _G.pp_times = {}; return t")[-1]
            table.setdefault(op, []).append(
                (s["ms"], s["status"], inner["nvim_ms"], inner["server_ms"], inner["scan_ms"])
            )
    med = statistics.median
    summary = {
        op: {
            "n": len(v),
            "median_ms": med(x[0] for x in v),
            "min_ms": min(x[0] for x in v),
            "max_ms": max(x[0] for x in v),
            "statuses": sorted({x[1] for x in v}),
            "median_server_ms": round(med(x[3] for x in v), 1),
            "median_adapter_ms": round(med(x[2] - x[3] for x in v), 1),
            "median_scan_ms": round(med(x[4] for x in v), 1),
            "median_transport_ms": round(med(x[0] - x[2] for x in v), 1),
        }
        for op, v in table.items()
    }
    a.cases.append(
        {
            "case": f"T warm latency, {n} interleaved rounds",
            "result": "MEASURED",
            "problems": [],
            "attempts": n,
            "samples": [],
            "final_status": None,
            "final_answer": summary,
        }
    )
    for op, s in summary.items():
        print(
            f"MEASURED T {op:<22} median {s['median_ms']} ms (min {s['min_ms']}, max "
            f"{s['max_ms']}) server {s['median_server_ms']} adapter {s['median_adapter_ms']} "
            f"(scan {s['median_scan_ms']}) transport {s['median_transport_ms']} {s['statuses']}",
            flush=True,
        )


def shutdown(a, output, results):
    """Close stdin (EOF) and check that the launcher exits cleanly and reaps its processes."""
    a.client.remember()
    a.client.proc.stdin.close()
    a.client.proc.wait(timeout=10)
    results["eof_cleanup"] = poll(lambda: alive(a.client.owned), lambda x: not x, 6)["matched"]
    results["launcher_exit"] = a.client.proc.returncode
    a.client.log.flush()
    results["launcher_stderr"] = (output / "seven.stderr.log").read_text()[-2000:]


def verdict(results, control):
    """Exit 1 on any FAIL or lifecycle problem, 2 on INCONCLUSIVE only, else 0."""
    cases = results["cases"]
    results["failed"] = [c["case"] for c in cases if c["result"] == "FAIL"]
    results["inconclusive"] = [c["case"] for c in cases if c["result"] == "INCONCLUSIVE"]
    lifecycle = []
    if results.get("launcher_exit") != 0 or results.get("launcher_stderr"):
        lifecycle.append("launcher did not exit 0 with empty stderr")
    if not results.get("eof_cleanup"):
        lifecycle.append("EOF did not reap the launcher's processes")
    if results["survivors_after_cleanup"]:
        lifecycle.append("processes survived cleanup")
    results["lifecycle_problems"] = lifecycle
    if control:
        # Caught = every FAIL is a wrong or empty `current` answer and the run itself was clean.
        content = ("wrong settled", "current without an answer")
        results["control_caught"] = (
            bool(results["failed"])
            and not lifecycle
            and all(
                any(k in p for k in content)
                for c in cases
                if c["result"] == "FAIL"
                for p in c["problems"]
            )
        )
    if results["failed"] or lifecycle:
        return 1
    return 2 if results["inconclusive"] else 0


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--bundle", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--timing", type=int, default=0)
    parser.add_argument("--control", choices=["always-current"])
    parser.add_argument("--compose", action="store_true", help="explicit check beside the live LS")
    args = parser.parse_args()
    if args.compose and not all(shutil.which(tool) for tool in ("mix", "timeout")):
        raise SystemExit("--compose needs `mix` and GNU `timeout` on PATH (coreutils on macOS)")
    os.environ["PYTHONDONTWRITEBYTECODE"] = "1"
    bundle, output = args.bundle.resolve(), args.output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    sys.path.insert(0, str(bundle / "vendor/python"))
    results = {
        "bundle": str(bundle),
        "manifest_sha256": hashlib.sha256((bundle / "manifest.json").read_bytes()).hexdigest(),
        "gate_sha256": hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
        "control": args.control,
        "compose": args.compose,
        "retry_s": RETRY_S,
        "retry_gap_s": RETRY_GAP,
    }
    a = Acceptance(bundle, output)
    try:
        results["tools"] = [t["name"] for t in a.client.tools.get("tools", [])]
        if args.control:
            a.call("document_symbols", "lib/empty.ex")  # starts Neovim and vv-mcp before wrapping
            if not a.lua(ALWAYS_CURRENT):
                raise SystemExit("negative control was not installed")
        run(a, args.timing)
        if args.compose:
            compose(a)
        shutdown(a, output, results)
    finally:
        a.client.cleanup()
        results["survivors_after_cleanup"] = sorted(alive(a.client.owned))
        results["cases"] = a.cases
        results["elapsed_s"] = round(time.monotonic() - a.started, 1)
        code = verdict(results, args.control)
        (output / "results.json").write_text(json.dumps(results, indent=2) + "\n")
    keys = ("failed", "inconclusive", "lifecycle_problems", "control_caught", "eof_cleanup")
    summary = {k: results[k] for k in keys if k in results}
    summary.update(
        launcher_exit=results.get("launcher_exit"),
        launcher_stderr_tail=results.get("launcher_stderr", "")[-300:],
        survivors_after_cleanup=results["survivors_after_cleanup"],
        elapsed_s=results["elapsed_s"],
        exit=code,
    )
    print(json.dumps(summary, indent=1))
    sys.exit(code)


if __name__ == "__main__":
    main()
