#!/usr/bin/env python3
"""Check whether the retained Mix race affects behavior and compile-time callers."""
import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
import time


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    root = args.output.resolve()
    root.mkdir(parents=True, exist_ok=False)
    (root / 'lib').mkdir()
    env = os.environ | {'ERL_FLAGS': '+S 4:4', 'MIX_ENV': 'dev'}
    commands = []

    def run(label, *arguments):
        command = ['unbuffer', 'mix', *arguments]
        result = subprocess.run(command, cwd=root, env=env, text=True,
                                stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=45)
        (root / f'{label}.log').write_text(result.stdout)
        commands.append({'label': label, 'command': command, 'exit_code': result.returncode})
        return result

    (root / 'mix.exs').write_text('''defmodule MixRace.MixProject do
  use Mix.Project

  def project, do: [app: :mix_race, version: "0.1.0", elixir: "~> 1.20"]
end
''')
    target = root / 'lib/target.ex'

    def source(marker):
        return f'''defmodule MixRaceTarget do
  IO.puts("TRIAGE_{marker}_STARTED")
  Process.sleep(1500)
  @doc "{marker} documentation."
  def answer, do: :{marker}
end
'''

    target.write_text(source('aa'))
    (root / 'lib/caller.ex').write_text('''defmodule MixRaceCaller do
  @answer MixRaceTarget.answer()
  def answer, do: @answer
end
''')
    (root / 'acceptance.exs').write_text('''ExUnit.start()

defmodule MixRaceAcceptanceTest do
  use ExUnit.Case, async: true

  test "target matches the saved source" do
    assert MixRaceTarget.answer() == :bb
  end

  test "compile-time caller matches the saved source" do
    assert MixRaceCaller.answer() == :bb
  end
end
''')
    (root / 'inspect.exs').write_text('''manifest = "_build/dev/lib/mix_race/.mix/compile.elixir"
term = manifest |> File.read!() |> :erlang.binary_to_term()
source = term |> elem(2) |> Map.fetch!("lib/target.ex")
disk = File.read!("lib/target.ex")
digest = elem(source, 3)

IO.puts(
  "TRIAGE_JSON " <>
    JSON.encode!(%{
      target: MixRaceTarget.answer(),
      caller: MixRaceCaller.answer(),
      digest_matches_disk: digest == :crypto.hash(:blake2b, disk),
      stored_size: elem(source, 1),
      stored_mtime: elem(source, 2),
      disk_mtime: File.stat!("lib/target.ex", time: :posix).mtime,
      docs: inspect(Code.fetch_docs(MixRaceTarget))
    })
)
''')
    assert run('format', 'format', 'mix.exs', 'lib/target.ex', 'lib/caller.ex',
               'acceptance.exs', 'inspect.exs').returncode == 0
    # Replace the formatted source literally to preserve byte length and layout.
    a = target.read_text()
    b = a.replace('aa', 'bb')
    assert len(a.encode()) == len(b.encode()) and a != b
    (root / 'source-a.txt').write_text(a)
    (root / 'source-b.txt').write_text(b)
    changed = False
    lines = []
    proc = subprocess.Popen(['unbuffer', 'mix', 'compile', '--warnings-as-errors'],
                            cwd=root, env=env, text=True, stdout=subprocess.PIPE,
                            stderr=subprocess.STDOUT, bufsize=1)
    try:
        for line in proc.stdout:
            lines.append(line)
            if 'TRIAGE_aa_STARTED' in line:
                time.sleep(1.1)
                target.write_text(b)
                changed = True
        proc.wait(timeout=15)
    finally:
        if proc.poll() is None:
            proc.terminate()
            proc.wait(timeout=10)
    (root / 'overlap-compile.log').write_text(''.join(lines))
    assert changed and proc.returncode == 0, 'Overlap control failed'
    for index in range(2):
        assert run(f'incremental-{index}', 'compile', '--warnings-as-errors').returncode == 0

    def inspect_state(label):
        result = run(label, 'run', '--no-compile', 'inspect.exs')
        assert result.returncode == 0
        return json.loads(next(line.removeprefix('TRIAGE_JSON ')
                               for line in result.stdout.splitlines()
                               if line.startswith('TRIAGE_JSON ')))

    stale = inspect_state('stale-inspect')
    before = run('stale-acceptance', 'run', '--no-compile', 'acceptance.exs')
    shutil.copytree(root / '_build', root / 'stale-build-artifacts')
    assert run('force', 'compile', '--force', '--warnings-as-errors').returncode == 0
    fresh = inspect_state('fresh-inspect')
    after = run('fresh-acceptance', 'run', '--no-compile', 'acceptance.exs')
    assert run('format-check', 'format', '--check-formatted', 'mix.exs', 'lib/target.ex',
               'lib/caller.ex', 'acceptance.exs', 'inspect.exs').returncode == 0
    credo = run('credo', 'credo', '--strict')
    result = {'stale': stale, 'fresh': fresh, 'stale_tests_exit': before.returncode,
              'fresh_tests_exit': after.returncode, 'commands': commands,
              'credo_unavailable': 'task "credo" could not be found' in credo.stdout.lower()}
    (root / 'results.json').write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps(result, indent=2))
    assert stale['target'] == 'aa' and stale['caller'] == 'aa' and stale['digest_matches_disk']
    assert before.returncode != 0 and after.returncode == 0
    assert fresh['target'] == 'bb' and fresh['caller'] == 'bb'


if __name__ == '__main__':
    main()
