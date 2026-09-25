#!/usr/bin/env python3
"""Cached-prune correctness scenarios through the real hook path.

Fixture: a disposable Tips clone plus a path dependency and a local Git
dependency. `Tips.WarmDepsProbe` emits a compile-time warning that names the
dependency values, dependency version and compile-time config value it saw, so
stale dependency or configuration state is visible in published diagnostics.

Run the same steps against r7 and the candidate and compare settled outcomes.
"""

import argparse
import json
import os
import shutil
import subprocess
import sys
import threading
import time
from pathlib import Path

E = Path(__file__).resolve().parent
sys.path.insert(0, str(E))

from bundle_probe import BundleMCP  # noqa: E402
from neovim_dogfood import environment  # noqa: E402

GIT_DEP = Path("/private/tmp/tips-lsp-warm-gitdep")
HOST_MIX = "/opt/homebrew/bin/mix"

OBSERVER = r"""
local m = require('neovim_sync')
if not _G.warm_observe then
  _G.warm_observe = m.observe
  m.observe = function(method, data)
    local e = _G.warm_events
    if method == 'telemetry/event' and data.name == 'build' then
      e[#e + 1] = { kind = 'build', result = data.properties and data.properties['elixir_ls.build_result'] or vim.NIL }
    elseif method == 'telemetry/event' and data.name == 'build_error' then
      -- Build worker exited abnormally (server.ex :DOWN handler); neovim_sync ignores it.
      e[#e + 1] = { kind = 'build', result = 'build_error' }
    elseif method == 'window/logMessage' and (data.message or ''):find('Starting build with MIX_ENV:', 1, true) then
      e[#e + 1] = { kind = 'start' }
    elseif method == 'window/logMessage' and (data.message or ''):sub(1, 5) == '[warm' then
      e[#e + 1] = { kind = 'log', message = data.message:sub(1, 4000) }
    end
    return _G.warm_observe(method, data)
  end
end
_G.warm_events = {}
return true
"""

TAKE = "local e = _G.warm_events; _G.warm_events = {}; return e"

DIAGNOSTICS = r"""
local root = require('neovim_sync').root
local out = {}
for _, d in ipairs(vim.diagnostic.get()) do
  local path = vim.api.nvim_buf_get_name(d.bufnr)
  if path:sub(1, #root + 1) == root .. '/' then
    out[#out + 1] = { path = path:sub(#root + 2), line = d.lnum + 1, severity = d.severity,
      message = d.message:sub(1, 300) }
  end
end
table.sort(out, function(a, b)
  if a.path ~= b.path then return a.path < b.path end
  if a.line ~= b.line then return a.line < b.line end
  return a.message < b.message
end)
return out
"""

PROBE_MODULE = '''defmodule Tips.WarmDepsProbe do
  @moduledoc false
  @observed "path=#{WarmPathDep.value()} path_vsn=#{WarmPathDep.version()} " <>
              "git=#{WarmGitDep.value()} config=#{Application.compile_env(:tips, :warm_probe_value, 0)}"
  IO.warn("warm deps probe: " <> @observed, __ENV__)
  def observed, do: @observed
end
'''

PATH_MIX = '''defmodule WarmPathDep.MixProject do
  use Mix.Project

  def project, do: [app: :warm_path_dep, version: "{version}", elixir: "~> 1.17"]
end
'''

PATH_LIB = '''defmodule WarmPathDep do
  @version Mix.Project.config()[:version]
  def value, do: {value}
  def version, do: @version
end
'''

GIT_MIX = '''defmodule WarmGitDep.MixProject do
  use Mix.Project

  def project, do: [app: :warm_git_dep, version: "0.1.0", elixir: "~> 1.17"]
end
'''

DURING_MODULE = '''defmodule Tips.WarmDuring do
  @moduledoc false
  IO.warn("warm during build: marker", __ENV__)
end
'''

BUILDING = "return require('neovim_sync').status().building"

GIT_LIB = '''defmodule WarmGitDep do
  def value, do: {value}
end
'''


def run(argv, cwd, env=None, check=True):
    proc = subprocess.run(argv, cwd=cwd, env=env, text=True, capture_output=True, timeout=600)
    if check and proc.returncode:
        raise RuntimeError(f"{argv} failed: {proc.stdout[-2000:]}{proc.stderr[-2000:]}")
    return proc


def git_commit(value: int, message: str) -> None:
    (GIT_DEP / "lib/warm_git_dep.ex").write_text(GIT_LIB.replace("{value}", str(value)))
    run(["git", "add", "-A"], GIT_DEP)
    run(["git", "-c", "user.name=warm", "-c", "user.email=warm@localhost", "commit", "-qm", message],
        GIT_DEP)


def mix_env(root: Path) -> dict:
    values = environment(root, 8, "warmdeps", "beta", 300)
    return os.environ | values | {"MIX_ENV": "test"}


def setup(root: Path, source: Path, deps_from: Path) -> None:
    """Create the disposable fixture once: clone, deps copy, path + Git deps, probe module."""
    assert not root.exists() and not GIT_DEP.exists()
    run(["git", "clone", "-q", "--local", "--no-checkout", str(source), str(root)], "/")
    run(["git", "checkout", "-q", "--detach", "fd4e2da8b013996ffb8527f30784f423fb9fc61a"], root)
    run(["cp", "-cRp", str(deps_from / "deps"), str(root / "deps")], "/")
    GIT_DEP.mkdir()
    run(["git", "init", "-q", "-b", "main"], GIT_DEP)
    (GIT_DEP / "mix.exs").write_text(GIT_MIX)
    (GIT_DEP / "lib").mkdir()
    git_commit(1, "value 1")
    path_dep = root / "local/warm_path_dep"
    (path_dep / "lib").mkdir(parents=True)
    (path_dep / "mix.exs").write_text(PATH_MIX.replace("{version}", "0.1.0"))
    (path_dep / "lib/warm_path_dep.ex").write_text(PATH_LIB.replace("{value}", "1"))
    mix = (root / "mix.exs").read_text()
    anchor = '      {:bandit, "~> 1.5"}\n'
    assert mix.count(anchor) == 1
    mix = mix.replace(anchor, anchor.rstrip("\n") + ",\n"
                      '      {:warm_path_dep, path: "local/warm_path_dep"},\n'
                      f'      {{:warm_git_dep, git: "{GIT_DEP}", branch: "main"}}\n')
    (root / "mix.exs").write_text(mix)
    with (root / "config/test.exs").open("a") as stream:
        stream.write("\nconfig :tips, warm_probe_value: 1\n")
    (root / "lib/tips/warm_deps_probe.ex").write_text(PROBE_MODULE)
    run([HOST_MIX, "deps.get"], root, mix_env(root))


class Scenario:
    def __init__(self, bundle: Path, root: Path, output: Path, settle_timeout: float):
        self.bundle, self.root, self.output = bundle, root, output
        self.settle_timeout = settle_timeout
        self.client = None
        self.audit = output / "hook-audit.jsonl"
        self.results: dict = {"bundle": str(bundle), "root": str(root), "steps": []}

    def save(self) -> None:
        (self.output / "results.json").write_text(json.dumps(self.results, indent=2) + "\n")

    def lua(self, code: str):
        return self.client.rpc().exec_lua(code)

    def hook(self, tool: str) -> dict:
        then = time.monotonic()
        proc = subprocess.run(
            [sys.executable, str(self.bundle / "bundle.py"), "hook", "--workspace", str(self.root),
             "--state", str(self.client.state_dir), "--budget-ms", "5000", "--audit", str(self.audit)],
            input=json.dumps({"hook_event_name": "PostToolUse", "tool_name": tool}),
            text=True, capture_output=True, check=True, timeout=8)
        output = json.loads(proc.stdout)
        context = output.get("hookSpecificOutput", {}).get("additionalContext", "")
        return {"seconds": round(time.monotonic() - then, 3), "message": context.split("\nFeedback receipt")[0]}

    def settle(self, timeout: float = 120) -> dict:
        deadline = time.monotonic() + timeout
        stable_since, last = None, None
        while time.monotonic() < deadline:
            status = self.lua("return require('neovim_sync').status()")
            key = (status["status"], status["generation"], status["completed"])
            settled = status["status"] in ("current", "failed") and not status["building"] and not status["queued"]
            if settled and key == last:
                if stable_since and time.monotonic() - stable_since >= 1.0:
                    return status
                stable_since = stable_since or time.monotonic()
            else:
                stable_since = None
            last = key
            time.sleep(0.25)
        return self.lua("return require('neovim_sync').status()")

    def step(self, name: str, action, tool: str = "apply_patch") -> dict:
        action()
        hook = self.hook(tool)
        time.sleep(1.0)
        status = self.settle(self.settle_timeout)
        events = self.lua(TAKE)
        record = {
            "step": name,
            "hook": hook,
            "status": status["status"],
            "diagnostics": self.lua(DIAGNOSTICS),
            "builds": [e.get("result") for e in events if e["kind"] == "build"],
            "starts": sum(1 for e in events if e["kind"] == "start"),
            "logs": [e["message"] for e in events if e["kind"] == "log"],
        }
        self.results["steps"].append(record)
        self.save()
        probe = [d["message"] for d in record["diagnostics"] if "warm deps probe" in d["message"]]
        print(json.dumps({"step": name, "status": record["status"], "builds": record["builds"],
                          "probe": probe, "diagnostics": len(record["diagnostics"])}), flush=True)
        return record


    def during(self, name: str, first, second) -> dict:
        """Make `second` while the build started by `first` runs, then settle and record."""
        first()
        hooked = {}
        thread = threading.Thread(target=lambda: hooked.update(self.hook("apply_patch")))
        thread.start()
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline and not self.lua(BUILDING):
            time.sleep(0.01)
        building = self.lua(BUILDING)
        second()
        still_building = self.lua(BUILDING)
        thread.join()
        record = self.step(name, lambda: None)
        record.update({"first_hook": hooked, "while_building": [building, still_building]})
        self.save()
        return record


def run_during(s: Scenario, root: Path, originals: dict, health: Path, path_mix: Path,
               config: Path) -> None:
    """Changes that land while a build runs must reach the final settled state."""
    during = root / "lib/tips/warm_during.ex"
    s.during("d1_new_module_during_build", edit(health, "its database.", "its database. D1."),
             lambda: during.write_text(DURING_MODULE))
    s.during("d2_path_dep_version_during_build",
             edit(health, "its database. D1.", "its database. D2."),
             edit(path_mix, 'version: "0.1.0"', 'version: "0.3.0"'))
    s.during("d3_config_during_build", edit(health, "its database. D2.", "its database. D3."),
             edit(config, "warm_probe_value: 1", "warm_probe_value: 3"))
    s.step("d4_restore", lambda: (during.unlink(), health.write_text(originals[health]),
                                  path_mix.write_text(originals[path_mix]),
                                  config.write_text(originals[config])))


def edit(path: Path, old: str, new: str, preserve_mtime: bool = False):
    def action():
        stat = path.stat()
        text = path.read_text()
        assert text.count(old) == 1, (path, old)
        path.write_text(text.replace(old, new))
        if preserve_mtime:
            os.utime(path, ns=(stat.st_atime_ns, stat.st_mtime_ns))
    return action


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--bundle", type=Path)
    parser.add_argument("--workspace", type=Path, required=True)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--label")
    parser.add_argument("--during", action="store_true",
                        help="run only the edits-during-build steps")
    parser.add_argument("--settle-timeout", type=float, default=120,
                        help="seconds to wait for current/failed after each step")
    parser.add_argument("--setup-from", type=Path, help="main repository to clone (setup only)")
    parser.add_argument("--deps-from", type=Path, help="checkout whose deps/ to copy (setup only)")
    args = parser.parse_args()
    root = args.workspace.resolve()
    if args.setup_from:
        setup(root, args.setup_from.resolve(), args.deps_from.resolve())
        print("fixture ready: " + str(root))
        return
    bundle = args.bundle.resolve()
    output = args.output.resolve() / args.label
    output.mkdir(parents=True, exist_ok=False)
    values = environment(root, 8, "warmdeps", "beta", 300)
    values.pop("MIX_ENV")
    os.environ.update(values)
    os.environ.pop("MIX_ENV", None)
    sys.path.insert(0, str(bundle / "vendor/python"))
    s = Scenario(bundle, root, output, args.settle_timeout)
    health = root / "lib/tips/health.ex"
    path_lib = root / "local/warm_path_dep/lib/warm_path_dep.ex"
    path_mix = root / "local/warm_path_dep/mix.exs"
    config = root / "config/test.exs"
    mixfile = root / "mix.exs"
    lock = root / "mix.lock"
    originals = {p: p.read_text() for p in (health, path_lib, path_mix, config, mixfile, lock)}
    git_head = run(["git", "rev-parse", "HEAD"], GIT_DEP).stdout.strip()

    locks = {}

    def restore_lock_and_touch():
        lock.write_text(locks["after_git"])
        health.write_text(originals[health].replace("its database.", "its database. Restored."))

    def original_git_dep():
        lock.write_text(originals[lock])
        run([HOST_MIX, "deps.get"], root, mix_env(root))

    def new_module():
        (root / "lib/tips/warm_new.ex").write_text(
            "defmodule Tips.WarmNew do\n  def value, do: :new\nend\n")

    def delete_new_module():
        (root / "lib/tips/warm_new.ex").unlink()

    def delete_compiled_dep():
        shutil.rmtree(root / ".elixir_ls/build/test/lib/mime")
        health.write_text(originals[health].replace("its database.", "its database. Mime rebuilt."))

    try:
        then = time.monotonic()
        s.client = BundleMCP(bundle, root, output, "session")
        s.lua(OBSERVER)
        first = s.settle(timeout=300)
        s.results["ready_s"] = round(time.monotonic() - then, 3)
        s.results["initial"] = {"status": first["status"], "diagnostics": s.lua(DIAGNOSTICS),
                                "logs": [e["message"] for e in s.lua(TAKE) if e["kind"] == "log"]}
        s.save()
        if args.during:
            run_during(s, root, originals, health, path_mix, config)
            s.results["completed"] = True
            s.save()
            return
        s.step("s00_source_edit", edit(health, "its database.", "its database. Step 0."))
        s.step("s01_path_dep_value_2", edit(path_lib, "def value, do: 1", "def value, do: 2"))
        s.step("s02_path_dep_version", edit(path_mix, 'version: "0.1.0"', 'version: "0.2.0"'))
        s.step("s03_path_dep_broken", edit(path_lib, "def value, do: 2", "def value, do: (2"))
        s.step("s04_path_dep_repaired", lambda: (path_lib.write_text(originals[path_lib]),
                                                 path_mix.write_text(originals[path_mix])))
        s.step("s05_git_dep_update", lambda: (git_commit(2, "value 2"),
                                              run([HOST_MIX, "deps.update", "warm_git_dep"], root,
                                                  mix_env(root))), tool="Bash")
        s.step("s06_git_dep_back", lambda: (git_commit(1, "value 1 again"),
                                            run([HOST_MIX, "deps.update", "warm_git_dep"], root,
                                                mix_env(root))), tool="Bash")
        locks["after_git"] = lock.read_text()
        s.step("s07_config_value_2", edit(config, "warm_probe_value: 1", "warm_probe_value: 2"))
        s.step("s08_config_value_1_same_mtime",
               edit(config, "warm_probe_value: 2", "warm_probe_value: 1", preserve_mtime=True))
        s.step("s09_config_touch", lambda: os.utime(config) or health.write_text(
            originals[health].replace("its database.", "its database. Touch.")))
        s.step("s10_config_broken", edit(config, "warm_probe_value: 1", "warm_probe_value: (1"))
        s.step("s11_config_repaired", lambda: config.write_text(originals[config]))
        s.step("s12_mixfile_broken", edit(mixfile, "app: :tips,", "app: :tips,,"))
        s.step("s13_mixfile_repaired", lambda: mixfile.write_text(originals[mixfile]))
        s.step("s14_source_broken", edit(health, "def check do", "def check do ("))
        s.step("s15_source_repaired", lambda: health.write_text(originals[health]))
        s.step("s16_new_module", new_module)
        s.step("s17_reference_new", edit(health, "@deadline 1_000", "@deadline 1_000\n  @new Tips.WarmNew.value()"))
        s.step("s18_delete_new_module", delete_new_module)
        s.step("s19_unreference", lambda: health.write_text(originals[health]))
        s.step("s20_lock_only_edit", edit(lock, '"mime": {:hex, :mime, "2.0.7"', '"mime": {:hex, :mime, "2.0.6"'))
        s.step("s21_source_after_lock_edit", edit(health, "its database.", "its database. Lock."))
        s.step("s22_lock_restored", restore_lock_and_touch)
        s.step("s23_compiled_dep_deleted", delete_compiled_dep)
        s.step("s24_after_dep_rebuild", lambda: health.write_text(originals[health]))
        s.step("s25_git_dep_original_lock", original_git_dep, tool="Bash")
        s.results["final_git_head_restored"] = git_head
        s.results["completed"] = True
        s.save()
    finally:
        for path, text in originals.items():
            if path.read_text() != text:
                path.write_text(text)
        (root / "lib/tips/warm_new.ex").unlink(missing_ok=True)
        (root / "lib/tips/warm_during.ex").unlink(missing_ok=True)
        run([HOST_MIX, "deps.get"], root, mix_env(root), check=False)
        if s.client:
            s.client.cleanup()


if __name__ == "__main__":
    main()
