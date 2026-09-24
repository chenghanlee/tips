#!/usr/bin/env python3
"""Fresh-VM ExUnit acceptance for stock versus existing targeted Mix invalidation."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import time


def main():
    p = argparse.ArgumentParser()
    p.add_argument('--output', type=Path, required=True)
    p.add_argument('--toolchain', type=Path)
    args = p.parse_args()
    out = args.output.resolve()
    (out / 'lib').mkdir(parents=True, exist_ok=False)
    env = os.environ | {'MIX_ENV': 'test', 'ERL_FLAGS': '+S 4:4'}
    if args.toolchain:
        env['PATH'] = str(args.toolchain.resolve() / 'bin') + os.pathsep + env['PATH']
    commands = []

    def run(label, *task):
        start = time.monotonic()
        result = subprocess.run(['unbuffer', 'mix', *task], cwd=out, env=env,
            capture_output=True, text=True, timeout=30)
        (out / f'{label}.log').write_text(result.stdout + result.stderr)
        commands.append({'label': label, 'seconds': time.monotonic() - start,
                         'exit_code': result.returncode})
        return result

    (out / 'mix.exs').write_text('''defmodule Sequential.MixProject do
  use Mix.Project

  def project, do: [app: :sequential, version: "0.1.0"]
end
''')
    target = out / 'lib/target.ex'

    def source(value):
        return f'''defmodule SequentialTarget do
  def answer, do: :{value}
end
'''

    target.write_text(source('zz'))
    (out / 'lib/caller.ex').write_text('''defmodule SequentialCaller do
  @answer SequentialTarget.answer()
  def answer, do: @answer
end
''')
    (out / 'lib/unrelated.ex').write_text('''defmodule SequentialUnrelated do
  def answer, do: :unchanged
end
''')
    (out / 'acceptance.exs').write_text('''ExUnit.start()

defmodule SequentialAcceptanceTest do
  use ExUnit.Case, async: true

  test "target matches saved B" do
    assert :bb = SequentialTarget.answer()
  end

  test "compile-time caller matches saved B" do
    assert :bb = SequentialCaller.answer()
  end
end
''')
    files = ['mix.exs', 'lib/target.ex', 'lib/caller.ex', 'lib/unrelated.ex', 'acceptance.exs']
    assert run('format', 'format', *files).returncode == 0
    assert run('baseline', 'compile', '--warnings-as-errors').returncode == 0
    unrelated = out / '_build/test/lib/sequential/ebin/Elixir.SequentialUnrelated.beam'
    original_unrelated = unrelated.stat().st_mtime_ns
    attempts = []
    for index in range(5):
        time.sleep(1.02 - time.time() % 1)
        target.write_text(source('aa'))
        first = target.stat()
        assert run(f'a-{index}', 'compile', '--warnings-as-errors').returncode == 0
        target.write_text(source('bb'))
        second = target.stat()
        forced = ['--force-path', str(target)] if args.toolchain else []
        compiled = run(f'b-{index}', 'compile', '--warnings-as-errors', '--verbose', *forced)
        assert compiled.returncode == 0
        same_second = int(first.st_mtime) == int(second.st_mtime)
        attempts.append({'same_second': same_second, 'mtime_a_ns': first.st_mtime_ns,
                         'mtime_b_ns': second.st_mtime_ns, 'same_size': first.st_size == second.st_size})
        if same_second:
            break
    assert same_second, attempts
    acceptance = run('acceptance', 'run', '--no-compile', 'acceptance.exs')
    expected = 0 if args.toolchain else 2
    assert acceptance.returncode == expected, acceptance.stdout + acceptance.stderr
    assert unrelated.stat().st_mtime_ns == original_unrelated, 'Unrelated module rebuilt'
    noop = run('unchanged', 'compile', '--warnings-as-errors', '--verbose')
    assert noop.returncode == 0 and 'Compiled lib/' not in noop.stdout
    assert run('final-format', 'format', '--check-formatted', *files).returncode == 0
    result = {'mode': 'targeted' if args.toolchain else 'stock', 'attempts': attempts,
              'exunit_exit': acceptance.returncode, 'unrelated_not_rebuilt': True,
              'unchanged_compile_is_noop': True, 'commands': commands}
    (out / 'results.json').write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps(result, indent=2))


if __name__ == '__main__':
    main()
