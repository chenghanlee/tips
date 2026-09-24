#!/usr/bin/env python3
"""Compare plain-Mix feedback policies against the declared long-build contract.

This is a disposable experiment, not an installed hook. Cancellation observes and
reaps the whole test-owned process tree; a timeout never masquerades as success.
"""
import argparse
import json
import os
from pathlib import Path
import signal
import subprocess
import time

from probe import alive, descendants, prepare


def main():
    p = argparse.ArgumentParser()
    p.add_argument('--output', type=Path, required=True)
    p.add_argument('--tips-workspace', type=Path, required=True)
    p.add_argument('--deadlines-only', action='store_true')
    args = p.parse_args()
    output, tips = args.output.resolve(), args.tips_workspace.resolve()
    output.mkdir(parents=True, exist_ok=False)
    results = {}
    env = os.environ | {'MIX_ENV': 'test', 'ERL_FLAGS': '+S 4:4'}

    def invoke(label, root, seconds=120, cancel=False, task=None):
        command = ['unbuffer', 'mix', *(task or ['compile', '--warnings-as-errors'])]
        owned, timed_out = {}, False
        start = time.monotonic()
        with (output / f'{label}.log').open('w') as log:
            proc = subprocess.Popen(command, cwd=root, env=env, stdout=log,
                                    stderr=subprocess.STDOUT, start_new_session=True)
            try:
                while proc.poll() is None:
                    owned.update(descendants(proc.pid))
                    if time.monotonic() - start >= seconds:
                        timed_out = True
                        break
                    time.sleep(0.04)
            finally:
                if proc.poll() is None:
                    owned.update(descendants(proc.pid))
                if timed_out:
                    for sig in (signal.SIGTERM, signal.SIGKILL):
                        for pid in alive(owned):
                            try:
                                os.kill(pid, sig)
                            except ProcessLookupError:
                                pass
                        if sig == signal.SIGTERM:
                            time.sleep(0.1)
                proc.wait(timeout=2)
        # Reap/check before allowing the next simulated agent edit.
        deadline = time.monotonic() + 0.2
        while alive(owned) and time.monotonic() < deadline:
            time.sleep(0.02)
        result = {'command': command, 'seconds': time.monotonic() - start,
            'timed_out': timed_out, 'exit_code': proc.returncode,
            'survivors': alive(owned), 'cancellation_policy': cancel}
        results[label] = result
        (output / 'results.json').write_text(json.dumps(results, indent=2) + '\n')
        print(label, json.dumps(result), flush=True)
        assert not result['survivors'], result
        assert cancel or not timed_out, result
        return result

    if not args.deadlines_only:
        # Independent warmed-Tips measurements, with the cold preparation reported separately.
        results['tips_build_existed_before_preparation'] = (tips / '_build/test/lib/tips/ebin').exists()
        baseline = invoke('tips_preparation', tips, seconds=180)
        assert baseline['exit_code'] == 0, baseline
        for index in range(3):
            assert invoke(f'tips_warm_noop_{index}', tips)['exit_code'] == 0
        target = tips / 'lib/tips/provider_config.ex'
        original = target.read_text()
        try:
            target.write_text(original.replace('defmodule Tips.ProviderConfig do',
                'defmodule Tips.ProviderConfig do\n  # Plain-Mix feedback timing control.'))
            assert invoke('tips_one_source_edit', tips)['exit_code'] == 0
            target.write_text(original.replace('defmodule Tips.ProviderConfig do',
                'defmodule Tips.ProviderConfig do\n  def feedback_probe, do: missing_plain_feedback()'))
            failed = invoke('tips_compiler_error', tips)
            assert failed['exit_code'] != 0
            assert 'missing_plain_feedback/0' in (output / 'tips_compiler_error.log').read_text()
        finally:
            target.write_text(original)
        assert invoke('tips_repair', tips)['exit_code'] == 0
        assert invoke('tips_format', tips, task=['format', '--check-formatted', str(target)])['exit_code'] == 0
        assert invoke('tips_credo', tips, task=['credo', '--strict', '--files-included', str(target)])['exit_code'] == 0

    # A real compile-time operation longer than the budget, using a dependency-free project.
    fixture = output / 'fixture'
    fixture.mkdir()
    root, _, _, _ = prepare(fixture)
    path = root / 'lib/target.ex'
    original = path.read_text()
    assert invoke('fixture_baseline', root)['exit_code'] == 0
    slow = original.replace('defmodule V2Target do',
        'defmodule V2Target do\n  Process.sleep(8000)').replace('def answer, do: :alpha',
        'def answer, do: missing_deadline_probe()')
    assert slow != original and 'missing_deadline_probe' in slow
    path.write_text(slow)
    for index in range(2):
        result = invoke(f'cancel_at_budget_{index}', root, seconds=4.7, cancel=True)
        assert result['timed_out'] and result['seconds'] < 5.1, result
        assert 'undefined function missing_deadline_probe' not in (
            output / f'cancel_at_budget_{index}.log').read_text()
    # Same source and same incremental cache: waiting is able to produce the error.
    completed = invoke('wait_to_completion', root, seconds=30)
    assert completed['exit_code'] != 0 and completed['seconds'] > 8
    assert 'missing_deadline_probe/0' in (output / 'wait_to_completion.log').read_text()
    path.write_text(original)
    assert invoke('repair_after_cancellation', root)['exit_code'] == 0
    acceptance = root / 'acceptance.exs'
    acceptance.write_text('''ExUnit.start()

defmodule FeedbackAcceptanceTest do
  use ExUnit.Case, async: true

  test "repaired target and caller execute correctly" do
    assert :alpha = V2Target.answer()
    assert :alpha = V2Caller.call_1()
  end
end
''')
    assert invoke('fixture_format', root, task=['format', '--check-formatted',
        'lib/target.ex', 'lib/caller.ex', 'acceptance.exs'])['exit_code'] == 0
    assert invoke('fresh_vm_acceptance', root, task=['run', '--no-compile', 'acceptance.exs'])['exit_code'] == 0
    credo = invoke('fixture_credo', root, task=['credo', '--strict'])
    assert credo['exit_code'] != 0 and 'task "credo" could not be found' in (
        output / 'fixture_credo.log').read_text().lower()
    results['conclusion'] = {'warm_tips_feedback_checked_in_this_run': not args.deadlines_only,
        'repeated_cancellation_never_delivered_the_slow_error': True,
        'waiting_delivered_error_but_exceeded_feedback_budget': True,
        'normal_incremental_repair_after_cancellation': True,
        'fixture_credo_unavailable': True}
    (output / 'results.json').write_text(json.dumps(results, indent=2) + '\n')


if __name__ == '__main__':
    main()
