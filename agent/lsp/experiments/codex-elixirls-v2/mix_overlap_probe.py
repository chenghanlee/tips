#!/usr/bin/env python3
"""Isolate the equal-size edit-during-compilation attack in plain Mix."""

import argparse
import json
from pathlib import Path
import subprocess
import time

from inversion_probe import target_text


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    root = args.output.resolve()
    (root / "lib").mkdir(parents=True)
    (root / "mix.exs").write_text('''defmodule V2Inversion.MixProject do
  use Mix.Project

  def project, do: [app: :v2_inversion, version: "0.1.0", elixir: "~> 1.20"]
end
''')
    target = root / "lib/target.ex"
    target.write_text(target_text("MIX_A", delay=1500))
    a_stat = target.stat()
    proc = subprocess.Popen(
        ["unbuffer", "mix", "compile", "--warnings-as-errors"], cwd=root,
        stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, bufsize=1,
    )
    lines = []
    changed = False
    try:
        for line in proc.stdout:
            lines.append(line)
            if "INVERSION_MIX_A_STARTED" in line:
                time.sleep(1.1)
                target.write_text(target_text("MIX_B", delay=1500))
                b_stat = target.stat()
                changed = True
        proc.wait(timeout=10)
    finally:
        if proc.poll() is None:
            proc.terminate()
            proc.wait(timeout=10)
    assert changed and proc.returncode == 0, "Initial compilation control failed"
    second = subprocess.run(
        ["unbuffer", "mix", "compile", "--warnings-as-errors"], cwd=root,
        text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=30,
    )
    docs = subprocess.run(
        ["unbuffer", "mix", "run", "--no-compile", "-e", "IO.inspect(Code.fetch_docs(V2Target))"],
        cwd=root, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=30,
    )
    assert second.returncode == 0 and docs.returncode == 0, "Follow-up commands failed"
    result = {
        "first_compile_exit": proc.returncode, "first_compile_output": "".join(lines),
        "second_compile_exit": second.returncode, "second_compile_output": second.stdout,
        "docs_exit": docs.returncode, "docs": docs.stdout,
        "a_stat": {"size": a_stat.st_size, "mtime_ns": a_stat.st_mtime_ns},
        "b_stat": {"size": b_stat.st_size, "mtime_ns": b_stat.st_mtime_ns},
        "disk_source": target.read_text(),
        "stale_after_second_compile": "MIX_A documentation" in docs.stdout,
    }
    (root / "results.json").write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps(result, indent=2))


if __name__ == "__main__":
    main()
