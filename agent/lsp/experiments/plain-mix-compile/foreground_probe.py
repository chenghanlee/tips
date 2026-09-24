#!/usr/bin/env python3
"""End-to-end acceptance of the standalone foreground compiler and hook protocol."""
import argparse
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import time

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent / 'codex-elixirls-v2'))
from probe import alive, descendants


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--toolchain', type=Path, required=True)
    args = parser.parse_args()
    out = args.output.resolve()
    root, state = out / 'fixture', out / 'state'
    (root / 'lib').mkdir(parents=True, exist_ok=False)
    subprocess.run(['git', 'init', '-q', str(root)], check=True)
    (root / '.gitignore').write_text('_build/\n/tmp/\n')
    (root / 'mix.exs').write_text('''defmodule Foreground.MixProject do
  use Mix.Project

  def project, do: [app: :foreground, version: "0.1.0"]
end
''')
    target = root / 'lib/target.ex'

    def source(value='aa', sleep=0, error=False):
        return ('defmodule ForegroundTarget do\n' +
                (f'  Process.sleep({sleep})\n' if sleep else '') +
                ('  def answer, do: missing_foreground()\n' if error else
                 f'  def answer, do: :{value}\n') + 'end\n')

    target.write_text(source())
    (root / 'lib/caller.ex').write_text('''defmodule ForegroundCaller do
  @answer ForegroundTarget.answer()
  def answer, do: @answer
end
''')
    base = [sys.executable, str(HERE / 'foreground_mix.py'),
            '--workspace', str(root), '--state', str(state),
            '--toolchain', str(args.toolchain.resolve())]
    results = []
    event = {'hook_event_name': 'PostToolUse', 'tool_name': 'apply_patch', 'cwd': str(root)}

    def invoke(label, mode='hook', timeout=None, payload=None):
        start = time.monotonic()
        command = base + [mode] + (['--timeout', str(timeout)] if timeout else [])
        proc = subprocess.run(command, input=json.dumps(payload or event), text=True,
                              capture_output=True, timeout=25)
        assert proc.returncode == 0, proc.stdout + proc.stderr
        result = json.loads(proc.stdout)
        record = json.loads((state / 'result.json').read_text()) if (state / 'result.json').exists() else None
        item = {'label': label, 'seconds': time.monotonic() - start,
                'output': result, 'record': record}
        results.append(item)
        (out / 'results.json').write_text(json.dumps(results, indent=2) + '\n')
        print(label, round(item['seconds'], 3), record and record['status'], flush=True)
        return item

    missing = invoke('not-prepared')
    assert 'prepare' in missing['output']['hookSpecificOutput']['additionalContext']
    assert not (root / '_build').exists(), 'Hook silently performed cold preparation'
    assert invoke('prepare', 'prepare')['record']['status'] == 'passed'
    assert invoke('unchanged')['output'] == {}

    # Both ordinary tools and preserved metadata must deliver the targeted path.
    stamp = target.stat()
    target.write_text(source('bb'))
    os.utime(target, ns=(stamp.st_atime_ns, stamp.st_mtime_ns))
    changed = invoke('same-metadata-edit')
    assert changed['record']['status'] == 'passed'
    assert 'lib/target.ex' in changed['record']['changed']
    acceptance = out / 'acceptance.exs'
    acceptance.write_text('''ExUnit.start()

defmodule ForegroundAcceptanceTest do
  use ExUnit.Case, async: true

  test "target and compile-time caller match saved B" do
    assert :bb = ForegroundTarget.answer()
    assert :bb = ForegroundCaller.answer()
  end
end
''')
    env = os.environ | {'MIX_ENV': 'test', 'ERL_FLAGS': '+S 4:4',
        'PATH': str(args.toolchain.resolve() / 'bin') + os.pathsep + os.environ['PATH']}
    checked = subprocess.run(['unbuffer', 'mix', 'run', '--no-compile', str(acceptance)],
        cwd=root, env=env, capture_output=True, text=True, timeout=20)
    (out / 'acceptance.log').write_text(checked.stdout + checked.stderr)
    assert checked.returncode == 0

    target.write_text(source('bb', sleep=8000, error=True))
    error = invoke('eight-second-error')
    assert error['record']['status'] == 'failed' and 8 < error['seconds'] < 15
    assert 'missing_foreground/0' in error['output']['hookSpecificOutput']['additionalContext']
    assert invoke('unchanged-after-error')['output'] == {}
    target.write_text(source('bb'))
    assert invoke('repair')['record']['status'] == 'passed'

    target.write_text(source('cc', sleep=8000))
    timeout = invoke('safety-timeout', timeout=1)
    assert timeout['record']['status'] == 'unfinished' and timeout['seconds'] < 5
    assert 'unfinished' in timeout['output']['hookSpecificOutput']['additionalContext'].lower()
    assert not timeout['record']['survivors']
    # Same source must not repeatedly restart on unrelated tools or Stop.
    saved = json.loads((state / 'state.json').read_text())
    assert saved['pending']
    assert invoke('unchanged-after-timeout')['output'] == {}
    stop = {'hook_event_name': 'Stop', 'cwd': str(root)}
    assert invoke('stop-after-timeout', payload=stop)['output']['decision'] == 'block'
    assert invoke('repeat-stop', payload=stop | {'stop_hook_active': True})['output'] == {}
    retried = invoke('same-source-longer-retry', 'check', timeout=15)
    assert retried['record']['status'] == 'passed' and 8 < retried['seconds'] < 15
    target.write_text(source('dd'))
    assert invoke('timeout-repair')['record']['status'] == 'passed'

    # Changes during compilation qualify the result and survive for explicit check.
    target.write_text(source('ee', sleep=1500))
    proc = subprocess.Popen(base + ['hook'], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                            stderr=subprocess.PIPE, text=True)
    proc.stdin.write(json.dumps(event))
    proc.stdin.close()
    until = time.monotonic() + 5
    while time.monotonic() < until:
        data = json.loads((state / 'state.json').read_text())
        if data.get('status') == 'running':
            break
        time.sleep(0.02)
    contending = invoke('concurrent-check')
    assert 'another foreground check' in contending['output']['hookSpecificOutput']['additionalContext']
    time.sleep(0.6)
    target.write_text(source('ff', sleep=1500))
    proc.wait(timeout=10)
    assert proc.returncode == 0, proc.stderr.read()
    qualified = json.loads(proc.stdout.read())
    assert 'changed during' in qualified['hookSpecificOutput']['additionalContext'].lower()
    results.append({'label': 'overlapping-write', 'output': qualified})
    assert invoke('reconcile-superseded', 'check')['record']['status'] == 'passed'
    overlap_acceptance = out / 'overlap_acceptance.exs'
    overlap_acceptance.write_text(acceptance.read_text().replace(':bb', ':ff'))
    checked = subprocess.run(['unbuffer', 'mix', 'run', '--no-compile', str(overlap_acceptance)],
        cwd=root, env=env, capture_output=True, text=True, timeout=20)
    (out / 'overlap-acceptance.log').write_text(checked.stdout + checked.stderr)
    assert checked.returncode == 0

    # SIGTERM while compiling follows the same cleanup and explicit unfinished path.
    target.write_text(source('gg', sleep=8000))
    owned = {}
    proc = subprocess.Popen(base + ['hook'], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                            stderr=subprocess.PIPE, text=True)
    proc.stdin.write(json.dumps(event))
    proc.stdin.close()
    try:
        time.sleep(0.8)
        owned.update(descendants(proc.pid))
        proc.send_signal(signal.SIGTERM)
        proc.wait(timeout=5)
        response = json.loads(proc.stdout.read())
        assert 'unfinished' in response['hookSpecificOutput']['additionalContext'].lower()
        assert not alive(owned), alive(owned)
    finally:
        if proc.poll() is None:
            proc.kill()
            proc.wait()
    results.append({'label': 'interrupted', 'output': response, 'survivors': alive(owned)})
    target.write_text(source('bb'))
    assert invoke('interrupt-repair')['record']['status'] == 'passed'

    # A non-Elixir resource must survive edit, deletion failure, and recreation.
    resource = root / 'answer.txt'
    resource.write_text('aa')
    (root / 'lib/resource.ex').write_text('''defmodule ForegroundResource do
  @external_resource "answer.txt"
  @answer File.read!("answer.txt")
  def answer, do: @answer
end
''')
    assert invoke('resource-created')['record']['status'] == 'passed'
    stamp = resource.stat()
    resource.write_text('bb')
    os.utime(resource, ns=(stamp.st_atime_ns, stamp.st_mtime_ns))
    assert invoke('resource-same-metadata')['record']['status'] == 'passed'
    resource_test = out / 'resource_acceptance.exs'
    resource_test.write_text('''ExUnit.start()

defmodule ForegroundResourceTest do
  use ExUnit.Case, async: true

  test "resource was recompiled despite identical file metadata" do
    assert "bb" = ForegroundResource.answer()
  end
end
''')
    checked = subprocess.run(['unbuffer', 'mix', 'run', '--no-compile', str(resource_test)],
        cwd=root, env=env, capture_output=True, text=True, timeout=20)
    (out / 'resource-acceptance.log').write_text(checked.stdout + checked.stderr)
    assert checked.returncode == 0
    resource.unlink()
    assert invoke('resource-deleted')['record']['status'] == 'failed'
    assert 'answer.txt' in json.loads((state / 'state.json').read_text())['pending']
    resource.write_text('bb')
    assert invoke('resource-recreated')['record']['status'] == 'passed'
    (root / 'tmp').mkdir()
    (root / 'tmp/runtime.exs').write_text('invalid_disposable_fixture()\n')
    assert invoke('ignored-fixture-noise')['output'] == {}
    (root / 'test').mkdir()
    test_file = root / 'test/uncompiled_test.exs'
    test_file.write_text('undefined_test_function()\n')
    test_only = invoke('test-only-edit')
    assert test_only['record']['status'] == 'passed'
    assert 'Tests were not run' in test_only['output']['hookSpecificOutput']['additionalContext']
    test_file.unlink()
    assert invoke('test-only-removal')['record']['status'] == 'passed'
    assert invoke('clean-stop', payload=stop)['output'] == {}
    for task in [['format', '--check-formatted', 'mix.exs', 'lib/target.ex', 'lib/caller.ex',
                  'lib/resource.ex', str(acceptance), str(resource_test), str(overlap_acceptance)],
                 ['compile', '--warnings-as-errors'], ['run', '--no-compile', str(acceptance)]]:
        checked = subprocess.run(['unbuffer', 'mix', *task], cwd=root, env=env,
            capture_output=True, text=True, timeout=20)
        assert checked.returncode == 0, checked.stdout + checked.stderr
    credo = subprocess.run(['unbuffer', 'mix', 'credo', '--strict'], cwd=root, env=env,
        capture_output=True, text=True, timeout=20)
    assert credo.returncode != 0 and 'task "credo" could not be found' in (credo.stdout + credo.stderr).lower()
    results.append({'label': 'final-checks', 'format_compile_exunit_passed': True, 'credo_unavailable': True})
    (out / 'results.json').write_text(json.dumps(results, indent=2) + '\n')


if __name__ == '__main__':
    main()
