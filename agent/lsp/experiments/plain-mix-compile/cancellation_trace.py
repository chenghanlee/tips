#!/usr/bin/env python3
"""Trace existing five-second cancellation policy; never install a compiler hook."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import time

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'codex-elixirls-v2'))
from probe import alive, descendants


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    root = args.output.resolve()
    (root / 'lib').mkdir(parents=True, exist_ok=False)
    (root / 'mix.exs').write_text('''defmodule CancellationTrace.MixProject do
  use Mix.Project

  def project, do: [app: :cancellation_trace, version: "0.1.0"]
end
''')
    target = root / 'lib/target.ex'
    original = '''defmodule CancellationTarget do
  def answer, do: :ok
end
'''
    target.write_text(original)
    env = os.environ | {'MIX_ENV': 'test', 'ERL_FLAGS': '+S 4:4'}
    command = ['unbuffer', 'mix', 'compile', '--warnings-as-errors']
    baseline = subprocess.run(command, cwd=root, env=env, capture_output=True, text=True, timeout=30)
    assert baseline.returncode == 0, baseline.stdout + baseline.stderr
    target.write_text('''defmodule CancellationTarget do
  File.write!("phases.log", "entered " <> System.pid() <> "\\n", [:append])
  Process.sleep(8000)
  File.write!("phases.log", "finished " <> System.pid() <> "\\n", [:append])
  def answer, do: missing_cancellation_trace()
end
''')
    formatted = subprocess.run(['unbuffer', 'mix', 'format', 'mix.exs', 'lib/target.ex'],
                               cwd=root, env=env, capture_output=True, text=True, timeout=30)
    assert formatted.returncode == 0
    source_digest = hashlib.sha256(target.read_bytes()).hexdigest()
    results = []
    for index, budget in enumerate([4.7, 4.7, 20]):
        owned = {}
        start = time.monotonic()
        times = {}
        polls = []
        with (root / f'attempt-{index}.log').open('w') as log:
            proc = subprocess.Popen(command, cwd=root, env=env, stdout=log,
                                    stderr=subprocess.STDOUT, start_new_session=True)
            try:
                times['spawned'] = time.monotonic() - start
                while proc.poll() is None:
                    check_start = time.monotonic()
                    owned.update(descendants(proc.pid))
                    polls.append(time.monotonic() - check_start)
                    if time.monotonic() - start >= budget:
                        times['deadline_observed'] = time.monotonic() - start
                        break
                    time.sleep(0.04)
            finally:
                if proc.poll() is None:
                    owned.update(descendants(proc.pid))
                    times['final_discovery'] = time.monotonic() - start
                    for sig, label in [(signal.SIGTERM, 'term'), (signal.SIGKILL, 'kill')]:
                        remaining = alive(owned)
                        times[label + '_discovery'] = time.monotonic() - start
                        for pid in remaining:
                            try:
                                os.kill(pid, sig)
                            except ProcessLookupError:
                                pass
                        times[label + '_sent'] = time.monotonic() - start
                        if sig == signal.SIGTERM:
                            time.sleep(0.1)
                proc.wait(timeout=2)
                times['wait_finished'] = time.monotonic() - start
        until = time.monotonic() + 0.2
        while alive(owned) and time.monotonic() < until:
            time.sleep(0.02)
        survivors = alive(owned)
        times['survivors_checked'] = time.monotonic() - start
        phases = (root / 'phases.log').read_text().splitlines()
        output = (root / f'attempt-{index}.log').read_text()
        checkpoint = list((root / '_build/test/lib/cancellation_trace/.mix').glob('*.cp'))
        entry = {'attempt': index + 1, 'budget': budget, 'times': times,
                 'max_process_scan_seconds': max(polls), 'polls': len(polls),
                 'exit_code': proc.returncode, 'survivors': survivors,
                 'compile_phases': phases, 'error_delivered': 'undefined function missing_cancellation_trace/0' in output,
                 'checkpoints': [p.name for p in checkpoint],
                 'source_unchanged': hashlib.sha256(target.read_bytes()).hexdigest() == source_digest}
        results.append(entry)
        (root / 'results.json').write_text(json.dumps(results, indent=2) + '\n')
        print(json.dumps(entry), flush=True)
        assert not survivors and entry['source_unchanged']
        assert len([p for p in phases if p.startswith('entered')]) == index + 1
        if index < 2:
            assert 'deadline_observed' in times and not entry['error_delivered']
            assert not any(p.startswith('finished') for p in phases)
        else:
            assert entry['error_delivered'] and proc.returncode != 0
            assert len([p for p in phases if p.startswith('finished')]) == 1
    target.write_text(original)
    for task in [['format', '--check-formatted', 'mix.exs', 'lib/target.ex'],
                 ['compile', '--warnings-as-errors']]:
        result = subprocess.run(['unbuffer', 'mix', *task], cwd=root, env=env,
                                capture_output=True, text=True, timeout=30)
        assert result.returncode == 0, result.stdout + result.stderr


if __name__ == '__main__':
    main()
