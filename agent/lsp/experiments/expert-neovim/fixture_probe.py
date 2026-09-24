"""Observe the installed server before introducing synchronization workarounds."""
import argparse
import json
from pathlib import Path
import time
import traceback

from probe_support import prepare, process_table
from session import Session, poll


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--sync', action='store_true')
    parser.add_argument('--reindex', action='store_true')
    parser.add_argument('--edit-sync', action='store_true')
    parser.add_argument('--delete-reindex', action='store_true')
    args = parser.parse_args()
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    if (output / 'results.json').exists():
        raise RuntimeError('Choose a fresh output directory; preserved results are never overwritten')
    process_table()
    results, clients = {}, []

    def save(name, value):
        results[name] = value
        (output / 'results.json').write_text(json.dumps(results, indent=2) + '\n')
        print(name, json.dumps(value)[:700], flush=True)

    def contains(text):
        return lambda v: text in json.dumps(v)

    try:
        alpha, beta, a_sha, b_sha = prepare(output)
        save('commits', {'alpha': a_sha, 'beta': b_sha})
        for root in (alpha, beta):
            s = Session(root, output, root.name, {'EXPERT_AUTO_SYNC': '1' if args.sync else '0',
                        'EXPERT_EDIT_SYNC': '1' if args.edit_sync else '0',
                        'EXPERT_REINDEX_ON_DELETE': '1' if args.delete_reindex else '0',
                        'EXPERT_REINDEX_ON_CHANGE': '1' if args.reindex else '0'})
            clients.append(s)
            started = time.monotonic()
            save(root.name + '_first_hover', s.nav('hover'))
            ready = poll(lambda: s.nav('hover'), contains(root.name.upper()), 120)
            save(root.name + '_baseline', ready)
            save(root.name + '_startup_seconds', round(time.monotonic() - started, 3))
            save(root.name + '_state', s.state())
            if not ready['matched']:
                raise RuntimeError('No baseline hover; inspect startup before edit tests')
            save(root.name + '_definition', s.nav('definition'))
            save(root.name + '_references', poll(lambda: s.nav('references', includeDeclaration=False),
                 contains('caller.ex'), 60))
            s.remember()
        a, b = clients
        target, caller = alpha / 'lib/target.ex', alpha / 'lib/caller.ex'
        old_target, old_caller = target.read_text(), caller.read_text()
        save('before_unopened_edit', a.state())
        target.write_text(old_target.replace('ALPHA', 'GAMMA'))
        save('unopened_equal_size_edit', poll(lambda: a.nav('hover'), contains('GAMMA'), 20))
        save('other_worktree_hover', b.nav('hover'))
        temp = target.with_suffix('.replacement')
        temp.write_text(old_target.replace('ALPHA', 'OMEGA'))
        temp.replace(target)
        save('unopened_atomic_replacement', poll(lambda: a.nav('hover'), contains('OMEGA'), 20))
        extra = alpha / 'lib/extra.ex'
        extra.write_text('defmodule V2Extra do\n  def call, do: V2Target.answer()\nend\n')
        save('created_file_references', poll(lambda: a.nav('references', includeDeclaration=False), contains('extra.ex'), 20))
        extra.unlink()
        save('deleted_file_references', poll(lambda: a.nav('references', includeDeclaration=False),
             lambda v: not v['isError'] and not v['data'].get('errors')
             and 'caller.ex' in json.dumps(v) and 'extra.ex' not in json.dumps(v), 20))
        save('deletion_validated', results['created_file_references']['matched']
             and results['deleted_file_references']['matched'])
        # A local undefined call is a compiler error, not only a remote-call warning.
        caller.write_text(old_caller.replace('V2Target.answer()', 'missing()', 1))
        save('external_error', poll(lambda: a.nav('diagnostics'), contains('undefined'), 12))
        save('error_buffer_state', a.state())
        a.rpc().command('checktime')
        save('checktime_control', poll(lambda: a.nav('diagnostics'), contains('undefined'), 8))
        if not results['checktime_control']['matched']:
            a.rpc().exec_lua("local b=vim.fn.bufnr(...); vim.api.nvim_buf_call(b, function() vim.cmd('write') end)", str(caller))
            save('editor_save_control', poll(lambda: a.nav('diagnostics'), contains('undefined'), 8))
        caller.write_text(old_caller)
        save('external_repair', poll(lambda: a.nav('diagnostics'),
             lambda v: 'undefined' not in json.dumps(v), 12))
        a.rpc().command('checktime')
        save('repair_checktime_control', poll(lambda: a.nav('diagnostics'),
             lambda v: 'undefined' not in json.dumps(v), 8))
        save('final_state', a.state())
        if args.sync:
            save('sync_state', a.rpc().exec_lua("local m=require('sync'); return {applied=m.applied, conflicts=m.conflicts, failures=m.failures, reindexes=m.reindexes}"))
        for s in clients:
            save(s.name + '_events', s.events())
        save('alpha_eof', a.close_stdin())
        save('beta_after_alpha_eof', b.nav('hover'))
        save('beta_eof', b.close_stdin())
    except Exception:
        save('exception', traceback.format_exc())
        raise
    finally:
        for s in clients:
            try:
                if s.proc.poll() is None:
                    save(s.name + '_events_at_cleanup', s.events())
            except Exception:
                pass
            s.cleanup()


if __name__ == '__main__':
    main()
