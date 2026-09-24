"""Repeat external edit/error/repair tests against real Tips, restoring its source."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import shutil
import time
import uuid

from session import Session, poll


def app_environment(root):
    env = {
        'PGHOST': '127.0.0.1', 'PGPORT': '5433', 'PGUSER': 'postgres', 'PGPASSWORD': 'postgres',
        'TIPS_DB_SUFFIX': '_expert_neovim', 'PORT': '4711', 'TIPS_TEST_PORT': '4712',
        'TIPS_PROVIDER_ENV_FILE': str(root / 'tmp/no-providers.env'),
        'TIPS_REAL_PROVIDERS': '0', 'TIPS_BROWSER': '0', 'ERL_FLAGS': '+S 4:4',
        'MIX_ENV': 'dev', 'MIX_TEST_PARTITION': '',
    }
    for key in ('OPENROUTER_API_KEY CLOUDFLARE_ACCOUNT_ID R2_BUCKET R2_ENDPOINT '
                'R2_ACCESS_KEY_ID R2_SECRET_ACCESS_KEY R2_PUBLIC_URL '
                'CLOUDFLARE_STREAM_API_TOKEN CLOUDFLARE_STREAM_CUSTOMER_CODE '
                'CLOUDFLARE_STREAM_SIGNING_KEY').split():
        env[key] = ''
    return env


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--sync', action='store_true')
    parser.add_argument('--reindex', action='store_true')
    parser.add_argument('--edit-sync', action='store_true')
    parser.add_argument('--delete-reindex', action='store_true')
    parser.add_argument('--check', action='store_true')
    parser.add_argument('--trace-supervisor', action='store_true')
    args = parser.parse_args()
    root, output = Path.cwd().resolve(), args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    if (output / 'results.json').exists():
        raise RuntimeError('Choose a fresh output directory')
    results = {}

    def save(name, value):
        results[name] = value
        (output / 'results.json').write_text(json.dumps(results, indent=2) + '\n')
        print(name, json.dumps(value)[:450], flush=True)

    env = app_environment(root)
    if args.check:
        for name, command, mix_env in [
            ('format', ['unbuffer', 'mix', 'format', '--check-formatted'], 'dev'),
            ('compile', ['unbuffer', 'mix', 'compile', '--warnings-as-errors'], 'dev'),
            ('test', ['unbuffer', 'mix', 'test', 'test/tips/provider_config_test.exs'], 'test'),
            ('credo', ['unbuffer', 'mix', 'credo', '--strict', '--files-included', 'lib/tips/provider_config.ex'], 'dev'),
        ]:
            started = time.monotonic()
            with (output / f'{name}.log').open('w') as log:
                r = subprocess.run(command, cwd=root, env=os.environ | env | {'MIX_ENV': mix_env},
                                   stdout=log, stderr=subprocess.STDOUT, timeout=600)
            save(name, {'exit_code': r.returncode, 'seconds': time.monotonic() - started, 'command': command})
            if r.returncode: raise RuntimeError(f'{name} failed')
        return
    source = root / 'lib/tips/provider_config.ex'
    original = source.read_text()
    nonce = uuid.uuid4().hex[:10]
    extra = root / f'lib/tips/expert_probe_{nonce}.ex'
    if extra.exists(): raise RuntimeError('Probe file already exists')
    save('created_path', str(extra))
    client = Session(root, output, 'tips', env | {'EXPERT_AUTO_SYNC': '1' if args.sync else '0',
                     'EXPERT_EDIT_SYNC': '1' if args.edit_sync else '0',
                     'EXPERT_REINDEX_ON_DELETE': '1' if args.delete_reindex else '0',
                     'EXPERT_REINDEX_ON_CHANGE': '1' if args.reindex else '0'})
    def query(op):
        return client.nav(op, 'lib/tips/search_probe.ex', line=64, character=58,
                          **({'includeDeclaration': False} if op == 'references' else {}))
    def contains(marker): return lambda v: marker in json.dumps(v)
    def healthy(v): return not v.get('isError') and not v.get('data', {}).get('errors')
    try:
        save('first_hover', query('hover'))
        save('baseline_hover', poll(lambda: query('hover'), contains('TIPS_REAL_PROVIDERS'), 180))
        if not results['baseline_hover']['matched']:
            save('events', client.events())
            raise RuntimeError('No baseline hover; inspect startup before editing application source')
        save('state', client.state())
        save('definition', query('definition'))
        save('references', poll(lambda: query('references'), contains('test_helper.exs'), 90))
        client.remember()
        if args.trace_supervisor:
            save('supervisor_trace', client.trace_engine_supervisor(output))
        source.write_text(original.replace('Returns `:real` or `:stub`.', 'EXPERT_TIPS_DOC: Returns `:real` or `:stub`.'))
        save('unopened_doc_edit', poll(lambda: query('hover'), contains('EXPERT_TIPS_DOC'), 15))
        source.write_text(original.replace('def mode, do: :tips', 'def mode, do: expert_probe_missing() |> then(fn _ -> :tips end)'))
        save('compiler_error', poll(lambda: client.nav('diagnostics', 'lib/tips/provider_config.ex'),
             contains('undefined function expert_probe_missing'), 15))
        source.write_text(original)
        save('repair', poll(lambda: client.nav('diagnostics', 'lib/tips/provider_config.ex'),
             lambda v: healthy(v) and 'expert_probe_missing' not in json.dumps(v), 15))
        save('repair_validated', results['compiler_error']['matched'] and results['repair']['matched'])
        extra.write_text(f'defmodule Tips.ExpertProbe{nonce.upper()} do\n  def mode, do: Tips.ProviderConfig.mode()\nend\n')
        save('created_reference', poll(lambda: query('references'),
             lambda v: healthy(v) and str(extra) in v.get('data', {}).get('locations', {}), 15))
        extra.unlink()
        save('deleted_reference', poll(lambda: query('references'),
             lambda v: healthy(v) and 'test_helper.exs' in json.dumps(v)
             and str(extra) not in json.dumps(v), 15))
        save('deletion_validated', results['created_reference']['matched'] and results['deleted_reference']['matched'])
        save('events', client.events())
        if args.sync:
            save('sync_state', client.rpc().exec_lua("local m=require('sync'); return {applied=m.applied, conflicts=m.conflicts, failures=m.failures, reindexes=m.reindexes}"))
        save('eof', client.close_stdin())
    finally:
        source.write_text(original)
        extra.unlink(missing_ok=True)
        client.cleanup()
        for name in ('expert.log', 'project.log'):
            log = root / '.expert' / name
            if log.exists(): shutil.copy(log, output / name)
        save('source_restored', source.read_text() == original)


if __name__ == '__main__':
    main()
