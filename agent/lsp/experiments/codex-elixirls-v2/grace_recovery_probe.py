#!/usr/bin/env python3
"""Exercise a real ElixirLS against the proposed grace-window recovery rule.

Uses the retained protocol client. Generated ExUnit acceptance tests read the
server's compiled artifacts in a fresh VM; they do not compile or repair them.
"""
import argparse
import json
import os
from pathlib import Path
import re
import subprocess
import threading
import time

from inversion_probe import LSP


class Client(LSP):
    def __init__(self, root, output, source):
        self.root, self.messages, self.responses = root, [], {}
        self.condition, self.write_lock = threading.Condition(), threading.Lock()
        self.counter = 0
        self.stderr = (output / 'server.stderr.log').open('wb')
        self.transcript = (output / 'protocol.jsonl').open('w')
        env = os.environ | {'ERL_FLAGS': '+S 4:4'}
        if source:
            env |= {'ELS_LOCAL': '1', 'ELS_INSTALL_PREFIX': str(source / 'scripts'),
                    'MIX_INSTALL_DIR': str(source.parent / 'install-cache'),
                    'HEX_HOME': str(source.parent / 'hex-home')}
        self.proc = subprocess.Popen(['/opt/homebrew/bin/elixir-ls'], cwd=root, env=env,
                                     stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                     stderr=self.stderr, start_new_session=True)
        threading.Thread(target=self.read, daemon=True).start()

    def hover(self):
        return self.request('textDocument/hover', {
            'textDocument': {'uri': (self.root / 'lib/query.ex').as_uri()},
            'position': {'line': 1, 'character': 27},
        })

    def marker(self, marker, since):
        return self.wait_for(lambda m: m.get('method') == 'window/logMessage'
                             and f'GRACE_{marker}_STARTED' in m.get('params', {}).get('message', ''),
                             since=since)


def source_text(marker, slow=True):
    return f'''defmodule GraceTarget do
  IO.puts("GRACE_{marker}_STARTED")
  Process.sleep({1500 if slow else 0})
  @doc "{marker} documentation."
  def answer, do: :{marker}
end
'''


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--server-source', type=Path)
    parser.add_argument('--case', choices=['overlap', 'recovery-edit', 'late-300', 'late-2000',
                                          'ordinary', 'revert'], required=True)
    args = parser.parse_args()
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    root = output / 'fixture'
    (root / 'lib').mkdir(parents=True)
    (root / 'mix.exs').write_text('''defmodule Grace.MixProject do
  use Mix.Project
  def project, do: [app: :grace_probe, version: "0.1.0", elixir: "~> 1.20"]
end
''')
    (root / 'lib/caller.ex').write_text('''defmodule GraceCaller do
  @answer GraceTarget.answer()
  def answer, do: @answer
end
''')
    (root / 'lib/query.ex').write_text('''defmodule GraceQuery do
  def call, do: GraceTarget.answer()
end
''')
    target = root / 'lib/target.ex'
    target.write_text(source_text('zz', slow=False))
    # Written before applying the candidate patch: acceptance is saved-source
    # behavior, including a compile-time dependent, not an internal flag.
    (root / 'acceptance.exs').write_text('''ExUnit.start()

defmodule GraceAcceptanceTest do
  use ExUnit.Case, async: true

  test "target matches saved source" do
    assert Atom.to_string(GraceTarget.answer()) == System.fetch_env!("GRACE_EXPECTED")
  end

  test "compile-time caller matches saved source" do
    assert Atom.to_string(GraceCaller.answer()) == System.fetch_env!("GRACE_EXPECTED")
  end
end
''')
    (root / 'inspect.exs').write_text('''IO.puts(
  "GRACE_JSON " <>
    JSON.encode!(%{target: GraceTarget.answer(), caller: GraceCaller.answer()})
)
''')
    commands, events = [], []
    env = os.environ | {'ERL_FLAGS': '+S 4:4', 'MIX_ENV': 'test',
                       'MIX_BUILD_PATH': str(root / '.elixir_ls/build/test')}

    def run(label, *args, extra=None):
        command = ['unbuffer', 'mix', *args]
        proc = subprocess.run(command, cwd=root, env=env | (extra or {}),
                              text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                              timeout=30)
        (output / f'{label}.log').write_text(proc.stdout)
        commands.append({'label': label, 'argv': command, 'exit': proc.returncode})
        return proc

    assert run('format', 'format', 'mix.exs', 'lib/caller.ex', 'lib/query.ex',
               'lib/target.ex', 'acceptance.exs', 'inspect.exs').returncode == 0
    client = Client(root, output, args.server_source.resolve() if args.server_source else None)
    result = {'case': args.case, 'server_source': str(args.server_source), 'commands': commands,
              'events': events}
    try:
        client.request('initialize', {
            'processId': os.getpid(), 'rootUri': root.as_uri(),
            'capabilities': {'workspace': {'configuration': True,
                             'didChangeWatchedFiles': {'dynamicRegistration': True}},
                             'textDocument': {'hover': {'contentFormat': ['markdown']}}},
            'workspaceFolders': [{'uri': root.as_uri(), 'name': 'grace'}],
        }, timeout=180)
        client.notify('initialized', {})
        client.open(root / 'lib/query.ex')
        client.build(0)
        time.sleep(1.3)  # Ordinary first edit is outside the startup grace window.
        result['baseline_hover'] = client.hover()
        assert 'zz documentation' in json.dumps(result['baseline_hover'])
        mark = len(client.messages)

        def write(marker, notify=True, slow=True):
            target.write_text(source_text(marker, slow))
            events.append({'event': 'write', 'marker': marker, 'time': time.monotonic()})
            if notify:
                client.changed(target)
                events.append({'event': 'notify', 'marker': marker, 'time': time.monotonic()})

        if args.case == 'ordinary':
            for marker in ['d0', 'd1', 'd2', 'd3', 'd4', 'd5', 'd6', 'd7', 'd8', 'd9']:
                start = len(client.messages)
                write(marker, slow=False)
                client.build(start)
                time.sleep(1.3)  # Gap measured from completion, not edit start.
            expected = 'd9'
        else:
            write('aa')
            client.marker('aa', mark)
            time.sleep(0.6)
            write('bb', notify=args.case not in ('late-300', 'late-2000'))
            first = client.build(mark)
            if args.case.startswith('late-'):
                time.sleep(int(args.case.split('-')[1]) / 1000)
                client.changed(target)
                events.append({'event': 'delayed-notify', 'time': time.monotonic()})
            if args.case in ('recovery-edit', 'revert'):
                client.marker('bb', first[0] + 1)
                time.sleep(0.6)
                write('cc' if args.case == 'recovery-edit' else 'aa')
            second = client.build(first[0] + 1)
            if args.case in ('recovery-edit', 'revert'):
                client.build(second[0] + 1)
            expected = {'recovery-edit': 'cc', 'revert': 'aa'}.get(args.case, 'bb')

        # Detect autonomous rebuild loops after the expected work completes.
        end = len(client.messages)
        time.sleep(1.3 if args.case == 'ordinary' else 5)
        result['unexpected_builds_after_settle'] = sum(
            e['message'].get('method') == 'telemetry/event'
            and e['message'].get('params', {}).get('name') == 'build'
            for e in client.messages[end:])
        result['hover'] = client.hover()
        result['hover_fresh'] = f'{expected} documentation' in json.dumps(result['hover'])
        result['expected'] = expected
        inspection = run('inspect', 'run', '--no-start', '--no-compile', 'inspect.exs')
        if inspection.returncode == 0:
            result['behavior'] = json.loads(next(line.removeprefix('GRACE_JSON ')
                for line in inspection.stdout.splitlines() if line.startswith('GRACE_JSON ')))
        acceptance = run('acceptance', 'run', '--no-start', '--no-compile', 'acceptance.exs',
                         extra={'GRACE_EXPECTED': expected})
        result['acceptance_exit'] = acceptance.returncode
        result['builds'] = [e for e in client.messages if e['message'].get('method') == 'telemetry/event'
                            and e['message'].get('params', {}).get('name') == 'build']
        result['compile_markers'] = [e for e in client.messages if e['message'].get('method') == 'window/logMessage'
                                     and 'GRACE_' in e['message'].get('params', {}).get('message', '')]
        result['compiled_file_counts_after_startup'] = [int(match.group(1))
            for e in client.messages[mark:]
            if (match := re.search(r'Compiling (\d+) files? \(\.ex\)',
                                   e['message'].get('params', {}).get('message', '')))]
        if args.case == 'ordinary':
            result['incremental_preserved'] = result['compiled_file_counts_after_startup'] == [2] * 10
        result['passed'] = (result['hover_fresh'] and acceptance.returncode == 0
                            and result['unexpected_builds_after_settle'] == 0
                            and result.get('incremental_preserved', True))
    finally:
        client.stop()
        result['server_exit'] = client.proc.returncode
        (output / 'results.json').write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps({k: result.get(k) for k in ['case', 'passed', 'hover_fresh', 'behavior',
                                               'acceptance_exit', 'server_exit']}), flush=True)
    raise SystemExit(0 if result.get('passed') else 1)


if __name__ == '__main__':
    main()
