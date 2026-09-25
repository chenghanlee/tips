#!/usr/bin/env python3
"""The ElixirLS entry must run the interpreter that `bundle.py serve` verified.

A different `python3` first on PATH (for example macOS /usr/bin/python3 3.9)
must not be used. The shim records any use and fails, so a red run is explicit.
"""
import argparse
import json
import os
from pathlib import Path
import subprocess
import sys

from bundle_probe import BundleMCP
from neovim_probe import poll
from probe import alive, prepare, process_table


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--bundle', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    bundle, output = args.bundle.resolve(), args.output.resolve()
    process_table()
    output.mkdir(parents=True, exist_ok=False)
    sys.path.insert(0, str(bundle / 'vendor/python'))
    root, _, _, _ = prepare(output)
    shim, marker = output / 'shim', output / 'path-python3-used'
    shim.mkdir()
    (shim / 'python3').write_text(f'#!/bin/sh\necho "$*" >> "{marker}"\nexit 97\n')
    (shim / 'python3').chmod(0o755)
    # Only the session under test sees the shim; the fixture was built normally.
    os.environ['PATH'] = str(shim) + os.pathsep + os.environ['PATH']
    results, client = {}, None

    def save(key, value):
        results[key] = value
        (output / 'results.json').write_text(json.dumps(results, indent=2) + '\n')
        print(key, json.dumps(value)[:300], flush=True)

    def ready():
        try:
            return client.rpc().exec_lua("return require('neovim_sync').ready()")
        except Exception as error:  # Red: Neovim quits after ElixirLS fails to start.
            return 'unavailable: ' + type(error).__name__

    def used():
        return marker.read_text().splitlines() if marker.exists() else []

    try:
        client = BundleMCP(bundle, root, output, 'entry')
        environment = json.loads((client.state_dir / 'environment.json').read_text())
        save('serve_python', sys.executable)
        save('v2_python', environment.get('V2_PYTHON'))
        save('ready', poll(ready, lambda v: v is True or isinstance(v, str), 60))
        if results['ready']['matched'] and results['ready']['samples'][-1]['value'] is True:
            hover = client.nav('hover')
            save('hover', hover)
        save('path_python3_used', used())
        client.remember()
        if client.proc.poll() is None:
            client.proc.stdin.close()
            client.proc.wait(timeout=8)
        save('exit', client.proc.returncode)
        save('eof_cleanup', poll(lambda: alive(client.owned), lambda p: not p, 6))
        save('stderr', Path(client.log.name).read_text())
        save('owner_removed', not (client.state_dir / 'owner.json').exists())
        before = used()
        env = {k: v for k, v in os.environ.items() if k != 'V2_PYTHON'}
        missing = subprocess.run([str(bundle / 'elixir-ls')], env=env, stdin=subprocess.DEVNULL,
                                 capture_output=True, text=True, timeout=10)
        save('entry_without_verified_python', {'exit': missing.returncode,
             'stderr': missing.stderr.strip(), 'path_python3_used': used()[len(before):]})
        hover = results.get('hover', {}).get('data', {})
        save('passed', all([
            results['v2_python'] == sys.executable,
            results['ready']['samples'][-1]['value'] is True,
            bool(hover.get('items')),
            results['path_python3_used'] == [],
            results['exit'] == 0,
            results['eof_cleanup']['matched'],
            results['stderr'] == '',
            results['owner_removed'],
            results['entry_without_verified_python']['exit'] != 0,
            'V2_PYTHON' in results['entry_without_verified_python']['stderr'],
            results['entry_without_verified_python']['path_python3_used'] == [],
        ]))
    finally:
        if client:
            client.cleanup()


if __name__ == '__main__':
    main()
