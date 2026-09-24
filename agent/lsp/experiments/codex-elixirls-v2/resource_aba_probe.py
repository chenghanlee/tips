#!/usr/bin/env python3
"""A resource can change twice between compiler-side boundary snapshots."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import time


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--toolchain', type=Path, required=True)
    parser.add_argument('--notify-resource', action='store_true')
    args = parser.parse_args()
    root = args.output.resolve()
    (root / 'lib').mkdir(parents=True, exist_ok=False)
    env = os.environ | {'ERL_FLAGS': '+S 4:4', 'MIX_ENV': 'dev',
        'PATH': str(args.toolchain.resolve() / 'bin') + os.pathsep + os.environ['PATH']}
    (root / 'mix.exs').write_text('''defmodule ABA.MixProject do
  use Mix.Project
  def project, do: [app: :aba, version: "0.1.0"]
end
''')
    target = root / 'lib/target.ex'
    target.write_text('''defmodule ABATarget do
  @external_resource Path.expand("value.heex", __DIR__)
  if File.exists?("gate") do
    IO.puts("BEFORE_READ")
    Stream.repeatedly(fn -> Process.sleep(10) end)
    |> Enum.take_while(fn _ -> not File.exists?("read_now") end)
  end
  @answer File.read!(@external_resource)
  if File.exists?("gate") do
    IO.puts("AFTER_READ")
    Stream.repeatedly(fn -> Process.sleep(10) end)
    |> Enum.take_while(fn _ -> not File.exists?("finish_now") end)
  end
  def answer, do: @answer
end
''')
    (root / 'lib/caller.ex').write_text('''defmodule ABACaller do
  @answer ABATarget.answer()
  def answer, do: @answer
end
''')
    (root / 'acceptance.exs').write_text('''ExUnit.start()
defmodule ABATest do
  use ExUnit.Case, async: true
  test "target reflects final saved resource" do
    assert ABATarget.answer() == File.read!("lib/value.heex")
  end
  test "compile-time caller reflects final saved resource" do
    assert ABACaller.answer() == File.read!("lib/value.heex")
  end
end
''')
    resource = root / 'lib/value.heex'
    resource.write_text('aa')
    def run(label, *args):
        p = subprocess.run(['unbuffer', 'mix', *args], cwd=root, env=env,
            text=True, capture_output=True, timeout=30)
        (root / (label + '.log')).write_text(p.stdout + p.stderr)
        return p
    assert run('format', 'format', 'mix.exs', 'lib/target.ex', 'lib/caller.ex', 'acceptance.exs').returncode == 0
    assert run('warmup', 'compile', '--warnings-as-errors').returncode == 0
    # Give any provisional metadata one stable invocation to settle.
    assert run('stable', 'compile', '--warnings-as-errors').returncode == 0
    target.write_text(target.read_text() + '\n# trigger an ordinary source compile\n')
    (root / 'gate').touch()
    p = subprocess.Popen(['unbuffer', 'mix', 'compile', '--warnings-as-errors'],
        cwd=root, env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    import threading
    timer = threading.Timer(20, p.kill)
    timer.start()
    lines, markers = [], []
    try:
        for line in p.stdout:
            lines.append(line)
            if 'BEFORE_READ' in line:
                resource.write_text('bb')
                (root / 'read_now').touch()
                markers.append('bb')
            if 'AFTER_READ' in line:
                resource.write_text('aa')
                (root / 'finish_now').touch()
                markers.append('aa')
        assert p.wait(timeout=5) == 0
    finally:
        timer.cancel()
        if p.poll() is None:
            p.kill(); p.wait()
    (root / 'overlap.log').write_text(''.join(lines))
    (root / 'gate').unlink()
    assert markers == ['bb', 'aa'], markers
    hint = ['--force-path', str(resource)] if args.notify_resource else []
    followup = run('followup', 'compile', '--warnings-as-errors', *hint)
    test = run('acceptance', 'run', '--no-start', '--no-compile', 'acceptance.exs')
    result = {'markers': markers, 'notification_hint': args.notify_resource, 'followup_exit': followup.returncode,
        'followup_compiled': 'Compiling ' in followup.stdout,
        'acceptance_exit': test.returncode, 'passed': test.returncode == 0}
    (root / 'results.json').write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps(result), flush=True)
    raise SystemExit(0 if result['passed'] else 1)


if __name__ == '__main__':
    main()
