#!/usr/bin/env python3
"""Exercise reviewed feedback composition through the installed MCP (ordinary lsp requests, no hook)."""
import argparse
import json
from pathlib import Path
import sys
import time

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
    target = root / 'lib/target.ex'
    original = target.read_bytes()
    results, client = {}, None

    def save(name, value):
        results[name] = value
        (output / 'results.json').write_text(json.dumps(results, indent=2) + '\n')
        print(name, json.dumps(value)[:800], flush=True)

    def lua(code, *args):
        return client.rpc().exec_lua(code, *args)

    def settle(seconds=20):
        """Ordinary diagnostics request, repeated (labelled bounded retry) until current or failed."""
        deadline = time.monotonic() + seconds
        while True:
            reply = client.call('lsp', operation='diagnostics', uri=str(target))
            data = reply['data']
            feedback = data.get('feedback') or (data.get('error') or {}).get('feedback') or {}
            if feedback.get('status') in ('current', 'failed') or time.monotonic() > deadline:
                return reply
            time.sleep(0.25)

    try:
        client = BundleMCP(bundle, root, output, 'feedback')
        tool = next(tool for tool in client.tools['tools'] if tool['name'] == 'lsp')
        operations = tool['inputSchema']['$defs']['LspOperation']['enum']
        assert set(operations) == {'hover', 'definition', 'references', 'diagnostics',
            'workspace_diagnostics', 'document_symbols', 'workspace_symbols'}, operations
        save('read_only_schema', operations)
        for operation in ('rename_apply', 'code_action_apply', 'fix_document', 'implementation'):
            try:
                response = client.request('tools/call', {'name': 'lsp', 'arguments': {
                    'operation': operation, 'uri': str(target)}})
            except RuntimeError as error:
                response = {'rejected': str(error)}
            save('reject_' + operation, response)
            assert 'unknown variant' in json.dumps(response) or response.get('isError'), response
        assert target.read_bytes() == original
        assert poll(lambda: lua("return require('neovim_sync').ready()"), bool, 20)['matched']
        client.call('lsp', operation='hover', uri=str(target), line=1, character=12)
        # didOpen can publish diagnostics and reset the normal quiet window.
        assert poll(lambda: lua("return require('neovim_sync').ready()"), bool, 5)['matched']
        lua("""
          local b=vim.fn.bufnr(...); local ds={}
          for i=1,9 do ds[#ds+1]={lnum=0,col=0,severity=2,message='warning '..i} end
          ds[#ds+1]={lnum=1,col=0,severity=1,message='THE_COMPILE_ERROR'}
          _G.review_ns=vim.api.nvim_create_namespace('feedback_probe')
          vim.diagnostic.set(_G.review_ns,b,ds)
        """, str(target))
        lua("vim.api.nvim_buf_set_lines(vim.fn.bufnr(...),0,0,false,{'# unsaved edit'})", str(target))
        target.write_bytes(original + b'\n# external edit\n')
        reply = client.call('lsp', operation='diagnostics', uri=str(target))
        save('conflict_cached_diagnostics', reply)
        assert 'error' not in reply['data'], reply
        assert reply['data']['feedback']['status'] == 'conflict', reply
        assert 'THE_COMPILE_ERROR' in json.dumps(reply), reply
        assert target.read_bytes() == original + b'\n# external edit\n'
        assert lua("return vim.bo[vim.fn.bufnr(...)].modified", str(target))
        # Discard only this probe's intentionally unsaved buffer, then test BOM reload.
        lua("vim.diagnostic.reset(_G.review_ns); vim.api.nvim_buf_call(vim.fn.bufnr(...),function() vim.cmd('edit!') end)", str(target))
        settle()
        target.write_bytes(b'\xef\xbb\xbf' + original + b'\n# first BOM\n')
        lua("vim.api.nvim_buf_call(vim.fn.bufnr(...),function() vim.cmd('edit!') end)", str(target))
        settle()
        target.write_bytes(b'\xef\xbb\xbf' + original + b'\n# second BOM\n')
        reply = settle()
        save('bom_diagnostics', reply)
        assert reply['data']['feedback']['status'] == 'failed', reply
        assert 'unexpected token' in json.dumps(reply), reply
        state = lua("return require('neovim_sync').status()")
        save('bom_state', state)
        assert state['status'] == 'failed' and state['completed'] == state['generation'], state
        assert not lua("return next(require('neovim_sync').pending)"), state
        reply = client.call('lsp', operation='hover', uri=str(target), line=3, character=7)
        save('bom_navigation', reply)
        assert reply['data']['feedback']['status'] == 'failed', reply
        assert 'error' not in reply['data'], reply
        target.write_bytes(original)
        reply = settle()
        save('bom_repair', reply)
        assert reply['data']['feedback']['status'] == 'current', reply
        assert lua("return require('neovim_sync').status().status") == 'current'
        client.remember()
        client.proc.stdin.close()
        client.proc.wait(timeout=6)
        assert client.proc.returncode == 0 and not Path(client.log.name).read_text()
        assert not any((client.state_dir / 'registry').glob('*.json'))
        assert not Path(client.instance['socket']).exists()
        assert poll(lambda: alive(client.owned), lambda p: not p, 3)['matched']
        save('passed', True)
    finally:
        target.write_bytes(original)
        if client:
            client.cleanup()


if __name__ == '__main__':
    main()
