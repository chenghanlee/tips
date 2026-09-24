#!/usr/bin/env python3
"""Warm-VM synthetic comparison; no compile sleeps or database dependencies."""
import argparse
import json
import os
from pathlib import Path
import statistics
import subprocess


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--root', type=Path, required=True)
    args = parser.parse_args()
    root = args.root.resolve()
    results = []
    for count in [49, 1000]:
        for mode in ['baseline', 'direct', 'targeted']:
            project = root / f'bench-{count}-{mode}'
            (project / 'lib').mkdir(parents=True, exist_ok=False)
            (project / 'mix.exs').write_text('''defmodule Bench.MixProject do
  use Mix.Project
  def project, do: [app: :bench, version: "0.1.0", elixir: "~> 1.20"]
end
''')
            for i in range(count - 2):
                (project / 'lib' / f'unrelated_{i}.ex').write_text(
                    f'defmodule BenchUnrelated{i} do\n  def answer, do: {i}\nend\n#' + 'x' * 8192 + '\n')
            (project / 'lib/target.ex').write_text('defmodule BenchTarget do\n  def answer, do: 0\nend\n')
            (project / 'lib/caller.ex').write_text('defmodule BenchCaller do\n  @answer BenchTarget.answer()\n  def answer, do: @answer\nend\n')
            (project / 'bench.exs').write_text('''Mix.Task.run("compile", ["--warnings-as-errors"])
target = "lib/target.ex"
base = File.read!(target)
mode = System.fetch_env!("COMPARE_MODE")

for phase <- ["noop", "edit", "duplicate", "force"] do
  for i <- 1..(if phase == "noop", do: 10, else: 5) do
    if phase == "edit", do: File.write!(target, base <> String.duplicate("# edit\\n", i))
    opts = cond do
      phase == "force" -> ["--force"]
      mode == "targeted" and phase in ["edit", "duplicate"] -> ["--force-path", Path.expand(target)]
      true -> []
    end
    Mix.Task.clear()
    start = System.monotonic_time(:microsecond)
    result = Mix.Task.run("compile", opts)
    elapsed = System.monotonic_time(:microsecond) - start
    IO.puts("BENCH_JSON " <> JSON.encode!(%{phase: phase, iteration: i, us: elapsed, result: inspect(result)}))
  end
end
''')
            env = os.environ | {'ERL_FLAGS': '+S 4:4', 'COMPARE_MODE': mode, 'MIX_ENV': 'dev'}
            if mode != 'baseline':
                env['PATH'] = str(root / mode / 'toolchain/bin') + os.pathsep + env['PATH']
            p = subprocess.run(['unbuffer', 'mix', 'run', '--no-start', '--no-compile', 'bench.exs'],
                               cwd=project, env=env, text=True, capture_output=True, timeout=180)
            (project / 'bench.log').write_text(p.stdout + p.stderr)
            assert p.returncode == 0, p.stdout + p.stderr
            samples = [json.loads(line.removeprefix('BENCH_JSON ')) for line in p.stdout.splitlines()
                       if line.startswith('BENCH_JSON ')]
            summary = {phase: round(statistics.median(s['us'] for s in samples if s['phase'] == phase) / 1000, 2)
                       for phase in ['noop', 'edit', 'duplicate', 'force']}
            row = {'files': count, 'source_bytes': sum(p.stat().st_size for p in (project/'lib').glob('*.ex')),
                   'mode': mode, 'median_ms': summary, 'samples': samples}
            results.append(row)
            (root / 'benchmark.json').write_text(json.dumps(results, indent=2) + '\n')
            print(json.dumps({k: row[k] for k in ['files', 'mode', 'median_ms']}), flush=True)


if __name__ == '__main__':
    main()
