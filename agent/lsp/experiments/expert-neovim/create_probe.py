"""Falsify adapter blame: compare disk synchronization with an actual editor save."""
import argparse
import json
from pathlib import Path
import shutil
import time
import uuid

from session import Session, poll
from tips_probe import app_environment


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--via-editor', action='store_true')
    args = parser.parse_args()
    root, output = Path.cwd().resolve(), args.output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    nonce = uuid.uuid4().hex[:10]
    extra = root / f'lib/tips/expert_probe_{nonce}.ex'
    if extra.exists():
        raise RuntimeError('Probe file already exists')
    results = {'via_editor': args.via_editor, 'created_path': str(extra)}

    def save(name, value):
        results[name] = value
        (output / 'results.json').write_text(json.dumps(results, indent=2) + '\n')
        print(name, json.dumps(value)[:300], flush=True)

    client = Session(root, output, 'tips', app_environment(root) | {
        'EXPERT_AUTO_SYNC': '0' if args.via_editor else '1',
        'EXPERT_EDIT_SYNC': '1',
        'EXPERT_REINDEX_ON_CHANGE': '0', 'EXPERT_REINDEX_ON_DELETE': '0',
    })

    def refs():
        return client.nav('references', 'lib/tips/search_probe.ex', line=64,
                          character=58, includeDeclaration=False)

    try:
        save('baseline', poll(refs, lambda v: 'test_helper.exs' in json.dumps(v), 180))
        if not results['baseline']['matched']:
            raise RuntimeError('No baseline references')
        if str(extra) in json.dumps(results['baseline']['samples'][-1]['value']):
            raise RuntimeError('Created path unexpectedly present in baseline')
        client.remember()
        lines = [f'defmodule Tips.ExpertProbe{nonce.upper()} do',
                 '  def mode, do: Tips.ProviderConfig.mode()', 'end']
        if args.via_editor:
            client.rpc().exec_lua('''
              local path, lines = ...
              vim.cmd.edit(vim.fn.fnameescape(path))
              vim.bo.filetype = 'elixir'
              local b = vim.api.nvim_get_current_buf()
              for _, c in ipairs(vim.lsp.get_clients({name='expert'})) do
                vim.lsp.buf_attach_client(b, c.id)
              end
              vim.api.nvim_buf_set_lines(b, 0, -1, false, lines)
              vim.cmd.write()
            ''', str(extra), lines)
        else:
            extra.write_text('\n'.join(lines) + '\n')
        save('created_reference', poll(refs, lambda v: str(extra) in v.get('data', {}).get('locations', {}), 20))
        time.sleep(6)
        save('references_after_settle', refs())
        save('hover_after_create', client.nav('hover', 'lib/tips/search_probe.ex', line=64, character=58))
        save('events', client.events())
        save('eof', client.close_stdin())
    finally:
        client.cleanup()
        extra.unlink(missing_ok=True)
        for name in ('expert.log', 'project.log'):
            source = root / '.expert' / name
            if source.exists():
                shutil.copy(source, output / name)
        save('source_restored', not extra.exists())


if __name__ == '__main__':
    main()
