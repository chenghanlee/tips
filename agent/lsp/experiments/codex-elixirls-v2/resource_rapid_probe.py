#!/usr/bin/env python3
"""Stress the claimed one-extra-build bound using repeated tasks in one warm VM."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--beam', type=Path, required=True)
    args = parser.parse_args()
    root = args.output.resolve()
    (root / 'lib').mkdir(parents=True, exist_ok=False)
    (root / 'mix.exs').write_text('''defmodule Rapid.MixProject do
  use Mix.Project
  def project, do: [app: :rapid, version: "0.1.0", elixir: "~> 1.20"]
end
''')
    (root / 'lib/value.heex').write_text('aa')
    (root / 'lib/owner.ex').write_text('''defmodule RapidOwner do
  @external_resource Path.expand("value.heex", __DIR__)
  @value File.read!(@external_resource)
  IO.puts("RAPID_OWNER_COMPILED")
  def value, do: @value
end
''')
    (root / 'lib/other.ex').write_text('''defmodule RapidOther do
  IO.puts("RAPID_OTHER_COMPILED")
  def value, do: :other
end
''')
    (root / 'rapid.exs').write_text('''Mix.Task.run("compile", ["--warnings-as-errors"])
IO.puts("RAPID_CORE " <> to_string(:code.which(Mix.Compilers.Elixir)))
# Start just after a wall-clock second boundary, rather than giving each
# follow-up a fresh VM startup delay that can mask repeated sentinels.
wait = 1000 - rem(System.system_time(:millisecond), 1000) + 5
Process.sleep(wait)
File.write!("lib/value.heex", "bb")

for i <- 1..8 do
  IO.puts("RAPID_ITERATION #{i}")
  Mix.Task.clear()
  started = System.system_time(:microsecond)
  result = Mix.Task.run("compile", ["--warnings-as-errors"])
  IO.puts("RAPID_JSON " <> JSON.encode!(%{i: i, start_us: started,
    end_us: System.system_time(:microsecond), result: inspect(result), value: RapidOwner.value()}))
end

Process.sleep(1100)
for i <- 9..10 do
  IO.puts("RAPID_ITERATION #{i}")
  Mix.Task.clear()
  result = Mix.Task.run("compile", ["--warnings-as-errors"])
  IO.puts("RAPID_JSON " <> JSON.encode!(%{i: i, result: inspect(result), value: RapidOwner.value()}))
end
''')
    env = os.environ | {'ERL_FLAGS': '+S 4:4', 'MIX_ENV': 'dev',
                       'PATH': str(args.beam.resolve().parent / 'toolchain/bin') + os.pathsep + os.environ['PATH']}
    fmt = subprocess.run(['unbuffer', 'mix', 'format', 'mix.exs', 'lib/owner.ex',
                          'lib/other.ex', 'rapid.exs'], cwd=root, env=env,
                         text=True, capture_output=True, timeout=30)
    assert fmt.returncode == 0, fmt.stdout + fmt.stderr
    p = subprocess.run(['unbuffer', 'mix', 'run', '--no-start', '--no-compile', 'rapid.exs'],
                       cwd=root, env=env, text=True, capture_output=True, timeout=45)
    (root / 'rapid.log').write_text(p.stdout + p.stderr)
    rows, section = [], []
    for line in p.stdout.splitlines():
        if line.startswith('RAPID_ITERATION '):
            section = []
        elif line.startswith('RAPID_JSON '):
            row = json.loads(line.removeprefix('RAPID_JSON '))
            row['owner_compiled'] = any('RAPID_OWNER_COMPILED' in s for s in section)
            row['other_compiled'] = any('RAPID_OTHER_COMPILED' in s for s in section)
            rows.append(row)
        else:
            section.append(line)
    loaded = next(line.removeprefix('RAPID_CORE ') for line in p.stdout.splitlines() if line.startswith('RAPID_CORE '))
    result = {'exit': p.returncode, 'rows': rows, 'loaded': loaded,
              'candidate_hash_matches': hashlib.sha256(Path(loaded).read_bytes()).digest() ==
                  hashlib.sha256((args.beam / 'Elixir.Mix.Compilers.Elixir.beam').read_bytes()).digest()}
    (root / 'results.json').write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps(result), flush=True)


if __name__ == '__main__':
    main()
