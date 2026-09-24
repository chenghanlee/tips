#!/usr/bin/env python3
"""Cold preparation and warm feedback on an isolated, disposable Tips checkout."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import sys
import time

HERE = Path(__file__).resolve().parent


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--workspace', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--toolchain', type=Path, required=True)
    parser.add_argument('--dependencies', type=Path, required=True)
    args = parser.parse_args()
    root, out = args.workspace.resolve(), args.output.resolve()
    out.mkdir(parents=True, exist_ok=False)
    assert not (root / '_build').exists(), 'Use a fresh disposable worktree for cold preparation'
    assert subprocess.check_output(['git', 'status', '--porcelain'], cwd=root) == b''
    (root / 'deps').symlink_to(args.dependencies.resolve(), target_is_directory=True)
    target = root / 'lib/tips/health.ex'
    original = target.read_bytes()
    results = []
    base = [sys.executable, str(HERE / 'foreground_mix.py'), '--workspace', str(root),
            '--state', str(out / 'state'), '--toolchain', str(args.toolchain.resolve())]
    payload = json.dumps({'hook_event_name': 'PostToolUse', 'tool_name': 'apply_patch', 'cwd': str(root)})

    def invoke(label, mode='hook'):
        start = time.monotonic()
        proc = subprocess.run(base + [mode], input=payload, capture_output=True, text=True, timeout=210)
        output = json.loads(proc.stdout)
        assert proc.returncode == 0, output
        state = json.loads((out / 'state/result.json').read_text())
        item = {'label': label, 'seconds': time.monotonic() - start, 'output': output, 'record': state}
        results.append(item)
        (out / 'results.json').write_text(json.dumps(results, indent=2) + '\n')
        (out / (label + '.log')).write_text((out / 'state/compile.log').read_text())
        print(label, round(item['seconds'], 3), state['status'], flush=True)
        return item

    env = os.environ | {'MIX_ENV': 'test', 'ERL_FLAGS': '+S 4:4',
        'PATH': str(args.toolchain.resolve() / 'bin') + os.pathsep + os.environ['PATH']}

    def mix(label, task):
        proc = subprocess.run(['unbuffer', 'mix', *task], cwd=root, env=env,
                              capture_output=True, text=True, timeout=90)
        (out / (label + '.log')).write_text(proc.stdout + proc.stderr)
        assert proc.returncode == 0, proc.stdout + proc.stderr

    try:
        assert invoke('cold-prepare', 'prepare')['record']['status'] == 'passed'
        for index in range(3):
            assert invoke(f'unchanged-{index}')['output'] == {}
        for index in range(3):
            assert invoke(f'warm-check-{index}', 'check')['record']['status'] == 'passed'
        alpha = original.replace(b'Checks whether the application can reach its database.', b'Foreground Mix acceptance alpha.')
        assert alpha != original
        target.write_bytes(alpha)
        assert invoke('warm-edit')['record']['status'] == 'passed'
        stamp = target.stat()
        target.write_bytes(alpha.replace(b'alpha.', b'bravo.'))
        os.utime(target, ns=(stamp.st_atime_ns, stamp.st_mtime_ns))
        assert invoke('same-metadata-edit')['record']['status'] == 'passed'
        acceptance = out / 'acceptance.exs'
        acceptance.write_text('''ExUnit.start()

defmodule ForegroundTipsTest do
  use ExUnit.Case, async: true

  test "compiled Tips module contains the latest saved documentation" do
    assert {:docs_v1, _, _, _, %{"en" => "Foreground Mix acceptance bravo."}, _, _} =
             Code.fetch_docs(Tips.Health)
  end
end
''')
        mix('fresh-vm-acceptance', ['run', '--no-compile', '--no-start', str(acceptance)])
        broken = original.replace(b'    repo = Tips.Repo.get_dynamic_repo()', b'    repo = missing_foreground_probe()')
        assert broken != original
        target.write_bytes(broken)
        failed = invoke('warm-error')
        assert failed['record']['status'] == 'failed'
        assert 'missing_foreground_probe/0' in failed['output']['hookSpecificOutput']['additionalContext']
        target.write_bytes(original)
        assert invoke('warm-repair')['record']['status'] == 'passed'
        mix('format', ['format', '--check-formatted', 'lib/tips/health.ex', str(acceptance)])
        mix('compile', ['compile', '--warnings-as-errors'])
        mix('credo', ['credo', '--strict', 'lib/tips/health.ex'])
        results.append({'label': 'checks', 'fresh_vm_exunit_passed': True,
                        'format_compile_credo_passed': True})
        (out / 'results.json').write_text(json.dumps(results, indent=2) + '\n')
    finally:
        target.write_bytes(original)
        assert target.read_bytes() == original


if __name__ == '__main__':
    main()
