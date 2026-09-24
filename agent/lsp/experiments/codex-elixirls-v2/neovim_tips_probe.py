#!/usr/bin/env python3
"""Local-only read queries on Tips; no model request and no source edits."""

import argparse
import json
from pathlib import Path
import sys
import time

from neovim_probe import NvimMCP, poll
from probe import alive, process_table


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--vendor', type=Path, required=True)
    parser.add_argument('--workspace', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    vendor, root, output = args.vendor.resolve(), args.workspace.resolve(), args.output.resolve()
    sys.path.insert(0, str(vendor / 'python'))
    process_table()
    output.mkdir(parents=True)
    source = root / 'lib/tips/search_probe.ex'
    lines = source.read_text().splitlines()
    line = next(i+1 for i, text in enumerate(lines) if '&Tips.ProviderConfig.mode/0' in text)
    column = lines[line-1].index('mode/0') + 1
    results = {}

    def save(name, value):
        results[name] = value
        (output / 'results.json').write_text(json.dumps(results, indent=2) + '\n')
        print(name, json.dumps(value)[:400], flush=True)

    client = NvimMCP(vendor, root, output, 'tips', sync_reads=True)
    def query(operation, **extra):
        return client.call('lsp', operation=operation, uri=str(source), line=line,
                           character=column, timeoutMs=10000, **extra)
    try:
        start = time.monotonic()
        save('first_hover', query('hover'))
        save('first_hover_seconds', round(time.monotonic()-start, 3))
        save('hover', poll(lambda: query('hover'),
                           lambda v: 'Tips.ProviderConfig.mode()' in json.dumps(v), 60))
        save('definition', query('definition'))
        save('references', query('references', includeDeclaration=False))
        save('diagnostics', query('diagnostics'))
        save('instances', client.call('list_instances'))
        save('events', client.events())
        client.remember()
        client.proc.stdin.close()
        client.proc.wait(timeout=8)
        save('eof_cleanup', poll(lambda: alive(client.owned), lambda v: not v, 6))
        save('completed', True)
    finally:
        client.cleanup()


if __name__ == '__main__':
    main()
