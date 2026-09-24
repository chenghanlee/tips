#!/usr/bin/env python3
"""Qualify Fable's stock-Mix assumptions in a disposable, dependency-free project."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import time


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    root = output / 'fixture'
    for folder in ('lib', 'test', 'config'):
        (root / folder).mkdir(parents=True, exist_ok=True)
    env = os.environ | {'MIX_ENV': 'test', 'ERL_FLAGS': '+S 4:4'}
    results = {'commands': [], 'cases': {}}

    def save():
        (output / 'results.json').write_text(json.dumps(results, indent=2) + '\n')

    def run(label, *task):
        start = time.monotonic()
        command = ['unbuffer', 'mix', *task]
        result = subprocess.run(command, cwd=root, env=env, text=True,
                                stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=30)
        (output / f'{label}.log').write_text(result.stdout)
        results['commands'].append({'label': label, 'command': command,
            'exit_code': result.returncode, 'seconds': time.monotonic() - start})
        save()
        return result

    def compile_project(label):
        result = run(label, 'compile', '--warnings-as-errors')
        assert result.returncode == 0, result.stdout
        return result

    def inspect_state(label):
        result = run(label, 'run', '--no-compile', 'inspect.exs')
        assert result.returncode == 0, result.stdout
        return json.loads(next(line.removeprefix('PROPOSAL_JSON ') for line in
            result.stdout.splitlines() if line.startswith('PROPOSAL_JSON ')))

    (root / 'mix.exs').write_text('''defmodule Proposal.MixProject do
  use Mix.Project

  def project, do: [app: :proposal, version: "0.1.0", elixir: "~> 1.20"]
end
''')
    target = root / 'lib/target.ex'

    def source(marker):
        return f'''defmodule ProposalTarget do
  def answer, do: :{marker}
end
'''

    target.write_text(source('zz'))
    (root / 'lib/caller.ex').write_text('''defmodule ProposalCaller do
  @answer ProposalTarget.answer()
  def answer, do: @answer
end
''')
    (root / 'lib/resource.ex').write_text('''defmodule ProposalResource do
  @external_resource "data.txt"
  @value File.read!("data.txt")
  def value, do: @value
end
''')
    resource = root / 'data.txt'
    resource.write_text('one')
    (root / 'config/config.exs').write_text('import Config\n')
    (root / 'test/test_helper.exs').write_text('ExUnit.start()\n')
    test = root / 'test/proposal_test.exs'
    test.write_text('''defmodule ProposalTest do
  use ExUnit.Case, async: true

  test "target and compile-time caller agree" do
    assert ProposalTarget.answer() == ProposalCaller.answer()
  end
end
''')
    (root / 'inspect.exs').write_text('''manifest = "_build/test/lib/proposal/.mix/compile.elixir"
term = manifest |> File.read!() |> :erlang.binary_to_term()
source = term |> elem(2) |> Map.fetch!("lib/target.ex")
disk = File.read!("lib/target.ex")

IO.puts(
  "PROPOSAL_JSON " <>
    JSON.encode!(%{
      target: ProposalTarget.answer(),
      caller: ProposalCaller.answer(),
      resource: ProposalResource.value(),
      manifest_mtime: elem(source, 2),
      disk_mtime: File.stat!("lib/target.ex", time: :posix).mtime,
      digest_matches_disk: elem(source, 3) == :crypto.hash(:blake2b, disk)
    })
)
''')
    files = ['mix.exs', 'lib/target.ex', 'lib/caller.ex', 'lib/resource.ex',
             'config/config.exs', 'test/test_helper.exs', 'test/proposal_test.exs', 'inspect.exs']
    assert run('format', 'format', *files).returncode == 0
    compile_project('baseline')
    assert run('baseline-tests', 'test').returncode == 0

    # Real writes in the same wall-clock second, no timestamp restoration or overlap.
    attempted = []
    for index in range(5):
        time.sleep(1.02 - (time.time() % 1))
        target.write_text(source('aa'))
        before = target.stat()
        first = compile_project(f'rapid-{index}-a')
        target.write_text(source('bb'))
        after = target.stat()
        second = compile_project(f'rapid-{index}-b')
        state = inspect_state(f'rapid-{index}-state')
        same_second = int(before.st_mtime) == int(after.st_mtime)
        attempted.append({'same_second': same_second, 'first_mtime_ns': before.st_mtime_ns,
            'second_mtime_ns': after.st_mtime_ns, 'same_size': before.st_size == after.st_size,
            'first_compiled': 'Compiling' in first.stdout, 'second_compiled': 'Compiling' in second.stdout,
            'state': state})
        if same_second:
            break
    assert attempted[-1]['same_second'], attempted
    state = attempted[-1]['state']
    assert state['target'] == state['caller'] == 'aa' and not state['digest_matches_disk'], state
    results['cases']['sequential_same_second'] = attempted
    compile_project('rapid-later-retry')
    assert inspect_state('rapid-later-state')['target'] == 'aa'
    # Advance metadata as a control. This works here because the manifest digest is A.
    stamp = target.stat()
    os.utime(target, (stamp.st_atime, stamp.st_mtime + 2))
    compile_project('rapid-metadata-control')
    repaired = inspect_state('rapid-repaired-state')
    assert repaired['target'] == repaired['caller'] == 'bb' and repaired['digest_matches_disk']
    results['cases']['sequential_metadata_control'] = repaired

    # A test-only error is outside the compile task's validation scope.
    original_test = test.read_text()
    test.write_text(original_test.replace('  use ExUnit.Case, async: true',
        '  use ExUnit.Case, async: true\n  def broken, do: missing_test_function()'))
    compiled = compile_project('test-error-compile')
    tested = run('test-error-test', 'test')
    assert tested.returncode != 0 and 'missing_test_function/0' in tested.stdout
    results['cases']['test_file_not_validated'] = {'compile_exit': compiled.returncode,
                                                  'test_exit': tested.returncode}
    test.write_text(original_test)

    # A non-Elixir extension can still be a compiler input through @external_resource.
    resource.write_text('two revised')
    compile_project('resource-edit')
    state = inspect_state('resource-state')
    assert state['resource'] == 'two revised'
    results['cases']['non_elixir_resource'] = state

    # The Mix build lock is released before ExUnit executes the test body.
    test.write_text(original_test.replace('    assert ProposalTarget',
        '    File.write!("test-running", "yes")\n    Process.sleep(4000)\n    assert ProposalTarget'))
    assert run('slow-test-format', 'format', 'test/proposal_test.exs').returncode == 0
    with (output / 'background-test.log').open('w') as log:
        proc = subprocess.Popen(['unbuffer', 'mix', 'test'], cwd=root, env=env,
                                stdout=log, stderr=subprocess.STDOUT)
        try:
            until = time.monotonic() + 15
            while not (root / 'test-running').exists() and time.monotonic() < until:
                assert proc.poll() is None, 'Test exited before marker'
                time.sleep(0.02)
            assert (root / 'test-running').exists(), 'Missing test marker'
            during = compile_project('compile-during-test')
            test_still_running = proc.poll() is None
            results['cases']['build_lock_not_test_lock'] = {
                'compile_exit': during.returncode, 'test_still_running': test_still_running,
                'compiler_waited_for_lock': 'Waiting for lock' in during.stdout}
            assert test_still_running, results['cases']['build_lock_not_test_lock']
        finally:
            proc.wait(timeout=15)
        assert proc.returncode == 0
    test.write_text(original_test)
    assert run('final-format', 'format', '--check-formatted', *files).returncode == 0
    compile_project('final-compile')
    assert run('final-tests', 'test').returncode == 0
    credo = run('credo', 'credo', '--strict')
    assert credo.returncode != 0 and 'task "credo" could not be found' in credo.stdout.lower()
    results['credo_unavailable'] = True
    save()
    print(json.dumps(results['cases'], indent=2))


if __name__ == '__main__':
    main()
