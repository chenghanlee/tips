#!/usr/bin/env python3
"""Cold Tips startup and termination while actual dependency compilation runs."""
import argparse
import json
from pathlib import Path
import sys
import time

from bundle_probe import BundleMCP
from neovim_probe import poll
from probe import alive


def main():
    p = argparse.ArgumentParser()
    p.add_argument('--bundle', type=Path, required=True)
    p.add_argument('--workspace', type=Path, required=True)
    p.add_argument('--output', type=Path, required=True)
    args = p.parse_args()
    bundle, root, output = args.bundle.resolve(), args.workspace.resolve(), args.output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    sys.path.insert(0, str(bundle / 'vendor/python'))
    assert not (root / '.elixir_ls').exists(), 'Use a worktree with a cold ElixirLS build'
    client, result = None, {}
    try:
        start = time.monotonic()
        client = BundleMCP(bundle, root, output, 'tips')
        result['initialize_seconds'] = time.monotonic() - start
        result['cold_symbols'] = client.call('lsp', operation='document_symbols',
            uri=str(root / 'lib/tips/provider_config.ex'), timeoutMs=1000)
        rpc = client.rpc()
        started = poll(lambda: rpc.exec_lua("return require('neovim_sync').status()"),
                       lambda x: x['building'], 15)
        result['build_started'] = started
        assert result['initialize_seconds'] < 5, result
        assert started['matched'], result
        assert result['cold_symbols']['data']['feedback']['status'] in {'pending', 'unavailable'}
        client.remember()
        start = time.monotonic()
        client.proc.stdin.close()
        client.proc.wait(timeout=6)
        result['cleanup'] = poll(lambda: alive(client.owned), lambda x: not x, 4)
        result['shutdown_seconds'] = time.monotonic() - start
        assert result['cleanup']['matched'], result
        result['passed'] = True
    finally:
        if client:
            client.cleanup()
        (output / 'results.json').write_text(json.dumps(result, indent=2) + '\n')
        print(json.dumps(result, indent=2))


if __name__ == '__main__':
    main()
